const std = @import("std");

pub const Transport = @import("http/Transport.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const Client = @import("http/Client.zig");
pub const FormData = @import("http/FormData.zig");
pub const MultiFormData = @import("http/MultiFormData.zig");
pub const File = @import("http/File.zig");
pub const Conn = @import("http/Conn.zig");

pub const MultiFormValue = MultiFormData.Value;

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

/// HTTP protocol versions.
pub const Version = std.http.Version;

/// HTTP status codes - re-exported from std.http.Status for convenience.
///
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status
///
/// Includes useful methods:
/// - `phrase()`: Returns the status message (e.g., "OK", "Not Found")
/// - `class()`: Returns the status class (.informational, .success, .redirect, .client_error, .server_error)
pub const Status = std.http.Status;

/// HTTP header name/value pair.
pub const Header = std.http.Header;

/// Options for setting cookies.
///
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies
pub const CookieOptions = struct {
    /// Specifies the URL path that must exist in the requested URL.
    path: []const u8 = "",
    /// Specifies allowed hosts to receive the cookie.
    domain: []const u8 = "",
    /// The cookie's lifetime, sent as whole seconds. Zero or negative expires it now.
    max_age: ?std.Io.Duration = null,
    /// Indicates that the cookie is sent only over HTTPS.
    secure: bool = false,
    /// Forbids JavaScript from accessing the cookie.
    http_only: bool = false,
    /// Indicates the cookie should be stored using partitioned storage.
    partitioned: bool = false,
    /// Controls whether the cookie is sent with cross-site requests.
    same_site: ?SameSite = null,

    pub fn maxAgeSeconds(self: CookieOptions) ?i32 {
        const age = self.max_age orelse return null;
        return std.math.lossyCast(i32, age.toSeconds());
    }

    pub const SameSite = enum {
        lax,
        strict,
        none,
    };
};
