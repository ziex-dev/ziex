//! HTTP client for both sides of a Ziex app.
//!
//! Native builds use `std.http.Client`. On wasm the request is handed to the
//! host's `fetch()`, so the browser bundle carries no TLS or HTTP parsing code.
//!
//! ```zig
//! var client: zx.http.Client = .{ .io = io, .allocator = gpa };
//! defer client.deinit();
//!
//! const res = try client.fetch(.{ .url = "https://example.com/api" });
//! defer res.deinit(gpa);
//! ```
const Client = @This();

const std = @import("std");
const builtin = @import("builtin");
const http = @import("../http.zig");
const zxon = @import("../../../util/zxon.zig");

pub const Method = http.Method;
pub const Status = http.Status;
pub const Header = http.Header;

const is_wasm = builtin.cpu.arch.isWasm();
const is_browser = is_wasm and builtin.os.tag == .freestanding;

io: std.Io,
allocator: std.mem.Allocator,
_internal: Internal = .{},

pub const Internal = struct {
    std_client: if (is_wasm) void else ?*std.http.Client = if (is_wasm) {} else null,
};

pub const Error = error{
    InvalidUrl,
    NetworkError,
    Timeout,
    InvalidResponse,
    TooManyPendingRequests,
    OutOfMemory,
    Canceled,
};

pub const Redirect = enum {
    /// Follow up to 3 redirects and return the final response.
    follow,
    /// Return the 3xx response as is.
    manual,
};

pub const FetchOptions = struct {
    /// Absolute URL. In the browser it may also be relative to the page.
    url: []const u8,
    method: Method = .GET,
    /// Overrides `method` with a token `std.http.Method` lacks, e.g. `PROPFIND`.
    method_name: ?[]const u8 = null,
    headers: []const Header = &.{},
    payload: ?[]const u8 = null,
    redirect: Redirect = .follow,
    /// How long to wait for the response, as in `std.http.Client`. Natively the
    /// request races `io.sleep`, which needs an Io with concurrency; without it the
    /// request runs untimed.
    timeout: std.Io.Timeout = .none,

    pub fn methodName(self: FetchOptions) []const u8 {
        return self.method_name orelse @tagName(self.method);
    }
};

pub const Result = struct {
    status: Status,
    headers: []const Header,
    body: []const u8,
    /// Backing memory for `headers` and `body`.
    _bytes: []const u8 = &.{},

    /// Builds a result from a raw HTTP/1.1 response head followed by the body.
    /// Takes ownership of `bytes`, which must be allocated with `allocator`.
    pub fn parse(allocator: std.mem.Allocator, status: Status, bytes: []const u8, head_len: usize) error{ OutOfMemory, InvalidResponse }!Result {
        errdefer allocator.free(bytes);
        if (head_len > bytes.len) return error.InvalidResponse;

        var headers: std.ArrayList(Header) = .empty;
        errdefer headers.deinit(allocator);
        if (head_len > 0) {
            var it = std.http.HeaderIterator.init(bytes[0..head_len]);
            while (it.next()) |h| try headers.append(allocator, h);
        }

        return .{
            .status = status,
            .headers = try headers.toOwnedSlice(allocator),
            .body = bytes[head_len..],
            ._bytes = bytes,
        };
    }

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self._bytes);
    }

    /// First header with `name`, compared case-insensitively.
    pub fn header(self: Result, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn json(self: Result, comptime T: type, allocator: std.mem.Allocator) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }
};

pub fn deinit(client: *Client) void {
    if (comptime is_wasm) return;
    if (client._internal.std_client) |sc| {
        sc.deinit();
        client.allocator.destroy(sc);
        client._internal.std_client = null;
    }
}

/// Sends the request and waits for the response. The caller owns the result.
/// In the browser this suspends the calling handler, so it needs JSPI.
pub fn fetch(client: *Client, options: FetchOptions) Error!Result {
    if (comptime is_wasm) return host.fetch(client.allocator, options, try client.timeoutMillis(options.timeout));
    return client.fetchNative(options);
}

