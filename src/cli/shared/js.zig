const pkg_find_paths = [_][]const u8{ "package.json", "site" ++ std.fs.path.sep_str ++ "package.json" };
pub const PackageJson = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: ?std.json.Value = null,
    devDependencies: ?std.json.Value = null,
    scripts: ?std.json.Value = null,
    packageManager: ?PM = null,
    main: ?[]const u8 = null,
    pkg_path: ?[]const u8 = null,

    const PM = enum {
        npm,
        pnpm,
        yarn,
        bun,
    };

    pub fn parse(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(PackageJson) {
        const cwd = std.Io.Dir.cwd();
        var pkg_final_path: ?[]const u8 = null;
        const package_json_str = blk: {
            for (pkg_find_paths) |pkg_find_path| {
                const package_json_str = cwd.readFileAlloc(io, pkg_find_path, allocator, .limited(std.math.maxInt(usize))) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };

                pkg_final_path = try std.fs.path.join(allocator, &.{pkg_find_path});
                break :blk package_json_str;
            }
            return error.PackageJsonNotFound;
        };

        var package_json_parsed: std.json.Parsed(PackageJson) = std.json.parseFromSlice(
            PackageJson,
            allocator,
            package_json_str,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        ) catch |err| switch (err) {
            else => {
                allocator.free(package_json_str);
                return error.InvalidPackageJson;
            },
        };
        package_json_parsed.value.pkg_path = pkg_final_path;
        allocator.free(package_json_str);

        return package_json_parsed;
    }

    fn getPackageManager(self: *PackageJson, io: std.Io) PM {
        if (self.packageManager) |pm| return pm;
        if (self.dependencies) |deps| {
            switch (deps) {
                .object => |obj| {
                    if (obj.get("bun")) |_| return .bun;
                    if (obj.get("pnpm")) |_| return .pnpm;
                    if (obj.get("yarn")) |_| return .yarn;
                    if (obj.get("npm")) |_| return .npm;
                },
                else => {},
            }
        }
        if (self.pkg_path) |pkg_path| {
            const dir_from_pkg_path = std.fs.path.dirname(pkg_path) orelse return .npm;
            const cwd = std.Io.Dir.cwd().openDir(io, dir_from_pkg_path, .{}) catch return .npm;

            // Check for lockfiles
            if (cwd.statFile(io, "package-lock.json", .{}) catch null) |_| return .npm;
            if (cwd.statFile(io, "pnpm-lock.yaml", .{}) catch null) |_| return .pnpm;
            if (cwd.statFile(io, "yarn.lock", .{}) catch null) |_| return .yarn;
            if (cwd.statFile(io, "bun.lock", .{}) catch null) |_| return .bun;
            if (cwd.statFile(io, "bun.lockb", .{}) catch null) |_| return .bun;
        }
        // Check for binary in path
        return .npm;
    }
};

pub fn checkEsbuildBin(io: std.Io, allocator: std.mem.Allocator, pkg_rootdir: []const u8) bool {
    const esbuild_bin_path = std.fs.path.join(allocator, &.{ pkg_rootdir, "node_modules", ".bin", "esbuild" }) catch return false;
    defer allocator.free(esbuild_bin_path);

    return if (std.Io.Dir.cwd().statFile(io, esbuild_bin_path, .{}) catch null) |_| true else false;
}

