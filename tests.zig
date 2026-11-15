const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");
const asmins = @import("asmInstructions.zig");

const PSW_C = cpu.PSW_C;
const PSW_V = cpu.PSW_V;
const PSW_Z = cpu.PSW_Z;
const PSW_N = cpu.PSW_N;

fn assembleDoubleOp(opcode: u4, src: u6, dst: u6) u16 {
    return (@as(u16, opcode) << 12) | (@as(u16, src) << 6) | @as(u16, dst);
}

fn assembleSingleOp(opcode: u10, dst: u6) u16 {
    return (@as(u16, opcode) << 6) | @as(u16, dst);
}

fn assembleBranch(opcode: u8, offset: i8) u16 {
    return (@as(u16, opcode) << 8) | (@as(u16, @bitCast(@as(i16, offset))) & 0xFF);
}

/// Immediate addressing: mode 2 through R7, literal stored in the next word.
fn immOp() u6 {
    return 0o27;
}

test "MOV R1, R2" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, 0o01, 0o02));
    ram.writeWord(2, 0);

    proc.registers[1] = 1234;
    proc.run();

    try std.testing.expectEqual(@as(u16, 1234), proc.registers[2]);
    try std.testing.expectEqual(@as(u16, 1234), proc.registers[1]);
}

test "ADD flags" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o06, immOp(), 0o02)); // ADD #0o100000, R2
    ram.writeWord(2, 0o100000);
    ram.writeWord(4, assembleDoubleOp(0o06, immOp(), 0o02)); // ADD #1, R2
    ram.writeWord(6, 1);
    ram.writeWord(8, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0o100001), proc.registers[2]);
    try std.testing.expect(PSW_N & proc.PSW != 0);
    try std.testing.expectEqual(@as(u16, 0), proc.PSW & (PSW_C | PSW_V));
}

test "ADD sets carry" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o06, immOp(), 0o02)); // ADD #0xFFFF, R2
    ram.writeWord(2, 0xFFFF);
    ram.writeWord(4, assembleDoubleOp(0o06, immOp(), 0o02)); // ADD #1, R2
    ram.writeWord(6, 1);
    ram.writeWord(8, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0), proc.registers[2]);
    try std.testing.expect(PSW_C & proc.PSW != 0);
    try std.testing.expect(PSW_Z & proc.PSW != 0);
}

test "SUB sets carry on borrow" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, immOp(), 0o01)); // MOV #5, R1
    ram.writeWord(2, 5);
    ram.writeWord(4, assembleDoubleOp(0o01, immOp(), 0o02)); // MOV #3, R2
    ram.writeWord(6, 3);
    ram.writeWord(8, assembleDoubleOp(0o16, 0o01, 0o02)); // SUB R1, R2
    ram.writeWord(10, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0xFFFE), proc.registers[2]);
    try std.testing.expect(PSW_C & proc.PSW != 0);
    try std.testing.expect(PSW_N & proc.PSW != 0);
}

test "BEQ branch taken" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleSingleOp(0o057, 0o00)); // TST R0 (Z=1)
    ram.writeWord(2, assembleBranch(0o003, 1)); // BEQ +1 word, skips the MOV
    ram.writeWord(4, assembleDoubleOp(0o01, 0o01, 0o02)); // MOV R1, R2
    ram.writeWord(6, assembleSingleOp(0o052, 0o02)); // INC R2
    ram.writeWord(8, 0);

    proc.registers[0] = 0;
    proc.registers[2] = 0;
    proc.run();

    try std.testing.expectEqual(@as(u16, 1), proc.registers[2]);
}

test "BNE branch not taken" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleSingleOp(0o057, 0o00)); // TST R0 (Z=1)
    ram.writeWord(2, assembleBranch(0o002, 1)); // BNE +1, not taken
    ram.writeWord(4, assembleDoubleOp(0o01, 0o01, 0o02)); // MOV R1, R2
    ram.writeWord(6, assembleSingleOp(0o052, 0o02)); // INC R2
    ram.writeWord(8, 0);

    proc.registers[0] = 0;
    proc.registers[1] = 5;
    proc.registers[2] = 0;
    proc.run();

    try std.testing.expectEqual(@as(u16, 6), proc.registers[2]);
}

test "immediate and indexed addressing" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, immOp(), 0o00)); // MOV #0o1000, R0
    ram.writeWord(2, 0o1000);
    ram.writeWord(4, assembleDoubleOp(0o01, immOp(), 0o01)); // MOV #0o2000, R1
    ram.writeWord(6, 0o2000);
    ram.writeWord(8, assembleDoubleOp(0o01, 0o01, 0o60)); // MOV R1, 100(R0)
    ram.writeWord(10, 100);
    ram.writeWord(12, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0o2000), ram.readWord(0o1000 + 100));
    try std.testing.expectEqual(@as(u16, 14), proc.registers[7]);
}

