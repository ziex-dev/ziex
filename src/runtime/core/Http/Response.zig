const Response = @This();

const std = @import("std");
const common = @import("common.zig");
const Http = @import("../Http.zig");

pub const Cookies = common.Cookies;
pub const CookieOptions = common.CookieOptions;
pub const ContentType = common.ContentType;
pub const HttpStatus = common.HttpStatus;

/// The Headers object associated with the response.
///
/// MDN: [Response.headers](https://developer.mozilla.org/en-US/docs/Web/API/Response/headers)
headers: Headers = .{},

/// Cookie accessor for setting/deleting cookies.
cookies: ResponseCookies = .{},

/// Arena allocator for response-scoped allocations.
arena: std.mem.Allocator,

/// Internal backend transport carrier. All response writes delegate here.
_internal: Http.Facade = .{},

/// Sets the HTTP status code using an HttpStatus enum.
pub fn setStatus(self: *const Response, stat: HttpStatus) void {
    self._internal.http.resSetStatus(@backingInt(stat));
}

/// Sets the response body directly.
pub fn text(self: *const Response, content: []const u8) void {
    self._internal.http.resSetBody(content);
}

/// Sets the response body to a JSON string.
///
/// **Parameters:**
/// - `value`: The value to serialize as JSON.
/// - `options`: Optional JSON stringify options (whitespace, etc.).
pub fn json(self: *const Response, value: anytype, options: std.json.Stringify.Options) !void {
    self.setContentType(.@"application/json");
    if (self.writer()) |w| {
        try std.json.fmt(value, options).format(w);
        return;
    }
    // Stub / no-transport Response (e.g. docs RenderTest): buffer then text().
    var aw = std.Io.Writer.Allocating.init(self.arena);
    defer aw.deinit();
    try std.json.fmt(value, options).format(&aw.writer);
    self.text(try self.arena.dupe(u8, aw.written()));
}

/// Sets a header on the response.
///
/// MDN: [Response.headers](https://developer.mozilla.org/en-US/docs/Web/API/Response/headers)
pub fn setHeader(self: *const Response, name: []const u8, value: []const u8) void {
    self._internal.http.resHeaderSet(name, value);
}

/// Sets the Content-Type header.
pub fn setContentType(self: *const Response, content_type: ContentType) void {
    self.setHeader("Content-Type", content_type.toString());
}

/// Creates a redirect response by setting the Location header and status code.
///
/// **Parameters:**
/// - `location`: The URL to redirect to.
/// - `redirect_status`: Optional status code (default: 302 Found).
///
/// MDN: [Response.redirect()](https://developer.mozilla.org/en-US/docs/Web/API/Response/redirect_static)
pub fn redirect(self: *const Response, location: []const u8, redirect_status: ?u16) void {
    const code = redirect_status orelse 302;
    self.setStatus(@fromBackingInt(@intCast(code)));
    self.setHeader("Location", location);
}

/// Gets the response writer for streaming content.
pub fn writer(self: *const Response) ?*std.Io.Writer {
    return self._internal.http.resWriter();
}

/// Writes a chunk for chunked transfer encoding.
pub fn chunk(self: *const Response, data: []const u8) !void {
    try self._internal.http.resWriteChunk(data);
}

/// Clears the response writer/buffer.
pub fn clearWriter(self: *const Response) void {
    self._internal.http.resClearWriter();
}

/// The Headers interface of the Fetch API allows you to perform various actions on HTTP request and response headers.
///
/// MDN: [Headers](https://developer.mozilla.org/en-US/docs/Web/API/Headers)
pub const Headers = struct {
    _internal: Http.Facade = .{},

    /// Returns the values of a header with the given name.
    ///
    /// MDN: [Headers.get](https://developer.mozilla.org/en-US/docs/Web/API/Headers/get)
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        return self._internal.http.resHeaderGet(name);
    }

    /// Sets a new value for an existing header inside a Headers object,
    /// or adds the header if it does not already exist.
    ///
    /// MDN: [Headers.set](https://developer.mozilla.org/en-US/docs/Web/API/Headers/set)
    pub fn set(self: *const Headers, name: []const u8, value: []const u8) void {
        self._internal.http.resHeaderSet(name, value);
    }

    /// Appends a new value onto an existing header inside a Headers object,
    /// or adds the header if it does not already exist.
    ///
    /// MDN: [Headers.append](https://developer.mozilla.org/en-US/docs/Web/API/Headers/append)
    pub fn add(self: *const Headers, name: []const u8, value: []const u8) void {
        self._internal.http.resHeaderAdd(name, value);
    }
};

/// The ResponseCookies interface provides utility methods to work with cookies on the response.
pub const ResponseCookies = struct {
    _internal: Http.Facade = .{},

    /// Sets a cookie on the response.
    ///
    /// MDN: [Cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies)
    pub fn set(self: *const ResponseCookies, name: []const u8, value: []const u8, options: ?CookieOptions) void {
        const opts = options orelse CookieOptions{};
        self._internal.http.resSetCookie(name, value, opts) catch {};
    }

    /// Deletes a cookie by setting it with an expired max-age.
    pub fn delete(self: *const ResponseCookies, name: []const u8, options: ?CookieOptions) void {
        var opts = options orelse CookieOptions{};
        opts.max_age = 0;
        self.set(name, "", opts);
    }
};

pub const Init = struct {
    arena: std.mem.Allocator,
    http: Http = .{},
};

pub fn init(opts: Init) Response {
    return .{
        .arena = opts.arena,
        ._internal = .{ .http = opts.http },
        .headers = .{ ._internal = .{ .http = opts.http } },
        .cookies = .{ ._internal = .{ .http = opts.http } },
    };
}
