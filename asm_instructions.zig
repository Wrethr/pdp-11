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
    reg: Register,
    mode: AddressingMode,
};

pub const Opcode = enum(u8) {
    // Двухоперандные (старшие 4 бита)
    MOV = 0o01,
    CMP = 0o02,
    BIC = 0o04,
    BIS = 0o05,
    ADD = 0o06,
    SUB = 0o16,

    // Однооперандные (старшие 8 бит, вторые 4 бита = 5)
    CLR = 0o50,
    COM = 0o51,
    INC = 0o52,
    DEC = 0o53,
    NEG = 0o54,
    ADC = 0o55,
    SBC = 0o56,
    TST = 0o57,
    ROR = 0o60,
    ROL = 0o61,
    ASR = 0o62,
    ASL = 0o63,
    SXT = 0o67,

    // Ветвления (старшие 8 бит)
    BR = 0o04,
    BNE = 0o10,
    BEQ = 0o14,
    BGE = 0o20,
    BLT = 0o24,
    BGT = 0o30,
    BLE = 0o34,

    // Управление
    JMP = 0o01,
    JSR = 0o41,
    RTS = 0o20,
    SOB = 0o77,

    _,
};

pub fn getOpcode(raw: u16) Opcode {
    // Сдвигаем на 8 бит вправо, оставляя старшие 8 бит
    // @intCast нужен, так как u16 >> 8 дает u16, а нам нужен u8 для enum
    return @intCast(raw >> 8);
}

pub const Instruction = packed struct(u16) {
    dst: Operand,
    src: Operand,
    opcode: Opcode,
};

pub fn decode(raw_instruction: u16) Instruction {
    return @bitCast(raw_instruction);
}
