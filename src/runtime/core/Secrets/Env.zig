// Secrets from environment variables, optionally merged with `.env` files.
const Env = @This();

const std = @import("std");
const Secrets = @import("../Secrets.zig");
const dotenv = @import("dotenv.zig");

const Map = std.process.Environ.Map;

map: Map,

pub fn init(gpa: std.mem.Allocator) Env {
    return .{ .map = .init(gpa) };
}

pub fn fromEnviron(gpa: std.mem.Allocator, environ: std.process.Environ) !Env {
    return .{ .map = try environ.createMap(gpa) };
}

pub fn deinit(e: *Env) void {
    e.map.deinit();
}

pub fn secrets(e: *const Env) Secrets {
    return .{ .userdata = @constCast(e), .vtable = &.{ .get = &get } };
}

pub const LoadOptions = struct {
    // Defaults to cwd, resolved at runtime (not comptime-known on Windows).
    dir: ?std.Io.Dir = null,
    // e.g. `development`, `production`, `test`, `staging`.
    mode: ?[]const u8 = null,
    max_size: usize = 1 << 20,
};

// Merges, highest priority first: `.env.{mode}.local`, `.env.local`, `.env.{mode}`, `.env`.
// Variables already in the map always win; `.env.local` is skipped in `test` mode.
pub fn load(e: *Env, io: std.Io, opts: LoadOptions) !void {
    const gpa = e.map.allocator;
    const dir = opts.dir orelse std.Io.Dir.cwd();
    const is_test = if (opts.mode) |m| std.mem.eql(u8, m, "test") else false;

    var bufs: [2][128]u8 = undefined;
    const names = [_]?[]const u8{
        ".env",
        if (opts.mode) |m| try std.mem.print(&bufs[0], ".env.{s}", .{m}) else null,
        if (is_test) null else ".env.local",
        if (opts.mode) |m| try std.mem.print(&bufs[1], ".env.{s}.local", .{m}) else null,
    };

    var files: Map = .init(gpa);
    defer files.deinit();
    for (names) |maybe_name| {
        const name = maybe_name orelse continue;
        const src = dir.readFileAlloc(io, name, gpa, .limited(opts.max_size)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(src);
        try dotenv.parse(&files, src, &e.map);
    }

    for (files.keys(), files.values()) |key, value| {
        if (!e.map.contains(key)) try e.map.put(key, value);
    }
}

fn get(userdata: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
    const e: *const Env = @ptrCast(@alignCast(userdata));
    if (!Map.validateKeyForFetch(name)) return null;
    const value = e.map.get(name) orelse return null;
    return try allocator.dupe(u8, value);
}
