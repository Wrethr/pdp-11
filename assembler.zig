const std = @import("std");
const memory = @import("memory.zig");

pub const Error = error{ AssemblyFailed, OutOfMemory };

/// Two-pass assembler for a small subset of PDP-11 MACRO-11 syntax.
/// Supported: word/byte variants of MOV/CMP/BIT/BIC/BIS/ADD/SUB, the single
/// operand group, JMP/JSR/RTS/SOB, all branches, HALT, and the directives
/// .byte, .word, .ascii. Numbers are decimal; 0o-prefixed values are octal;
/// character literals are written as 'c.
/// On success the image is written into `mem` starting at address 0.
pub fn assemble(allocator: std.mem.Allocator, source: []const u8, mem: *memory.Memory) Error!void {
    var labels = std.StringHashMap(u16).init(allocator);
    defer labels.deinit();

    var pass: enum { layout, emit } = .layout;
    while (true) {
        var addr: u16 = 0;
        var it = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 0;
        while (it.next()) |raw_line| : (line_no += 1) {
            const parsed = parseLine(raw_line) orelse continue;

            if (pass == .layout) {
                if (parsed.label) |l| {
                    if (labels.contains(l)) return fail(line_no, "duplicate label '{s}'", .{l});
                    labels.put(l, addr) catch return error.OutOfMemory;
                }
                if (parsed.mnem.len == 0) continue;
                addr +%= try instructionSize(parsed, line_no);
            } else {
                if (parsed.mnem.len == 0) continue;
                addr = try emit(parsed, addr, &labels, mem, line_no);
            }
        }
        if (pass == .emit) break;
        pass = .emit;
    }
}

fn fail(line_no: usize, comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("asm error: line {d}: " ++ fmt ++ "\n", .{line_no} ++ args);
    return error.AssemblyFailed;
}

const Parsed = struct {
    label: ?[]const u8 = null,
    mnem: []const u8 = "",
    rest: []const u8 = "",
};

fn parseLine(line: []const u8) ?Parsed {
    var s = line;
    if (std.mem.indexOfScalar(u8, s, ';')) |p| s = s[0..p];
    s = std.mem.trim(u8, s, " \t\r");
    if (s.len == 0) return null;

    var result: Parsed = .{};

    if (std.mem.indexOfScalar(u8, s, ':')) |cp| {
        const before = std.mem.trim(u8, s[0..cp], " \t");
        if (before.len > 0 and std.mem.indexOfAny(u8, before, " \t") == null) {
            result.label = before;
            s = std.mem.trim(u8, s[cp + 1 ..], " \t");
            if (s.len == 0) return result;
        }
    }

    const sp = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    result.mnem = s[0..sp];
    result.rest = std.mem.trim(u8, s[sp..], " \t");
    return result;
}

const OperandShape = struct {
    mode: u3,
    reg: u3,
    val: ?[]const u8 = null,
};

