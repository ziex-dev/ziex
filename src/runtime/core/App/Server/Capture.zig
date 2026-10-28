/// Tees outgoing bytes into a buffer for the page cache.
const Capture = @This();

const std = @import("std");

downstream: *std.Io.Writer,
sink: std.Io.Writer.Allocating,
writer: std.Io.Writer,

pub fn init(allocator: std.mem.Allocator, downstream: *std.Io.Writer) Capture {
    return .{
        .downstream = downstream,
        .sink = .init(allocator),
        .writer = .{
            .buffer = &.{},
            .vtable = &vtable,
        },
    };
}

pub fn deinit(self: *Capture) void {
    self.sink.deinit();
}

pub fn captured(self: *Capture) []const u8 {
    return self.sink.written();
}

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Capture = @alignCast(@fieldParentPtr("writer", w));
    for (data[0 .. data.len - 1]) |slice| {
        try writeBoth(self, slice);
    }
    const pattern = data[data.len - 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        try writeBoth(self, pattern);
    }
    return std.Io.Writer.countSplat(data, splat);
}

fn writeBoth(self: *Capture, bytes: []const u8) std.Io.Writer.Error!void {
    try self.downstream.writeAll(bytes);
    self.sink.writer.writeAll(bytes) catch return error.WriteFailed;
}

fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
    const self: *Capture = @alignCast(@fieldParentPtr("writer", w));
    try self.downstream.flush();
}
