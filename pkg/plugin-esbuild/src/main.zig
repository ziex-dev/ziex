const std = @import("std");
const plugin_system = @import("plugin_system");
const Options = @import("util.zig").Options;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var esbuild_path: []const u8 = undefined;
    var outdir_path: ?[]const u8 = null;
    var dep_file_path: ?[]const u8 = null;
    var name: []const u8 = "esbuild";
    var entrypoints: std.ArrayList([]const u8) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--esbuild-path")) {
            esbuild_path = args.next() orelse return error.MissingEsbuildPath;
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            outdir_path = args.next() orelse return error.MissingOutdirPath;
        } else if (std.mem.eql(u8, arg, "--dep-file")) {
            dep_file_path = args.next() orelse return error.MissingDepFilePath;
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = args.next() orelse return error.MissingName;
        } else if (std.mem.eql(u8, arg, "--entry")) {
            try entrypoints.append(allocator, args.next() orelse return error.MissingEntry);
        } else if (std.mem.eql(u8, arg, "--alias")) {
            const key = args.next() orelse return error.MissingAlias;
            // esbuild treats relative paths without a leading ./ (incl. .\ on Windows) as package names
            const path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args.next() orelse return error.MissingAlias, allocator);
            try aliases.append(allocator, try allocator.print("--alias:{s}={s}", .{ key, path }));
        }
    }

    if (entrypoints.items.len == 0) return error.MissingEntrypoints;

    const outdir = outdir_path orelse "dist";

    // Read stdin Options JSON
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdin_writer = std.Io.Writer.Allocating.init(allocator);
    defer stdin_writer.deinit();
    _ = try stdin_reader.interface.streamRemaining(&stdin_writer.writer);
    const input_json = try stdin_writer.toOwnedSlice();
    defer allocator.free(input_json);

    const options_json = if (input_json.len == 0) "{}" else input_json;
    const parsed = try std.json.parseFromSlice(Options, allocator, options_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const opts = parsed.value;

    var progress = std.Progress.start(init.io, .{
        .root_name = "esbuild",
        .estimated_total_items = 1,
    });
    defer progress.end();

    const node = progress.start(name, 0);
    defer {
        node.end();
        progress.completeOne();
    }

    var all_deps = std.ArrayList([]const u8).empty;
    defer all_deps.deinit(allocator);

    const meta_path = try allocator.print("{s}/.esbuild-meta.json", .{outdir});

    const argv = try buildEsbuildArgv(allocator, esbuild_path, entrypoints.items, aliases.items, opts, outdir, meta_path);
    defer allocator.free(argv);

    var child = std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Failed to execute esbuild: executable not found at '{s}'\n", .{esbuild_path});
            return error.EsbuildNotFound;
        }
        return err;
    };

    const term = child.wait(init.io) catch |err| {
        std.debug.print("Failed to wait for esbuild process: {any}\n", .{err});
        return error.WaitFailed;
    };
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    if (exit_code != 0) {
        std.debug.print("esbuild [{s}] failed with exit code {d}\n", .{ name, exit_code });
        std.process.exit(1);
    }

    collectMetafileDeps(allocator, init.io, meta_path, &all_deps) catch |err| {
        std.debug.print("esbuild [{s}] warning: failed to read metafile: {any}\n", .{ name, err });
    };
    std.Io.Dir.cwd().deleteFile(init.io, meta_path) catch {};

    if (dep_file_path) |dfp| {
        plugin_system.writeDepFile(allocator, init.io, dfp, outdir, all_deps.items) catch |err| {
            std.debug.print("Failed to write dep file: {any}\n", .{err});
        };
    }
}

fn buildEsbuildArgv(
    allocator: std.mem.Allocator,
    esbuild_bin: []const u8,
    entrypoints: []const []const u8,
    aliases: []const []const u8,
    opts: Options,
    outdir: []const u8,
    meta_path: []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    try argv.append(allocator, esbuild_bin);

    for (entrypoints) |ep| {
        try argv.append(allocator, ep);
    }

    // Bundle defaults to true (matches previous runner behavior).
    if (opts.bundle orelse true) try argv.append(allocator, "--bundle");

    try argv.append(allocator, try allocator.print("--outdir={s}", .{outdir}));
    try argv.append(allocator, try allocator.print("--metafile={s}", .{meta_path}));
    try argv.append(allocator, "--log-level=error");

    if (opts.platform) |v| {
        try argv.append(allocator, try allocator.print("--platform={s}", .{@tagName(v)}));
    }
    if (opts.format) |v| {
        try argv.append(allocator, try allocator.print("--format={s}", .{@tagName(v)}));
    }
    if (opts.minify) |v| {
        if (v) try argv.append(allocator, "--minify");
    }
    if (opts.splitting) |v| {
        if (v) try argv.append(allocator, "--splitting");
    }
    if (opts.public_path) |v| {
        try argv.append(allocator, try allocator.print("--public-path={s}", .{v}));
    }
    if (opts.sourcemap) |v| {
        if (v != .none) {
            try argv.append(allocator, try allocator.print("--sourcemap={s}", .{@tagName(v)}));
        }
    }
    for (opts.external) |ext| {
        try argv.append(allocator, try allocator.print("--external:{s}", .{ext}));
    }
    if (opts.target.len > 0) {
        var targets: std.ArrayList(u8) = .empty;
        defer targets.deinit(allocator);
        for (opts.target, 0..) |t, i| {
            if (i > 0) try targets.append(allocator, ',');
            try targets.appendSlice(allocator, t);
        }
        try argv.append(allocator, try allocator.print("--target={s}", .{targets.items}));
    }
    for (opts.define) |d| {
        try argv.append(allocator, try allocator.print("--define:{s}={s}", .{ d.key, d.value }));
    }
    try argv.appendSlice(allocator, aliases);

    return try argv.toOwnedSlice(allocator);
}

fn collectMetafileDeps(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta_path: []const u8,
    all_deps: *std.ArrayList([]const u8),
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, meta_path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var contents = std.Io.Writer.Allocating.init(allocator);
    defer contents.deinit();
    _ = try reader.interface.streamRemaining(&contents.writer);
    const json_bytes = try contents.toOwnedSlice();
    defer allocator.free(json_bytes);

    const meta = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer meta.deinit();

    const inputs = meta.value.object.get("inputs") orelse return;
    var it = inputs.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // Skip plugin-namespaced keys (e.g. "text-attr:/abs/path") if any appear.
        var path = key;
        if (std.mem.indexOfScalar(u8, key, ':')) |colon| {
            if (colon > 1) path = key[colon + 1 ..];
        }

        const abs = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch continue;
        try all_deps.append(allocator, abs);
    }
}
