const std = @import("std");
const zx = @import("zx");

const Request = zx.server.Request;
const Response = zx.server.Response;

// --- Type Re-exports --- //
test "Request.Method" {
    try std.testing.expect(Request.Method == std.http.Method);
}

test "Request.Version" {
    try std.testing.expect(Request.Version == std.http.Version);
}

test "Request.Header" {
    try std.testing.expect(Request.Header == std.http.Header);
}

// --- Request Instance (without backend) --- //

test "Request.init default" {
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

test "Request.text no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.text() == null);
}

test "Request.params.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.params.get("id") == null);
}

test "Request.cookies accessor" {
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

test "Request.headers.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.headers.get("Content-Type") == null);
}

test "Request.headers.has no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(!req.headers.has("Content-Type"));
}

// --- URLSearchParams --- //

test "Request.queries.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(req.queries.get("q") == null);
}

test "Request.queries.has no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{ .arena = fba.allocator() });
    try std.testing.expect(!req.queries.has("q"));
}

test "Conn.queries.get percent-decodes values" {
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

test "Request.init custom" {
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

test "Response.HttpStatus" {
    try std.testing.expect(Response.HttpStatus == std.http.Status);
}

test "Response.ContentType" {
    // Verify it exists and has expected variants
    try std.testing.expectEqualStrings("text/html", Response.ContentType.@"text/html".toString());
}

test "Response.CookieOptions" {
    const opts = Response.CookieOptions{};
    try std.testing.expectEqualStrings("", opts.path);
}

test "Response.Headers" {
    const headers = Response.Headers{};
    // Response.Headers has get, set, add methods
    try std.testing.expect(headers.get("X-Test") == null);
}

// --- Response Instance (Web Standard Properties) --- //

test "Response default" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response{ .arena = fba.allocator() };

    try std.testing.expectEqualStrings("", res.body);
    try std.testing.expect(!res.bodyUsed);
    try std.testing.expect(res.ok);
    try std.testing.expect(!res.redirected);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("OK", res.statusText);
    try std.testing.expectEqual(Response.ResponseType.default, res.type);
    try std.testing.expectEqualStrings("", res.url);
}

test "Response.ok 2xx" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res200 = Response.init(.{ .status = 200, .arena = fba.allocator() });
    const res201 = Response.init(.{ .status = 201, .arena = fba.allocator() });
    const res299 = Response.init(.{ .status = 299, .arena = fba.allocator() });

    try std.testing.expect(res200.ok);
    try std.testing.expect(res201.ok);
    try std.testing.expect(res299.ok);
}

test "Response.ok non-2xx" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res199 = Response.init(.{ .status = 199, .arena = fba.allocator() });
    const res300 = Response.init(.{ .status = 300, .arena = fba.allocator() });
    const res404 = Response.init(.{ .status = 404, .arena = fba.allocator() });
    const res500 = Response.init(.{ .status = 500, .arena = fba.allocator() });

    try std.testing.expect(!res199.ok);
    try std.testing.expect(!res300.ok);
    try std.testing.expect(!res404.ok);
    try std.testing.expect(!res500.ok);
}

test "Response.statusText" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res200 = Response.init(.{ .status = 200, .arena = fba.allocator() });
    const res404 = Response.init(.{ .status = 404, .arena = fba.allocator() });
    const res500 = Response.init(.{ .status = 500, .arena = fba.allocator() });

    try std.testing.expectEqualStrings("OK", res200.statusText);
    try std.testing.expectEqualStrings("Not Found", res404.statusText);
    try std.testing.expectEqualStrings("Internal Server Error", res500.statusText);
}

// --- ResponseType --- //

test "Response.ResponseType" {
    const types = [_]Response.ResponseType{
        .basic, .cors, .default, .@"error", .@"opaque", .opaqueredirect,
    };
    try std.testing.expectEqual(6, types.len);
}

// --- Init --- //

test "Response.init custom" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{
        .status = 201,
        .url = "https://example.com/api",
        .response_type = .cors,
        .arena = fba.allocator(),
    });

    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expect(res.ok);
    try std.testing.expectEqualStrings("Created", res.statusText);
    try std.testing.expectEqualStrings("https://example.com/api", res.url);
    try std.testing.expectEqual(Response.ResponseType.cors, res.type);
}

// --- Methods (without backend) --- //

test "Response.setStatus no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    // Should not crash, but local fields remain unchanged
    res.setStatus(.not_found);
    try std.testing.expectEqual(@as(u16, 200), res.status);
}

test "Response.text no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    res.text("Hello");
    try std.testing.expectEqualStrings("", res.body);
}

test "Response.redirect no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response.init(.{ .arena = fba.allocator() });

    res.redirect("/new", null);
    res.redirect("/permanent", 301);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(!res.redirected);
}

