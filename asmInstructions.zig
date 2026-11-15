const std = @import("std");

/// Operand field: addressing mode in bits 5-3, register number in bits 2-0.
pub const Operand = packed struct(u6) {
    reg: u3,
    mode: u3,
};

/// Two-operand instructions occupying bits 15-12. ADD and SUB exist only in
/// the word variant.
pub const DoubleOp = enum(u4) {
    MOV = 0o01,
    CMP = 0o02,
    BIT = 0o03,
    BIC = 0o04,
    BIS = 0o05,
    ADD = 0o06,
    SUB = 0o16,
};

/// Byte variants of the two-operand instructions (bits 15-12). ADD and SUB
/// have no byte form.
pub const DoubleByteOp = enum(u4) {
    MOVB = 0o11,
    BITB = 0o12,
    CMPB = 0o13,
    BICB = 0o14,
    BISB = 0o15,
};

/// One-operand instructions occupying bits 15-6; bit 15 selects the byte
/// variant. MARK/MFPI/MTPI (0o64-0o66) are intentionally absent.
pub const SingleOp = enum(u6) {
    CLR = 0o050,
    COM = 0o051,
    INC = 0o052,
    DEC = 0o053,
    NEG = 0o054,
    ADC = 0o055,
    SBC = 0o056,
    TST = 0o057,
    ROR = 0o060,
    ROL = 0o061,
    ASR = 0o062,
    ASL = 0o063,
    SXT = 0o067,
};

/// Branch instructions occupying bits 15-8. The offset in bits 7-0 is signed
/// and counted in words (PC += 2 * offset).
pub const BranchOp = enum(u8) {
    BR = 0o001,
    BNE = 0o002,
    BEQ = 0o003,
    BGE = 0o004,
    BLT = 0o005,
    BGT = 0o006,
    BLE = 0o007,
    BPL = 0o201,
    BMI = 0o202,
    BHI = 0o203,
    BLOS = 0o204,
    BVC = 0o205,
    BVS = 0o206,
    BCC = 0o207,
    BCS = 0o210,
};

pub const Instruction = union(enum) {
    halt,
    double: struct { op: DoubleOp, src: Operand, dst: Operand },
    double_byte: struct { op: DoubleByteOp, src: Operand, dst: Operand },
    single: struct { op: SingleOp, dst: Operand, byte: bool },
    branch: struct { op: BranchOp, offset: i8 },
    jmp: Operand,
    jsr: struct { reg: u3, dst: Operand },
    rts: u3,
    sob: struct { reg: u3, offset: u6 },
};

pub const DecodeError = error{IllegalInstruction};

fn srcOperand(raw: u16) Operand {
    return @bitCast(@as(u6, @truncate(raw >> 6)));
}

fn dstOperand(raw: u16) Operand {
    return @bitCast(@as(u6, @truncate(raw)));
}

/// Decodes a raw 16-bit instruction word into a typed instruction.
pub fn decode(raw: u16) DecodeError!Instruction {
    if (raw == 0) return .halt;

    const high4: u4 = @intCast(raw >> 12);
    const high8: u8 = @intCast(raw >> 8);
    const op10: u10 = @intCast(raw >> 6);

    // JMP: bits 15-6 = 0o0001, destination in bits 5-0 (raw 0x0040-0x007F).
    if (op10 == 0o0001) {
        return .{ .jmp = dstOperand(raw) };
    }

    // RTS: 0o020R, register in bits 2-0 (raw 0x0080-0x0087).
    if (raw >= 0x0080 and raw <= 0x0087) {
        return .{ .rts = @truncate(raw) };
    }

    // Branches: opcode in bits 15-8.
    if ((high8 >= 0o001 and high8 <= 0o007) or (high8 >= 0o201 and high8 <= 0o210)) {
        const op: BranchOp = @enumFromInt(high8);
        const offset: i8 = @bitCast(@as(u8, @truncate(raw)));
        return .{ .branch = .{ .op = op, .offset = offset } };
    }

    // JSR: bits 15-12 = 0, bits 11-9 = 0b100, register in bits 8-6,
    // destination in bits 5-0.
    if (high4 == 0 and (raw & 0x0E00) == 0x0800) {
        return .{ .jsr = .{ .reg = @truncate(raw >> 6), .dst = dstOperand(raw) } };
    }

    // SOB: bits 15-9 = 0o077 (raw 0x7E00-0x7FFF), register in bits 8-6,
    // 6-bit offset in bits 5-0.
    if (raw & 0xFE00 == 0x7E00) {
        return .{ .sob = .{ .reg = @truncate(raw >> 6), .offset = @truncate(raw) } };
    }

    // One-operand instructions: word 0o0050-0o0067, byte 0o1050-0o1067.
    if (op10 >= 0o0050 and op10 <= 0o0067) {
        const code = op10 & 0o77;
        if (code >= 0o064 and code <= 0o066) return error.IllegalInstruction;
        return .{ .single = .{ .op = @enumFromInt(code), .dst = dstOperand(raw), .byte = false } };
    }
    if (op10 >= 0o1050 and op10 <= 0o1067) {
        const code = op10 & 0o77;
        if (code >= 0o064 and code <= 0o066) return error.IllegalInstruction;
        return .{ .single = .{ .op = @enumFromInt(code), .dst = dstOperand(raw), .byte = true } };
    }

    // Two-operand instructions: word bits 15-12 = 0o01-0o06 and 0o16,
    // byte = 0o11-0o15.
    if (high4 >= @intFromEnum(DoubleOp.MOV) and high4 <= @intFromEnum(DoubleOp.ADD)) {
        return .{ .double = .{ .op = @enumFromInt(high4), .src = srcOperand(raw), .dst = dstOperand(raw) } };
    }
    if (high4 == @intFromEnum(DoubleOp.SUB)) {
        return .{ .double = .{ .op = .SUB, .src = srcOperand(raw), .dst = dstOperand(raw) } };
    }
    if (high4 >= @intFromEnum(DoubleByteOp.MOVB) and high4 <= @intFromEnum(DoubleByteOp.BISB)) {
        return .{ .double_byte = .{ .op = @enumFromInt(high4), .src = srcOperand(raw), .dst = dstOperand(raw) } };
    }

    return error.IllegalInstruction;
}
