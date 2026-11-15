const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");
const ioFiler = @import("ioFiler.zig");
const assembler = @import("assembler.zig");

pub fn main(init: std.process.Init) !void {
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip();

    const arg1 = arg_it.next() orelse {
        std.debug.print("Usage: pdp11 <file.bin | file.asm>\n", .{});
        return;
    };

    var ram = memory.Memory{};
    var proc = cpu.Cpu.init(&ram);

    if (std.ascii.endsWithIgnoreCase(arg1, ".asm")) {
        const source = std.Io.Dir.cwd().readFileAlloc(init.io, arg1, init.gpa, .limited(1 << 20)) catch {
            std.debug.print("Error: could not read file: {s}\n", .{arg1});
            return;
        };
        defer init.gpa.free(source);

        assembler.assemble(init.gpa, source, &ram) catch |e| {
            if (e != error.AssemblyFailed) {
                std.debug.print("Error: assembly of {s} failed\n", .{arg1});
            }
            return;
        };
    } else {
        ioFiler.loadBinary(init.io, init.gpa, arg1, &ram) catch {
            std.debug.print("Error: could not load file: {s}\n", .{arg1});
            return;
        };
    }

    proc.run();

    std.debug.print("\nExecution complete. PC = {o}\n", .{proc.registers[7]});
}
