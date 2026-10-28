const Host = @This();

const std = @import("std");
const ext = @import("../../../server/wasm/extern.zig");
const Conn = @import("../../http/Conn.zig");

buf: [4096]u8 = undefined,
writer: std.Io.Writer = undefined,

pub fn init(self: *Host) void {
    self.writer = .{
        .buffer = &self.buf,
        .vtable = &vtable,
    };
}

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    try flush(w);
    for (data[0 .. data.len - 1]) |slice| ext.http.write(slice);
    const pattern = data[data.len - 1];
    for (0..splat) |_| ext.http.write(pattern);
    return std.Io.Writer.countSplat(data, splat);
}

fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
    ext.http.write(w.buffer[0..w.end]);
    w.end = 0;
}

pub fn commit(allocator: std.mem.Allocator, conn: *const Conn, streaming: bool) !void {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeMetaJson(&aw.writer, conn, streaming);
    const meta = aw.written();
    ext.http.commit(conn.status, meta);
}

pub fn end() void {
    ext.http.end();
}

fn writeMetaJson(writer: *std.Io.Writer, conn: *const Conn, streaming: bool) !void {
    try writer.writeAll("{\"streaming\":");
    try writer.writeAll(if (streaming) "true" else "false");
    try writer.writeAll(",\"headers\":[");
    for (conn.resp_headers.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("[");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(",");
        try writeJsonString(writer, entry.value);
        try writer.writeAll("]");
    }
    try writer.writeAll("]}");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}
