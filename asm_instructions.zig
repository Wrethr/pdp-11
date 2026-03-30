const std = @import("std");

pub const AddressingMode = enum(u3) {
    Register = 0,
    Deferred = 1,
    AutoInc = 2,
    AutoDec = 4,
    Indexed = 6,
    // Режимы 3, 5, 7 - отложены
    _,
};

pub const Register = enum(u3) {
    R0,
    R1,
    R2,
    R3,
    R4,
    R5,
    SP, // Указатель стека
    PC, // Счетчик команд
};

pub const Operand = packed struct(u6) {
    mode: AddressingMode,
    reg: Register,
};

// Потом больше асм инструкций
pub const Opcode = enum(u4) {
    MOV = 0o01,
    ADD = 0o06,
    SUB = 0o16,
    _,
};

pub const Instruction = packed struct(u16) {
    opcode: Opcode,
    src: Operand,
    dst: Operand,
};

pub fn decode(raw_instruction: u16) Instruction {
    return @bitCast(raw_instruction);
}
