const std = @import("std");
const zx = @import("zx");

const Client = zx.http.Client;
const Harness = zx.testing.Harness;
const Backend = zx.testing.Backend;

const io = std.testing.io;
const gpa = std.testing.allocator;

const backends = [_]Backend{ .httpz, .std };

// --- Result.parse --- //

const sample_head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n";

fn sampleResult(body: []const u8) !Client.Result {
    const bytes = try std.mem.concat(gpa, u8, &.{ sample_head, body });
    return Client.Result.parse(gpa, .ok, bytes, sample_head.len);
}

test "result > parse splits head and body" {
    const res = try sampleResult("hello");
    defer res.deinit(gpa);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("hello", res.body);
    try std.testing.expectEqual(@as(usize, 3), res.headers.len);
    try std.testing.expectEqualStrings("Content-Type", res.headers[0].name);
}

test "result > header is case-insensitive" {
    const res = try sampleResult("");
    defer res.deinit(gpa);

    try std.testing.expectEqualStrings("text/plain", res.header("content-type").?);
    try std.testing.expect(res.header("x-missing") == null);
}

test "result > repeated headers are kept" {
    const res = try sampleResult("");
    defer res.deinit(gpa);

    var cookies: usize = 0;
    for (res.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) cookies += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cookies);
    try std.testing.expectEqualStrings("a=1", res.header("set-cookie").?);
}

test "result > parse without head" {
    const bytes = try gpa.dupe(u8, "raw");
    const res = try Client.Result.parse(gpa, .not_found, bytes, 0);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.headers.len);
    try std.testing.expectEqualStrings("raw", res.body);
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
}

test "result > head longer than bytes is rejected and freed" {
    const bytes = try gpa.dupe(u8, "short");
    try std.testing.expectError(error.InvalidResponse, Client.Result.parse(gpa, .ok, bytes, 10));
}

test "result > json" {
    const res = try sampleResult("{\"n\":7,\"extra\":true}");
    defer res.deinit(gpa);

    const parsed = try res.json(struct { n: u32 }, gpa);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 7), parsed.value.n);
}

// --- Request encoding --- //

test "options > method name" {
    try std.testing.expectEqualStrings("GET", (Client.FetchOptions{ .url = "/" }).methodName());
    try std.testing.expectEqualStrings("DELETE", (Client.FetchOptions{ .url = "/", .method = .DELETE }).methodName());
    try std.testing.expectEqualStrings("PROPFIND", (Client.FetchOptions{ .url = "/", .method_name = "PROPFIND" }).methodName());
}

test "headers json > pairs keep order, duplicates and escapes" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try Client.writeHeadersJson(&out.writer, &.{
        .{ .name = "Accept", .value = "a" },
        .{ .name = "Accept", .value = "b" },
        .{ .name = "X-Quote", .value = "say \"hi\"" },
    });
    try std.testing.expectEqualStrings(
        \\[["Accept","a"],["Accept","b"],["X-Quote","say \"hi\""]]
    , out.written());
}

test "headers json > empty" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try Client.writeHeadersJson(&out.writer, &.{});
    try std.testing.expectEqualStrings("[]", out.written());
}

// --- Native fetch against the test server --- //

fn forEachBackend(comptime case: *const fn (*Client, []const u8) anyerror!void) !void {
    inline for (backends) |backend| {
        runCase(backend, case) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

fn runCase(backend: Backend, comptime case: *const fn (*Client, []const u8) anyerror!void) !void {
    var harness = try Harness.start(backend, io, gpa, .{});
    defer harness.stop();

    var base_buf: [32]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{harness.tcp.?.port});

    var client: Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();
    try case(&client, base);
}

fn url(buf: []u8, base: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, path });
}

test "fetch > GET" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/") });
            defer res.deinit(gpa);

            try std.testing.expectEqual(std.http.Status.ok, res.status);
            try std.testing.expectEqualStrings("ok", res.body);
        }
    }.run);
}

test "fetch > query string" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/echo?q=hello") });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("hello", res.body);
        }
    }.run);
}

test "fetch > POST payload" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/echo"), .method = .POST, .payload = "ping" });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("ping", res.body);
        }
    }.run);
}

test "fetch > request and response headers" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{
                .url = try url(&buf, base, "/headers"),
                .headers = &.{.{ .name = "x-test", .value = "abc" }},
            });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("abc", res.body);
            try std.testing.expectEqualStrings("abc", res.header("X-Echo").?);
        }
    }.run);
}

test "fetch > json" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/json") });
            defer res.deinit(gpa);

            try std.testing.expect(std.mem.startsWith(u8, res.header("content-type").?, "application/json"));
        }
    }.run);
}

test "fetch > non-2xx is a result, not an error" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/missing") });
            defer res.deinit(gpa);

            try std.testing.expectEqual(std.http.Status.not_found, res.status);
        }
    }.run);
}

