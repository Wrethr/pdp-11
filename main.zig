const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");

pub fn main() !void {
    var ram = memory.Memory{};

    var proc = cpu.Cpu.init(&ram);

    proc.registers[1] = 10;
    proc.registers[2] = 32;

    ram.writeWord(0, 0x6042);

    ram.writeWord(2, 0); // HALT

    proc.run();

    std.debug.print("R2 = {}\n", .{proc.registers[2]});
}
