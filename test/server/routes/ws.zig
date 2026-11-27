const zx = @import("zx");

pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.socket.upgrade({});
}

pub fn Socket(ctx: zx.SocketContext) !void {
    try ctx.socket.send(ctx.message);
}
