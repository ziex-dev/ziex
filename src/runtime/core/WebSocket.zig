// TODO: legacy design, needs to be refactored
/// WebSocket client API for server and wasm.
///
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket
const WebSocket = @This();

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// The state of the WebSocket connection.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/readyState
pub const ReadyState = enum(u16) {
    /// Socket has been created. The connection is not yet open.
    connecting = 0,
    /// The connection is open and ready to communicate.
    open = 1,
    /// The connection is in the process of closing.
    closing = 2,
    /// The connection is closed or couldn't be opened.
    closed = 3,
};

/// The type of binary data being transmitted.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/binaryType
pub const BinaryType = enum {
    /// Binary data is returned as Blob objects (default in browser, not applicable in Zig)
    blob,
    /// Binary data is returned as ArrayBuffer/byte slices
    arraybuffer,
};

/// Options for closing a WebSocket connection.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/close
pub const CloseOptions = struct {
    /// A numeric value indicating the status code explaining why the connection is being closed.
    /// If not specified, a default value of 1005 is assumed.
    /// https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent/code
    code: ?u16 = null,
    /// A human-readable string explaining why the connection is closing.
    /// Must be no longer than 123 bytes of UTF-8 text.
    reason: ?[]const u8 = null,
};

/// Close event data passed to onclose handler.
/// https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent
pub const CloseEvent = struct {
    /// The close code sent by the server.
    code: u16,
    /// The reason the server closed the connection.
    reason: []const u8,
    /// Whether the connection was cleanly closed.
    was_clean: bool,
};

/// Message event data passed to onmessage handler.
/// https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent
pub const MessageEvent = struct {
    /// The data sent by the message emitter.
    data: Data,

    pub const Data = union(enum) {
        text: []const u8,
        binary: []const u8,
    };

    /// Get data as text (for text messages)
    pub fn text(self: MessageEvent) ?[]const u8 {
        return switch (self.data) {
            .text => |t| t,
            .binary => null,
        };
    }

    /// Get data as binary
    pub fn binary(self: MessageEvent) ?[]const u8 {
        return switch (self.data) {
            .binary => |b| b,
            .text => null,
        };
    }
};

/// Error event passed to onerror handler.
pub const ErrorEvent = struct {
    /// Error message describing what went wrong.
    message: []const u8,
};

/// Callback for when the connection is opened.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/open_event
pub const OpenHandler = *const fn (ws: *WebSocket) void;

/// Callback for when a message is received.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/message_event
pub const MessageHandler = *const fn (ws: *WebSocket, event: MessageEvent) void;

/// Callback for when an error occurs.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/error_event
pub const ErrorHandler = *const fn (ws: *WebSocket, event: ErrorEvent) void;

/// Callback for when the connection is closed.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/close_event
pub const CloseHandler = *const fn (ws: *WebSocket, event: CloseEvent) void;

/// Options for creating a WebSocket connection.
pub const InitOptions = struct {
    /// Sub-protocols to use for the connection.
    /// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/WebSocket#protocols
    protocols: ?[]const []const u8 = null,
    /// The type of binary data being transmitted.
    binary_type: BinaryType = .arraybuffer,
    /// User data to associate with this WebSocket.
    user_data: ?*anyopaque = null,
};

pub const Error = error{
    /// The WebSocket connection failed.
    ConnectionFailed,
    /// The URL is invalid.
    InvalidUrl,
    /// The close code is invalid (must be 1000 or 3000-4999).
    InvalidCloseCode,
    /// The close reason is too long (max 123 bytes).
    ReasonTooLong,
    /// The connection is not open.
    NotConnected,
    /// The connection is already open.
    AlreadyConnected,
    /// Failed to send message.
    SendFailed,
    /// The WebSocket is closing or closed.
    ConnectionClosed,
    /// Operation timed out.
    Timeout,
    /// Out of memory.
    OutOfMemory,
    /// This operation is not supported on the current platform.
    UnsupportedPlatform,
    /// TLS/SSL error.
    TlsError,
    /// Protocol error.
    ProtocolError,
};