pub fn buildjs(ctx: CommandContext, binpath: []const u8, is_dev: bool, verbose: bool) !void {
    const app = ctx.app;
    const io = app.io;
    var program_meta = try util.findprogram(io, ctx.allocator, binpath);
    defer util.freeBuildMeta(ctx.allocator, &program_meta);

    const rootdir = program_meta.rootdir orelse "";

    log.debug("Parsing package.json", .{});
    var package_json_parsed = try PackageJson.parse(ctx.allocator, io);
    defer package_json_parsed.deinit();
    var package_json = package_json_parsed.value;
    log.debug("Found and parsed package.json in ./{s}", .{package_json.pkg_path orelse "na"});

    const pkg_path = package_json.pkg_path orelse return error.PkgPathNotFound;
    const pkg_rootdir = std.fs.path.dirname(pkg_path) orelse ".";

    const pm = package_json.getPackageManager(io);
    log.debug("Package manager: {s}", .{@tagName(pm)});

    if (!checkEsbuildBin(io, ctx.allocator, pkg_rootdir)) {
        log.debug("Installing dependencies for JavaScript", .{});
        log.debug("We try bun first", .{});
        var bun_installer = try std.process.spawn(io, .{
            .argv = &.{ "bun", "install" },
            .cwd = .{ .path = pkg_rootdir },
        });
        defer bun_installer.kill(io);

        const status = try bun_installer.wait(io);

        log.debug("Bun installer status: {s}", .{@tagName(status)});

        if (!checkEsbuildBin(io, ctx.allocator, pkg_rootdir)) {
            var installer = try std.process.spawn(io, .{
                .argv = &.{ @tagName(pm), "install" },
                .cwd = .{ .path = pkg_rootdir },
            });
            defer installer.kill(io);
            _ = try installer.wait(io);
        }
        if (!checkEsbuildBin(io, ctx.allocator, pkg_rootdir)) {
            std.debug.print(
                \\
                \\Could not find a Node.js package manager on your system. 
                \\We tried running '{s} install' but it failed.
                \\Please ensure you have a package manager (npm, pnpm, yarn, or bun) installed,
                \\or set the correct "packageManager" field in your package.json.
                \\You may need to run "npm install" or equivalent manually.
                \\
            , .{@tagName(pm)});
        } else {
            log.debug("Dependencies installed", .{});
        }
    } else {
        log.debug("Esbuild binary found", .{});
    }

    const outfile_arg = try std.fmt.allocPrintSentinel(ctx.allocator, "--outfile={s}/assets/main.js", .{rootdir}, 0);
    const main_tsx_arg = package_json.main orelse "site/main.tsx";
    defer ctx.allocator.free(outfile_arg);

    const main_tsx_argz = try ctx.allocator.dupeSentinel(u8, main_tsx_arg, 0);
    defer ctx.allocator.free(main_tsx_argz);

    log.debug("Building main.tsx: in package.json: {s}", .{package_json.main orelse "na"});
    log.debug("Outfile: {s}", .{outfile_arg});

    const esbuild_bin_path = std.fs.path.join(ctx.allocator, &.{ pkg_rootdir, "node_modules", ".bin", "esbuild" }) catch return error.EsbuildBinNotFound;
    defer ctx.allocator.free(esbuild_bin_path);
    var esbuild_args = std.ArrayList([]const u8).empty;
    try esbuild_args.append(ctx.allocator, esbuild_bin_path);
    try esbuild_args.append(ctx.allocator, main_tsx_argz);
    try esbuild_args.append(ctx.allocator, "--bundle");
    if (!is_dev) try esbuild_args.append(ctx.allocator, "--minify");
    try esbuild_args.append(ctx.allocator, outfile_arg);
    if (is_dev) try esbuild_args.append(ctx.allocator, "--define:process.env.NODE_ENV=\"development\"") else try esbuild_args.append(ctx.allocator, "--define:process.env.NODE_ENV=\"production\"");
    if (is_dev) try esbuild_args.append(ctx.allocator, "--define:__DEV__=true") else try esbuild_args.append(ctx.allocator, "--define:__DEV__=false");

    const esbuild_args_str = try std.mem.join(ctx.allocator, " ", esbuild_args.items);
    defer ctx.allocator.free(esbuild_args_str);
    log.debug("Esbuild args: {s}", .{esbuild_args_str});

    var esbuild_cmd = try std.process.spawn(io, .{
        .argv = esbuild_args.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_writer = std.Io.Writer.Allocating.init(ctx.allocator);
    defer stdout_writer.deinit();
    var stderr_writer = std.Io.Writer.Allocating.init(ctx.allocator);
    defer stderr_writer.deinit();

    // Read output from pipes
    if (esbuild_cmd.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        var streaming_reader = stdout_file.readerStreaming(io, &buf);
        const reader = &streaming_reader.interface;
        _ = reader.streamRemaining(&stdout_writer.writer) catch {};
    }
    if (esbuild_cmd.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        var streaming_reader = stderr_file.readerStreaming(io, &buf);
        const reader = &streaming_reader.interface;
        _ = reader.streamRemaining(&stderr_writer.writer) catch {};
    }

    const stdout = stdout_writer.written();
    const stderr = stderr_writer.written();
    _ = try esbuild_cmd.wait(io);

    log.debug("Esbuild stdout: {s} \n stderr: {s}", .{ stdout, stderr });

    const esbuild_output = try parseEsbuildOutput(stderr);

    // Pretty print esbuild output with colors
    if (verbose and esbuild_output.path.len > 0 and esbuild_output.size.len > 0 and esbuild_output.time.len > 0) {
        var printer = tui.Printer.init(ctx.allocator, .{});
        defer printer.deinit();
        // printer.header("{s} Bundled JS to {s}{s}{s} ({s}{s}{s}) in {s}{s}{s}", .{
        //     tui.Printer.emoji("📦"),
        //     tui.Colors.cyan,
        //     esbuild_output.path,
        //     tui.Colors.reset,
        //     tui.Colors.green,
        //     esbuild_output.size,
        //     tui.Colors.reset,
        //     tui.Colors.yellow,
        //     esbuild_output.time,
        //     tui.Colors.reset,
        // });
    }
}

const EsbuildOutput = struct {
    path: []const u8,
    size: []const u8,
    time: []const u8,
};

// Example output:
//   site/.zx/assets/main.js  190.7kb
// ⚡ Done in 21ms
fn parseEsbuildOutput(stdout: []const u8) !EsbuildOutput {
    // First trim by line break and whitespace
    const trimmed_output = std.mem.trim(u8, stdout, " \t\n\r");

    // Split by line
    var lines = std.mem.splitSequence(u8, trimmed_output, "\n");

    var path: []const u8 = "";
    var size: []const u8 = "";
    var time: []const u8 = "";

    var line_count: usize = 0;

    // Continue with while loop and only take lines that have length
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len > 0) {
            if (line_count == 0) {
                // First found one is path (and size)
                // Find the last space-separated token (the size)
                var last_space: ?usize = null;
                var i = trimmed_line.len;
                while (i > 0) {
                    i -= 1;
                    if (trimmed_line[i] == ' ' or trimmed_line[i] == '\t') {
                        last_space = i;
                        break;
                    }
                }

                if (last_space) |space_idx| {
                    path = std.mem.trim(u8, trimmed_line[0..space_idx], " \t");
                    size = std.mem.trim(u8, trimmed_line[space_idx + 1 ..], " \t");
                } else {
                    path = trimmed_line;
                }
                line_count += 1;
            } else if (line_count == 1) {
                // Second found one is time
                // Look for "Done in" pattern
                if (std.mem.indexOf(u8, trimmed_line, "Done in")) |done_idx| {
                    const time_start = done_idx + 7; // "Done in" is 7 chars
                    if (time_start < trimmed_line.len) {
                        time = std.mem.trim(u8, trimmed_line[time_start..], " \t\r");
                    }
                }
                line_count += 1;
                break; // We found both, no need to continue
            }
        }
    }

    return EsbuildOutput{
        .path = path,
        .size = size,
        .time = time,
    };
}

