pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.socket.upgrade({});
}

pub fn Socket(ctx: zx.SocketContext) !void {
    var count: usize = 0;

    while (count < 10) : (count += 1) {
        std.Io.sleep(zx.Io.default(), .fromMilliseconds(1000), .awake) catch {};
        try ctx.socket.send(.{
            .text = try ctx.fmt("You said: {s}, count {d}", .{
                ctx.message.bytes(),
                count,
            }),
        });
    }
}

const zx = @import("zx");
const std = @import("std");
