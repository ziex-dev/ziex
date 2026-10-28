//! Ziex settings for a `zig build` run, passed by the zx CLI as one ZON value:
//! `zig build -Dziex-config=.{ .command = .dev, .incremental = true }`.
//! Unknown fields are ignored so a newer CLI can drive an older Ziex build.
const BuildConfig = @This();

const std = @import("std");

pub const option_name = "ziex-config";

pub const Command = enum { dev, serve, static };

/// CLI command the build is for; null for a plain `zig build`.
command: ?Command = null,
/// Enable incremental compilation.
incremental: bool = false,
/// Pre-render routes with `rendering.prerender` into `<prefix>/static`.
prerender: bool = false,
/// Default server port, overridden by the `PORT` env var.
port: ?u16 = null,
/// Default server address, overridden by the `HOST` env var.
address: ?[]const u8 = null,

/// The `-Dziex-config=<zon>` argument for this config.
pub fn arg(self: BuildConfig, allocator: std.mem.Allocator) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("-D" ++ option_name ++ "=");
    try std.zon.stringify.serialize(self, .{ .whitespace = false, .emit_default_optional_fields = false }, &out.writer);
    return out.toOwnedSlice();
}

pub fn parse(arena: std.mem.Allocator, source: []const u8, diagnostics: *std.zon.parse.Diagnostics) !BuildConfig {
    const source_z = try arena.dupeSentinel(u8, source, 0);
    return std.zon.parse.fromSlice(BuildConfig, .{
        .gpa = arena,
        .arena = arena,
        .source = source_z,
        .diagnostics = diagnostics,
        .ignore_unknown_fields = true,
    });
}
