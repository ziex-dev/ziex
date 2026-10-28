const std = @import("std");
const BuildConfig = @import("../build/init/BuildConfig.zig");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
const log = std.log.scoped(.cli);
pub const command = cli_args.serve;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const port = args.port;
    const install_prefix = args.@"install-prefix";

    var build_argv = std.ArrayList([]const u8).empty;
    defer build_argv.deinit(ctx.allocator);
    const config_arg = try (BuildConfig{ .command = .serve }).arg(ctx.allocator);
    defer ctx.allocator.free(config_arg);
    try build_argv.appendSlice(ctx.allocator, &.{ args.@"zig-path", "build", config_arg, "--prefix", install_prefix });

    const release_arg = if (args.release.len > 0) try ctx.allocator.print("--release={s}", .{args.release}) else null;
    defer if (release_arg) |r| ctx.allocator.free(r);
    if (release_arg) |r| try build_argv.append(ctx.allocator, r);

    var i_build_args = std.mem.splitSequence(u8, args.@"build-args", " ");
    while (i_build_args.next()) |arg| {
        const trimmed_arg = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, trimmed_arg, "")) continue;
        try build_argv.append(ctx.allocator, trimmed_arg);
    }

    var build_proc = util.spawnZig(io, .{
        .argv = build_argv.items,
        .environ_map = app.environ_map,
    }) catch |err| util.exitZigSpawnFailed(args.@"zig-path", err);
    switch (try build_proc.wait(io)) {
        .exited => |code| if (code != 0) {
            try ctx.writer.print("Failed to build the Ziex executable for serve (exit {d})!\n", .{code});
            return;
        },
        else => {
            try ctx.writer.print("Failed to build the Ziex executable for serve!\n", .{});
            return;
        },
    }

    const exe_path = util.resolveExePath(io, ctx.allocator, install_prefix, args.@"bin-path") catch {
        try ctx.writer.print("Run \x1b[34mzig build\x1b[0m to build the Ziex executable first!\n", .{});
        return;
    };
    defer ctx.allocator.free(exe_path);

    const environ_map = app.environ_map;
    try environ_map.put("ZIEX_ROOT_DIR", install_prefix);

    const port_str = if (port != 0) try ctx.allocator.print("{d}", .{port}) else null;
    defer if (port_str) |s| ctx.allocator.free(s);
    if (port_str) |s| try environ_map.put("PORT", s);

    log.debug("Spawning serve exe={s} rootdir={s}", .{ exe_path, install_prefix });

    var app_child = try std.process.spawn(io, .{
        .argv = &.{exe_path},
        .environ_map = environ_map,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try app_child.wait(io);
    _ = term;
}
