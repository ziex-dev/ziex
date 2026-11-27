//! Outbound WebSocket client. In the browser it wraps JS `WebSocket`; natively
//! it runs over `std.http.Client`, with handlers called from a concurrent `Io`
//! task. Accepted (inbound) sockets are `zx.websocket.Socket`.
//!
//! ```zig
//! var ws: zx.websocket.Client = .{ .io = io, .allocator = gpa };
//! defer ws.deinit();
//! ws.onmessage = &onMessage;
//! try ws.connect(.{ .url = "/chat" });
//! ```
const Client = @This();

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch.isWasm();
const is_browser = is_wasm and builtin.os.tag == .freestanding;

const backend = if (is_browser)
    @import("../../client/websocket.zig")
else if (!is_wasm)
    @import("native.zig")
else
    unsupported;

/// A close frame payload is at most 125 bytes, two of which hold the code.
const max_reason_len = 123;

/// Natively it needs concurrency for the reader task; unused in the browser.
io: std.Io,
allocator: std.mem.Allocator,
/// Borrowed from the last `connect`; the caller owns the bytes.
url: []const u8 = "",
ready_state: ReadyState = .closed,
/// Subprotocol the server selected, owned by the client.
protocol: []const u8 = "",

onopen: ?OpenHandler = null,
onmessage: ?MessageHandler = null,
onerror: ?ErrorHandler = null,
onclose: ?CloseHandler = null,

_internal: Internal = .{},

const Internal = struct {
    user_data: ?*anyopaque = null,
    protocols: []const []const u8 = &.{},
    backend: backend.State = .{},
};

pub const ReadyState = enum { connecting, open, closing, closed };

pub const Error = error{
    ConnectionFailed,
    InvalidUrl,
    InvalidCloseCode,
    ReasonTooLong,
    NotConnected,
    AlreadyConnected,
    SendFailed,
    ConnectionClosed,
    OutOfMemory,
    ConcurrencyUnavailable,
    UnsupportedPlatform,
};

pub const ConnectOptions = struct {
    /// Absolute `ws://`/`wss://`, or a page-relative path in the browser.
    url: []const u8,
    protocols: []const []const u8 = &.{},
    user_data: ?*anyopaque = null,
};

pub const CloseOptions = struct {
    code: ?u16 = null,
    reason: ?[]const u8 = null,
};

pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,

    pub fn bytes(self: Message) []const u8 {
        return switch (self) {
            inline else => |data| data,
        };
    }
};

pub const MessageEvent = struct {
    data: Message,

    pub fn text(self: MessageEvent) ?[]const u8 {
        return switch (self.data) {
            .text => |data| data,
            .binary => null,
        };
    }

    pub fn binary(self: MessageEvent) ?[]const u8 {
        return switch (self.data) {
            .binary => |data| data,
            .text => null,
        };
    }
};

pub const ErrorEvent = struct {
    message: []const u8,
};

pub const CloseEvent = struct {
    code: u16,
    reason: []const u8,
    was_clean: bool,
};

pub const OpenHandler = *const fn (client: *Client) void;
pub const MessageHandler = *const fn (client: *Client, event: MessageEvent) void;
pub const ErrorHandler = *const fn (client: *Client, event: ErrorEvent) void;
pub const CloseHandler = *const fn (client: *Client, event: CloseEvent) void;

pub fn deinit(client: *Client) void {
    client.closeUnchecked(.{});
    backend.deinit(client);
    client.clearProtocol();
}

/// Natively this blocks on the handshake; in the browser it returns immediately and
/// `onopen` fires later. `options.url` is borrowed until the next `connect` or `deinit`.
pub fn connect(client: *Client, options: ConnectOptions) Error!void {
    switch (client.ready_state) {
        .connecting, .open => return error.AlreadyConnected,
        .closing, .closed => {},
    }
    backend.deinit(client);
    client.clearProtocol();

    client.url = options.url;
    client._internal.user_data = options.user_data;
    client._internal.protocols = options.protocols;
    client.ready_state = .connecting;
    errdefer client.ready_state = .closed;
    try backend.connect(client);
}

pub fn send(client: *Client, message: Message) Error!void {
    switch (client.ready_state) {
        .open => {},
        .connecting => return error.NotConnected,
        .closing, .closed => return error.ConnectionClosed,
    }
    try backend.send(client, message);
}

/// Starts the closing handshake; `onclose` fires when it completes.
/// Browsers only accept code 1000 or 3000-4999.
pub fn close(client: *Client, options: CloseOptions) Error!void {
    if (options.code) |code| {
        if (code != 1000 and (code < 3000 or code > 4999)) return error.InvalidCloseCode;
    }
    if (options.reason) |reason| {
        if (reason.len > max_reason_len) return error.ReasonTooLong;
    }
    client.closeUnchecked(options);
}

pub fn isConnected(client: *const Client) bool {
    return client.ready_state == .open;
}

/// The `user_data` passed to `connect`, cast to `*T`.
pub fn userData(client: *const Client, comptime T: type) ?*T {
    const ptr = client._internal.user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn closeUnchecked(client: *Client, options: CloseOptions) void {
    switch (client.ready_state) {
        .connecting, .open => {},
        .closing, .closed => return,
    }
    client.ready_state = .closing;
    backend.close(client, options);
}

fn clearProtocol(client: *Client) void {
    client.allocator.free(client.protocol);
    client.protocol = "";
}

// Called by the backends to update state and run the handlers.

pub fn emitOpen(client: *Client) void {
    client.ready_state = .open;
    if (client.onopen) |handler| handler(client);
}

pub fn emitMessage(client: *Client, event: MessageEvent) void {
    if (client.onmessage) |handler| handler(client, event);
}

pub fn emitError(client: *Client, event: ErrorEvent) void {
    if (client.onerror) |handler| handler(client, event);
}

/// Runs `onclose` at most once per connection.
pub fn emitClose(client: *Client, event: CloseEvent) void {
    if (client.ready_state == .closed) return;
    client.ready_state = .closed;
    if (client.onclose) |handler| handler(client, event);
}

const unsupported = struct {
    pub const State = struct {};

    pub fn connect(_: *Client) Error!void {
        return error.UnsupportedPlatform;
    }

    pub fn send(_: *Client, _: Message) Error!void {
        return error.UnsupportedPlatform;
    }

    pub fn close(_: *Client, _: CloseOptions) void {}

    pub fn deinit(_: *Client) void {}
};