fn parseReg(tok: []const u8) ?u3 {
    if (tok.len == 0 or tok.len > 2) return null;
    var buf: [2]u8 = undefined;
    for (tok, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    const up = buf[0..tok.len];
    if (std.mem.eql(u8, up, "SP")) return 6;
    if (std.mem.eql(u8, up, "PC")) return 7;
    if (up[0] == 'R' and up[1] >= '0' and up[1] <= '7') return @intCast(up[1] - '0');
    return null;
}

fn parseOperand(tok_in: []const u8) Error!OperandShape {
    var tok = tok_in;
    var deferred = false;
    if (tok.len > 0 and tok[0] == '@') {
        deferred = true;
        tok = tok[1..];
    }
    if (tok.len == 0) return error.AssemblyFailed;

    if (tok[0] == '#') {
        if (tok.len == 1) return error.AssemblyFailed;
        return .{ .mode = if (deferred) 3 else 2, .reg = 7, .val = tok[1..] };
    }

    if (tok[0] == '(') {
        const rp = std.mem.indexOfScalar(u8, tok, ')') orelse return error.AssemblyFailed;
        const inner = tok[1..rp];
        const suffix = tok[rp + 1 ..];
        if (std.mem.eql(u8, suffix, "+")) {
            const reg = parseReg(inner) orelse return error.AssemblyFailed;
            return .{ .mode = if (deferred) 3 else 2, .reg = reg };
        }
        if (suffix.len == 0) {
            if (deferred) return error.AssemblyFailed;
            const reg = parseReg(inner) orelse return error.AssemblyFailed;
            return .{ .mode = 1, .reg = reg };
        }
        return error.AssemblyFailed;
    }

    if (std.mem.startsWith(u8, tok, "-(") and tok[tok.len - 1] == ')') {
        const reg = parseReg(tok[2 .. tok.len - 1]) orelse return error.AssemblyFailed;
        return .{ .mode = if (deferred) 5 else 4, .reg = reg };
    }

    if (std.mem.indexOfScalar(u8, tok, '(')) |p| {
        if (tok[tok.len - 1] != ')') return error.AssemblyFailed;
        const reg = parseReg(tok[p + 1 .. tok.len - 1]) orelse return error.AssemblyFailed;
        return .{ .mode = if (deferred) 7 else 6, .reg = reg, .val = tok[0..p] };
    }

    if (parseReg(tok)) |reg| {
        return .{ .mode = if (deferred) 1 else 0, .reg = reg };
    }

    return .{ .mode = if (deferred) 7 else 6, .reg = 7, .val = tok };
}

fn parseValue(tok: []const u8) ?i32 {
    if (tok.len >= 2 and tok[0] == '\'') return tok[1];
    if (tok.len >= 3 and tok[0] == '0' and (tok[1] == 'o' or tok[1] == 'O')) {
        return std.fmt.parseInt(i32, tok[2..], 8) catch null;
    }
    return std.fmt.parseInt(i32, tok, 10) catch null;
}

fn operandWordCount(tok: []const u8) usize {
    const shape = parseOperand(tok) catch return 0;
    return if (shape.val != null) 2 else 0;
}

fn splitOperands(rest: []const u8, buf: *[3][]const u8) usize {
    var n: usize = 0;
    var s = rest;
    while (s.len > 0) {
        const p = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
        buf[n] = std.mem.trim(u8, s[0..p], " \t");
        n += 1;
        if (p == s.len) break;
        s = std.mem.trim(u8, s[p + 1 ..], " \t");
    }
    return n;
}

fn operandListSize(rest: []const u8) usize {
    var s = rest;
    var n: usize = 0;
    while (s.len > 0) {
        const p = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
        const item = std.mem.trim(u8, s[0..p], " \t");
        if (item.len > 0) n += 1;
        if (p == s.len) break;
        s = std.mem.trim(u8, s[p + 1 ..], " \t");
    }
    return n;
}

fn instructionSize(parsed: Parsed, line_no: usize) Error!u16 {
    const mnem = parsed.mnem;
    if (mnem[0] == '.') {
        if (std.ascii.eqlIgnoreCase(mnem, ".byte") or std.ascii.eqlIgnoreCase(mnem, ".word")) {
            return @intCast(operandListSize(parsed.rest) * (if (std.ascii.eqlIgnoreCase(mnem, ".word")) @as(usize, 2) else 1));
        }
        if (std.ascii.eqlIgnoreCase(mnem, ".ascii")) {
            if (parsed.rest.len < 2 or parsed.rest[0] != '"' or parsed.rest[parsed.rest.len - 1] != '"') {
                return fail(line_no, ".ascii expects a quoted string", .{});
            }
            return @intCast(parsed.rest.len - 2);
        }
        return fail(line_no, "unknown directive '{s}'", .{mnem});
    }

    var ops: [3][]const u8 = undefined;
    const nops = splitOperands(parsed.rest, &ops);

    if (isBranch(mnem) or std.ascii.eqlIgnoreCase(mnem, "halt")) {
        if (std.ascii.eqlIgnoreCase(mnem, "halt") and nops != 0) return fail(line_no, "halt takes no operands", .{});
        return 2;
    }
    if (std.ascii.eqlIgnoreCase(mnem, "rts")) {
        if (nops != 1) return fail(line_no, "rts expects a register", .{});
        return 2;
    }
    if (std.ascii.eqlIgnoreCase(mnem, "sob")) {
        if (nops != 2) return fail(line_no, "sob expects a register and a label", .{});
        return 2;
    }
    if (std.ascii.eqlIgnoreCase(mnem, "jmp")) {
        if (nops != 1) return fail(line_no, "jmp expects a destination", .{});
        return @intCast(2 + operandWordCount(ops[0]));
    }
    if (std.ascii.eqlIgnoreCase(mnem, "jsr")) {
        if (nops != 2) return fail(line_no, "jsr expects a register and a destination", .{});
        return @intCast(2 + operandWordCount(ops[1]));
    }

    // Double and single operand groups, with optional trailing B suffix.
    // The bare name is tried first so mnemonics ending in 'b' (e.g. SUB)
    // are not misparsed as byte variants.
    var base = mnem;
    var byte = false;
    if (doubleOpcode(base, false, line_no) == null and singleOpcode(base, false, line_no) == null and
        base.len > 1 and (base[base.len - 1] == 'b' or base[base.len - 1] == 'B'))
    {
        base = base[0 .. base.len - 1];
        byte = true;
    }

    if (doubleOpcode(base, byte, line_no)) |_| {
        if (nops != 2) return fail(line_no, "'{s}' expects two operands", .{mnem});
        return @intCast(2 + operandWordCount(ops[0]) + operandWordCount(ops[1]));
    }
    if (singleOpcode(base, byte, line_no)) |_| {
        if (nops != 1) return fail(line_no, "'{s}' expects one operand", .{mnem});
        return @intCast(2 + operandWordCount(ops[0]));
    }

    return fail(line_no, "unknown instruction '{s}'", .{mnem});
}

fn doubleOpcode(base: []const u8, byte: bool, line_no: usize) ?u4 {
    const word: u4 = if (std.ascii.eqlIgnoreCase(base, "mov")) 0o01 else if (std.ascii.eqlIgnoreCase(base, "cmp")) 0o02 else if (std.ascii.eqlIgnoreCase(base, "bit")) 0o03 else if (std.ascii.eqlIgnoreCase(base, "bic")) 0o04 else if (std.ascii.eqlIgnoreCase(base, "bis")) 0o05 else if (std.ascii.eqlIgnoreCase(base, "add")) 0o06 else if (std.ascii.eqlIgnoreCase(base, "sub")) 0o16 else return null;
    if (byte) {
        if (word == 0o06 or word == 0o16) {
            _ = line_no;
            return null; // ADD/SUB have no byte form
        }
        return word + 0o10;
    }
    return word;
}

fn singleOpcode(base: []const u8, byte: bool, line_no: usize) ?u10 {
    const code: u10 = if (std.ascii.eqlIgnoreCase(base, "clr")) 0o050 else if (std.ascii.eqlIgnoreCase(base, "com")) 0o051 else if (std.ascii.eqlIgnoreCase(base, "inc")) 0o052 else if (std.ascii.eqlIgnoreCase(base, "dec")) 0o053 else if (std.ascii.eqlIgnoreCase(base, "neg")) 0o054 else if (std.ascii.eqlIgnoreCase(base, "adc")) 0o055 else if (std.ascii.eqlIgnoreCase(base, "sbc")) 0o056 else if (std.ascii.eqlIgnoreCase(base, "tst")) 0o057 else if (std.ascii.eqlIgnoreCase(base, "ror")) 0o060 else if (std.ascii.eqlIgnoreCase(base, "rol")) 0o061 else if (std.ascii.eqlIgnoreCase(base, "asr")) 0o062 else if (std.ascii.eqlIgnoreCase(base, "asl")) 0o063 else if (std.ascii.eqlIgnoreCase(base, "sxt")) 0o067 else return null;
    _ = line_no;
    return if (byte) code + 0o1000 else code;
}

fn branchOpcode(mnem: []const u8) ?u8 {
    const table = [_]struct { name: []const u8, code: u8 }{
        .{ .name = "br", .code = 0o001 },
        .{ .name = "bne", .code = 0o002 },
        .{ .name = "beq", .code = 0o003 },
        .{ .name = "bge", .code = 0o004 },
        .{ .name = "blt", .code = 0o005 },
        .{ .name = "bgt", .code = 0o006 },
        .{ .name = "ble", .code = 0o007 },
        .{ .name = "bpl", .code = 0o201 },
        .{ .name = "bmi", .code = 0o202 },
        .{ .name = "bhi", .code = 0o203 },
        .{ .name = "blos", .code = 0o204 },
        .{ .name = "bvc", .code = 0o205 },
        .{ .name = "bvs", .code = 0o206 },
        .{ .name = "bcc", .code = 0o207 },
        .{ .name = "bcs", .code = 0o210 },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(mnem, e.name)) return e.code;
    }
    return null;
}