// TransformJS Zig bindings - provides a Zig interface to the TransformJS Rust library
const transformjs_c = @cImport({
    @cInclude("transformjs.h");
});

pub const TransformResult = struct {
    output: []const u8,
    err: ?[]const u8,
    success: bool,

    pub fn deinit(self: *TransformResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.err) |err| {
            allocator.free(err);
        }
    }
};

/// Transform options
/// Defaults are optimized for browser-compatible bundled output:
/// - Helper loader mode: Runtime (helpers are inlined for bundling)
/// - Module format: CommonJS (transformed from ES modules for bundling)
/// - Target: ES2020 (modern browser compatibility)
pub const TransformOptions = struct {
    jsx_enabled: bool = false,
    jsx_development: bool = false,
    typescript_enabled: bool = false,
    helper_loader_mode: TransformHelperLoaderMode = .Runtime, // Runtime = bundled helpers
    target: ?[]const u8 = null, // Defaults to "es2020" in Rust for browser compatibility
};

/// Helper loader mode
pub const TransformHelperLoaderMode = enum(u32) {
    Runtime = 0,
    External = 1,
};

/// Transform JavaScript/TypeScript source code
///
/// `source` - The source code to transform (must be null-terminated)
/// `file_path` - Optional file path for source type detection (can be null)
/// `options` - Optional transform options (can be null for defaults)
/// `allocator` - Allocator for temporary allocations
pub fn transform(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: ?[]const u8,
    options: ?TransformOptions,
) !TransformResult {
    // Ensure source is null-terminated
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    // Allocate file_path if provided, keep it alive during C call
    var file_path_z: ?[:0]u8 = null;
    if (file_path) |path| {
        file_path_z = try allocator.dupeSentinel(u8, path, 0);
    }
    defer if (file_path_z) |path_z| allocator.free(path_z);

    const file_path_ptr = if (file_path_z) |path_z| path_z.ptr else null;

    // Prepare C options struct if options provided
    var c_options: ?transformjs_c.CTransformOptions = null;
    var target_z: ?[:0]u8 = null;
    if (options) |opts| {
        if (opts.target) |target| {
            target_z = try allocator.dupeSentinel(u8, target, 0);
        }
        c_options = transformjs_c.CTransformOptions{
            .jsx_enabled = if (opts.jsx_enabled) 1 else 0,
            .jsx_development = if (opts.jsx_development) 1 else 0,
            .typescript_enabled = if (opts.typescript_enabled) 1 else 0,
            .helper_loader_mode = @backingInt(opts.helper_loader_mode),
            .target = if (target_z) |tz| tz.ptr else null,
        };
    }
    defer if (target_z) |tz| allocator.free(tz);

    const c_options_ptr = if (c_options) |*opts| opts else null;
    const c_result = transformjs_c.transformjs_transform(source_z.ptr, file_path_ptr, c_options_ptr);
    defer transformjs_c.transformjs_free_result(c_result);

    if (c_result == null) {
        return error.TransformFailed;
    }

    const result_ptr = c_result.?;
    const result = result_ptr.*;

    if (result.success != 0) {
        _ = if (result.@"error" != null)
            std.mem.span(result.@"error")
        else
            "Unknown error";
        return error.TransformError;
    }

    // Copy the output string before freeing the result
    const output_slice = if (result.output != null)
        std.mem.span(result.output)
    else
        "";

    const output = try allocator.dupe(u8, output_slice);
    // Note: We can't use defer here because we need to return it
    // The caller is responsible for freeing it (though currently we don't have deinit)

    return TransformResult{
        .output = output,
        .err = null,
        .success = true,
    };
}