/// Sends the request and calls `callback` with the result. The result is only
/// valid during the call; copy what you need.
///
/// ```zig
/// client.fetchThen(.{ .url = "/api" }, &state, onDone);
///
/// fn onDone(state: *State, result: zx.http.Client.Error!zx.http.Client.Result) void { ... }
/// ```
pub fn fetchThen(
    client: *Client,
    options: FetchOptions,
    context: anytype,
    comptime callback: fn (@TypeOf(context), Error!Result) void,
) void {
    const Context = @TypeOf(context);
    const erased = struct {
        fn call(ptr: *anyopaque, result: Error!Result) void {
            if (Context == void) callback({}, result) else callback(@ptrCast(@alignCast(ptr)), result);
        }
    }.call;
    const ptr: *anyopaque = if (Context == void) @ptrCast(@constCast(&unit)) else @ptrCast(@constCast(context));
    client.fetchThenErased(options, ptr, erased);
}

const unit: u8 = 0;

pub const Callback = *const fn (context: *anyopaque, result: Error!Result) void;

/// `fetchThen` with a type-erased context, for callers that store callbacks.
pub fn fetchThenErased(client: *Client, options: FetchOptions, context: *anyopaque, callback: Callback) void {
    if (comptime is_browser) {
        const timeout_ms = client.timeoutMillis(options.timeout) catch |err| return callback(context, err);
        return @import("../../client/fetch.zig").fetchThen(client.allocator, options, timeout_ms, context, callback);
    }

    const result = client.fetch(options);
    callback(context, result);
    if (result) |res| res.deinit(client.allocator) else |_| {}
}

fn stdClient(client: *Client) Error!*std.http.Client {
    if (client._internal.std_client) |sc| return sc;
    const sc = try client.allocator.create(std.http.Client);
    sc.* = .{ .allocator = client.allocator, .io = client.io };
    client._internal.std_client = sc;
    return sc;
}

/// The timeout for the host's `fetch`: 0 for none, or `error.Timeout` if the deadline has passed.
pub fn timeoutMillis(client: *const Client, timeout: std.Io.Timeout) Error!u32 {
    const remaining = timeout.toDurationFromNow(client.io) orelse return 0;
    const ms = remaining.raw.toMilliseconds();
    if (ms <= 0) return error.Timeout;
    return std.math.lossyCast(u32, ms);
}

fn fetchNative(client: *Client, options: FetchOptions) Error!Result {
    if (options.timeout == .none) return client.fetchUntimed(options);

    const Branch = union(enum) {
        fetched: Error!Result,
        expired: std.Io.Cancelable!void,
    };
    var buffer: [2]Branch = undefined;
    var select: std.Io.Select(Branch) = .init(client.io, &buffer);

    select.concurrent(.expired, std.Io.Timeout.sleep, .{ options.timeout, client.io }) catch
        return client.fetchUntimed(options);
    select.concurrent(.fetched, fetchUntimed, .{ client, options }) catch {
        select.cancelDiscard();
        return client.fetchUntimed(options);
    };

    const first = select.await() catch |err| {
        client.discard(&select);
        return err;
    };
    client.discard(&select);
    return switch (first) {
        .fetched => |result| result,
        .expired => error.Timeout,
    };
}

/// Cancels whatever is still running, freeing a response that finished too late.
fn discard(client: *Client, select: anytype) void {
    while (select.cancel()) |late| switch (late) {
        .fetched => |result| if (result) |res| res.deinit(client.allocator) else |_| {},
        .expired => {},
    };
}

fn fetchUntimed(client: *Client, options: FetchOptions) Error!Result {
    const uri = std.Uri.parse(options.url) catch return error.InvalidUrl;
    const sc = try client.stdClient();
    if (options.method_name) |name| return client.fetchCustomMethod(sc, uri, name, options);

    var req = sc.request(options.method, uri, .{
        .redirect_behavior = switch (options.redirect) {
            .follow => .init(3),
            .manual => .unhandled,
        },
        .extra_headers = options.headers,
    }) catch |err| return mapError(err);
    defer req.deinit();

    if (options.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = req.sendBodyUnflushed(&.{}) catch |err| return mapError(err);
        body.writer.writeAll(payload) catch return error.NetworkError;
        body.end() catch return error.NetworkError;
        req.connection.?.flush() catch return error.NetworkError;
    } else {
        req.sendBodiless() catch |err| return mapError(err);
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    const response = req.receiveHead(if (options.redirect == .follow) &redirect_buffer else &.{}) catch |err| return mapError(err);
    return client.readResponse(response);
}

/// `std.http.Client.request` only accepts `std.http.Method`, so the head is written by hand.
fn fetchCustomMethod(client: *Client, sc: *std.http.Client, uri: std.Uri, method_name: []const u8, options: FetchOptions) Error!Result {
    // `.POST` only shapes how the response is read (it always has a body).
    var req = sc.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    }) catch |err| return mapError(err);
    defer req.deinit();

    const payload = options.payload orelse "";
    const connection = req.connection orelse return error.NetworkError;
    const w = connection.writer();
    writeHead(w, uri, method_name, options.headers, payload.len) catch return error.NetworkError;
    w.writeAll(payload) catch return error.NetworkError;
    connection.flush() catch return error.NetworkError;

    const response = req.receiveHead(&.{}) catch |err| return mapError(err);
    return client.readResponse(response);
}

