const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");
const ioFiler = @import("ioFiler.zig");
const asmins = @import("asmInstructions.zig");

fn assembleDoubleOp(opcode: u4, src_mode: u3, src_reg: u3, dst_mode: u3, dst_reg: u3) u16 {
    return (@as(u16, opcode) << 12) |
        (@as(u16, dst_mode) << 9) | (@as(u16, dst_reg) << 6) |
        (@as(u16, src_mode) << 3) | @as(u16, src_reg);
}

fn assembleSingleOp(opcode: u8, dst_mode: u3, dst_reg: u3) u16 {
    return (@as(u16, opcode) << 8) | (@as(u16, dst_mode) << 3) | @as(u16, dst_reg);
}

fn assembleBranch(opcode: u8, offset: u8) u16 {
    return (@as(u16, opcode) << 8) | @as(u16, offset);
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Usage: pdp11 <file.bin> | test\n", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: pdp11 <file.bin> | test\n", .{});
        std.debug.print("  <file.bin> - загрузить и выполнить бинарный файл\n", .{});
        std.debug.print("  test       - запустить все тесты\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "test")) {
        std.debug.print("Running tests...\n", .{});
        return;
    }

    const filename = args[1];
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ioFiler.loadBinary(allocator, filename, &ram) catch {
        std.debug.print("Error: could not load file: {s}\n", .{filename});
        return;
    };

    proc.run();

    std.debug.print("Execution complete. PC = {o}\n", .{proc.registers[7]});
}

test "MOV and ADD instructions" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleDoubleOp(0o01, 0, 1, 0, 2)); // MOV R1, R2
    ram.writeWord(2, 0); // HALT

    proc.registers[1] = 1234;
    proc.run();

    try std.testing.expectEqual(proc.registers[2], 1234);
}

test "BEQ branch taken" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleSingleOp(0o057, 0, 0)); // TST R0 (Z=1)
    ram.writeWord(2, assembleBranch(0o014, 2)); // BEQ +2
    ram.writeWord(4, assembleDoubleOp(0o01, 0, 1, 0, 2)); // MOV R1, R2 (пропустится)
    ram.writeWord(6, assembleSingleOp(0o052, 0, 2)); // INC R2
    ram.writeWord(8, 0); // HALT

    proc.registers[0] = 0;
    proc.registers[2] = 0;
    proc.run();

    try std.testing.expectEqual(proc.registers[2], 1);
}

test "BNE branch not taken" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    ram.writeWord(0, assembleSingleOp(0o057, 0, 0)); // TST R0 (Z=1 since R0=0)
    ram.writeWord(2, assembleBranch(0o010, 2)); // BNE +2 (не перейдет)
    ram.writeWord(4, assembleDoubleOp(0o01, 0, 1, 0, 2)); // MOV R1, R2 (выполнится)
    ram.writeWord(6, assembleSingleOp(0o052, 0, 2)); // INC R2
    ram.writeWord(8, 0); // HALT

    proc.registers[0] = 0;
    proc.registers[1] = 5;
    proc.registers[2] = 0;
    proc.run();

    try std.testing.expectEqual(proc.registers[2], 6);
}

test "Hello World in memory" {
    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    const hello = "Hello World!";
    for (hello, 0..) |byte, i| {
        ram.ram[i] = byte;
    }
    ram.writeWord(12, 0); // HALT

    proc.registers[7] = 0;
    proc.run();

    try std.testing.expectEqual(ram.ram[0], 'H');
    try std.testing.expectEqual(ram.ram[6], 'W');
    try std.testing.expectEqual(ram.ram[11], '!');
}
