// /branding/banner.svg?label=<label> renders per request,
// /branding/banner-<preset>.svg is pre-rendered from `banner.presets`
pub fn GET(ctx: zx.RouteContext) !void {
    const label = resolveLabel(ctx) catch {
        ctx.response.setStatus(.not_found);
        return ctx.response.text("Not Found");
    };

    var aw = std.Io.Writer.Allocating.init(ctx.arena);
    try banner.render(&aw.writer, label);

    ctx.response.text(aw.written());
    ctx.response.setContentType(.@"image/svg+xml");
    ctx.response.headers.append("Cache-Control", "public, max-age=86400");
}

fn resolveLabel(ctx: zx.RouteContext) !?[]const u8 {
    const prefix = "/branding/";
    const pathname = ctx.request.pathname;
    if (!std.mem.startsWith(u8, pathname, prefix) or !std.mem.endsWith(u8, pathname, ".svg")) {
        return error.NotFound;
    }
    const name = pathname[prefix.len .. pathname.len - ".svg".len];

    if (std.mem.eql(u8, name, "banner")) return ctx.request.query.get("label");
    if (std.mem.startsWith(u8, name, "banner-")) {
        return banner.presetLabel(name["banner-".len..]) orelse error.NotFound;
    }
    return error.NotFound;
}

fn staticParams(ctx: *zx.StaticContext) !void {
    inline for (banner.presets) |preset| {
        try ctx.params.add(.{ .@"*" = "banner-" ++ preset.slug ++ ".svg" });
    }
}

pub const options = zx.RouteOptions{
    .static = staticParams,
};

const banner = @import("banner.zig");
const zx = @import("zx");
const std = @import("std");
