const std = @import("std");

pub const ziex_cache_dirname = "ziex";
pub const transpile_store_dirname = "tnsn";
pub const default_transpile_dir = std.fmt.comptimePrint("{f}", .{std.Io.Dir.path.fmtJoin(
    &.{ ".zig-cache", ziex_cache_dirname, transpile_store_dirname },
)});
pub const default_manifest_relpath = std.fmt.comptimePrint("{f}", .{
    std.Io.Dir.path.fmtJoin(&.{ "manifest", "app.zon" }),
});

/// Filesystem-routing dirs under the app root; their route files are the transpile roots.
pub const route_dirnames = [_][]const u8{ "pages", "routes" };

/// Route files (`page.zx`, `route.zig`, …) that the generated `app.zig` imports.
pub fn isRouteRoot(basename: []const u8) bool {
    const ext = std.Io.Dir.path.extension(basename);
    const exts = [_][]const u8{ ".zx", ".mdzx", ".md", ".zig" };
    const stems = [_][]const u8{ "page", "layout", "error", "route", "proxy", "notfound", "worker" };
    for (exts) |e| {
        if (!std.mem.eql(u8, ext, e)) continue;
        for (stems) |s| if (std.mem.eql(u8, basename[0 .. basename.len - ext.len], s)) return true;
    }
    return false;
}
