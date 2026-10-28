const std = @import("std");
const zx = @import("zx");

const Request = zx.server.Request;
const Response = zx.server.Response;

// --- Type Re-exports --- //
test "req > method" {
    try std.testing.expect(Request.Method == std.http.Method);
}

test "req > version" {
    try std.testing.expect(Request.Version == std.http.Version);
}

test "req > header" {
    try std.testing.expect(Request.Header == std.http.Header);
}

// --- Request Instance (without backend) --- //

test "req > init default" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });

    try std.testing.expectEqualStrings("", req.url);
    try std.testing.expectEqualStrings("/", req.pathname);
    try std.testing.expectEqualStrings("", req.search);
    try std.testing.expectEqualStrings("", req.referrer);
    try std.testing.expectEqual(Request.Method.GET, req.method);
    try std.testing.expectEqual(Request.Version.@"HTTP/1.1", req.version);
}

test "req > text no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.text() == null);
}

test "req > params.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.params.get("id") == null);
}

test "req > cookies accessor" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "session=abc123; count=42",
    });

    try std.testing.expectEqualStrings("abc123", req.cookies.get("session").?);
    try std.testing.expectEqual(@as(i32, 42), req.cookies.as("count", i32).?);
}

// --- Headers --- //

test "req > headers.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.headers.get("Content-Type") == null);
}

test "req > headers.has no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(!req.headers.has("Content-Type"));
}

// --- UrlSearchParams --- //

test "req > query.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.query.get("q") == null);
}

test "req > query.has no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(!req.query.has("q"));
}

test "conn > query.get percent-decodes values" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var conn = zx.Http.Conn.init(arena);
    defer conn.deinit();
    conn.search = "?msg=hello%20world&q=a+b&flag";

    const req = conn.request(.GET, "/", "/?msg=hello%20world&q=a+b&flag");
    try std.testing.expectEqualStrings("hello world", req.query.get("msg").?);
    try std.testing.expectEqualStrings("a b", req.query.get("q").?);
    try std.testing.expectEqualStrings("", req.query.get("flag").?);
    try std.testing.expect(req.query.has("msg"));
    try std.testing.expect(!req.query.has("missing"));
}

// --- Init --- //

test "req > init custom" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .url = "/api/users",
        .method = .POST,
        .pathname = "/api/users",
        .search = "?page=1",
        .referrer = "https://example.com",
        .version = .@"HTTP/1.0",
        .cookie_header = "session=xyz",
        .arena = fba.allocator(),
    });

    try std.testing.expectEqualStrings("/api/users", req.url);
    try std.testing.expectEqual(Request.Method.POST, req.method);
    try std.testing.expectEqualStrings("/api/users", req.pathname);
    try std.testing.expectEqualStrings("?page=1", req.search);
    try std.testing.expectEqualStrings("https://example.com", req.referrer);
    try std.testing.expectEqual(Request.Version.@"HTTP/1.0", req.version);
    try std.testing.expectEqualStrings("xyz", req.cookies.get("session").?);
}

// --- Type Re-exports --- //

test "res > status" {
    try std.testing.expect(zx.Http.Status == std.http.Status);
}

test "res > content type" {
    // Verify it exists and has expected variants
    try std.testing.expectEqualStrings("text/html", Response.ContentType.@"text/html".toString());
}

test "res > cookie options" {
    const opts = Response.CookieOptions{};
    try std.testing.expectEqualStrings("", opts.path);
}

test "res > headers" {
    const headers = Response.Headers{};
    // Response.Headers has get, set, append methods
    try std.testing.expect(headers.get("X-Test") == null);
}

// --- Methods (without backend) --- //

test "res > set status no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    // Should not crash
    res.setStatus(.not_found);
}

test "res > text no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    res.text("Hello");
}

test "res > redirect no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    res.redirect("/new", null);
    res.redirect("/permanent", .moved_permanently);
}

// --- Headers --- //

test "res > headers.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response{ .arena = fba.allocator() };
    try std.testing.expect(res.headers.get("Content-Type") == null);
}

test "res > headers.set no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response{ .arena = fba.allocator() };
    // These should not crash (no-op without backend)
    res.headers.set("X-Test", "value");
    res.headers.append("X-Test", "value2");
}

// --- Cookies (accessed via Request) --- //

test "cookies > get value" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "session=abc123; user=john",
    });

    try std.testing.expectEqualStrings("abc123", req.cookies.get("session").?);
    try std.testing.expectEqualStrings("john", req.cookies.get("user").?);
}

test "cookies > get missing" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "session=abc123",
    });

    try std.testing.expectEqual(null, req.cookies.get("missing"));
}

test "cookies > empty header" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "",
    });

    try std.testing.expectEqual(null, req.cookies.get("session"));
}

test "cookies > spaces" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "a=1; b=2;  c=3",
    });

    try std.testing.expectEqualStrings("1", req.cookies.get("a").?);
    try std.testing.expectEqualStrings("2", req.cookies.get("b").?);
    try std.testing.expectEqualStrings("3", req.cookies.get("c").?);
}

// --- CookieOptions (accessed via Response) --- //

test "cookie opts > default" {
    const opts = Response.CookieOptions{};
    try std.testing.expectEqualStrings("", opts.path);
    try std.testing.expectEqualStrings("", opts.domain);
    try std.testing.expectEqual(null, opts.max_age);
    try std.testing.expect(!opts.secure);
    try std.testing.expect(!opts.http_only);
    try std.testing.expect(!opts.partitioned);
    try std.testing.expectEqual(null, opts.same_site);
}

test "cookie opts > all values" {
    const opts = Response.CookieOptions{
        .path = "/api",
        .domain = "example.com",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .partitioned = true,
        .same_site = .strict,
    };
    try std.testing.expectEqualStrings("/api", opts.path);
    try std.testing.expectEqualStrings("example.com", opts.domain);
    try std.testing.expectEqual(@as(?i32, 3600), opts.max_age);
    try std.testing.expect(opts.secure);
    try std.testing.expect(opts.http_only);
    try std.testing.expect(opts.partitioned);
    try std.testing.expectEqual(Response.CookieOptions.SameSite.strict, opts.same_site.?);
}

test "cookie opts > same site" {
    const values = [_]Response.CookieOptions.SameSite{ .lax, .strict, .none };
    try std.testing.expectEqual(3, values.len);
}

// --- ContentType (accessed via Response) --- //

test "content type > to string" {
    try std.testing.expectEqualStrings("text/html", Response.ContentType.@"text/html".toString());
    try std.testing.expectEqualStrings("application/json", Response.ContentType.@"application/json".toString());
    try std.testing.expectEqualStrings("application/wasm", Response.ContentType.@"application/wasm".toString());
    try std.testing.expectEqualStrings("image/png", Response.ContentType.@"image/png".toString());
}

// --- MultiFormEntry (accessed via Request) --- //

test "form entry > fields" {
    const entry = Request.MultiFormEntry{
        .key = "file",
        .value = "binary data",
        .filename = "photo.jpg",
    };
    try std.testing.expectEqualStrings("file", entry.key);
    try std.testing.expectEqualStrings("binary data", entry.value);
    try std.testing.expectEqualStrings("photo.jpg", entry.filename.?);
}

test "form entry > filename" {
    const entry = Request.MultiFormEntry{
        .key = "name",
        .value = "John",
        .filename = null,
    };
    try std.testing.expectEqual(null, entry.filename);
}
