pub fn GET(ctx: zx.RouteContext) !void {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    var w = &aw.writer;
    const host = "ziex.dev";

    // Write XML header
    _ = try w.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    _ = try w.write("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    inline for (app.routes) |route| {
        if (std.mem.indexOf(u8, route.path, ":") != null) {} else try writeSitemapUrl(w, ctx.arena, host, route.path);
    }

    for (custom_paths) |path| {
        if (path.len == 0) continue;
        if (path[0] != '/') continue;
        if (hasStaticRoute(path)) continue;
        try writeSitemapUrl(w, ctx.arena, host, path);
    }

    _ = try w.write("</urlset>\n");

    ctx.response.text(aw.written());
}

fn hasStaticRoute(path: []const u8) bool {
    inline for (app.routes) |route| {
        if (std.mem.indexOf(u8, route.path, ":") != null) {} else {
            if (std.mem.eql(u8, route.path, path)) {
                return true;
            }
        }
    }
    return false;
}

fn writeSitemapUrl(w: *std.Io.Writer, arena: std.mem.Allocator, host: []const u8, path: []const u8) !void {
    _ = try w.write("  <url>\n");
    _ = try w.write("    <loc>");
    const full_path = try arena.print("https://{s}{s}", .{ host, path });
    _ = try w.write(full_path);
    _ = try w.write("</loc>\n");
    _ = try w.write("  </url>\n");
}

const custom_paths = [_][]const u8{
    "/vs/jetzig",
};

const options: zx.RouteOptions = .{};

const zx = @import("zx");
const std = @import("std");
const app = @import("app");