// TODO: remove these stubs
const server_impl = if (!is_wasm and @import("app_opts").enable_httpz) @import("App/Server/Httpz.zig").websocket else struct {
    pub fn connect(_: *WebSocket) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn send(_: *WebSocket, _: []const u8) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn sendBinary(_: *WebSocket, _: []const u8) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn close(_: *WebSocket, _: CloseOptions) void {}
    pub fn deinit(_: *WebSocket) void {}
};

// TODO: remove these stubs
const client_impl = if (is_wasm) @import("../client/websocket.zig") else struct {
    pub fn connect(_: *WebSocket) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn send(_: *WebSocket, _: []const u8) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn sendBinary(_: *WebSocket, _: []const u8) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn close(_: *WebSocket, _: CloseOptions) void {}
    pub fn deinit(_: *WebSocket) void {}
};

/// The absolute URL of the WebSocket.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/url
url: []const u8,

/// The current state of the connection.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/readyState
ready_state: ReadyState = .connecting,

/// The number of bytes of queued data.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount
buffered_amount: u64 = 0,

/// The extensions selected by the server.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/extensions
extensions: []const u8 = "",

/// The sub-protocol selected by the server.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/protocol
protocol: []const u8 = "",

/// The binary data type used by the connection.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/binaryType
binary_type: BinaryType = .arraybuffer,

// --- Event Handlers --- //

/// An event handler called when the connection is opened.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/open_event
onopen: ?OpenHandler = null,

/// An event handler called when a message is received.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/message_event
onmessage: ?MessageHandler = null,

/// An event handler called when an error occurs.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/error_event
onerror: ?ErrorHandler = null,

/// An event handler called when the connection is closed.
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/close_event
onclose: ?CloseHandler = null,

/// Allocator for internal allocations.
_allocator: std.mem.Allocator,

/// User data associated with this WebSocket.
_user_data: ?*anyopaque = null,

/// Requested protocols during initialization.
_requested_protocols: ?[]const []const u8 = null,

/// Backend-specific context (platform implementation data).
userdata: ?*anyopaque = null,

/// Creates a new WebSocket connection to the specified URL.
///
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/WebSocket
///
/// **Parameters:**
/// - `allocator`: Memory allocator for internal use.
/// - `url`: The URL to which to connect (ws:// or wss://).
/// - `options`: Optional configuration (protocols, binary_type, user_data).
///
/// **Example:**
/// ```zig
/// var ws = try WebSocket.init(allocator, "ws://localhost:8080/chat", .{
///     .protocols = &.{"chat", "superchat"},
/// });
/// ```
pub fn init(allocator: std.mem.Allocator, url: []const u8, options: InitOptions) Error!WebSocket {
    const owned_url = allocator.dupe(u8, url) catch return error.OutOfMemory;

    return WebSocket{
        .url = owned_url,
        .binary_type = options.binary_type,
        ._allocator = allocator,
        ._user_data = options.user_data,
        ._requested_protocols = options.protocols,
    };
}

/// Establishes the WebSocket connection.
///
/// On server-side (native Zig), this blocks until the connection is established
/// or an error occurs. On client-side (WASM), this initiates the connection
/// asynchronously; the `onopen` handler will be called when connected.
///
/// **Example:**
/// ```zig
/// try ws.connect();
/// // Connection is now open (on server) or connecting (on WASM)
/// ```
pub fn connect(self: *WebSocket) Error!void {
    if (self.ready_state != .connecting) {
        return error.AlreadyConnected;
    }

    if (is_wasm) {
        return client_impl.connect(self);
    } else {
        return server_impl.connect(self);
    }
}

