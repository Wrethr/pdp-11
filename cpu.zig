const std = @import("std");
const asmins = @import("asmInstructions.zig");
const memory = @import("memory.zig");

/// Processor status word bits (PDP-11 layout).
pub const PSW_C: u16 = 0o000001;
pub const PSW_V: u16 = 0o000002;
pub const PSW_Z: u16 = 0o000004;
pub const PSW_N: u16 = 0o000010;
pub const PSW_T: u16 = 0o000020;

/// DL11 console output buffer (UNIBUS address).
const TTY_BUF: u16 = 0o177566;

pub const Cpu = struct {
    PSW: u16 = 0,
    registers: [8]u16 = @splat(0),
    mem: *memory.Memory = undefined,
    halted: bool = false,

    const Self = @This();

    pub fn init(mem_ptr: *memory.Memory) Self {
        var regs: [8]u16 = @splat(0);
        regs[6] = 0xFFFE;
        return .{ .mem = mem_ptr, .registers = regs };
    }

    fn setNZ(self: *Self, result: u16, sign_bit: u16) void {
        self.PSW &= ~(PSW_N | PSW_Z);
        if (result == 0) self.PSW |= PSW_Z;
        if (result & sign_bit != 0) self.PSW |= PSW_N;
    }

    fn setV(self: *Self, v: bool) void {
        if (v) self.PSW |= PSW_V else self.PSW &= ~PSW_V;
    }

    fn setC(self: *Self, c: bool) void {
        if (c) self.PSW |= PSW_C else self.PSW &= ~PSW_C;
    }

    fn carry(self: *Self) u16 {
        return if (self.PSW & PSW_C != 0) 1 else 0;
    }

    /// Effective address of an operand, with addressing-mode side effects
    /// (autoincrement/autodecrement, index-word fetch) already applied.
    /// Deferred modes return the pointer value loaded from memory.
    const Ea = union(enum) {
        reg: u3,
        mem: u16,
    };

    fn operandEA(self: *Self, op: asmins.Operand, byte: bool) Ea {
        const reg_idx = op.reg;
        const r = self.registers[reg_idx];
        switch (op.mode) {
            0 => return .{ .reg = reg_idx },
            1 => return .{ .mem = r },
            2 => {
                const incr: u16 = if (byte and reg_idx != 7) 1 else 2;
                self.registers[reg_idx] = r +% incr;
                return .{ .mem = r };
            },
            3 => {
                self.registers[reg_idx] = r +% 2;
                return .{ .mem = self.mem.readWord(r) };
            },
            4 => {
                const decr: u16 = if (byte and reg_idx != 7) 1 else 2;
                self.registers[reg_idx] = r -% decr;
                return .{ .mem = self.registers[reg_idx] };
            },
            5 => {
                self.registers[reg_idx] = r -% 2;
                return .{ .mem = self.mem.readWord(self.registers[reg_idx]) };
            },
            6 => {
                const x = self.mem.readWord(self.registers[7]);
                self.registers[7] +%= 2;
                // The base is read after the index word is fetched; required
                // for PC-relative addressing.
                return .{ .mem = self.registers[reg_idx] +% x };
            },
            7 => {
                const x = self.mem.readWord(self.registers[7]);
                self.registers[7] +%= 2;
                return .{ .mem = self.mem.readWord(self.registers[reg_idx] +% x) };
            },
        }
    }

    fn readOperand(self: *Self, ea: Ea, byte: bool) u16 {
        switch (ea) {
            .reg => |r| {
                if (byte and r < 6) return self.registers[r] & 0xFF;
                return self.registers[r];
            },
            .mem => |a| {
                if (byte) return self.mem.readByte(a);
                return self.mem.readWord(a);
            },
        }
    }

    fn writeOperand(self: *Self, ea: Ea, byte: bool, value: u16) void {
        switch (ea) {
            .reg => |r| {
                if (byte and r < 6) {
                    self.registers[r] = (self.registers[r] & 0xFF00) | (value & 0xFF);
                } else {
                    self.registers[r] = value;
                }
            },
            .mem => |a| {
                if (byte) {
                    self.mem.writeByte(a, @truncate(value));
                } else {
                    self.mem.writeWord(a, value);
                }
                if (a == TTY_BUF) {
                    const ch: u8 = @truncate(value);
                    if (ch == 10 or (ch >= 0x20 and ch < 0x7F)) {
                        std.debug.print("{c}", .{ch});
                    }
                }
            },
        }
    }

    /// Jump target for JSR/JMP: the effective address itself, except for
    /// deferred modes where the pointer value loaded from memory is used.
    fn jumpTarget(self: *Self, op: asmins.Operand, byte: bool) u16 {
        const ea = self.operandEA(op, byte);
        return switch (ea) {
            .reg => |r| self.registers[r],
            .mem => |a| a,
        };
    }

    fn overflowAdd(a: u16, b: u16, r: u16, sign: u16) bool {
        return (~(a ^ b) & (a ^ r)) & sign != 0;
    }

    fn overflowSub(a: u16, b: u16, r: u16, sign: u16) bool {
        return ((a ^ b) & (a ^ r)) & sign != 0;
    }

    pub fn step(self: *Self, inst: asmins.Instruction) void {
        switch (inst) {
            .halt => self.halted = true,

            .double => |d| self.execDouble(d.op, d.src, d.dst, false),
            .double_byte => |d| self.execDoubleByte(d.op, d.src, d.dst),

            .single => |s| self.execSingle(s.op, s.dst, s.byte),

            .branch => |b| {
                if (branchCondition(b.op, self.PSW)) {
                    const ext: u16 = @bitCast(@as(i16, b.offset));
                    self.registers[7] +%= ext *% 2;
                }
            },

            .jmp => |dst| {
                self.registers[7] = self.jumpTarget(dst, false);
            },

            .jsr => |j| {
                const target = self.jumpTarget(j.dst, false);
                self.registers[6] -%= 2;
                self.mem.writeWord(self.registers[6], self.registers[j.reg]);
                self.registers[j.reg] = self.registers[7];
                self.registers[7] = target;
            },

            .rts => |reg| {
                self.registers[7] = self.registers[reg];
                self.registers[reg] = self.mem.readWord(self.registers[6]);
                self.registers[6] +%= 2;
            },

            .sob => |s| {
                self.registers[s.reg] -%= 1;
                if (self.registers[s.reg] != 0) {
                    self.registers[7] -%= @as(u16, s.offset) * 2;
                }
            },
        }
    }

    fn execDouble(self: *Self, op: asmins.DoubleOp, src_op: asmins.Operand, dst_op: asmins.Operand, byte: bool) void {
        const m: u16 = if (byte) 0xFF else 0xFFFF;
        const sign: u16 = if (byte) 0x80 else 0x8000;

        // The source is evaluated (with addressing side effects) before the
        // destination, as on real hardware.
        const src_ea = self.operandEA(src_op, byte);
        const src_val = self.readOperand(src_ea, byte);
        const dst_ea = self.operandEA(dst_op, byte);

        switch (op) {
            .MOV => {
                if (byte) {
                    const b: u16 = src_val & 0xFF;
                    switch (dst_ea) {
                        .reg => |r| {
                            if (r < 6) {
                                self.registers[r] = if (b & 0x80 != 0) 0xFF00 | b else b;
                            } else {
                                self.writeOperand(dst_ea, true, b);
                            }
                        },
                        .mem => self.writeOperand(dst_ea, true, b),
                    }
                    self.setNZ(b, 0x80);
                } else {
                    self.writeOperand(dst_ea, false, src_val);
                    self.setNZ(src_val, 0x8000);
                }
                self.setV(false);
                self.setC(false);
            },
            .CMP => {
                const a = src_val & m;
                const dst_val = self.readOperand(dst_ea, byte) & m;
                const result = dst_val -% a;
                self.setNZ(result & m, sign);
                self.setC(dst_val < a);
                self.setV(overflowSub(dst_val, a, result, sign));
            },
            .BIT => {
                const dst_val = self.readOperand(dst_ea, byte) & m;
                const result = (src_val & dst_val) & m;
                self.setNZ(result, sign);
                self.setV(false);
            },
            .BIC => {
                const dst_val = self.readOperand(dst_ea, byte) & m;
                const result = dst_val & ~src_val & m;
                self.writeOperand(dst_ea, byte, result);
                self.setNZ(result, sign);
                self.setV(false);
            },
            .BIS => {
                const dst_val = self.readOperand(dst_ea, byte) & m;
                const result = dst_val | (src_val & m);
                self.writeOperand(dst_ea, byte, result);
                self.setNZ(result, sign);
                self.setV(false);
            },
            .ADD => {
                const dst_val = self.readOperand(dst_ea, false);
                const sum: u32 = @as(u32, dst_val) + @as(u32, src_val);
                const result: u16 = @truncate(sum);
                self.writeOperand(dst_ea, false, result);
                self.setNZ(result, 0x8000);
                self.setC(sum > 0xFFFF);
                self.setV(overflowAdd(dst_val, src_val, result, 0x8000));
            },
            .SUB => {
                const dst_val = self.readOperand(dst_ea, false);
                const result = dst_val -% src_val;
                self.writeOperand(dst_ea, false, result);
                self.setNZ(result, 0x8000);
                self.setC(dst_val < src_val);
                self.setV(overflowSub(dst_val, src_val, result, 0x8000));
            },
        }
    }

    fn execDoubleByte(self: *Self, op: asmins.DoubleByteOp, src_op: asmins.Operand, dst_op: asmins.Operand) void {
        const word_op: asmins.DoubleOp = switch (op) {
            .MOVB => .MOV,
            .BITB => .BIT,
            .CMPB => .CMP,
            .BICB => .BIC,
            .BISB => .BIS,
        };
        self.execDouble(word_op, src_op, dst_op, true);
    }

    fn execSingle(self: *Self, op: asmins.SingleOp, dst_op: asmins.Operand, byte: bool) void {
        const m: u16 = if (byte) 0xFF else 0xFFFF;
        const sign: u16 = if (byte) 0x80 else 0x8000;
        const shift_top: u4 = if (byte) 7 else 15;

        const ea = self.operandEA(dst_op, byte);
        const val = self.readOperand(ea, byte) & m;

        switch (op) {
            .CLR => {
                self.writeOperand(ea, byte, 0);
                self.setNZ(0, sign);
                self.setV(false);
                self.setC(false);
            },
            .COM => {
                const r = ~val & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(false);
                self.setC(true);
            },
            .INC => {
                const r = (val +% 1) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(val == sign - 1);
            },
            .DEC => {
                const r = (val -% 1) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(val == sign);
            },
            .NEG => {
                const r = (0 -% val) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(val == sign);
                self.setC(r != 0);
            },
            .ADC => {
                const c = self.carry();
                const r = (val +% c) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(val == sign - 1 and c == 1);
                self.setC(val == m and c == 1);
            },
            .SBC => {
                const c = self.carry();
                const r = (val -% c) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                self.setV(val == sign and c == 1);
                self.setC(val == 0 and c == 1);
            },
            .TST => {
                self.setNZ(val, sign);
                self.setV(false);
                self.setC(false);
            },
            .ROR => {
                const c_old = self.carry();
                const r = ((val >> 1) | (c_old << shift_top)) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                const c_new = val & 1 != 0;
                self.setC(c_new);
                self.setV((r & sign != 0) != c_new);
            },
            .ROL => {
                const c_old = self.carry();
                const r = ((val << 1) | c_old) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                const c_new = (val >> shift_top) & 1 != 0;
                self.setC(c_new);
                self.setV((r & sign != 0) != c_new);
            },
            .ASR => {
                const r = ((val >> 1) | (val & sign)) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                const c_new = val & 1 != 0;
                self.setC(c_new);
                self.setV((r & sign != 0) != c_new);
            },
            .ASL => {
                const r = (val << 1) & m;
                self.writeOperand(ea, byte, r);
                self.setNZ(r, sign);
                const c_new = (val >> shift_top) & 1 != 0;
                self.setC(c_new);
                self.setV((r & sign != 0) != c_new);
            },
            .SXT => {
                // Real SXT is word-only: the high byte is set from bit 7 of
                // the operand's low byte.
                const r: u16 = if (val & 0x80 != 0) 0xFF00 else 0x0000;
                self.writeOperand(ea, false, r);
                self.setNZ(r, 0x8000);
                self.setV(false);
            },
        }
    }

    fn branchCondition(op: asmins.BranchOp, psw: u16) bool {
        const c = psw & PSW_C != 0;
        const v = psw & PSW_V != 0;
        const z = psw & PSW_Z != 0;
        const n = psw & PSW_N != 0;
        return switch (op) {
            .BR => true,
            .BNE => !z,
            .BEQ => z,
            .BGE => n == v,
            .BLT => n != v,
            .BGT => (n == v) and !z,
            .BLE => (n != v) or z,
            .BPL => !n,
            .BMI => n,
            .BHI => !c and !z,
            .BLOS => c or z,
            .BVC => !v,
            .BVS => v,
            .BCC => !c,
            .BCS => c,
        };
    }

    /// Fetches and executes instructions until HALT (word 0) or an error.
    pub fn run(self: *Self) void {
        while (!self.halted) {
            const pc = self.registers[7];
            if (pc & 1 != 0) {
                std.debug.print("CPU error: odd PC {o:0>6} at fetch\n", .{pc});
                self.halted = true;
                break;
            }
            const raw = self.mem.readWord(pc);
            self.registers[7] = pc +% 2;
            if (raw == 0) {
                self.halted = true;
                break;
            }
            const inst = asmins.decode(raw) catch {
                std.debug.print("CPU error: illegal instruction {o:0>6} at {o:0>6}\n", .{ raw, pc });
                self.halted = true;
                break;
            };
            self.step(inst);
        }
    }
};
