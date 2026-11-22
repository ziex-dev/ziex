const Stream = @This();

const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");
const api = @import("api.zig");

// Text deltas; `err` holds the cause when it fails with `error.ReadFailed`.
interface: std.Io.Reader,
finish: Ai.Finish = .other,
usage: Ai.Usage = .{},
err: ?Ai.Error = null,

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
parse: Parse,
client: http.Client,
body: *http.Client.Body = undefined,
delta: []const u8 = "",
done: bool = false,
buffer: [1024]u8 = undefined,

// Turns one SSE `data:` payload into a text delta, updating `finish`/`usage`.
pub const Parse = *const fn (s: *Stream, arena: std.mem.Allocator, data: []const u8) Ai.Error!?[]const u8;

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
        .parse = parse,
        .client = .{ .io = io, .allocator = gpa },
    };
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
    s.arena.deinit();
    s.gpa.destroy(s);
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const s: *Stream = @alignCast(@fieldParentPtr("interface", r));
    while (s.delta.len == 0) {
        const delta = s.next() catch |err| {
            s.err = err;
            return error.ReadFailed;
        };
        s.delta = delta orelse return error.EndOfStream;
    }
    const n = limit.minInt(s.delta.len);
    try w.writeAll(s.delta[0..n]);
    s.delta = s.delta[n..];
    return n;
}

fn next(s: *Stream) Ai.Error!?[]const u8 {
    while (!s.done) {
        const taken = s.body.reader.takeDelimiter('\n') catch |err| return switch (err) {
            error.StreamTooLong => error.InvalidResponse,
            error.ReadFailed => error.NetworkError,
        };
        const line = taken orelse break;

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trimStart(u8, trimmed["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;

        _ = s.arena.reset(.retain_capacity);
        const delta = try s.parse(s, s.arena.allocator(), data) orelse continue;
        if (delta.len > 0) return delta;
    }
    s.done = true;
    return null;
}