fn readResponse(client: *Client, response: std.http.Client.Response) Error!Result {
    var res = response;
    const gpa = client.allocator;
    const status = res.head.status;

    // `head.bytes` is invalidated once the body is read.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.writeAll(res.head.bytes) catch return error.OutOfMemory;
    const head_len = res.head.bytes.len;

    const decompress_buffer: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.InvalidResponse,
    };
    defer gpa.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.NetworkError,
    };

    const bytes = out.toOwnedSlice() catch return error.OutOfMemory;
    return Result.parse(gpa, status, bytes, head_len);
}

fn writeHead(
    w: *std.Io.Writer,
    uri: std.Uri,
    method_name: []const u8,
    headers: []const Header,
    content_length: usize,
) std.Io.Writer.Error!void {
    try w.writeAll(method_name);
    try w.writeByte(' ');
    if (uri.path.isEmpty()) try w.writeByte('/');
    try uri.writeToStream(w, .{ .path = true, .query = true });
    try w.writeAll(" HTTP/1.1\r\nhost: ");
    try uri.writeToStream(w, .{ .authority = true });
    try w.print("\r\nconnection: close\r\ncontent-length: {d}\r\n", .{content_length});
    for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    try w.writeAll("\r\n");
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => error.InvalidUrl,
        error.HttpHeadersInvalid, error.HttpChunkInvalid, error.HttpContentEncodingUnsupported => error.InvalidResponse,
        else => error.NetworkError,
    };
}

/// Encodes request headers as JSON `[[name, value], ...]` so repeated names survive.
pub fn writeHeadersJson(w: *std.Io.Writer, headers: []const Header) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (headers, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('[');
        zxon.serialize(h.name, w, .{}) catch return error.WriteFailed;
        try w.writeByte(',');
        zxon.serialize(h.value, w, .{}) catch return error.WriteFailed;
        try w.writeByte(']');
    }
    try w.writeByte(']');
}

/// Blocking fetch through the host (edge runtime, or the browser via JSPI).
const host = struct {
    fn fetch(gpa: std.mem.Allocator, options: FetchOptions, timeout_ms: u32) Error!Result {
        const method = options.methodName();
        const payload = options.payload orelse "";

        var headers_json: std.Io.Writer.Allocating = .init(gpa);
        defer headers_json.deinit();
        writeHeadersJson(&headers_json.writer, options.headers) catch return error.OutOfMemory;
        const headers = headers_json.written();

        var status: u16 = 0;
        var head_len: u32 = 0;
        var handle: u32 = 0;
        const n = ext.fetch(
            options.url.ptr,
            options.url.len,
            method.ptr,
            method.len,
            headers.ptr,
            headers.len,
            payload.ptr,
            payload.len,
            timeout_ms,
            @backingInt(options.redirect),
            &status,
            &head_len,
            &handle,
        );
        if (n == -3) return error.Timeout;
        if (n < 0) return error.NetworkError;

        const bytes = try gpa.alloc(u8, @intCast(n));
        ext.take(handle, bytes.ptr);
        return Result.parse(gpa, @fromBackingInt(@intCast(status)), bytes, head_len);
    }

    const ext = struct {
        /// Performs the request and holds the response until `take`. Returns its
        /// length, -1 on network failure or -3 on timeout.
        extern "__zx_net" fn fetch(
            url_ptr: [*]const u8,
            url_len: usize,
            method_ptr: [*]const u8,
            method_len: usize,
            headers_ptr: [*]const u8,
            headers_len: usize,
            body_ptr: [*]const u8,
            body_len: usize,
            timeout_ms: u32,
            redirect: u32,
            status_out: *u16,
            head_len_out: *u32,
            handle_out: *u32,
        ) i32;
        /// Copies the held response (head then body) into `buf_ptr` and releases it.
        extern "__zx_net" fn take(handle: u32, buf_ptr: [*]u8) void;
    };
};
