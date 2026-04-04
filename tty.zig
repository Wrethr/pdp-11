const cpu = @import("cpu.zig");

const TTY_OUTPUT_ADDR = 0o177566;
const TTY_INPUT_ADDR = 0o177560;

pub const Writer = struct {
    cpu_ptr: *cpu.Cpu,
    addr: u16,

    const Self = @This();

    pub fn init(cpu_ptr: *cpu.Cpu, addr: u16) Self {
        return .{ .cpu_ptr = cpu_ptr, .addr = addr };
    }

    pub fn write(self: *Self, value: u16) void {
        self.cpu_ptr.writeMem(self.addr, value);
    }

    pub fn print(self: *Self, string: []const u8) void {
        for (string) |char| {
            self.write(@as(u16, char));
        }
    }
};
