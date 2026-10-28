var progress: u32 = 0;
var prng = std.Random.DefaultPrng.init(0);

pub fn POST(ctx: zx.RouteContext) !void {
    const count = ctx.request.cookies.get("progress") orelse "0";
    progress = std.fmt.parseInt(u32, count, 10) catch 0;

    const delay = prng.random().intRangeAtMost(u64, 200, 800);
    std.Io.sleep(zx.Io.default(), .fromMilliseconds(@intCast(delay)), .awake) catch {};

    const increment = prng.random().intRangeAtMost(u32, 5, 25);
    progress += increment;

    if (progress >= 100) {
        progress = 100;
    }

    const completed = progress >= 100;
    const value = ctx.fmt("{d}", .{progress}) catch "0";
    ctx.response.cookies.set("progress", value, .{
        .path = "/",
    });

    try ctx.response.json(.{
        .progress = progress,
        .increment = increment,
        .completed = completed,
    }, .{});

    if (completed) {
        progress = 0;
    }
}

const std = @import("std");
const zx = @import("zx");
