pub const Memory = struct {
    ram: [65536]u8 = @splat(0),

    /// Reads a byte at any address.
    pub fn readByte(self: *Self, address: u16) u8 {
        return self.ram[address];
    }

    /// Writes a byte at any address.
    pub fn writeByte(self: *Self, address: u16, value: u8) void {
        self.ram[address] = value;
    }

    /// Reads a little-endian word. The address must be even.
    pub fn readWord(self: *Self, address: u16) u16 {
        if (address & 1 != 0) @panic("unaligned word read");
        const lowByte = self.ram[address];
        const highByte = self.ram[(address +% 1) & 0xFFFF];
        return @as(u16, lowByte) | (@as(u16, highByte) << 8);
    }

    /// Writes a little-endian word. The address must be even.
    pub fn writeWord(self: *Self, address: u16, value: u16) void {
        if (address & 1 != 0) @panic("unaligned word write");
        self.ram[address] = @truncate(value);
        self.ram[(address +% 1) & 0xFFFF] = @truncate(value >> 8);
    }

    const Self = @This();
};

const std = @import("std");

test "word read/write roundtrip" {
    var mem = Memory{};
    mem.writeWord(0o100, 0o123456);
    try std.testing.expectEqual(@as(u16, 0o123456), mem.readWord(0o100));
}

test "byte read/write roundtrip" {
    var mem = Memory{};
    mem.writeByte(0o101, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), mem.readByte(0o101));
}

test "word at last address wraps safely" {
    var mem = Memory{};
    mem.writeWord(0xFFFE, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), mem.readWord(0xFFFE));
}
