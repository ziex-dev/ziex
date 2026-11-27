const std = @import("std");
const zx = @import("zx");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Allocator = std.mem.Allocator;
const Backend = zx.testing.Backend;
const Harness = zx.testing.Harness;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

const backends = [_]Backend{ .httpz, .std, .wasm };

test "proxy > before and after the handler" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/proxy" });
            try expectEqual(200, res.status);
            try expectEqualStrings("root", res.body);
            try expectEqualStrings("root>,handler,<root", res.header("x-trace").?);
            try expectEqualStrings("200", res.header("x-seen-status").?);
        }
    }.run);
}

test "proxy > cascades, continues without next() and passes state" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/proxy/inner" });
            try expectEqual(200, res.status);
            try expectEqualStrings("ada", res.body);
            try expectEqualStrings("root>,inner,route-proxy,handler,<root", res.header("x-trace").?);
        }
    }.run);
}

test "proxy > PageProxy wraps a page; local proxies don't cascade" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/proxy/inner/page" });
            try expectEqual(200, res.status);
            try expect(std.mem.indexOf(u8, res.body, "proxied page") != null);
            try expectEqualStrings("root>,inner,page-proxy,page,<root", res.header("x-trace").?);
            try expectEqualStrings("1", res.header("x-after-page").?);
        }
    }.run);
}

test "proxy > abort skips the handler and unwinds outer proxies" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var res = try h.fetch(arena, .{ .path = "/proxy/guard" });
            try expectEqual(403, res.status);
            try expectEqualStrings("blocked", res.body);
            try expectEqualStrings("root>,guard,<root", res.header("x-trace").?);
            try expectEqualStrings("403", res.header("x-seen-status").?);

            res = try h.fetch(arena, .{ .path = "/proxy/guard", .headers = &.{.{ .name = "Authorization", .value = "yes" }} });
            try expectEqual(200, res.status);
            try expectEqualStrings("allowed", res.body);
            try expectEqualStrings("root>,guard,handler,<root", res.header("x-trace").?);
        }
    }.run);
}

test "proxy > after next() the response can change or be replaced" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var res = try h.fetch(arena, .{ .path = "/proxy/after" });
            try expectEqual(201, res.status);
            try expectEqualStrings("original", res.body);
            try expectEqualStrings("1", res.header("x-after").?);
            // The handler runs once even though next() is called twice.
            try expectEqualStrings("root>,handler,<root", res.header("x-trace").?);
            try expectEqualStrings("201", res.header("x-seen-status").?);

            res = try h.fetch(arena, .{ .path = "/proxy/after", .headers = &.{.{ .name = "x-replace", .value = "1" }} });
            try expectEqual(201, res.status);
            try expectEqualStrings("replaced", res.body);
        }
    }.run);
}

test "proxy > errors answer 500 without running the handler" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var res = try h.fetch(arena, .{ .path = "/proxy/fail" });
            try expectEqual(500, res.status);
            try expect(std.mem.indexOf(u8, res.body, "unreachable") == null);
            try expectEqualStrings("root>,<root", res.header("x-trace").?);

            res = try h.fetch(arena, .{ .path = "/proxy", .headers = &.{.{ .name = "x-fail-before", .value = "1" }} });
            try expectEqual(500, res.status);
            try expectEqualStrings("root>", res.header("x-trace").?);
        }
    }.run);
}

test "proxy > Proxy in a dynamic segment cascades" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var res = try h.fetch(arena, .{ .path = "/proxy/items/7/detail" });
            try expectEqual(200, res.status);
            try expectEqualStrings("detail", res.body);
            try expectEqualStrings("root>,item,handler,<root", res.header("x-trace").?);

            res = try h.fetch(arena, .{ .path = "/proxy/items/7" });
            try expectEqualStrings("item", res.body);
            try expectEqualStrings("root>,item,handler,<root", res.header("x-trace").?);
        }
    }.run);
}

test "proxy > unmatched paths run the closest ancestor's proxies" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var res = try h.fetch(arena, .{ .path = "/proxy/missing" });
            try expectEqual(404, res.status);
            try expectEqualStrings("root>,<root", res.header("x-trace").?);

            // Routes outside /proxy are untouched.
            res = try h.fetch(arena, .{ .path = "/" });
            try expectEqual(200, res.status);
            try expect(res.header("x-trace") == null);
        }
    }.run);
}

fn forEachBackend(comptime body: *const fn (*Harness, Allocator) anyerror!void) !void {
    inline for (backends) |backend| {
        run(backend, body) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

fn run(backend: Backend, comptime body: *const fn (*Harness, Allocator) anyerror!void) !void {
    var harness = try Harness.start(backend, io, gpa, .{
        .workers = .{ .count = 1, .min_conn = 1, .max_conn = 2 },
        .thread_pool = .{ .count = 1 },
    });
    defer harness.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try body(&harness, arena_state.allocator());
}
