const asmins = @import("asmInstructions.zig");
const memory = @import("memory.zig");

pub const Cpu = struct {
    PSW: u16 = 0,
    registers: [8]u16 = [_]u16{0} ** 8,
    mem: *memory.Memory = undefined,

    const Self = @This();

    fn updateFlagsNZ(self: *Self, result: u16) void {
        self.PSW &= ~(@as(u16, 0o14));
        if (result == 0) self.PSW |= 0o4;
        if (result & 0x8000 != 0) self.PSW |= 0o10;
    }

    pub const Addressator = struct {
        cpu: *Self,

        fn get(self: Addressator, op: asmins.Operand) u16 {
            const reg_idx = @intFromEnum(op.reg);
            switch (op.mode) {
                .Register => return self.cpu.registers[reg_idx],
                .AutoInc => {
                    const addr = self.cpu.registers[reg_idx];
                    self.cpu.registers[reg_idx] +%= 2;
                    return self.cpu.mem.readWord(addr);
                },
                .AutoDec => {
                    self.cpu.registers[reg_idx] -%= 2;
                    return self.cpu.mem.readWord(self.cpu.registers[reg_idx]);
                },
                .Deferred => return self.cpu.mem.readWord(self.cpu.registers[reg_idx]),
                else => return 0,
            }
        }

        fn set(self: Addressator, op: asmins.Operand, value: u16) void {
            const reg_idx = @intFromEnum(op.reg);
            switch (op.mode) {
                .Register => self.cpu.registers[reg_idx] = value,
                .AutoDec => {
                    self.cpu.registers[reg_idx] -%= 2;
                    self.cpu.mem.writeWord(self.cpu.registers[reg_idx], value);
                },
                .Deferred => self.cpu.mem.writeWord(self.cpu.registers[reg_idx], value),
                else => {},
            }
        }

        fn getAddress(self: Addressator, op: asmins.Operand) u16 {
            const reg_idx = @intFromEnum(op.reg);
            switch (op.mode) {
                .Deferred => return self.cpu.registers[reg_idx],
                .AutoInc => {
                    const addr = self.cpu.registers[reg_idx];
                    self.cpu.registers[reg_idx] +%= 2;
                    return addr;
                },
                else => return reg_idx * 2,
            }
        }
    };

    pub const Executor = struct {
        cpu: *Self,

        fn execute(self: Executor, inst: asmins.Instruction) void {
            const addr = Addressator{ .cpu = self.cpu };

            switch (inst.data) {
                .DoubleOp => |op| {
                    const src_val = addr.get(inst.src.?);
                    const dst_op = inst.dst.?;
                    const result: u16 = switch (op) {
                        .MOV => src_val,
                        .ADD => addr.get(dst_op) + src_val,
                        .SUB => addr.get(dst_op) - src_val,
                        .CMP => addr.get(dst_op) - src_val,
                        .BIC => addr.get(dst_op) & ~src_val,
                        .BIS => addr.get(dst_op) | src_val,
                        else => unreachable,
                    };
                    if (op != .CMP) addr.set(dst_op, result);
                    self.cpu.updateFlagsNZ(result);
                },

                .SingleOp => |op| {
                    const dst_op = inst.dst.?;
                    const val = addr.get(dst_op);
                    const result: u16 = switch (op) {
                        .CLR => 0,
                        .COM => ~val,
                        .INC => val + 1,
                        .DEC => val - 1,
                        .NEG => 0 -% val,
                        .TST => val,
                        .ADC => val + 1,
                        .SBC => val - 1,
                        .ROR => (val >> 1) | (val << 15),
                        .ROL => (val << 1) | (val >> 15),
                        .ASR => @bitCast(@as(i16, @bitCast(val)) >> 1),
                        .ASL => val << 1,
                        .SXT => if (val & 0x80 != 0) 0xFF00 else 0x0000,
                        else => unreachable,
                    };
                    if (op != .TST) addr.set(dst_op, result);
                    self.cpu.updateFlagsNZ(result);
                },

                .Branch => |op| {
                    const do_branch: bool = switch (op) {
                        .BR => true,
                        .BNE => (self.cpu.PSW & 0o4) == 0,
                        .BEQ => (self.cpu.PSW & 0o4) != 0,
                        else => true,
                    };
                    if (do_branch) {
                        if (inst.offset) |off| {
                            self.cpu.registers[7] +|= @as(u16, @bitCast(@as(i16, off)));
                        }
                    }
                },

                .Control => |op| {
                    switch (op) {
                        .JMP => self.cpu.registers[7] = addr.getAddress(inst.dst.?),
                        .JSR => {
                            const reg_idx = @intFromEnum(inst.extra_reg.?);
                            self.cpu.registers[reg_idx] = self.cpu.registers[7];
                            self.cpu.registers[7] = addr.getAddress(inst.dst.?);
                        },
                        .RTS => {
                            const reg_idx = @intFromEnum(inst.extra_reg.?);
                            self.cpu.registers[7] = self.cpu.registers[reg_idx];
                            const sp_op = asmins.Operand{ .reg = .SP, .mode = .AutoInc };
                            self.cpu.registers[reg_idx] = addr.get(sp_op);
                        },
                        .SOB => {
                            const reg_idx = @intFromEnum(inst.extra_reg.?);
                            self.cpu.registers[reg_idx] -= 1;
                            if (self.cpu.registers[reg_idx] != 0) {
                                if (inst.offset) |off| self.cpu.registers[7] -|= @as(u16, @bitCast(@as(i16, off)));
                            }
                        },
                        else => {},
                    }
                },
            }
        }
    };

    pub fn init(mem_ptr: *memory.Memory) Self {
        var regs = [_]u16{0} ** 8;
        regs[6] = 0xFFFE;
        return .{ .mem = mem_ptr, .registers = regs };
    }

    pub fn run(self: *Self) void {
        const executor = Executor{ .cpu = self };
        while (true) {
            const raw_instruction = self.mem.readWord(self.registers[7]);
            self.registers[7] += 2;
            if (raw_instruction == 0) break;
            const inst = asmins.decode(raw_instruction);
            executor.execute(inst);
        }
    }
};
