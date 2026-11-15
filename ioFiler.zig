const std = @import("std");
const memory = @import("memory.zig");

/// Loads a binary image into memory starting at address 0.
/// Files larger than the 64 KiB address space are rejected.
pub fn loadBinary(io: std.Io, allocator: std.mem.Allocator, filename: []const u8, mem: *memory.Memory) !void {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(mem.ram.len));
    defer allocator.free(file_data);

    @memcpy(mem.ram[0..file_data.len], file_data);
}

/// Dumps a 16-bit register as two little-endian bytes into a file.
pub fn writeRegisterToFile(io: std.Io, filename: []const u8, value: u16) !void {
    const low_byte: u8 = @truncate(value);
    const high_byte: u8 = @truncate(value >> 8);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = filename,
        .data = &.{ low_byte, high_byte },
    });
}

/// Dumps a memory range into a file.
pub fn writeMemoryToFile(io: std.Io, filename: []const u8, mem: *memory.Memory, start_addr: u16, length: u16) !void {
    // Computed in a wider type so the range check cannot overflow u16.
    const end_addr: u32 = @as(u32, start_addr) + @as(u32, length);

    if (end_addr > mem.ram.len) {
        return error.AddressOutOfRange;
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = filename,
        .data = mem.ram[start_addr..@as(usize, @intCast(end_addr))],
    });
}

test "writeRegisterToFile roundtrip" {
    const io = std.testing.io;
    try writeRegisterToFile(io, "pdp11_reg_test.bin", 0xBEEF);
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, "pdp11_reg_test.bin", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE }, saved);
}

test "writeMemoryToFile range check" {
    var mem = memory.Memory{};
    mem.writeWord(0o100, 0xBEEF);

    const io = std.testing.io;
    const full = "pdp11_mem_test.bin";

    try writeMemoryToFile(io, full, &mem, 0o100, 2);
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, full, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE }, saved);

    try std.testing.expectError(error.AddressOutOfRange, writeMemoryToFile(io, full, &mem, 0xFFFF, 2));
}
