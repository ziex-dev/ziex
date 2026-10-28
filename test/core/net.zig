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
    try std.testing.expectEqual(Request.Version.@"HTTP/1.1", req.protocol);
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

// --- URLSearchParams --- //

test "req > queries.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.queries.get("q") == null);
}

test "req > queries.has no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(!req.queries.has("q"));
}

test "conn > queries.get percent-decodes values" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var conn = zx.Http.Conn.init(arena);
    defer conn.deinit();
    conn.search = "?msg=hello%20world&q=a+b&flag";

    const req = conn.request(.GET, "/", "/?msg=hello%20world&q=a+b&flag");
    try std.testing.expectEqualStrings("hello world", req.queries.get("msg").?);
    try std.testing.expectEqualStrings("a b", req.queries.get("q").?);
    try std.testing.expectEqualStrings("", req.queries.get("flag").?);
    try std.testing.expect(req.queries.has("msg"));
    try std.testing.expect(!req.queries.has("missing"));
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
        .protocol = .@"HTTP/1.0",
        .cookie_header = "session=xyz",
        .arena = fba.allocator(),
    });

    try std.testing.expectEqualStrings("/api/users", req.url);
    try std.testing.expectEqual(Request.Method.POST, req.method);
    try std.testing.expectEqualStrings("/api/users", req.pathname);
    try std.testing.expectEqualStrings("?page=1", req.search);
    try std.testing.expectEqualStrings("https://example.com", req.referrer);
    try std.testing.expectEqual(Request.Version.@"HTTP/1.0", req.protocol);
    try std.testing.expectEqualStrings("xyz", req.cookies.get("session").?);
}

// --- Type Re-exports --- //

test "res > status" {
    try std.testing.expect(Response.HttpStatus == std.http.Status);
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
    // Response.Headers has get, set, add methods
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
    res.redirect("/permanent", 301);
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
    res.headers.add("X-Test", "value2");
}

const Headers = @import("zx").Headers;

// --- Type Re-exports --- //

test "headers > header" {
    try std.testing.expect(Headers.Header == std.http.Header);
}

test "headers > iterator" {
    try std.testing.expect(Headers.HeaderIterator == std.http.HeaderIterator);
}

// --- HeaderIterator Usage --- //

test "headers > iterator parse" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-Custom: value\r\n\r\n";
    var iter = Headers.HeaderIterator.init(raw);

    const h1 = iter.next().?;
    try std.testing.expectEqualStrings("Content-Type", h1.name);
    try std.testing.expectEqualStrings("text/html", h1.value);

    const h2 = iter.next().?;
    try std.testing.expectEqualStrings("X-Custom", h2.name);
    try std.testing.expectEqualStrings("value", h2.value);

    try std.testing.expect(iter.next() == null);
}

// --- Headers Instance (without backend) --- //

test "headers > read-only" {
    const headers = Headers{};
    try std.testing.expect(headers.isReadOnly());
}

test "headers > writable" {
    const headers = Headers{ .read_only = false };
    try std.testing.expect(!headers.isReadOnly());
}

test "headers > get no backend" {
    const headers = Headers{};
    try std.testing.expect(headers.get("Content-Type") == null);
}

test "headers > has no backend" {
    const headers = Headers{};
    try std.testing.expect(!headers.has("Content-Type"));
}

test "headers > entries no backend" {
    const headers = Headers{};
    try std.testing.expect(headers.entries() == null);
}

test "headers > write no backend" {
    var headers = Headers{ .read_only = false };
    // These should not crash
    headers.append("X-Test", "value");
    headers.set("X-Test", "value");
    headers.delete("X-Test");
}

test "headers > write read-only" {
    var headers = Headers{}; // read_only = true by default
    // These should not crash and should be no-ops
    headers.append("X-Test", "value");
    headers.set("X-Test", "value");
}

// --- Init --- //

test "headers > builder default" {
    const headers = (Headers.Builder{}).build();
    try std.testing.expect(headers.read_only);
    try std.testing.expect(headers.backend_ctx == null);
    try std.testing.expect(headers.vtable == null);
}

test "headers > builder custom" {
    const headers = (Headers.Builder{
        .read_only = false,
    }).build();
    try std.testing.expect(!headers.read_only);
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
