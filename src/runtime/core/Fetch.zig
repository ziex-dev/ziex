// TODO: legacy design, needs to be refactored

/// Fetch API - A unified HTTP client for ZX using an Io abstraction.
///
/// Uses a custom `Io` interface that allows the same `fetch()` function
/// to work on both server (blocking) and client (WASM/async).
///
/// ```zig
/// var response = try zx.fetch(zx.Io.blocking, allocator, url, .{});
/// defer response.deinit();
/// ```
const Fetch = @This();

const std = @import("std");
const builtin = @import("builtin");

const common = @import("Http/common.zig");
const server_impl = if (!is_wasm) @import("../server/fetch.zig") else struct {};
const client_impl = if (is_wasm) @import("../client/fetch.zig") else struct {};
const wasm_impl = if (is_wasm) @import("Fetch/Wasm.zig") else struct {};

pub const Method = common.Method;
pub const ContentType = common.ContentType;
pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Io determines how fetch operations are executed.
///
/// - `blocking`: Blocks until complete (server-side native, WASM via JSPI)
/// - `callback`: Calls a callback when complete (client-side WASM)
pub const Io = struct {
    mode: Mode,
    callback: ?ResponseCallback = null,

    pub const Mode = enum {
        /// Block until the operation completes (server-side)
        blocking,
        /// Use callback when complete (client-side WASM)
        callback,
    };

    /// Blocking Io - blocks until fetch completes.
    /// Use this on server-side.
    pub const blocking: Io = .{ .mode = .blocking };

    /// Create a callback-based Io for WASM.
    /// The callback will be invoked when the fetch completes.
    pub fn wasm(callback: ResponseCallback) Io {
        return .{ .mode = .callback, .callback = callback };
    }

    pub const noop: Io = .{ .mode = .callback, .callback = onFetchNoop };
    fn onFetchNoop(_: ?*Response, _: ?Error) void {}

    /// Check if this Io mode is supported on the current platform.
    pub fn isSupported(self: Io) bool {
        return switch (self.mode) {
            .blocking => true, // Native on server, JSPI-suspended on WASM
            .callback => true, // Callback works everywhere
        };
    }
};

/// Options for configuring a fetch request.
pub const RequestInit = struct {
    /// The request method (GET, POST, PUT, DELETE, etc.)
    method: Method = .GET,

    /// Arbitrary method token that overrides `method`
    /// `PROPFIND` or `REPORT`, which `std.http.Method` does not cover).
    method_name: ?[]const u8 = null,

    /// Headers to send with the request.
    headers: ?[]const Header = null,

    /// The request body (for POST, PUT, PATCH).
    body: ?[]const u8 = null,

    /// Request timeout in milliseconds (0 = no timeout).
    timeout_ms: u32 = 30_000,

    /// Follow redirects automatically.
    follow_redirects: bool = true,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// The method token sent on the wire.
    pub fn methodName(self: RequestInit) []const u8 {
        return self.method_name orelse @tagName(self.method);
    }
};

/// The Response interface of the Fetch API represents the response to a request.
pub const Response = struct {
    /// The HTTP status code (e.g., 200, 404, 500).
    status: u16,

    /// The status message (e.g., "OK", "Not Found").
    status_text: []const u8,

    /// Response headers.
    headers: Headers,

    /// The response body as raw bytes.
    _body: []const u8,

    /// Whether the body has been consumed.
    _body_used: bool = false,

    /// Allocator used for response data.
    _allocator: std.mem.Allocator,

    /// Whether this response owns its memory (needs cleanup).
    _owns_memory: bool = true,

    /// A boolean indicating whether the response was successful (status 200-299).
    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// Returns the body as text (UTF-8 string).
    pub fn text(self: *Response) ![]const u8 {
        if (self._body_used) return error.BodyAlreadyUsed;
        self._body_used = true;
        return self._body;
    }

    /// Returns the raw response body bytes.
    pub fn bytes(self: *Response) ![]const u8 {
        return self.text();
    }

    /// Get an `std.Io.Reader` for streaming the response body.
    pub fn reader(self: *Response) std.Io.Reader {
        return std.Io.Reader.fixed(self._body);
    }

    /// Returns the body parsed as JSON into type T.
    pub fn json(self: *Response, comptime T: type) !std.json.Parsed(T) {
        const body = try self.text();
        return try std.json.parseFromSlice(T, self._allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Clean up response resources.
    pub fn deinit(self: *Response) void {
        if (self._owns_memory) {
            if (self._body.len > 0) {
                self._allocator.free(self._body);
            }
            self.headers.deinit();
        }
    }
};

/// Response headers container.
pub const Headers = struct {
    _entries: std.ArrayList(Entry) = .empty,
    _allocator: std.mem.Allocator,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{ ._allocator = allocator };
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self._entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn deinit(self: *Headers) void {
        self._entries.deinit(self._allocator);
    }
};

pub const Error = error{
    Timeout,
    NetworkError,
    InvalidUrl,
    BodyAlreadyUsed,
    HttpError,
    OutOfMemory,
    /// This Io mode is not supported on the current platform.
    UnsupportedIoMode,
    TooManyPendingRequests,
    InvalidResponse,
    Unknown,
};

/// Callback type for async fetch completion.
/// - response: The response if successful, null on error
/// - err: The error if failed, null on success
pub const ResponseCallback = *const fn (response: ?*Response, err: ?Error) void;

/// Like ResponseCallback but carries an opaque context pointer for stateful callbacks.
pub const ResponseCallbackCtx = *const fn (ctx: *anyopaque, response: ?*Response, err: ?Error) void;

/// Perform an HTTP fetch request.
///
/// The `io` parameter determines the execution model:
/// - `Io.blocking` - Blocks until complete, returns Response (server native, WASM via JSPI)
/// - `Io.wasm(&callback)` - Calls callback when complete (WASM)
///
/// **Server-side (blocking):**
/// ```zig
/// var response = try zx.fetch(zx.Io.blocking, allocator, "/api/users", .{});
/// defer response.deinit();
/// const body = try response.text();
/// ```
///
/// **Client-side (WASM with callback):**
/// ```zig
/// zx.fetch(zx.Io.wasm(&onComplete), allocator, "/api/users", .{});
///
/// fn onComplete(response: ?*zx.Fetch.Response, err: ?zx.Fetch.Error) void {
///     if (response) |res| {
///         defer res.deinit();
///         const text = res.text() catch return;
///         // use text...
///     }
/// }
/// ```
///
/// **Returns:**
/// - For `Io.blocking`: Returns `Error!Response`
/// - For `Io.wasm`: Returns `Error!void` (result via callback)
pub fn fetch(
    io: Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    init: RequestInit,
) Error!?Response {
    if (!io.isSupported()) {
        return error.UnsupportedIoMode;
    }

    switch (io.mode) {
        .blocking => {
            if (is_wasm) {
                return try wasm_impl.fetch(allocator, url, init);
            }
            const response = try server_impl.fetch(allocator, url, init);
            return response;
        },
        .callback => {
            // Callback-based fetch
            const callback = io.callback orelse return error.InvalidResponse;

            if (is_wasm) {
                // WASM: use JS bridge
                client_impl.fetchAsync(allocator, url, init, callback);
            } else {
                // Server: execute synchronously, then call callback
                const result = server_impl.fetch(allocator, url, init);
                if (result) |res| {
                    const heap_res = allocator.create(Response) catch {
                        callback(null, error.OutOfMemory);
                        return null;
                    };
                    heap_res.* = res;
                    callback(heap_res, null);
                } else |err| {
                    callback(null, err);
                }
            }
            return null; // Result delivered via callback
        },
    }
}