fn isBranch(mnem: []const u8) bool {
    return branchOpcode(mnem) != null;
}

const Emitter = struct {
    mem: *memory.Memory,
    labels: *const std.StringHashMap(u16),
    line: usize,
    addr: u16,

    fn word(self: *Emitter, value: u16) Error!void {
        if (self.addr & 1 != 0) return fail(self.line, "unaligned word emission at {o}", .{self.addr});
        self.mem.writeWord(self.addr, value);
        self.addr += 2;
    }

    fn byte(self: *Emitter, value: u8) void {
        self.mem.writeByte(self.addr, value);
        self.addr += 1;
    }

    fn resolve(self: *Emitter, tok: []const u8) Error!u16 {
        if (parseValue(tok)) |n| return @truncate(@as(u32, @bitCast(n)));
        if (self.labels.get(tok)) |a| return a;
        return fail(self.line, "unknown label or value '{s}'", .{tok});
    }

    /// Emits addressing mode bits followed by the operand word (if the form
    /// requires one), applying the PC-relative displacement for modes 6/7
    /// through R7.
    fn operandWords(self: *Emitter, shape: OperandShape) Error!void {
        if (shape.val) |vt| {
            var v = try self.resolve(vt);
            if (shape.reg == 7 and (shape.mode == 6 or shape.mode == 7)) {
                v = v -% (self.addr + 2);
            }
            try self.word(v);
        }
    }
};

