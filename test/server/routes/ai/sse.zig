const std = @import("std");

pub fn event(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: ?[]const u8, value: anytype) !void {
    if (name) |n| try out.print(arena, "event: {s}\r\n", .{n});
    try out.print(arena, "data: {f}\r\n\r\n", .{std.json.fmt(value, .{})});
}

// Splits `text` into 3-byte deltas.
pub fn chunks(text: []const u8) std.mem.WindowIterator(u8) {
    return std.mem.window(u8, text, 3, 3);
}
