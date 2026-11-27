const std = @import("std");
const zx = @import("zx");

pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.socket.upgrade({});
}

// Echoes, except `big` replies with `big_len` patterned bytes and then `done`.
pub fn Socket(ctx: zx.SocketContext) !void {
    if (ctx.message == .text and std.mem.eql(u8, ctx.message.text, "big")) {
        const bytes = try ctx.allocator.alloc(u8, big_len);
        defer ctx.allocator.free(bytes);
        for (bytes, 0..) |*b, i| b.* = @truncate(i *% 31);
        try ctx.socket.send(.{ .binary = bytes });
        return ctx.socket.send(.{ .text = "done" });
    }
    try ctx.socket.send(ctx.message);
}

const big_len = 8 * 1024 * 1024;