/// Transmits data to the server over the WebSocket connection.
///
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/send
///
/// **Parameters:**
/// - `data`: The data to send. For text messages, use a string.
///
/// **Example:**
/// ```zig
/// try ws.send("Hello, Server!");
/// ```
pub fn send(self: *WebSocket, data: []const u8) Error!void {
    if (self.ready_state != .open) {
        return if (self.ready_state == .connecting)
            error.NotConnected
        else
            error.ConnectionClosed;
    }

    if (is_wasm) {
        return client_impl.send(self, data);
    } else {
        return server_impl.send(self, data);
    }
}

/// Transmits binary data to the server over the WebSocket connection.
///
/// **Parameters:**
/// - `data`: The binary data to send.
///
/// **Example:**
/// ```zig
/// try ws.sendBinary(&[_]u8{ 0x01, 0x02, 0x03 });
/// ```
pub fn sendBinary(self: *WebSocket, data: []const u8) Error!void {
    if (self.ready_state != .open) {
        return if (self.ready_state == .connecting)
            error.NotConnected
        else
            error.ConnectionClosed;
    }

    if (is_wasm) {
        return client_impl.sendBinary(self, data);
    } else {
        return server_impl.sendBinary(self, data);
    }
}

/// Closes the WebSocket connection.
///
/// https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/close
///
/// **Parameters:**
/// - `options`: Optional close code (1000 or 3000-4999) and reason (max 123 bytes).
///
/// **Example:**
/// ```zig
/// ws.close(.{ .code = 1000, .reason = "Goodbye" });
/// ```
pub fn close(self: *WebSocket, options: CloseOptions) void {
    // Validate close code if provided
    if (options.code) |code| {
        // Valid close codes: 1000 (normal), or 3000-4999 (application-defined)
        if (code != 1000 and (code < 3000 or code > 4999)) {
            if (self.onerror) |handler| {
                handler(self, .{ .message = "Invalid close code" });
            }
            return;
        }
    }

    // Validate reason length
    if (options.reason) |reason| {
        if (reason.len > 123) {
            if (self.onerror) |handler| {
                handler(self, .{ .message = "Close reason too long (max 123 bytes)" });
            }
            return;
        }
    }

    if (self.ready_state == .closed or self.ready_state == .closing) {
        return;
    }

    self.ready_state = .closing;

    if (is_wasm) {
        client_impl.close(self, options);
    } else {
        server_impl.close(self, options);
    }
}

/// Releases resources associated with this WebSocket.
/// Always call this when done with the WebSocket.
pub fn deinit(self: *WebSocket) void {
    // Close if still connected
    if (self.ready_state == .open or self.ready_state == .connecting) {
        self.close(.{ .code = 1001 }); // Going Away
    }

    // Clean up platform-specific resources
    if (is_wasm) {
        client_impl.deinit(self);
    } else {
        server_impl.deinit(self);
    }

    // Free owned URL and protocol
    if (self.url.len > 0) {
        self._allocator.free(self.url);
    }
    if (self.protocol.len > 0) {
        self._allocator.free(self.protocol);
    }
}

/// Get the user data associated with this WebSocket.
pub fn getUserData(self: *WebSocket, comptime T: type) ?*T {
    if (self._user_data) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

/// Check if the WebSocket is currently connected and ready to send/receive.
pub fn isConnected(self: *const WebSocket) bool {
    return self.ready_state == .open;
}

/// Called by platform implementation when connection is opened.
pub fn _handleOpen(self: *WebSocket) void {
    self.ready_state = .open;
    if (self.onopen) |handler| {
        handler(self);
    }
}

/// Called by platform implementation when a message is received.
pub fn _handleMessage(self: *WebSocket, event: MessageEvent) void {
    if (self.onmessage) |handler| {
        handler(self, event);
    }
}

/// Called by platform implementation when an error occurs.
pub fn _handleError(self: *WebSocket, event: ErrorEvent) void {
    if (self.onerror) |handler| {
        handler(self, event);
    }
}

/// Called by platform implementation when connection is closed.
pub fn _handleClose(self: *WebSocket, event: CloseEvent) void {
    self.ready_state = .closed;
    if (self.onclose) |handler| {
        handler(self, event);
    }
}
