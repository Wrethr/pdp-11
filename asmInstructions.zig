const std = @import("std");

pub const AddressingMode = enum(u3) {
    Register = 0,
    Deferred = 1,
    AutoInc = 2,
    AutoIncDeferred = 3,
    AutoDec = 4,
    AutoDecDeferred = 5,
    Indexed = 6,
    IndexedDeferred = 7,
};

pub const Register = enum(u3) {
    R0,
    R1,
    R2,
    R3,
    R4,
    R5,
    SP,
    PC,
};

pub const Operand = packed struct(u6) {
    reg: Register, // младшие 3 бита
    mode: AddressingMode, // старшие 3 бита
};

pub const DoubleOpCode = enum(u4) { MOV = 0o01, CMP = 0o02, BIC = 0o04, BIS = 0o05, ADD = 0o06, SUB = 0o16, _ };
pub const SingleOpCode = enum(u8) { CLR = 0o50, COM = 0o51, INC = 0o52, DEC = 0o53, NEG = 0o54, ADC = 0o55, SBC = 0o56, TST = 0o57, ROR = 0o60, ROL = 0o61, ASR = 0o62, ASL = 0o63, SXT = 0o67, _ };
pub const BranchCode = enum(u8) { BR = 0o04, BNE = 0o10, BEQ = 0o14, BGE = 0o20, BLT = 0o24, BGT = 0o30, BLE = 0o34, _ };
pub const ControlCode = enum(u8) { JMP = 0o01, JSR = 0o41, RTS = 0o20, SOB = 0o77, _ };

pub const Instruction = struct {
    data: union(enum) {
        DoubleOp: DoubleOpCode,
        SingleOp: SingleOpCode,
        Branch: BranchCode,
        Control: ControlCode,
    },
    src: ?Operand = null,
    dst: ?Operand = null,
    offset: ?i8 = null,
    extra_reg: ?Register = null,
};

fn extractOperand(raw: u16, shift: u4) Operand {
    const masked = (raw >> shift) & 0o77;
    return @bitCast(@as(u6, @truncate(masked)));
}

pub fn decode(raw: u16) Instruction {
    const high4: u4 = @intCast(raw >> 12);
    const high8: u8 = @intCast(raw >> 8);

    if (high8 >= 0o050 and high8 <= 0o067) {
        return .{ .data = .{ .SingleOp = @enumFromInt(high8) }, .dst = extractOperand(raw, 0) };
    }

    if (high4 == 0 and raw != 0) {
        return .{ .data = .{ .Branch = @enumFromInt(high8) }, .offset = @bitCast(@as(u8, @truncate(raw))) };
    }

    // Проверяем управление
    if (high4 == 0o1) {
        // JSR: high8 == 0o041
        if (high8 == 0o041) {
            const reg_bits: u3 = @truncate(raw >> 9);
            return .{ .data = .{ .Control = .JSR }, .extra_reg = @enumFromInt(reg_bits), .dst = extractOperand(raw, 0) };
        }
        // JMP: dst_mode (bits 9-11) != 0, bits 0-2 = 0
        if ((raw & 0o77) == 0 and (raw >> 9) & 0o7 != 0) {
            return .{ .data = .{ .Control = .JMP }, .dst = extractOperand(raw, 0) };
        }
    }
    // RTS: high8 == 0o020, bits 0-5 should be 0
    if (high8 == 0o020 and (raw & 0o77) == 0) {
        const reg_bits: u3 = @truncate(raw >> 6);
        return .{ .data = .{ .Control = .RTS }, .extra_reg = @enumFromInt(reg_bits) };
    }
    // SOB: high8 == 0o077
    if (high8 == 0o077) {
        const reg_bits: u3 = @truncate(raw >> 6);
        return .{ .data = .{ .Control = .SOB }, .extra_reg = @enumFromInt(reg_bits), .offset = @bitCast(@as(u8, @truncate(raw)) << 2) };
    }

    return .{
        .data = .{ .DoubleOp = @enumFromInt(high4) },
        .src = extractOperand(raw, 0),
        .dst = extractOperand(raw, 6),
    };
}

