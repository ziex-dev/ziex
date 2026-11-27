//! Server side of an accepted WebSocket, available as `ctx.socket` in
//! `route.zig` handlers. Outbound connections use `zx.websocket.Client`.
//!
//! ```zig
//! pub fn GET(ctx: zx.RouteContext) !void {
//!     try ctx.socket.upgrade({});
//! }
//!
//! pub fn Socket(ctx: zx.SocketContext) !void {
//!     try ctx.socket.send(.{ .text = "Hello!" });
//! }
//! ```
const Socket = @This();

const std = @import("std");
const Transport = @import("../http/Transport.zig");
const Message = @import("Client.zig").Message;

_internal: Internal = .{},

pub const Internal = struct {
    http: Transport = .{},
    attached: bool = false,
};

pub const Options = struct {
    /// When true, `publish` also sends the message to the sender.
    publish_to_self: bool = false,
};

/// Completes the upgrade. `data` is copied and handed to the `Socket*`
/// handlers as `ctx.data`.
pub fn upgrade(socket: Socket, data: anytype) !void {
    if (!socket._internal.attached) return;
    if (@TypeOf(data) == void) {
        try socket._internal.http.wsUpgrade(null);
    } else {
        try socket._internal.http.wsUpgrade(std.mem.asBytes(&data));
    }
}

/// Sends a text or binary message to the client.
///
/// ```zig
/// try ctx.socket.send(.{ .text = "Hello!" });
/// ```
pub fn send(socket: Socket, message: Message) !void {
    if (!socket._internal.attached) return;
    try socket._internal.http.wsSend(message);
}

pub fn read(socket: Socket) ?Message {
    if (!socket._internal.attached) return null;
    return socket._internal.http.wsRead();
}

pub fn close(socket: Socket) void {
    if (!socket._internal.attached) return;
    socket._internal.http.wsClose();
}

pub fn isUpgraded(socket: Socket) bool {
    return socket._internal.attached;
}

/// Subscribes to `topic`; many sockets can share one.
///
/// ```zig
/// ctx.socket.subscribe("chat-room");
/// ```
pub fn subscribe(socket: Socket, topic: []const u8) void {
    if (!socket._internal.attached) return;
    socket._internal.http.wsSubscribe(topic);
}

pub fn unsubscribe(socket: Socket, topic: []const u8) void {
    if (!socket._internal.attached) return;
    socket._internal.http.wsUnsubscribe(topic);
}

/// Sends `message` to every subscriber of `topic` except this socket (see
/// `Options.publish_to_self`). Returns how many sockets it was sent to.
///
/// ```zig
/// const sent = ctx.socket.publish("chat-room", "Hello everyone!");
/// ```
pub fn publish(socket: Socket, topic: []const u8, message: []const u8) usize {
    if (!socket._internal.attached) return 0;
    return socket._internal.http.wsPublish(topic, message);
}

pub fn isSubscribed(socket: Socket, topic: []const u8) bool {
    if (!socket._internal.attached) return false;
    return socket._internal.http.wsIsSubscribed(topic);
}

/// ```zig
/// ctx.socket.configure(.{ .publish_to_self = true });
/// ```
pub fn configure(socket: Socket, options: Options) void {
    if (!socket._internal.attached) return;
    socket._internal.http.wsSetPublishToSelf(options.publish_to_self);
}