test "fetch > redirect follow" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/redirect") });
            defer res.deinit(gpa);

            try std.testing.expectEqual(std.http.Status.ok, res.status);
            try std.testing.expectEqualStrings("moved", res.body);
        }
    }.run);
}

test "fetch > redirect manual" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{ .url = try url(&buf, base, "/redirect"), .redirect = .manual });
            defer res.deinit(gpa);

            try std.testing.expectEqual(std.http.Status.found, res.status);
            try std.testing.expectEqualStrings("/echo?q=moved", res.header("location").?);
        }
    }.run);
}

test "fetch > custom method name" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            const res = try client.fetch(.{
                .url = try url(&buf, base, "/echo"),
                .method_name = "POST",
                .payload = "custom",
                .headers = &.{.{ .name = "x-extra", .value = "1" }},
            });
            defer res.deinit(gpa);

            try std.testing.expectEqual(std.http.Status.ok, res.status);
            try std.testing.expectEqualStrings("custom", res.body);
        }
    }.run);
}

test "fetch > reuses the client across requests" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            for (0..3) |_| {
                const res = try client.fetch(.{ .url = try url(&buf, base, "/") });
                defer res.deinit(gpa);
                try std.testing.expectEqualStrings("ok", res.body);
            }
        }
    }.run);
}

test "fetch > invalid url" {
    var client: Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();
    try std.testing.expectError(error.InvalidUrl, client.fetch(.{ .url = "not a url" }));
}

test "fetch > connection refused" {
    var client: Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();
    try std.testing.expectError(error.NetworkError, client.fetch(.{ .url = "http://127.0.0.1:1/" }));
}

// --- fetchThen --- //

const Captured = struct {
    calls: usize = 0,
    status: ?std.http.Status = null,
    body: [16]u8 = undefined,
    body_len: usize = 0,
    err: ?Client.Error = null,

    fn onDone(self: *Captured, result: Client.Error!Client.Result) void {
        self.calls += 1;
        const res = result catch |err| {
            self.err = err;
            return;
        };
        self.status = res.status;
        self.body_len = @min(res.body.len, self.body.len);
        @memcpy(self.body[0..self.body_len], res.body[0..self.body_len]);
    }
};

test "fetchThen > calls back with a typed context" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            var captured: Captured = .{};
            client.fetchThen(.{ .url = try url(&buf, base, "/echo?q=then") }, &captured, Captured.onDone);

            try std.testing.expectEqual(@as(usize, 1), captured.calls);
            try std.testing.expectEqual(std.http.Status.ok, captured.status.?);
            try std.testing.expectEqualStrings("then", captured.body[0..captured.body_len]);
        }
    }.run);
}

var void_calls: usize = 0;

fn onVoid(_: void, result: Client.Error!Client.Result) void {
    _ = result catch return;
    void_calls += 1;
}

test "fetchThen > void context" {
    try forEachBackend(struct {
        fn run(client: *Client, base: []const u8) !void {
            var buf: [64]u8 = undefined;
            void_calls = 0;
            client.fetchThen(.{ .url = try url(&buf, base, "/") }, {}, onVoid);
            try std.testing.expectEqual(@as(usize, 1), void_calls);
        }
    }.run);
}

test "fetchThen > errors reach the callback" {
    var client: Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    var captured: Captured = .{};
    client.fetchThen(.{ .url = "not a url" }, &captured, Captured.onDone);
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(error.InvalidUrl, captured.err.?);
}

// --- Context helpers --- //

test "ctx > fetch uses the request arena" {
    var harness = try Harness.start(.std, io, gpa, .{});
    defer harness.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = zx.RouteContext.init(
        zx.server.Request.init(.{ .arena = arena }),
        zx.server.Response.init(.{ .arena = arena }),
        gpa,
        io,
    );

    const target = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/echo?q=ctx", .{harness.tcp.?.port});
    // No deinit: the arena owns the result.
    const res = try ctx.fetch(.{ .url = target });
    try std.testing.expectEqualStrings("ctx", res.body);

    var captured: Captured = .{};
    ctx.fetchThen(.{ .url = target }, &captured, Captured.onDone);
    try std.testing.expectEqualStrings("ctx", captured.body[0..captured.body_len]);
}

// --- zx.Io --- //

test "io > default is shared and usable" {
    const io_a = zx.Io.default();
    const io_b = zx.Io.default();
    try std.testing.expectEqual(io_a.userdata, io_b.userdata);

    const start = std.Io.Clock.awake.now(io_a);
    try io_a.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io_a)).nanoseconds >= 5 * std.time.ns_per_ms);

    var bytes: [32]u8 = @splat(0);
    io_a.random(&bytes);
    try std.testing.expect(!std.mem.allEqual(u8, &bytes, 0));
}

test "io > component context gets the default io" {
    const Ctx = zx.ComponentCtx(void);
    try std.testing.expect(@FieldType(Ctx, "io") == std.Io);
    try std.testing.expect(@hasDecl(Ctx, "fetch") and @hasDecl(Ctx, "fetchThen"));
}
