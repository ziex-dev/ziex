// Collects SafeAllocator leak reports from an app's stderr, line by line.
// Colour codes are ignored: `zig build` sets `CLICOLOR_FORCE` for the app.

const LeakReport = @This();

const std = @import("std");

allocator: std.mem.Allocator,
leaks: std.ArrayList(Leak) = .empty,
plain: std.ArrayList(u8) = .empty,
in_report: bool = false,
context_left: u2 = 0,

pub const Frame = struct {
    /// Empty for `???:?:?`.
    file: []const u8,
    line: u32,
    col: u32,
    function: []const u8,
};

pub const Leak = struct {
    frames: std.ArrayList(Frame) = .empty,
};

pub const Feed = enum { consumed, pass };

pub fn init(allocator: std.mem.Allocator) LeakReport {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *LeakReport) void {
    self.clear();
    self.leaks.deinit(self.allocator);
    self.plain.deinit(self.allocator);
}

pub fn feed(self: *LeakReport, raw_line: []const u8) !Feed {
    try stripAnsi(self.allocator, &self.plain, raw_line);
    const line = std.mem.trimEnd(u8, self.plain.items, "\r");

    if (std.mem.startsWith(u8, line, "error(SafeAllocator): leaked ")) {
        try self.leaks.append(self.allocator, .{});
        self.in_report = true;
        self.context_left = 0;
        return .consumed;
    }
    if (!self.in_report) return .pass;

    if (parseFrame(line)) |frame| {
        const leak = &self.leaks.items[self.leaks.items.len - 1];
        try leak.frames.append(self.allocator, .{
            .file = try self.allocator.dupe(u8, frame.file),
            .line = frame.line,
            .col = frame.col,
            .function = try self.allocator.dupe(u8, frame.function),
        });
        self.context_left = 2;
        return .consumed;
    }
    if (self.context_left > 0 and line.len > 0) {
        self.context_left -= 1;
        return .consumed;
    }

    self.in_report = false;
    return if (line.len == 0) .consumed else .pass;
}

pub fn clear(self: *LeakReport) void {
    for (self.leaks.items) |*leak| {
        for (leak.frames.items) |f| {
            self.allocator.free(f.file);
            self.allocator.free(f.function);
        }
        leak.frames.deinit(self.allocator);
    }
    self.leaks.clearRetainingCapacity();
    self.in_report = false;
    self.context_left = 0;
}

fn stripAnsi(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len and !(line[i] >= '@' and line[i] <= '~')) i += 1;
            continue;
        }
        try out.append(allocator, line[i]);
    }
}

/// `<file>:<line>:<col>: 0x<addr> in <function> (<binary>)`, parsed from the
/// right so Windows drive letters don't interfere.
fn parseFrame(line: []const u8) ?Frame {
    const addr = std.mem.findLast(u8, line, ": 0x") orelse return null;
    const after = line[addr + ": 0x".len ..];
    const in_pos = std.mem.find(u8, after, " in ") orelse return null;
    const rest = after[in_pos + " in ".len ..];
    const function = if (std.mem.findLast(u8, rest, " (")) |p| rest[0..p] else rest;

    const loc = line[0..addr];
    const col_sep = std.mem.findScalarLast(u8, loc, ':') orelse return null;
    const line_sep = std.mem.findScalarLast(u8, loc[0..col_sep], ':') orelse return null;
    const file = loc[0..line_sep];
    const line_no = std.fmt.parseInt(u32, loc[line_sep + 1 .. col_sep], 10) catch 0;
    const col_no = std.fmt.parseInt(u32, loc[col_sep + 1 ..], 10) catch 0;

    if (line_no == 0 or std.mem.eql(u8, file, "???")) return .{ .file = "", .line = 0, .col = 0, .function = function };
    return .{ .file = file, .line = line_no, .col = col_no, .function = function };
}
