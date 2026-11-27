const std = @import("std");
const zx = @import("zx");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Backend = zx.testing.Backend;
const Harness = zx.testing.Harness;

const backends = [_]Backend{ .httpz, .std, .wasm };

test "GET /" {
    try forEachBackend(testGetRoot);
}

test "404 for unknown path" {
    try forEachBackend(testNotFound);
}

test "POST /echo body" {
    try forEachBackend(testPostEcho);
}

test "POST without Content-Length has an empty body" {
    try forEachBackend(testPostWithoutBody);
}

test "keepalive after POST without Content-Length" {
    try forEachBackend(testKeepaliveAfterBodylessPost);
}

test "GET /echo query" {
    try forEachBackend(testGetEchoQuery);
}

test "request/response headers" {
    try forEachBackend(testHeaders);
}

test "json response" {
    try forEachBackend(testJson);
}

test "keepalive second request" {
    try forEachBackend(testKeepalive);
}

test "half-close frees connection slots" {
    try forEachBackend(testHalfClose);
}

fn forEachBackend(comptime case: *const fn (Backend) anyerror!void) !void {
    inline for (backends) |backend| {
        case(backend) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

fn withHarness(backend: Backend, comptime body: *const fn (*Harness, Allocator) anyerror!void) !void {
    var harness = try Harness.start(backend, io, allocator, .{
        .workers = .{ .count = 1, .min_conn = 1, .max_conn = 2 },
        .thread_pool = .{ .count = 1 },
    });
    defer harness.stop();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try body(&harness, arena_state.allocator());
}

fn testGetRoot(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/" });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("ok", res.body);
        }
    }.run);
}

fn testNotFound(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/no-such-route" });
            try std.testing.expectEqual(@as(u16, 404), res.status);
        }
    }.run);
}

fn testPostEcho(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{
                .method = .POST,
                .path = "/echo",
                .headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
                .body = "hello-echo",
            });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("hello-echo", res.body);
        }
    }.run);
}

fn testPostWithoutBody(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .method = .POST, .path = "/echo" });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("", res.body);
        }
    }.run);
}

fn testKeepaliveAfterBodylessPost(backend: Backend) !void {
    if (!backend.isTcp()) return;

    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var stream = try h.connect();
            defer stream.close(io);

            const keep = [_]zx.testing.Header{.{ .name = "Connection", .value = "keep-alive" }};
            const res1 = try h.fetch(arena, .{ .method = .POST, .path = "/echo", .headers = &keep, .stream = &stream });
            try std.testing.expectEqual(@as(u16, 200), res1.status);
            try std.testing.expectEqualStrings("", res1.body);

            const res2 = try h.fetch(arena, .{ .path = "/echo?q=after", .headers = &keep, .stream = &stream });
            try std.testing.expectEqual(@as(u16, 200), res2.status);
            try std.testing.expectEqualStrings("after", res2.body);
        }
    }.run);
}

fn testGetEchoQuery(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/echo?q=ziex" });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("ziex", res.body);
        }
    }.run);
}

fn testHeaders(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{
                .path = "/headers",
                .headers = &.{
                    .{ .name = "X-Test", .value = "abc" },
                },
            });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("abc", res.body);
            try std.testing.expectEqualStrings("abc", res.header("x-echo").?);
        }
    }.run);
}

fn testJson(backend: Backend) !void {
    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/json" });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expect(std.mem.find(u8, res.body, "\"ok\":true") != null or std.mem.find(u8, res.body, "\"ok\": true") != null);
            try std.testing.expect(std.mem.find(u8, res.body, "42") != null);
            if (res.header("content-type")) |ct| {
                try std.testing.expect(std.mem.find(u8, ct, "application/json") != null);
            }
        }
    }.run);
}

fn testKeepalive(backend: Backend) !void {
    if (!backend.isTcp()) return;

    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var stream = try h.connect();
            defer stream.close(io);

            const keep = [_]zx.testing.Header{.{ .name = "Connection", .value = "keep-alive" }};
            const res1 = try h.fetch(arena, .{ .path = "/", .headers = &keep, .stream = &stream });
            try std.testing.expectEqual(@as(u16, 200), res1.status);
            try std.testing.expectEqualStrings("ok", res1.body);

            const res2 = try h.fetch(arena, .{ .path = "/echo?q=again", .headers = &keep, .stream = &stream });
            try std.testing.expectEqual(@as(u16, 200), res2.status);
            try std.testing.expectEqualStrings("again", res2.body);
        }
    }.run);
}

fn testHalfClose(backend: Backend) !void {
    if (!backend.isTcp()) return;

    try withHarness(backend, struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var held: [2]std.Io.net.Stream = undefined;
            for (&held) |*slot| {
                slot.* = try h.connect();
                const res = try h.fetch(arena, .{ .path = "/", .stream = slot });
                try std.testing.expectEqual(@as(u16, 200), res.status);
                try slot.shutdown(io, .send);
            }
            defer for (&held) |*slot| slot.close(io);

            const res = try h.fetch(arena, .{ .path = "/" });
            try std.testing.expectEqual(@as(u16, 200), res.status);
            try std.testing.expectEqualStrings("ok", res.body);
        }
    }.run);
}

const Allocator = std.mem.Allocator;
