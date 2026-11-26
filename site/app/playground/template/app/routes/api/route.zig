pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.response.json(.{ .status = "ok" }, .{});
}

const zx = @import("zx");
