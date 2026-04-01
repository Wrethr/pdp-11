const asmins = @import("asmInstructions.zig");
const memory = @import("memory.zig");

const std = @import("std");

pub const Cpu = struct {
    /// Psw register
    PSW: u16 = 0,
    /// Registers
    registers: [8]u16 = [_]u16{0} ** 8,
    /// memory
    mem: *memory.Memory = undefined,

    const Self = @This();

    const Addressator = struct {
        cpu: *Cpu,

        fn get(self: Addressator, op: asmins.Operand) u16 {
            const reg_idx = @intFromEnum(op.reg);

            switch (op.mode) {
                .Register => {
                    return self.cpu.registers[reg_idx];
                },
                .AutoInc => {
                    const addr = self.cpu.registers[reg_idx];
                    self.cpu.registers[reg_idx] += 2;
                    return self.cpu.mem.readWord(addr);
                },
                else => {
                    return 0;
                },
            }
        }

        fn set(self: Addressator, op: asmins.Operand, value: u16) void {
            const reg_idx = @intFromEnum(op.reg);

            switch (op.mode) {
                .Register => {
                    self.cpu.registers[reg_idx] = value;
                },
                else => {},
            }
        }
    };

    pub fn init(mem_ptr: *memory.Memory) Self {
        var regs = [_]u16{0} ** 8;
        regs[6] = 0xFFFE;

        return .{
            .mem = mem_ptr,
            .registers = regs,
        };
    }

    pub fn run(self: *Self) void {
        while (true) {
            const raw_instruction = self.mem.readWord(self.registers[7]);
            self.registers[7] += 2;

            if (raw_instruction == 0) break;

            // Узнаем опкод по старшим битам
            const opcode = asmins.getOpcode(raw_instruction);

            self.execute(opcode, raw_instruction);
        }
    }

    fn execute(self: *Self, opcode: asmins.Opcode, raw: u16) void {
        const addr = Addressator{ .cpu = self };

        switch (opcode) {
            .MOV, .ADD, .SUB => {
                // формат: [4 бит:код][6 бит:src][6 бит:dst]
                const src = getOperandFromRaw(raw, 0); // биты с 0 по 5
                const dst = getOperandFromRaw(raw, 6); // биты с 6 по 11

                const src_val = addr.get(src);
                const dst_val = if (opcode == .MOV) 0 else addr.get(dst);

                const result = switch (opcode) {
                    .MOV => src_val,
                    .ADD => dst_val + src_val,
                    .SUB => dst_val - src_val,
                    else => unreachable,
                };

                addr.set(dst, result);
            },
            else => {
                // позже...
            },
        }
    }

    fn getOperandFromRaw(raw: u16, shift_in_bits: u4) asmins.Operand {
        const shifted = raw >> shift_in_bits;
        const masked = shifted & 0o77;

        return @bitCast(@as(u6, @truncate(masked)));
    }
};