// --- Headers --- //

test "Response.headers.get no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response{ .arena = fba.allocator() };
    try std.testing.expect(res.headers.get("Content-Type") == null);
}

test "Response.headers.set no backend" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const res = Response{ .arena = fba.allocator() };
    // These should not crash (no-op without backend)
    res.headers.set("X-Test", "value");
    res.headers.add("X-Test", "value2");
}

const Headers = @import("zx").Headers;

// --- Type Re-exports --- //

test "Headers.Header" {
    try std.testing.expect(Headers.Header == std.http.Header);
}

test "Headers.HeaderIterator" {
    try std.testing.expect(Headers.HeaderIterator == std.http.HeaderIterator);
}

// --- HeaderIterator Usage --- //

test "Headers.HeaderIterator parse" {
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

test "Headers read-only" {
    const headers = Headers{};
    try std.testing.expect(headers.isReadOnly());
}

test "Headers writable" {
    const headers = Headers{ .read_only = false };
    try std.testing.expect(!headers.isReadOnly());
}

test "Headers.get no backend" {
    const headers = Headers{};
    try std.testing.expect(headers.get("Content-Type") == null);
}

test "Headers.has no backend" {
    const headers = Headers{};
    try std.testing.expect(!headers.has("Content-Type"));
}

test "Headers.entries no backend" {
    const headers = Headers{};
    try std.testing.expect(headers.entries() == null);
}

test "Headers.write no backend" {
    var headers = Headers{ .read_only = false };
    // These should not crash
    headers.append("X-Test", "value");
    headers.set("X-Test", "value");
    headers.delete("X-Test");
}

test "Headers.write read-only" {
    var headers = Headers{}; // read_only = true by default
    // These should not crash and should be no-ops
    headers.append("X-Test", "value");
    headers.set("X-Test", "value");
}

// --- Init --- //

test "Headers.Builder default" {
    const headers = (Headers.Builder{}).build();
    try std.testing.expect(headers.read_only);
    try std.testing.expect(headers.backend_ctx == null);
    try std.testing.expect(headers.vtable == null);
}

test "Headers.Builder custom" {
    const headers = (Headers.Builder{
        .read_only = false,
    }).build();
    try std.testing.expect(!headers.read_only);
}

// --- Cookies (accessed via Request) --- //

test "Cookies.get value" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "session=abc123; user=john",
    });

    try std.testing.expectEqualStrings("abc123", req.cookies.get("session").?);
    try std.testing.expectEqualStrings("john", req.cookies.get("user").?);
}

test "Cookies.get missing" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "session=abc123",
    });

    try std.testing.expectEqual(null, req.cookies.get("missing"));
}

test "Cookies empty header" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const req = Request.init(.{
        .arena = fba.allocator(),
        .cookie_header = "",
    });

    try std.testing.expectEqual(null, req.cookies.get("session"));
}

test "Cookies spaces" {
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

test "CookieOptions default" {
    const opts = Response.CookieOptions{};
    try std.testing.expectEqualStrings("", opts.path);
    try std.testing.expectEqualStrings("", opts.domain);
    try std.testing.expectEqual(null, opts.max_age);
    try std.testing.expect(!opts.secure);
    try std.testing.expect(!opts.http_only);
    try std.testing.expect(!opts.partitioned);
    try std.testing.expectEqual(null, opts.same_site);
}

test "CookieOptions all values" {
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

test "CookieOptions.SameSite" {
    const values = [_]Response.CookieOptions.SameSite{ .lax, .strict, .none };
    try std.testing.expectEqual(3, values.len);
}

// --- ContentType (accessed via Response) --- //

test "ContentType.toString" {
    try std.testing.expectEqualStrings("text/html", Response.ContentType.@"text/html".toString());
    try std.testing.expectEqualStrings("application/json", Response.ContentType.@"application/json".toString());
    try std.testing.expectEqualStrings("application/wasm", Response.ContentType.@"application/wasm".toString());
    try std.testing.expectEqualStrings("image/png", Response.ContentType.@"image/png".toString());
}

// --- MultiFormEntry (accessed via Request) --- //

test "MultiFormEntry fields" {
    const entry = Request.MultiFormEntry{
        .key = "file",
        .value = "binary data",
        .filename = "photo.jpg",
    };
    try std.testing.expectEqualStrings("file", entry.key);
    try std.testing.expectEqualStrings("binary data", entry.value);
    try std.testing.expectEqualStrings("photo.jpg", entry.filename.?);
}

test "MultiFormEntry filename" {
    const entry = Request.MultiFormEntry{
        .key = "name",
        .value = "John",
        .filename = null,
    };
    try std.testing.expectEqual(null, entry.filename);
}