fn emit(parsed: Parsed, addr: u16, labels: *const std.StringHashMap(u16), mem: *memory.Memory, line_no: usize) Error!u16 {
    var em = Emitter{ .mem = mem, .labels = labels, .line = line_no, .addr = addr };
    const mnem = parsed.mnem;

    if (mnem[0] == '.') {
        if (std.ascii.eqlIgnoreCase(mnem, ".byte") or std.ascii.eqlIgnoreCase(mnem, ".word")) {
            const wide = std.ascii.eqlIgnoreCase(mnem, ".word");
            var s = parsed.rest;
            while (s.len > 0) {
                const p = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
                const item = std.mem.trim(u8, s[0..p], " \t");
                if (item.len > 0) {
                    const v = try em.resolve(item);
                    if (wide) {
                        try em.word(v);
                    } else {
                        em.byte(@truncate(v));
                    }
                }
                if (p == s.len) break;
                s = std.mem.trim(u8, s[p + 1 ..], " \t");
            }
            return em.addr;
        }
        if (std.ascii.eqlIgnoreCase(mnem, ".ascii")) {
            const content = parsed.rest[1 .. parsed.rest.len - 1];
            for (content) |c| em.byte(c);
            return em.addr;
        }
        return fail(line_no, "unknown directive '{s}'", .{mnem});
    }

    var ops: [3][]const u8 = undefined;
    const nops = splitOperands(parsed.rest, &ops);

    if (std.ascii.eqlIgnoreCase(mnem, "halt")) {
        try em.word(0);
        return em.addr;
    }

    if (branchOpcode(mnem)) |code| {
        if (nops != 1) return fail(line_no, "branch expects a label", .{});
        const target = try em.resolve(ops[0]);
        const diff = @as(i32, target) - @as(i32, addr + 2);
        if (diff & 1 != 0) return fail(line_no, "branch target is not word aligned", .{});
        const off = @divTrunc(diff, 2);
        if (off < -128 or off > 127) return fail(line_no, "branch out of range", .{});
        const off_bits: u16 = @bitCast(@as(i16, @intCast(off)));
        try em.word((@as(u16, code) << 8) | (off_bits & 0xFF));
        return em.addr;
    }

    if (std.ascii.eqlIgnoreCase(mnem, "rts")) {
        const reg = parseReg(ops[0]) orelse return fail(line_no, "rts expects a register", .{});
        try em.word((@as(u16, 0o020) << 3) | reg);
        return em.addr;
    }

    if (std.ascii.eqlIgnoreCase(mnem, "sob")) {
        const reg = parseReg(ops[0]) orelse return fail(line_no, "sob expects a register", .{});
        const target = try em.resolve(ops[1]);
        const diff = @as(i32, addr + 2) - @as(i32, target);
        const words = @divTrunc(diff, 2);
        if (diff & 1 != 0 or diff <= 0 or words > 63) return fail(line_no, "sob target must be behind (1..63 words)", .{});
        try em.word((0o077 << 9) | (@as(u16, reg) << 6) | @as(u16, @intCast(words)));
        return em.addr;
    }

    if (std.ascii.eqlIgnoreCase(mnem, "jmp")) {
        if (nops != 1) return fail(line_no, "jmp expects a destination", .{});
        const shape = parseOperand(ops[0]) catch return fail(line_no, "bad operand '{s}'", .{ops[0]});
        try em.word((0o001 << 6) | (@as(u16, shape.mode) << 3) | shape.reg);
        try em.operandWords(shape);
        return em.addr;
    }

    if (std.ascii.eqlIgnoreCase(mnem, "jsr")) {
        if (nops != 2) return fail(line_no, "jsr expects a register and a destination", .{});
        const reg = parseReg(ops[0]) orelse return fail(line_no, "jsr register expected", .{});
        const shape = parseOperand(ops[1]) catch return fail(line_no, "bad operand '{s}'", .{ops[1]});
        try em.word(0x0800 | (@as(u16, reg) << 6) | (@as(u16, shape.mode) << 3) | shape.reg);
        try em.operandWords(shape);
        return em.addr;
    }

    var base = mnem;
    var byte = false;
    if (doubleOpcode(base, false, line_no) == null and singleOpcode(base, false, line_no) == null and
        base.len > 1 and (base[base.len - 1] == 'b' or base[base.len - 1] == 'B'))
    {
        base = base[0 .. base.len - 1];
        byte = true;
    }

    if (doubleOpcode(base, byte, line_no)) |code| {
        if (nops != 2) return fail(line_no, "'{s}' expects two operands", .{mnem});
        const src = parseOperand(ops[0]) catch return fail(line_no, "bad operand '{s}'", .{ops[0]});
        const dst = parseOperand(ops[1]) catch return fail(line_no, "bad operand '{s}'", .{ops[1]});
        try em.word((@as(u16, code) << 12) | (@as(u16, src.mode) << 9) | (@as(u16, src.reg) << 6) | (@as(u16, dst.mode) << 3) | dst.reg);
        try em.operandWords(src);
        try em.operandWords(dst);
        return em.addr;
    }

    if (singleOpcode(base, byte, line_no)) |code| {
        if (nops != 1) return fail(line_no, "'{s}' expects one operand", .{mnem});
        const dst = parseOperand(ops[0]) catch return fail(line_no, "bad operand '{s}'", .{ops[0]});
        try em.word((@as(u16, code) << 6) | (@as(u16, dst.mode) << 3) | dst.reg);
        try em.operandWords(dst);
        return em.addr;
    }

    return fail(line_no, "unknown instruction '{s}'", .{mnem});
}

