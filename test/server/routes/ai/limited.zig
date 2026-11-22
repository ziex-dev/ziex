const zx = @import("zx");

pub fn POST(ctx: zx.RouteContext) !void {
    ctx.response.setStatus(.too_many_requests);
    ctx.response.text("slow down");
}
