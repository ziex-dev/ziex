const std = @import("std");
const BuildConfig = @import("../build/init/BuildConfig.zig");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const build_status = @import("shared/status.zig");
const Builder = @import("dev/Builder.zig");
const Diagnostics = @import("dev/Diagnostics.zig");
const tui = @import("../tui/main.zig");
const cli_args = @import("root.zig");
const static_cmd = @import("static.zig");

const CommandContext = context.CommandContext;
const Colors = tui.Colors;
pub const command = cli_args.build;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const allocator = ctx.allocator;

    if (args.static) {
        // Static builds run the built app on this machine, so they can't be cross-compiled.
        if (args.target.len > 0 and !std.mem.eql(u8, args.target, "native")) {
            try ctx.writer.print("{s}error:{s} --static builds for this machine and can't be combined with --target={s}\n", .{ Colors.red, Colors.reset, args.target });
            std.process.exit(1);
        }
        return static_cmd.buildStatic(ctx, .{
            .outdir = args.outdir,
            .@"bin-path" = args.@"bin-path",
            .@"zig-path" = args.@"zig-path",
            .release = if (args.release.len > 0) args.release else "small",
            .@"build-args" = args.@"build-args",
            .@"prerendered-only" = args.@"prerendered-only",
        });
    }

    var build_args = std.ArrayList([]const u8).empty;
    defer build_args.deinit(allocator);
    try build_args.appendSlice(allocator, &.{ args.@"zig-path", "build", "--prefix", args.@"install-prefix" });

    const target_arg = if (args.target.len > 0) try allocator.print("-Dtarget={s}", .{args.target}) else null;
    defer if (target_arg) |t| allocator.free(t);
    if (target_arg) |t| try build_args.append(allocator, t);
    const release_arg = if (args.release.len > 0) try allocator.print("--release={s}", .{args.release}) else null;
    defer if (release_arg) |r| allocator.free(r);
    if (release_arg) |r| try build_args.append(allocator, r);
    const config_arg = if (args.prerender) try (BuildConfig{ .prerender = true }).arg(allocator) else null;
    defer if (config_arg) |c| allocator.free(c);
    if (config_arg) |c| try build_args.append(allocator, c);

    var i_build_args = std.mem.splitSequence(u8, args.@"build-args", " ");
    while (i_build_args.next()) |arg| {
        const trimmed_arg = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, trimmed_arg, "")) continue;
        try build_args.append(allocator, trimmed_arg);
    }

    build_args.items[0] = util.resolveZigExe(app.environ_map, build_args.items[0]);

    var builder_impl: Builder.Bsp = undefined;
    builder_impl.init(io, .{
        .allocator = allocator,
        .argv = build_args.items,
        .environ_map = app.environ_map,
        .watch = false,
    }) catch |err| {
        try ctx.writer.print("{s}error:{s} zig build failed to start ({s})\n", .{ Colors.red, Colors.reset, @errorName(err) });
        std.process.exit(1);
    };
    var builder = builder_impl.builder();
    defer builder.deinit(io);

    var spinner = ctx.spinner;
    spinner.updateStyle(.{ .frames = tui.Spinner.SpinnerStyles.dots2, .refresh_rate_ms = 80 });
    try spinner.start("{s}{s}Building...{s}", .{ Colors.cyan, Colors.bold, Colors.reset });

    const start_ts = std.Io.Timestamp.now(io, .awake);
    var failed = false;
    var error_output: ?[]u8 = null;
    defer if (error_output) |f| allocator.free(f);
    var last_listed_step: ?[]const u8 = null;
    defer if (last_listed_step) |s| allocator.free(s);

    while (try builder.next(io)) |event| {
        switch (event) {
            .step_progress => |progress| {
                var status_buf: [256]u8 = undefined;
                const msg = build_status.formatStepProgress(&status_buf, "Building", progress);
                if (spinner.interactive) {
                    try spinner.updateMessage("{s}", .{msg});
                } else {
                    const step = progress.step orelse "";
                    const changed = last_listed_step == null or !std.mem.eql(u8, last_listed_step.?, step);
                    if (changed) {
                        if (last_listed_step) |s| allocator.free(s);
                        last_listed_step = try allocator.dupe(u8, step);
                        try ctx.writer.print("{s}\n", .{msg});
                        try ctx.writer.flush();
                    }
                }
            },
            .errors => |result_val| {
                var build_result = result_val;
                defer build_result.deinit();
                Diagnostics.remap(allocator, build_result.diagnostics, .{});
                const deduped = Diagnostics.dedupe(allocator, build_result.diagnostics);
                error_output = try Diagnostics.formatOxlint(allocator, deduped);
                failed = true;
                break;
            },
            .should_restart, .build_complete_no_change, .resolved => break,
            .assets_installed => |result_val| {
                var assets = result_val;
                assets.deinit();
                break;
            },
            .change_detected => {},
        }
    }

    const elapsed_ms: u64 = @intCast(start_ts.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    if (failed) {
        try spinner.fail("{s}Build failed {s}({d:.2}s){s}", .{ Colors.red, Colors.gray, elapsed_s, Colors.reset });
        if (error_output) |f| try ctx.writer.writeAll(f);
        std.process.exit(1);
    }

    try spinner.succeed("{s}Built {s}({d:.2}s){s}", .{ Colors.green, Colors.gray, elapsed_s, Colors.reset });
}
