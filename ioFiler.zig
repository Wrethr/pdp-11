const std = @import("std");
const memory = @import("memory.zig");

pub fn loadBinary(allocator: std.mem.Allocator, filename: []const u8, mem: *memory.Memory) !void {
    const file_data = try std.fs.cwd().readFileAlloc(allocator, filename, mem.ram.len);
    defer allocator.free(file_data);

    if (file_data.len > mem.ram.len) {
        return error.FileTooLargeForMemory;
    }

    @memcpy(mem.ram[0..file_data.len], file_data);
}

pub fn writeRegisterToFile(filename: []const u8, value: u16) !void {
    const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
    defer file.close();

    const writer = file.writer();

    const low_byte = @as(u8, @truncate(value));
    const high_byte = @as(u8, @truncate(value >> 8));

    try writer.writeAll(&[_]u8{ low_byte, high_byte });
}

pub fn writeMemoryToFile(filename: []const u8, mem: *memory.Memory, start_addr: u16, length: u16) !void {
    const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
    defer file.close();

    const writer = file.writer();

    const end_addr = start_addr + length;

    if (end_addr > mem.ram.len) {
        return error.AddressOutOfRange;
    }

    try writer.writeAll(mem.ram[start_addr..end_addr]);
}
