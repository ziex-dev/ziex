const zx = @import("zx");

pub fn GET(ctx: zx.RouteContext) !void {
    ctx.response.redirect("/echo?q=moved", null);
}
