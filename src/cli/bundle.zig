const std = @import("std");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const tui = @import("../tui/main.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
const log = std.log.scoped(.cli);
pub const command = cli_args.bundle;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const outdir = args.outdir;
    const binpath = args.@"bin-path";
    const install_prefix = args.@"install-prefix";

    const program_path = util.resolveExePath(io, ctx.allocator, install_prefix, binpath) catch |err| {
        if (err == error.ExecutableNotFound or err == error.FileNotFound) {
            std.log.err("Run \x1b[34mzig build\x1b[0m to build your app first!\n", .{});
            return;
        }
        std.log.err("Error finding app manifest executable! {any}\n", .{err});
        return;
    };
    defer ctx.allocator.free(program_path);

    const staticdir = try std.fs.path.join(ctx.allocator, &.{ install_prefix, "static" });
    defer ctx.allocator.free(staticdir);

    var printer = tui.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    printer.header("{s} Bundling app!", .{tui.Printer.emoji("○")});
    printer.info("{s}", .{outdir});

    log.debug("Bundling app! binpath={s} staticdir={s}", .{ program_path, staticdir });
    log.debug("Outdir: {s}", .{outdir});

    const bin_name = std.fs.path.basename(program_path);
    const dest_binpath = try std.fs.path.join(ctx.allocator, &.{ outdir, bin_name });
    defer ctx.allocator.free(dest_binpath);
    log.debug("Copying bin from {s} to outdir {s}", .{ program_path, dest_binpath });

    std.Io.Dir.cwd().createDirPath(io, outdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), program_path, std.Io.Dir.cwd(), dest_binpath, io, .{});
    printer.filepath(bin_name);

    const static_outdir = try std.fs.path.join(ctx.allocator, &.{ outdir, "static" });
    defer ctx.allocator.free(static_outdir);
    log.debug("Copying static directory! {s}", .{staticdir});
    util.copydirs(io, ctx.allocator, staticdir, &.{"."}, static_outdir, false, &printer) catch |err| {
        std.log.err("Failed to copy static directory: {any}", .{err});
        return err;
    };

    printer.footer("Now run {s}\n\n{s}(cd {s} && ./{s}){s}", .{ tui.Printer.emoji("→"), tui.Colors.cyan, outdir, bin_name, tui.Colors.reset });
}
