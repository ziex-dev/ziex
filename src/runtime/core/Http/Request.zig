const Request = @This();

const std = @import("std");
const common = @import("common.zig");
const Http = @import("../Http.zig");
const FormDataModule = @import("FormData.zig");
const MultiFormDataModule = @import("MultiFormData.zig");

pub const FormData = FormDataModule;
pub const MultiFormData = MultiFormDataModule;
pub const Method = common.Method;
pub const Version = common.Version;
pub const Cookies = common.Cookies;
pub const Header = common.Header;
pub const MultiFormEntry = common.MultiFormEntry;

/// Contains the URL of the request.
///
/// MDN: [Request.url](https://developer.mozilla.org/en-US/docs/Web/API/Request/url)
url: []const u8,

/// Contains the request's method (GET, POST, etc.).
///
/// In this implementation, it is represented as a `Method` enum. The original string is available via `method_str`.
///
/// MDN: [Request.method](https://developer.mozilla.org/en-US/docs/Web/API/Request/method)
method: Method,

/// Contains the request's method as a string.
method_str: []const u8 = "",

/// Contains the pathname portion of the URL.
///
/// MDN: [URL.pathname](https://developer.mozilla.org/en-US/docs/Web/API/URL/pathname)
pathname: []const u8,

/// Contains the referrer of the request (e.g., client, no-referrer, or a URL).
///
/// MDN: [Request.referrer](https://developer.mozilla.org/en-US/docs/Web/API/Request/referrer)
referrer: []const u8 = "",

/// Contains the search/query string portion of the URL.
///
/// MDN: [URL.search](https://developer.mozilla.org/en-US/docs/Web/API/URL/search)
search: []const u8 = "",

/// Contains the associated Headers object of the request.
///
/// MDN: [Request.headers](https://developer.mozilla.org/en-US/docs/Web/API/Request/headers)
headers: Headers,

/// Cookie accessor for parsing cookies from the Cookie header.
///
/// MDN: [Cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies)
cookies: Cookies = .{ .header_value = "" },

/// URL search parameters accessor.
///
/// MDN: [URLSearchParams](https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams)
query: UrlSearchParams = .{},

/// URL parameters accessor from route matching.
params: Params = .{},

/// HTTP protocol version (HTTP/1.0 or HTTP/1.1).
version: Version = .@"HTTP/1.1",

/// Arena allocator for request-scoped allocations.
arena: std.mem.Allocator,

/// Internal backend transport carrier. All request reads delegate here.
_internal: Http.Facade = .{},

/// Returns the request body as text.
///
/// MDN: [Request.text](https://developer.mozilla.org/en-US/docs/Web/API/Request/text)
pub fn text(self: *const Request) ?[]const u8 {
    return self._internal.http.reqText();
}

pub fn json(self: *const Request, comptime T: type, opts: std.json.ParseOptions) !?T {
    const raw = self.text() orelse return null;
    const parsed = std.json.parseFromSlice(T, self.arena, raw, opts) catch return null;
    return parsed.value;
}

/// Returns the URL-encoded form data of the request body.
///
/// MDN: [Request.formData](https://developer.mozilla.org/en-US/docs/Web/API/Request/formData)
pub fn formData(self: *const Request) FormDataModule {
    return .{ ._internal = self._internal };
}

/// Returns the multipart form data of the request body.
pub fn multiFormData(self: *const Request) MultiFormDataModule {
    return .{ ._internal = self._internal };
}

/// The URLSearchParams interface defines utility methods to work with the query string of a URL.
///
/// MDN: [URLSearchParams](https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams)
pub const UrlSearchParams = struct {
    _internal: Http.Facade = .{},

    /// Returns the first value associated with the given search parameter.
    /// MDN: [URLSearchParams.get](https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams/get)
    pub fn get(self: *const UrlSearchParams, name: []const u8) ?[]const u8 {
        return self._internal.http.reqQueryGet(name);
    }

    /// Returns a boolean indicating if the given parameter exists.
    ///
    /// MDN: [URLSearchParams.has](https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams/has)
    pub fn has(self: *const UrlSearchParams, name: []const u8) bool {
        return self._internal.http.reqQueryHas(name);
    }
};

/// The Params interface provides utility methods to work with URL parameters.
/// extracted from dynamic routes.
pub const Params = struct {
    _internal: Http.Facade = .{},

    /// Returns the value of a URL parameter by name.
    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        return self._internal.http.reqParam(name);
    }

    /// Returns a typed value of a URL parameter by name.
    pub fn as(self: *const Params, name: []const u8, comptime T: type) ?T {
        const str = self.get(name) orelse return null;

        return switch (@typeInfo(T)) {
            .pointer => |p| switch (p.size) {
                .Slice => if (p.child == u8 and p.is_const) str else @compileError("Params.as: only []const u8 is supported, got " ++ @typeName(T)),
                else => @compileError("Params.as: only []const u8 is supported, got " ++ @typeName(T)),
            },
            .int => std.fmt.parseInt(T, str, 10) catch return null,
            .float => std.fmt.parseFloat(T, str) catch return null,
            .bool => if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) true else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) false else return null,
            .@"enum" => std.meta.stringToEnum(T, str) orelse return null,
            else => @compileError("Params.as: unsupported type " ++ @typeName(T)),
        };
    }
};

/// The Headers interface of the Fetch API allows you to perform various actions on HTTP request and response headers.
///
/// MDN: [Headers](https://developer.mozilla.org/en-US/docs/Web/API/Headers)
pub const Headers = struct {
    _internal: Http.Facade = .{},

    /// Returns the values of a header with the given name.
    ///
    /// MDN: [Headers.get](https://developer.mozilla.org/en-US/docs/Web/API/Headers/get)
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        return self._internal.http.reqHeaderGet(name);
    }

    /// Returns a boolean stating whether a Headers object contains a certain header.
    ///
    /// MDN: [Headers.has](https://developer.mozilla.org/en-US/docs/Web/API/Headers/has)
    pub fn has(self: *const Headers, name: []const u8) bool {
        return self._internal.http.reqHeaderHas(name);
    }
};

pub const Init = struct {
    url: []const u8 = "",
    method: Method = .GET,
    method_str: []const u8 = "GET",
    pathname: []const u8 = "/",
    referrer: []const u8 = "",
    search: []const u8 = "",
    version: Version = .@"HTTP/1.1",
    arena: std.mem.Allocator,
    cookie_header: []const u8 = "",
    http: Http = .{},
};

pub fn init(opts: Init) Request {
    return .{
        .url = opts.url,
        .method = opts.method,
        .method_str = opts.method_str,
        .pathname = opts.pathname,
        .referrer = opts.referrer,
        .search = opts.search,
        .version = opts.version,
        .arena = opts.arena,
        ._internal = .{ .http = opts.http },
        .headers = .{ ._internal = .{ .http = opts.http } },
        .cookies = .{ .header_value = opts.cookie_header },
        .query = .{ ._internal = .{ .http = opts.http } },
        .params = .{ ._internal = .{ .http = opts.http } },
    };
}