test "assemble and run hello example" {
    var ram = memory.Memory{};
    const src =
        \\        mov #msg, r0
        \\        mov #6, r1
        \\loop:   movb (r0)+, @#0o177566
        \\        sob r1, loop
        \\        halt
        \\msg:    .ascii "Hey!"
        \\        .byte 10
    ;
    try assemble(std.testing.allocator, src, &ram);

    try std.testing.expectEqual(@as(u16, 0o012700), ram.readWord(0));
    try std.testing.expectEqual(@as(u16, 16), ram.readWord(2));
    try std.testing.expectEqual(@as(u16, 0o112037), ram.readWord(8));
    try std.testing.expectEqual(@as(u16, 0o077103), ram.readWord(12));
    try std.testing.expectEqual(@as(u16, 0), ram.readWord(14));
    try std.testing.expectEqualStrings("Hey!", ram.ram[16 .. 16 + 4]);
    try std.testing.expectEqual(@as(u8, 10), ram.ram[20]);
}

test "assemble branch backward" {
    var ram = memory.Memory{};
    const src =
        \\top:   dec r0
        \\       bne top
        \\       halt
    ;
    try assemble(std.testing.allocator, src, &ram);
    // BNE = 0o001000, offset -2 words = 0o376.
    try std.testing.expectEqual(@as(u16, 0o001376), ram.readWord(2));
}
