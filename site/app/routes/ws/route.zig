const SocketData = struct {
    user_id: u32,
};

/// HTTP GET handler - upgrades the connection to WebSocket
pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.socket.upgrade(SocketData{
        .user_id = 123,
    });
}

/// Called for each message received from the client
pub fn Socket(ctx: zx.SocketCtx(SocketData)) !void {
    try ctx.socket.send(.{ .text = try ctx.fmt(
        "Echo: {s} (user_id: {d}, type: {s})",
        .{ ctx.message.bytes(), ctx.data.user_id, @tagName(ctx.message) },
    ) });
}

/// Optional: Called once when the WebSocket connection opens
pub fn SocketOpen(ctx: zx.SocketOpenCtx(SocketData)) !void {
    try ctx.socket.send(.{ .text = try ctx.fmt(
        "Welcome! user_id: {d}",
        .{ctx.data.user_id},
    ) });
}

/// Optional: Called once when the WebSocket connection closes
pub fn SocketClose(ctx: zx.SocketCloseCtx(SocketData)) void {
    std.log.info("WebSocket closed for user_id: {d}", .{ctx.data.user_id});
}

const zx = @import("zx");
const std = @import("std");
