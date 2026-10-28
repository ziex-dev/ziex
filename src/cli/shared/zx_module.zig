// Resolve the `zx` module root from the nearest `build.zig.zon`, without the build system.

const std = @import("std");
const builtin = @import("builtin");

const package_prefix = "ziex-";
const root_relpath = "src" ++ std.fs.path.sep_str ++ "root.zig";

// Walks up from `start_dir` to the nearest `build.zig.zon` and returns the
// fetched ziex package's `src/root.zig` (project `zig-pkg/` or global cache).
pub fn resolve(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    start_dir: []const u8,
) ?[]u8 {
    const abs_start = std.Io.Dir.cwd().realPathFileAlloc(io, start_dir, allocator) catch return null;
    defer allocator.free(abs_start);
    var dir: ?[]const u8 = abs_start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const zon_path = std.fs.path.join(allocator, &.{ d, "build.zig.zon" }) catch return null;
        defer allocator.free(zon_path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(1 << 20)) catch continue;
        defer allocator.free(source);

        const hash = findPackageHash(source) orelse return null;
        return findPackageRoot(io, allocator, environ_map, d, hash);
    }
    return null;
}

// Returns the first `.hash = "ziex-…"` value in a `build.zig.zon` source.
pub fn findPackageHash(source: []const u8) ?[]const u8 {
    var rest = source;
    while (std.mem.indexOf(u8, rest, ".hash")) |idx| {
        rest = rest[idx + ".hash".len ..];
        const trimmed = std.mem.trimStart(u8, rest, " \t\r\n=");
        if (trimmed.len == 0 or trimmed[0] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return null;
        const hash = trimmed[1..end];
        if (std.mem.startsWith(u8, hash, package_prefix)) return hash;
    }
    return null;
}

fn findPackageRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    project_dir: []const u8,
    hash: []const u8,
) ?[]u8 {
    const local = std.fs.path.join(allocator, &.{ project_dir, "zig-pkg", hash, root_relpath }) catch return null;
    if (exists(io, local)) return local;
    allocator.free(local);

    const cache_dir = globalCacheDir(allocator, environ_map orelse return null) orelse return null;
    defer allocator.free(cache_dir);
    const global = std.fs.path.join(allocator, &.{ cache_dir, "p", hash, root_relpath }) catch return null;
    if (exists(io, global)) return global;
    allocator.free(global);
    return null;
}

// Mirrors zig's default global cache dir resolution.
fn globalCacheDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ?[]u8 {
    if (environ_map.get("ZIG_GLOBAL_CACHE_DIR")) |p| if (p.len > 0) return allocator.dupe(u8, p) catch null;
    if (builtin.os.tag == .windows) {
        const local_app_data = environ_map.get("LOCALAPPDATA") orelse return null;
        return std.fs.path.join(allocator, &.{ local_app_data, "zig" }) catch null;
    }
    if (environ_map.get("XDG_CACHE_HOME")) |p| if (p.len > 0) return std.fs.path.join(allocator, &.{ p, "zig" }) catch null;
    const home = environ_map.get("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ home, ".cache", "zig" }) catch null;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test findPackageHash {
    const source =
        \\.{
        \\    .dependencies = .{
        \\        .other = .{ .url = "x", .hash = "other-1.0.0-abc" },
        \\        .ziex = .{
        \\            .url = "git+https://github.com/ziex-dev/ziex",
        \\            .hash = "ziex-0.1.0-Z3YcvXianQEADbve",
        \\        },
        \\    },
        \\}
    ;
    try std.testing.expectEqualStrings("ziex-0.1.0-Z3YcvXianQEADbve", findPackageHash(source).?);
    try std.testing.expectEqual(null, findPackageHash(".{ .dependencies = .{ .ziex = .{ .path = \"..\" } } }"));
}
