const std = @import("std");
const cpu = @import("cpu.zig");

const TTY_OUTPUT_ADDR = 0o177566;
const TTY_INPUT_ADDR = 0o177560;

/// Console terminal output (DL11). Real MMIO is not implemented yet; writes
/// land in the mapped memory cell and are mirrored to the host console.
pub const Writer = struct {
    cpu_ptr: *cpu.Cpu,
    addr: u16 = TTY_OUTPUT_ADDR,

    const Self = @This();

    pub fn init(cpu_ptr: *cpu.Cpu, addr: u16) Self {
        return .{ .cpu_ptr = cpu_ptr, .addr = addr };
    }

    pub fn write(self: *Self, value: u16) void {
        self.cpu_ptr.mem.writeWord(self.addr, value);
        const char: u8 = @truncate(value);
        if (char >= 0x20 and char < 0x7F) {
            std.debug.print("{c}", .{char});
        }
    }

    pub fn print(self: *Self, string: []const u8) void {
        for (string) |char| {
            self.write(@as(u16, char));
        }
    }
};

test "writer stores written value" {
    var ram = @import("memory.zig").Memory{};
    var proc = cpu.Cpu.init(&ram);
    var tty = Writer.init(&proc, TTY_OUTPUT_ADDR);
    tty.write('A');
    try std.testing.expectEqual(@as(u16, 'A'), ram.readWord(TTY_OUTPUT_ADDR));
}
