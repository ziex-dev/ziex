const zx = @import("zx");

pub fn GET(ctx: zx.RouteContext) !void {
    // Upgrade HTTP connection to WebSocket
    try ctx.socket.upgrade({});
}

pub fn Socket(ctx: zx.SocketContext) !void {
    // Echo back the received message
    try ctx.socket.send(.{
        .text = try ctx.fmt("You said: {s}", .{ctx.message.bytes()}),
    });
}

pub fn SocketOpen(ctx: zx.SocketOpenContext) !void {
    try ctx.socket.send(.{ .text = "Welcome to the WebSocket!" });
}