/// Transform JavaScript/TypeScript source code with error details
///
/// Returns the error message if transformation fails
pub fn transformWithError(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: ?[]const u8,
    options: ?TransformOptions,
) !struct { result: TransformResult, error_message: ?[]const u8 } {
    // Ensure source is null-terminated
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    // Allocate file_path if provided, keep it alive during C call
    var file_path_z: ?[:0]u8 = null;
    if (file_path) |path| {
        file_path_z = try allocator.dupeSentinel(u8, path, 0);
    }
    defer if (file_path_z) |path_z| allocator.free(path_z);

    const file_path_ptr = if (file_path_z) |path_z| path_z.ptr else null;

    // Prepare C options struct if options provided
    var c_options: ?transformjs_c.CTransformOptions = null;
    var target_z: ?[:0]u8 = null;
    if (options) |opts| {
        if (opts.target) |target| {
            target_z = try allocator.dupeSentinel(u8, target, 0);
        }
        c_options = transformjs_c.CTransformOptions{
            .jsx_enabled = if (opts.jsx_enabled) 1 else 0,
            .jsx_development = if (opts.jsx_development) 1 else 0,
            .typescript_enabled = if (opts.typescript_enabled) 1 else 0,
            .helper_loader_mode = @backingInt(opts.helper_loader_mode),
            .target = if (target_z) |tz| tz.ptr else null,
        };
    }
    defer if (target_z) |tz| allocator.free(tz);

    const c_options_ptr = if (c_options) |*opts| opts else null;
    const c_result = transformjs_c.transformjs_transform(source_z.ptr, file_path_ptr, c_options_ptr);
    defer transformjs_c.transformjs_free_result(c_result);

    if (c_result == null) {
        return error.TransformFailed;
    }

    const result_ptr = c_result.?;
    const result = result_ptr.*;

    // Copy error message before freeing
    const error_slice = if (result.@"error" != null)
        std.mem.span(result.@"error")
    else
        null;
    const error_message = if (error_slice) |err| try allocator.dupe(u8, err) else null;

    // Copy output before freeing
    const output_slice = if (result.output != null)
        std.mem.span(result.output)
    else
        "";
    const output = try allocator.dupe(u8, output_slice);

    return .{
        .result = TransformResult{
            .output = output,
            .err = error_message,
            .success = result.success == 0,
        },
        .error_message = error_message,
    };
}

pub const TransformError = error{
    TransformFailed,
    TransformError,
};

const std = @import("std");
const util = @import("util.zig");
const tui = @import("../../tui/main.zig");
const CommandContext = @import("context.zig").CommandContext;
const log = std.log.scoped(.cli);