test "autoincrement deferred reads pointer" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, immOp(), 0o01)); // MOV #0o100, R1
    ram.writeWord(2, 0o100);
    ram.writeWord(4, assembleDoubleOp(0o01, immOp(), 0o02)); // MOV #0o777, R2
    ram.writeWord(6, 0o777);
    ram.writeWord(8, assembleDoubleOp(0o01, 0o02, 0o31)); // MOV R2, @(R1)+
    ram.writeWord(10, 0);

    ram.writeWord(0o100, 0o300);
    proc.run();

    try std.testing.expectEqual(@as(u16, 0o777), ram.readWord(0o300));
    try std.testing.expectEqual(@as(u16, 0o102), proc.registers[1]);
}

test "JSR/RTS call and return" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, 0o004567); // JSR R5, sub (PC-relative)
    ram.writeWord(2, 4); // target = 4 + 4 = 8
    ram.writeWord(4, assembleSingleOp(0o052, 0o02)); // INC R2 (after return)
    ram.writeWord(6, 0); // HALT
    ram.writeWord(8, assembleSingleOp(0o052, 0o02)); // sub: INC R2
    ram.writeWord(10, 0o000205); // RTS R5

    proc.registers[2] = 0;
    proc.run();

    try std.testing.expectEqual(@as(u16, 2), proc.registers[2]);
    try std.testing.expectEqual(@as(u16, 0), proc.registers[5]);
    try std.testing.expectEqual(@as(u16, 0xFFFE), proc.registers[6]);
    try std.testing.expectEqual(@as(u16, 8), proc.registers[7]);
}

test "SOB loop" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, 0o012703); // MOV #3, R3
    ram.writeWord(2, 3);
    ram.writeWord(4, assembleSingleOp(0o052, 0o02)); // INC R2
    ram.writeWord(6, 0o077302); // SOB R3, -2 bytes
    ram.writeWord(8, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 3), proc.registers[2]);
    try std.testing.expectEqual(@as(u16, 0), proc.registers[3]);
}

test "INC sets V on overflow" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, 0o012702); // MOV #0o077777, R2
    ram.writeWord(2, 0o077777);
    ram.writeWord(4, assembleSingleOp(0o052, 0o02)); // INC R2
    ram.writeWord(6, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0o100000), proc.registers[2]);
    try std.testing.expect(PSW_V & proc.PSW != 0);
    try std.testing.expect(PSW_N & proc.PSW != 0);
}

test "NEG keeps C unless result is zero" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, 0o012702); // MOV #0o100000, R2
    ram.writeWord(2, 0o100000);
    ram.writeWord(4, assembleSingleOp(0o054, 0o02)); // NEG R2
    ram.writeWord(6, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0o100000), proc.registers[2]);
    try std.testing.expect(PSW_V & proc.PSW != 0);
    try std.testing.expect(PSW_C & proc.PSW != 0);
}

test "MOVB to register sign-extends" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o11, immOp(), 0o01)); // MOVB #0o377, R1
    ram.writeWord(2, 0o377);
    ram.writeWord(4, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0xFFFF), proc.registers[1]);
}

test "byte INC preserves high register byte" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    proc.registers[1] = 0xFFFF;
    ram.writeWord(0, 0o105201); // INCB R1
    ram.writeWord(2, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0xFF00), proc.registers[1]);
    try std.testing.expect(PSW_Z & proc.PSW != 0);
}

test "CMP does not modify operands" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, immOp(), 0o01)); // MOV #10, R1
    ram.writeWord(2, 10);
    ram.writeWord(4, assembleDoubleOp(0o01, immOp(), 0o02)); // MOV #20, R2
    ram.writeWord(6, 20);
    ram.writeWord(8, assembleDoubleOp(0o02, 0o01, 0o02)); // CMP R1, R2
    ram.writeWord(10, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 10), proc.registers[1]);
    try std.testing.expectEqual(@as(u16, 20), proc.registers[2]);
    try std.testing.expectEqual(@as(u16, 0), proc.PSW & (PSW_N | PSW_C));
}

test "autodecrement destination writes once" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    proc.registers[6] = 0o200;
    ram.writeWord(0, assembleDoubleOp(0o01, immOp(), 0o00)); // MOV #55, R0
    ram.writeWord(2, 55);
    ram.writeWord(4, assembleDoubleOp(0o01, 0o00, 0o46)); // MOV R0, -(R6)
    ram.writeWord(6, 0);

    proc.run();

    try std.testing.expectEqual(@as(u16, 0o176), proc.registers[6]);
    try std.testing.expectEqual(@as(u16, 55), ram.readWord(0o176));
}

test "illegal instruction stops execution" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, 0o000004);
    ram.writeWord(2, 0);

    proc.run();

    try std.testing.expect(proc.halted);
    try std.testing.expectEqual(@as(u16, 2), proc.registers[7]);
}

test "data in memory is not executed" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    const hello = "Hello World!";
    for (hello, 0..) |byte, i| {
        ram.ram[0o200 + i] = byte;
    }
    ram.writeWord(0, 0);

    proc.run();

    try std.testing.expectEqual(@as(u8, 'H'), ram.ram[0o200]);
    try std.testing.expectEqual(@as(u8, 'W'), ram.ram[0o206]);
    try std.testing.expectEqual(@as(u8, '!'), ram.ram[0o213]);
    try std.testing.expect(proc.halted);
}
