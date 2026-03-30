const std = @import("std");

const TTY_OUTPUT_ADDR = 0o177566;
const TTY_INPUT_ADDR = 0o177560;

pub const Memory = struct {
    ram: [65536]u8 = [_]u8{0} ** 65536,

    const Self = @This();

    pub fn readWord(self: *Self, address: u16) u16 {
        const lowByte = self.ram[address];
        const highByte = self.ram[address + 1];

        // литл эндиан, по этому сначала lowByte
        return @as(u16, lowByte) | (@as(u16, highByte) << 8);
    }

    pub fn writeWord(self: *Self, address: u16, value: u16) void {
        const lowByte = @as(u8, @truncate(value));
        const highByte = @as(u8, @truncate(value >> 8));

        self.ram[address] = lowByte;
        self.ram[address + 1] = highByte;

        if (address == TTY_OUTPUT_ADDR) {
            const char = @as(u8, @truncate(value));
            std.debug.print("{c}", .{char});
        }
    }
};
