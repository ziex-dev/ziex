const std = @import("std");

/// HTTP header name/value pair
pub const Header = std.http.Header;

/// HTTP header iterator for parsing raw header bytes.
///
/// Useful for parsing HTTP headers from raw bytes. Initializes with `init(bytes)`
/// and iterates via `next()` returning `?Header`.
pub const HeaderIterator = std.http.HeaderIterator;

/// Entry type for multipart form data (includes optional filename).
pub const MultiFormEntry = struct {
    key: []const u8,
    value: []const u8,
    filename: ?[]const u8,
};

// --- HTTP Method (from std.http) --- //
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods

/// HTTP request methods - re-exported from std.http.Method for convenience.
///
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods
///
/// Includes useful methods:
/// - `requestHasBody()`: Returns true if request of this method can have a body
/// - `responseHasBody()`: Returns true if response to this method can have a body
/// - `safe()`: Returns true if this method doesn't alter server state
/// - `idempotent()`: Returns true if identical requests have the same effect
/// - `cacheable()`: Returns true if response can be cached
///
/// **Note:** Unlike some HTTP libraries, std.http.Method does not have an "OTHER"
/// variant for unknown methods. All standard HTTP methods are supported.
/// TODO: move to using own custom Method type that includes an "OTHER" variant for non-standard methods.
pub const Method = std.http.Method;

/// HTTP protocol versions
pub const Version = std.http.Version;

/// Cookie accessor - parses cookies from the Cookie header.
///
/// In browsers, cookies are accessed via `document.cookie`.
pub const Cookies = struct {
    header_value: []const u8,

    pub fn get(self: Cookies, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.header_value, ';');
        while (it.next()) |kv| {
            const trimmed = std.mem.trimStart(u8, kv, " ");
            if (name.len >= trimmed.len) continue;
            if (!std.mem.startsWith(u8, trimmed, name)) continue;
            if (trimmed[name.len] != '=') continue;
            return trimmed[name.len + 1 ..];
        }
        return null;
    }

    pub fn as(self: Cookies, name: []const u8, comptime T: type) ?T {
        var it = std.mem.splitScalar(u8, self.header_value, ';');
        while (it.next()) |kv| {
            const trimmed = std.mem.trimStart(u8, kv, " ");
            if (name.len >= trimmed.len) continue;
            if (!std.mem.startsWith(u8, trimmed, name)) continue;
            if (trimmed[name.len] != '=') continue;
            const str = trimmed[name.len + 1 ..];

            return switch (@typeInfo(T)) {
                .pointer => |p| switch (p.size) {
                    .Slice => if (p.child == u8 and p.is_const) str else @compileError("Cookies.getAs: only []const u8 is supported, got " ++ @typeName(T)),
                    else => @compileError("Cookies.getAs: only []const u8 is supported, got " ++ @typeName(T)),
                },
                .int => std.fmt.parseInt(T, str, 10) catch return null,
                .float => std.fmt.parseFloat(T, str) catch return null,
                .bool => if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) true else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) false else return null,
                .@"enum" => std.meta.stringToEnum(T, str) orelse return null,
                .@"struct", .@"union" => @compileError("Cookies.getAs: use getJson for struct/union types"),
                else => @compileError("Cookies.getAs: unsupported type " ++ @typeName(T)),
            };
        }
        return null;
    }
};

/// Options for setting cookies.
///
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies
pub const CookieOptions = struct {
    /// Specifies the URL path that must exist in the requested URL.
    path: []const u8 = "",
    /// Specifies allowed hosts to receive the cookie.
    domain: []const u8 = "",
    /// Indicates the maximum lifetime of the cookie in seconds.
    max_age: ?i32 = null,
    /// Indicates that the cookie is sent only over HTTPS.
    secure: bool = false,
    /// Forbids JavaScript from accessing the cookie.
    http_only: bool = false,
    /// Indicates the cookie should be stored using partitioned storage.
    partitioned: bool = false,
    /// Controls whether the cookie is sent with cross-site requests.
    same_site: ?SameSite = null,

    pub const SameSite = enum {
        lax,
        strict,
        none,
    };
};

// --- HTTP Status (from std.http) --- //
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status

/// HTTP status codes - re-exported from std.http.Status for convenience.
///
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status
///
/// Includes useful methods:
/// - `phrase()`: Returns the status message (e.g., "OK", "Not Found")
/// - `class()`: Returns the status class (.informational, .success, .redirect, .client_error, .server_error)
pub const Status = std.http.Status;

/// Returns the status message (phrase) for an HTTP status code.
/// Uses the standard library's Status.phrase() method.
pub fn statusCodeToText(code: u16) []const u8 {
    const status: Status = @enumFromInt(code);
    return status.phrase() orelse "Unknown";
}

// --- Content Types (MIME types) --- //
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types

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

/// HTTP content encoding - re-exported from std.http.ContentEncoding.
pub const ContentEncoding = std.http.ContentEncoding;

/// HTTP transfer encoding - re-exported from std.http.TransferEncoding.
pub const TransferEncoding = std.http.TransferEncoding;

/// HTTP connection type - re-exported from std.http.Connection.
pub const Connection = std.http.Connection;
