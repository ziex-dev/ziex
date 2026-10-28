const std = @import("std");
const zx = @import("zx");

pub fn GET(ctx: zx.RouteContext) !void {
    const ms = std.fmt.parseInt(u32, ctx.request.query.get("ms") orelse "0", 10) catch 0;
    try ctx.io.sleep(.fromMilliseconds(ms), .awake);
    ctx.response.text("slow");
}
