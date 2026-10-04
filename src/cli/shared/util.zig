fn resolveBinPath(io: std.Io, allocator: std.mem.Allocator, binpath: []const u8) ![]const u8 {
    if (fileExists(io, binpath)) {
        return allocator.dupe(u8, binpath);
    }

    if (builtin.os.tag == .windows and !std.mem.endsWith(u8, binpath, ".exe")) {
        const exe_binpath = try std.fmt.allocPrint(allocator, "{s}.exe", .{binpath});
        if (fileExists(io, exe_binpath)) {
            return exe_binpath;
        }
        allocator.free(exe_binpath);
    }

    return allocator.dupe(u8, binpath);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Resolve the zig executable for nested `zig build` / `zig fetch` calls.
///
/// Preference order:
/// 1. Explicit `--zig-path` (anything other than the default `"zig"`)
/// 2. `ZIEX_ZIG_PATH` (absolute path injected by `zig build zx`)
/// 3. `_` when it names a `zig` binary
/// 4. The original `zig_path` (usually `"zig"`, resolved via PATH)
pub fn resolveZigExe(environ_map: ?*const std.process.Environ.Map, zig_path: []const u8) []const u8 {
    if (zig_path.len > 0 and !std.mem.eql(u8, zig_path, "zig")) return zig_path;

    if (environ_map) |m| {
        if (m.get("ZIEX_ZIG_PATH")) |p| {
            if (p.len > 0) return p;
        }
        if (m.get("_")) |p| {
            const base = std.fs.path.basename(p);
            if (std.mem.eql(u8, base, "zig") or std.mem.eql(u8, base, "zig.exe")) return p;
        }
    }

    return if (zig_path.len > 0) zig_path else "zig";
}

pub fn spawnZig(io: std.Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    var argv_buf: [64][]const u8 = undefined;
    var spawn_opts = options;

    if (options.argv.len > 0 and options.argv.len <= argv_buf.len) {
        const resolved = resolveZigExe(options.environ_map, options.argv[0]);
        if (!std.mem.eql(u8, resolved, options.argv[0])) {
            log.debug("resolved zig exe {s} -> {s}", .{ options.argv[0], resolved });
            copyArgv(&argv_buf, options.argv);
            argv_buf[0] = resolved;
            spawn_opts.argv = argv_buf[0..options.argv.len];
        }
    }

    return std.process.spawn(io, spawn_opts) catch |err| switch (err) {
        error.FileNotFound => {
            if (spawn_opts.argv.len == 0 or spawn_opts.argv.len > argv_buf.len) return err;

            log.debug("zig not found at {s}, resolving from PATH", .{spawn_opts.argv[0]});
            return trySpawnZigFromPath(io, spawn_opts, &argv_buf) catch |path_err| switch (path_err) {
                error.FileNotFound => trySpawnZigFromUnderscore(io, spawn_opts, &argv_buf),
                else => return path_err,
            };
        },
        else => return err,
    };
}

fn trySpawnZigFromPath(
    io: std.Io,
    options: std.process.SpawnOptions,
    argv_buf: *[64][]const u8,
) std.process.SpawnError!std.process.Child {
    const environ_map = options.environ_map orelse return error.FileNotFound;
    const path = environ_map.get("PATH") orelse return error.FileNotFound;
    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
    var entries = std.mem.splitScalar(u8, path, delimiter);
    var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const separator = if (std.mem.endsWith(u8, entry, "/") or std.mem.endsWith(u8, entry, "\\")) "" else std.fs.path.sep_str;
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}{s}{s}", .{ entry, separator, exe_name }) catch continue;

        copyArgv(argv_buf, options.argv);
        argv_buf[0] = candidate;
        var retry = options;
        retry.argv = argv_buf[0..options.argv.len];
        return std.process.spawn(io, retry) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }

    return error.FileNotFound;
}

fn trySpawnZigFromUnderscore(
    io: std.Io,
    options: std.process.SpawnOptions,
    argv_buf: *[64][]const u8,
) std.process.SpawnError!std.process.Child {
    const environ_map = options.environ_map orelse return error.FileNotFound;
    const underscore = environ_map.get("_") orelse return error.FileNotFound;
    const base = std.fs.path.basename(underscore);
    if (!std.mem.eql(u8, base, "zig") and !std.mem.eql(u8, base, "zig.exe")) return error.FileNotFound;
    if (std.mem.eql(u8, options.argv[0], underscore)) return error.FileNotFound;

    log.debug("zig not on PATH, falling back to _={s}", .{underscore});
    copyArgv(argv_buf, options.argv);
    argv_buf[0] = underscore;
    var retry = options;
    retry.argv = argv_buf[0..options.argv.len];
    return std.process.spawn(io, retry);
}

fn copyArgv(dst: *[64][]const u8, src: []const []const u8) void {
    for (src, 0..) |arg, index| dst[index] = arg;
}

const ManifestApp = @import("../../build/Manifest.zig").App;
const CliConstant = @import("constant.zig");

/// Resolve `manifest/app.zon` under install-prefix, or an explicit `--manifest` path.
pub fn resolveManifestPath(
    allocator: std.mem.Allocator,
    install_prefix: []const u8,
    manifest_override: []const u8,
) ![]const u8 {
    if (manifest_override.len > 0) return try allocator.dupe(u8, manifest_override);
    return try std.fs.path.join(allocator, &.{ install_prefix, CliConstant.default_manifest_relpath });
}

