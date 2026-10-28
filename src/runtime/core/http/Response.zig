const Response = @This();

const std = @import("std");
const http = @import("../http.zig");
const Transport = @import("Transport.zig");

pub const CookieOptions = http.CookieOptions;

/// The Headers object associated with the response.
///
/// MDN: [Response.headers](https://developer.mozilla.org/en-US/docs/Web/API/Response/headers)
headers: Headers = .{},

/// Cookie accessor for setting/deleting cookies.
cookies: CookieJar = .{},

/// Arena allocator for response-scoped allocations.
arena: std.mem.Allocator,

/// Internal backend transport carrier. All response writes delegate here.
_internal: Transport.Facade = .{},

/// Sets the HTTP status code.
pub fn setStatus(self: *const Response, stat: http.Status) void {
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

/// Sets the Content-Type header.
pub fn setContentType(self: *const Response, content_type: ContentType) void {
    self.headers.set("Content-Type", content_type.toString());
}

/// Creates a redirect response by setting the Location header and status code.
///
/// **Parameters:**
/// - `location`: The URL to redirect to.
/// - `redirect_status`: Optional status code (default: 302 Found).
///
/// MDN: [Response.redirect()](https://developer.mozilla.org/en-US/docs/Web/API/Response/redirect_static)
pub fn redirect(self: *const Response, location: []const u8, redirect_status: ?http.Status) void {
    self.setStatus(redirect_status orelse .found);
    self.headers.set("Location", location);
}

/// Gets the response writer for streaming content.
pub fn writer(self: *const Response) ?*std.Io.Writer {
    return self._internal.http.resWriter();
}

/// Writes a chunk for chunked transfer encoding.
pub fn write(self: *const Response, data: []const u8) !void {
    try self._internal.http.resWrite(data);
}

/// Clears the response writer/buffer.
pub fn clearWriter(self: *const Response) void {
    self._internal.http.resClearWriter();
}

/// The Headers interface of the Fetch API allows you to perform various actions on HTTP request and response headers.
///
/// MDN: [Headers](https://developer.mozilla.org/en-US/docs/Web/API/Headers)
pub const Headers = struct {
    _internal: Transport.Facade = .{},

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
    pub fn append(self: *const Headers, name: []const u8, value: []const u8) void {
        self._internal.http.resHeaderAppend(name, value);
    }
};

/// Sets and deletes cookies on the response.
pub const CookieJar = struct {
    _internal: Transport.Facade = .{},

    /// Sets a cookie on the response.
    ///
    /// MDN: [Cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies)
    pub fn set(self: *const CookieJar, name: []const u8, value: []const u8, options: ?CookieOptions) void {
        const opts = options orelse CookieOptions{};
        self._internal.http.resSetCookie(name, value, opts) catch {};
    }

    /// Deletes a cookie by setting it with an expired max-age.
    pub fn delete(self: *const CookieJar, name: []const u8, options: ?CookieOptions) void {
        var opts = options orelse CookieOptions{};
        opts.max_age = 0;
        self.set(name, "", opts);
    }
};

pub const Init = struct {
    arena: std.mem.Allocator,
    http: Transport = .{},
};

pub fn init(opts: Init) Response {
    return .{
        .arena = opts.arena,
        ._internal = .{ .http = opts.http },
        .headers = .{ ._internal = .{ .http = opts.http } },
        .cookies = .{ ._internal = .{ .http = opts.http } },
    };
}

/// Common MIME content types.
///
/// MDN: https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
///
pub const ContentType = enum {
    // Application types
    @"application/gzip",
    @"application/javascript",
    @"application/json",
    @"application/octet-stream",
    @"application/pdf",
    @"application/wasm",
    @"application/xhtml+xml",
    @"application/xml",
    @"application/x-www-form-urlencoded",

    // Audio types
    @"audio/aac",
    @"audio/mpeg",
    @"audio/ogg",
    @"audio/wav",
    @"audio/webm",

    // Font types
    @"font/otf",
    @"font/ttf",
    @"font/woff",
    @"font/woff2",

    // Image types
    @"image/avif",
    @"image/bmp",
    @"image/gif",
    @"image/jpeg",
    @"image/png",
    @"image/svg+xml",
    @"image/tiff",
    @"image/webp",

    // Multipart types
    @"multipart/form-data",

    // Text types
    @"text/css",
    @"text/csv",
    @"text/html",
    @"text/javascript",
    @"text/plain",
    @"text/xml",

    // Video types
    @"video/mp4",
    @"video/mpeg",
    @"video/ogg",
    @"video/webm",
    @"video/x-msvideo",

    /// Returns the MIME type string.
    pub fn toString(self: ContentType) []const u8 {
        return @tagName(self);
    }
};
