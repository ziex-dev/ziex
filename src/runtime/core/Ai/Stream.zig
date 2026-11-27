const Stream = @This();

const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");
const api = @import("api.zig");

// Text deltas only; read `next` for images. `err` holds the cause when it
// fails with `error.ReadFailed`.
interface: std.Io.Reader,
finish: Ai.Finish = .other,
usage: Ai.Usage = .{},
err: ?Ai.Error = null,

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
// Current SSE line; image events are megabytes, larger than the transfer buffer.
line: std.Io.Writer.Allocating,
parse: Parse,
client: http.Client,
body: *http.Client.Body = undefined,
delta: []const u8 = "",
done: bool = false,
buffer: [1024]u8 = undefined,

// Slices stay valid until the next call to `next`.
pub const Event = union(enum) {
    text: []const u8,
    image: Ai.Image.Chunk,
};

// Turns one SSE `data:` payload into an event, updating `finish`/`usage`.
pub const Parse = *const fn (s: *Stream, arena: std.mem.Allocator, data: []const u8) Ai.Error!?Event;

// POSTs `payload` as JSON and reads the response as server-sent events.
pub fn open(io: std.Io, gpa: std.mem.Allocator, url: []const u8, headers: []const http.Header, payload: anytype, parse: Parse) Ai.Error!*Stream {
    const json = try api.json(gpa, payload);
    defer gpa.free(json);

    const s = try gpa.create(Stream);
    errdefer gpa.destroy(s);
    s.* = .{
        .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &s.buffer, .seek = 0, .end = 0 },
        .gpa = gpa,
        .arena = .init(gpa),
        .line = .init(gpa),
        .parse = parse,
        .client = .{ .io = io, .allocator = gpa },
    };
    errdefer s.line.deinit();
    errdefer s.arena.deinit();
    errdefer s.client.deinit();

    s.body = try s.client.open(.{ .url = url, .method = .POST, .headers = headers, .payload = json, .redirect = .manual });
    errdefer s.body.close();

    if (s.body.status.class() != .success) {
        const reply = s.body.reader.allocRemaining(gpa, .limited(64 * 1024)) catch "";
        defer if (reply.len > 0) gpa.free(reply);
        try api.check(s.body.status, url, reply);
    }
    return s;
}

pub fn deinit(s: *Stream) void {
    s.body.close();
    s.client.deinit();
    s.line.deinit();
    s.arena.deinit();
    s.gpa.destroy(s);
}

// The next event, or null once the response ends. Don't mix with `interface`.
pub fn next(s: *Stream) Ai.Error!?Event {
    return s.nextEvent() catch |err| {
        s.err = err;
        return err;
    };
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const s: *Stream = @alignCast(@fieldParentPtr("interface", r));
    while (s.delta.len == 0) {
        const event = s.next() catch return error.ReadFailed;
        switch (event orelse return error.EndOfStream) {
            .text => |t| s.delta = t,
            .image => {},
        }
    }
    const n = limit.minInt(s.delta.len);
    try w.writeAll(s.delta[0..n]);
    s.delta = s.delta[n..];
    return n;
}

fn nextEvent(s: *Stream) Ai.Error!?Event {
    const reader = s.body.reader;
    while (!s.done) {
        s.line.clearRetainingCapacity();
        _ = reader.streamDelimiterEnding(&s.line.writer, '\n') catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            error.ReadFailed => error.NetworkError,
        };
        // The delimiter is left unread; none buffered means the body ended.
        if (reader.buffered().len > 0) {
            reader.toss(1);
        } else if (s.line.written().len == 0) break;

        const line = std.mem.trimEnd(u8, s.line.written(), "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;

        _ = s.arena.reset(.retain_capacity);
        const event = try s.parse(s, s.arena.allocator(), data) orelse continue;
        switch (event) {
            .text => |t| if (t.len == 0) continue,
            .image => |i| if (i.base64.len == 0) continue,
        }
        return event;
    }
    s.done = true;
    return null;
}
