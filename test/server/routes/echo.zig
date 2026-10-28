const zx = @import("zx");

pub fn POST(ctx: zx.RouteContext) !void {
    const body = ctx.request.text() orelse "";
    ctx.response.text(body);
}

pub fn GET(ctx: zx.RouteContext) !void {
    ctx.response.text(ctx.request.query.get("q") orelse "");
}