/// Read `transpile_dir` from an app manifest, falling back to the CLI default.
pub fn resolveTranspileDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
) ![]const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch {
        return try allocator.dupe(u8, CliConstant.default_transpile_dir);
    };
    defer allocator.free(source);
    if (source.len == 0) return try allocator.dupe(u8, CliConstant.default_transpile_dir);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(ManifestApp, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = source_z,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch {
        return try allocator.dupe(u8, CliConstant.default_transpile_dir);
    };

    if (manifest.transpile_dir) |dir| {
        if (dir.len > 0) return try allocator.dupe(u8, dir);
    }
    return try allocator.dupe(u8, CliConstant.default_transpile_dir);
}

/// Resolve the installed app executable from `manifest/app.zon`, or `--binpath`.
pub fn resolveExePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    install_prefix: []const u8,
    binpath_override: []const u8,
) ![]const u8 {
    if (binpath_override.len > 0) {
        _ = std.Io.Dir.cwd().statFile(io, binpath_override, .{}) catch return error.ExecutableNotFound;
        return try allocator.dupe(u8, binpath_override);
    }

    const manifest_path = try std.fs.path.join(allocator, &.{ install_prefix, CliConstant.default_manifest_relpath });
    defer allocator.free(manifest_path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    defer allocator.free(source);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = try std.zon.parse.fromSlice(ManifestApp, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = source_z,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });

    const rel = manifest.exe_path orelse return error.ExecutableNotFound;
    const path = try std.fs.path.join(allocator, &.{ install_prefix, rel });
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.ExecutableNotFound;
    return path;
}

const ignore_dirs = [_][]const u8{".well-known" ++ std.fs.path.sep_str ++ "_zx"};
fn shouldIgnorePath(path: []const u8) bool {
    for (ignore_dirs) |ignore_dir| {
        if (std.mem.startsWith(u8, path, ignore_dir)) return true;
    }
    return false;
}
pub fn copydirs(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    source_dirs: []const []const u8,
    dest_dir: []const u8,
    public_to_root: bool,
    printer: *tui.Printer,
) !void {
    for (source_dirs) |source_dir| {
        const source_path = try std.fs.path.join(allocator, &.{ base_dir, source_dir });
        defer allocator.free(source_path);

        var source = std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.NotDir => continue,
            else => return err,
        };
        defer source.close(io);

        std.Io.Dir.cwd().createDirPath(io, dest_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var dest = try std.Io.Dir.cwd().openDir(io, dest_dir, .{});
        defer dest.close(io);

        var walker = try source.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            const src_path = try std.fs.path.join(allocator, &.{ source_path, entry.path });
            defer allocator.free(src_path);

            const rel_base = if ((public_to_root and std.mem.eql(u8, source_dir, "public")) or
                std.mem.eql(u8, source_dir, ".")) "" else source_dir;
            const dst_rel_path = try std.fs.path.join(allocator, &.{
                rel_base,
                entry.path,
            });
            defer allocator.free(dst_rel_path);

            const dst_abs_path = try std.fs.path.join(allocator, &.{ dest_dir, dst_rel_path });
            defer allocator.free(dst_abs_path);

            switch (entry.kind) {
                .file => {
                    if (shouldIgnorePath(dst_rel_path)) continue;

                    // Create parent directory if needed
                    if (std.fs.path.dirname(dst_abs_path)) |parent| {
                        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
                            error.PathAlreadyExists => {},
                            else => return err,
                        };
                    }

                    // Copy file
                    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, dest, dst_rel_path, io, .{});
                    printer.filepath(dst_rel_path);
                },
                .directory => {
                    if (shouldIgnorePath(dst_abs_path)) continue;
                    // Create directory if needed
                    std.Io.Dir.cwd().createDirPath(io, dst_abs_path) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                },
                else => continue,
            }
        }
    }
}

pub fn getRunnablePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    program_path: []const u8,
    temp_dir: TempDir,
) ![]const u8 {
    if (builtin.os.tag == .windows) {
        try std.Io.Dir.cwd().createDirPath(io, temp_dir.path);
        const dest_dir = try std.Io.Dir.cwd().openDir(io, temp_dir.path, .{});
        defer dest_dir.close(io);

        const bin_name = std.fs.path.basename(program_path);
        try std.Io.Dir.cwd().copyFile(program_path, dest_dir, bin_name, io, .{});
        return try std.fs.path.join(allocator, &.{ temp_dir.path, bin_name });
    } else {
        return program_path;
    }
}
pub fn randInt(io: std.Io, comptime T: type) T {
    var x: T = undefined;
    io.random(@ptrCast(&x));
    return x;
}

pub const TempDir = struct {
    const temp_dir = std.fs.path.fmtJoin(&.{ ".zig-cache", "ziex", "tmp" });
    path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !TempDir {
        return .{
            .path = try std.fmt.allocPrint(
                allocator,
                "{f}{s}{x}",
                .{ temp_dir, std.fs.path.sep_str, randInt(io, u32) },
            ),
        };
    }

    pub fn deinit(self: *TempDir, io: std.Io, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| switch (err) {
            else => log.err("failed to delete temp directory: {any}", .{err}),
        };
        allocator.free(self.path);
    }
};

const std = @import("std");
const builtin = @import("builtin");
const tui = @import("../../tui/main.zig");
const log = std.log.scoped(.cli);
