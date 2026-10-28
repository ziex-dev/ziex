const std = @import("std");
const lang = @import("lang");

const context = @import("shared/context.zig");
const tui = @import("../tui/main.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
const colors = tui.Colors;
const log = std.log.scoped(.cli);
pub const command = cli_args.fmt;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;

    const use_stdin = args.stdin;
    const use_stdout = args.stdout;

    if (use_stdin) {
        try formatFromStdin(io, ctx.allocator, ctx.writer);
        return;
    }

    const paths = args.paths;
    if (paths.len == 0) {
        try ctx.writer.print("{s}No paths were given.{s}\n", .{ colors.yellow, colors.reset });
        try ctx.writer.print("\nUsage:\n\n", .{});
        try ctx.writer.print("  {s}zx fmt{s} {s}{s}app/pages/page.zx{s}  {s}# Format a single file{s}\n\n", .{
            colors.cyan,
            colors.reset,
            colors.bold,
            colors.gray,
            colors.reset,
            colors.gray,
            colors.reset,
        });
        try ctx.writer.print("  {s}zx fmt{s} {s}{s}app/pages{s}  {s}# Format all .zx files in a directory{s}\n\n", .{
            colors.cyan,
            colors.reset,
            colors.bold,
            colors.gray,
            colors.reset,
            colors.gray,
            colors.reset,
        });
        return;
    }

    for (paths) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                try formatFile(ctx.allocator, io, ctx.writer, std.Io.Dir.cwd(), path, path, use_stdout);
                continue;
            },
            else => continue,
        };

        defer dir.close(io);
        try formatDir(ctx.allocator, io, ctx.writer, path, use_stdout);
    }
}

fn formatFromStdin(io: std.Io, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var reader = std.Io.File.stdin().reader(io, &.{});
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    _ = try reader.interface.streamRemaining(&buffer.writer);
    const input = try buffer.toOwnedSliceSentinel(0);
    defer allocator.free(input);

    var format_result = try lang.Ast.fmt(allocator, input);
    defer format_result.deinit(allocator);

    if (format_result.source == null) {
        for (format_result.diagnostics.items) |d| {
            log.err("{}:{}: {s}", .{ d.start_line + 1, d.start_column + 1, d.message });
        }
        return;
    }

    try writer.writeAll(format_result.source.?);
}

fn formatFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    base_dir: std.Io.Dir,
    sub_path: []const u8,
    full_path: []const u8,
    use_stdout: bool,
) !void {
    if (!std.mem.endsWith(u8, sub_path, ".zx")) {
        return; // Skip non-.zx files
    }
    const source = try base_dir.readFileAlloc(
        io,
        sub_path,
        allocator,
        .unlimited,
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var format_result = try lang.Ast.fmt(allocator, source_z);
    defer format_result.deinit(allocator);

    if (format_result.source == null) {
        for (format_result.diagnostics.items) |d| {
            log.err("{s}:{}:{}: {s}", .{ full_path, d.start_line + 1, d.start_column + 1, d.message });
        }
        return;
    }

    const formatted = format_result.source.?;

    if (use_stdout) {
        try writer.writeAll(formatted);
        return;
    }

    // Skip writing if content unchanged
    if (std.mem.eql(u8, formatted, source)) {
        return;
    }

    // Write formatted content back to file
    var atomic_file = try base_dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer atomic_file.deinit(io);

    try atomic_file.file.writeStreamingAll(io, formatted);
    try atomic_file.replace(io);
    try writer.print("{s}\n", .{full_path});
}

fn formatDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    path: []const u8,
    use_stdout: bool,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Check if file ends with .zx before processing
        if (!std.mem.endsWith(u8, entry.path, ".zx")) continue;

        // Construct full path relative to current working directory
        // Normalize path by removing leading ./ if present
        const normalized_path = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        const full_path = try std.fs.path.join(allocator, &.{ normalized_path, entry.path });
        defer allocator.free(full_path);

        // Read file using entry.dir (which is the directory containing the file)
        const source = try entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(std.math.maxInt(usize)),
        );
        defer allocator.free(source);

        const source_z = try allocator.dupeSentinel(u8, source, 0);
        defer allocator.free(source_z);

        var format_result = try lang.Ast.fmt(allocator, source_z);
        defer format_result.deinit(allocator);

        if (format_result.source == null) {
            for (format_result.diagnostics.items) |d| {
                log.err("{s}:{}:{}: {s}", .{ full_path, d.start_line + 1, d.start_column + 1, d.message });
            }
            continue;
        }

        const formatted = format_result.source.?;

        if (use_stdout) {
            try writer.writeAll(formatted);
            continue;
        }

        // Skip writing if content unchanged
        if (std.mem.eql(u8, formatted, source)) {
            continue;
        }

        // Write formatted content back to file using entry.dir
        var atomic_file = try entry.dir.createFileAtomic(io, entry.basename, .{ .replace = true });
        defer atomic_file.deinit(io);

        try atomic_file.file.writeStreamingAll(io, formatted);
        try atomic_file.replace(io);
        try writer.print("{s}\n", .{full_path});
    }
}
