const std = @import("std");
const builtin = @import("builtin");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const Builder = @import("dev/Builder.zig");
const tui = @import("../tui/main.zig");
const Diagnostics = @import("dev/Diagnostics.zig");
const DevServer = @import("dev/DevServer.zig");
const Highlight = @import("dev/Highlight.zig");
const RunnerOutput = @import("dev/RunnerOutput.zig");
const sig = @import("../util/sig.zig");
const cli_args = @import("root.zig");
const constants = @import("../runtime/core/constants.zig");

const CommandContext = context.CommandContext;
const Colors = tui.Colors;
const log = std.log.scoped(.cli);
pub const command = cli_args.dev;

fn ownProcessGroup() ?std.posix.pid_t {
    return if (comptime builtin.os.tag == .windows) null else 0;
}

fn trackChildGroup(child: *const std.process.Child) void {
    if (comptime builtin.os.tag == .windows) return;
    if (child.id) |pid| sig.watchGroup(pid);
}

fn untrackChildGroup(child: *const std.process.Child) void {
    if (comptime builtin.os.tag == .windows) return;
    if (child.id) |pid| sig.unwatchGroup(pid);
}

fn killRunnerHard(r: *std.process.Child, io: std.Io) void {
    if (comptime builtin.os.tag != .windows) {
        if (r.id) |pid| std.posix.kill(pid, sig.force_kill) catch {};
    }
    r.kill(io);
}

fn wakeLocalhostIo(io: std.Io, port: u16) void {
    if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |addr| {
        if (addr.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
        } else |_| {}
    } else |_| {}
}

fn stopRunnerGraceful(r: *std.process.Child, io: std.Io, inner_port: u16, timeout_ms: u64) void {
    if (r.id == null) {
        r.kill(io);
        return;
    }

    if (r.id) |pid| {
        if (comptime builtin.os.tag == .windows) {
            sig.killProcessGroup(pid, sig.force_kill);
        } else {
            sig.killProcessGroup(pid, std.posix.SIG.TERM);
        }
    }
    wakeLocalhostIo(io, inner_port);

    if (r.id) |pid| {
        if (sig.waitPidExit(pid, timeout_ms)) {
            _ = r.wait(io) catch {};
            return;
        }
    }

    killRunnerHard(r, io);
}

fn waitUntilPortFree(io: std.Io, port: u16, timeout_ms: u64) bool {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const begin = std.Io.Timestamp.now(io, .awake);
    while (true) {
        if (addr.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
        } else |_| {
            return true;
        }
        const elapsed: u64 = @intCast(begin.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());
        if (elapsed >= timeout_ms) return false;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
}

pub fn run(ctx: CommandContext, args: anytype) !void {
    var fatal_sig: ?std.posix.SIG = null;
    defer if (fatal_sig) |s| sig.raiseDefault(s);
    try runSupervised(ctx, args, &fatal_sig);
}

fn runSupervised(ctx: CommandContext, args: anytype, fatal_sig: *?std.posix.SIG) !void {
    const app = ctx.app;
    const io = app.io;
    const env_map = app.environ_map;
    var runner: ?std.process.Child = null;

    try sig.install();
    defer sig.uninstall();

    const allocator = ctx.allocator;
    const binpath = args.binpath;
    const install_prefix = args.@"install-prefix";
    const preferred_port = DevServer.resolvePreferredPort(args.port, env_map, constants.default_port);
    const build_args_str = args.@"build-args";
    const use_spinner = args.@"tui-spinner";
    const report_initial_build_time = args.@"tui-init-time-report";
    const clear_on_restart = args.@"tui-clear";
    const incremental = args.incremental;
    var build_args = std.mem.splitSequence(u8, build_args_str, " ");

    var build_args_array = std.ArrayList([]const u8).empty;
    defer build_args_array.deinit(allocator);

    const zig_path = args.@"zig-path";
    try build_args_array.appendSlice(allocator, &.{ zig_path, "build", "-Dcli-command=dev" });

    if (incremental) {
        try build_args_array.appendSlice(allocator, &.{"-Dincremental=true"});
    }

    log.debug("zig path: {s}", .{zig_path});

    while (build_args.next()) |arg| {
        const trimmed_arg = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, trimmed_arg, "")) continue;
        try build_args_array.appendSlice(allocator, &.{trimmed_arg});
    }

    const manifest_path = try util.resolveManifestPath(allocator, install_prefix, args.manifest);
    defer allocator.free(manifest_path);
    const transpile_dir = try util.resolveTranspileDir(io, allocator, manifest_path);
    defer allocator.free(transpile_dir);
    log.debug("manifest: {s}, transpile_dir: {s}", .{ manifest_path, transpile_dir });

    // Spin up the dev proxy first so it owns the user-facing port (and can
    // fall back to the next free port). Then pick an ephemeral inner port.
    log.debug("starting devserver preferred outer: {d}", .{preferred_port});
    var dev_server = DevServer.init(.{
        .gpa = allocator,
        .env_map = env_map,
        .address = try std.Io.net.IpAddress.parse("0.0.0.0", preferred_port),
        .inner_port = 0,
        .install_prefix = install_prefix,
        .transpile_dir = transpile_dir,
        .io = io,
    });
    var dev_server_active = true;
    defer if (dev_server_active) dev_server.deinit();
    dev_server.start() catch |err| {
        try ctx.writer.print("Failed to start dev proxy: {any}\n", .{err});
        return;
    };

    const outer_port = dev_server.address.getPort();
    const inner_port = DevServer.findFreePort(io) catch outer_port +% 1;
    if (inner_port == 0 or inner_port == outer_port) {
        try ctx.writer.print("Failed to allocate an inner port for the app binary\n", .{});
        return;
    }
    dev_server.inner_port = inner_port;

    const inner_port_str = try std.fmt.allocPrint(allocator, "{d}", .{inner_port});
    defer allocator.free(inner_port_str);
    const outer_port_str = try std.fmt.allocPrint(allocator, "{d}", .{outer_port});
    defer allocator.free(outer_port_str);

    try env_map.put("ZIEX_INNER_PORT", inner_port_str);
    try env_map.put("ZIEX_OUTER_PORT", outer_port_str);

    if (env_map.get("ZIEX_ROOT_DIR") == null) try env_map.put("ZIEX_ROOT_DIR", install_prefix);

    log.debug("devserver ready, inner: {d} outer: {d}", .{ inner_port, outer_port });

    // Resolve zig exe up-front so Builder backends can spawn without
    // importing cli util (keeps the `builder` test module self-contained).
    const resolved_zig = util.resolveZigExe(env_map, zig_path);
    if (build_args_array.items.len > 0) build_args_array.items[0] = resolved_zig;

    var builder_impl: Builder.default = undefined;
    try builder_impl.init(io, .{
        .allocator = allocator,
        .argv = build_args_array.items,
        .environ_map = env_map,
        .pgid = ownProcessGroup(),
    });
    var builder = builder_impl.builder();
    trackChildGroup(builder.child());

    var runner_output: ?RunnerOutput = null;
    var program_path: ?[]const u8 = null;
    var runner_temp: ?util.TempDir = null;
    var runnable_path_owned: ?[]const u8 = null;

    // Release the user-facing port first, then stop child processes.
    defer {
        if (sig.interrupted()) {
            std.debug.print("\n{s}Stopping dev server...{s}\n", .{ Colors.gray, Colors.reset });
        }
        dev_server.deinit();
        dev_server_active = false;

        if (runner) |*r| {
            untrackChildGroup(r);
            stopRunnerGraceful(r, io, inner_port, 3000);
            runner = null;
        }
        if (runner_output) |*o| {
            o.wait();
            o.deinit();
            runner_output = null;
        }
        untrackChildGroup(builder.child());
        builder.deinit(io);
        if (runnable_path_owned) |p| allocator.free(p);
        if (runner_temp) |*t| t.deinit(io, allocator);
        if (program_path) |p| allocator.free(p);
    }

    // Tracks wall-clock time from "change detected" to runner restart complete.
    var rebuild_timer: ?std.Io.Timestamp = std.Io.Timestamp.now(io, .awake);
    var rebuilding_shown = true;
    var rebuild_output_epoch: usize = 0;
    var is_first_run = true;
    var last_was_no_change = false;
    var last_error_formatted: ?[]const u8 = null;
    defer if (last_error_formatted) |prev| allocator.free(prev);

    if (use_spinner) {
        var spinner = ctx.spinner;
        spinner.updateStyle(.{ .frames = tui.Spinner.SpinnerStyles.dots2, .refresh_rate_ms = 80 });
        try spinner.start("{s}Building...{s}", .{ Colors.cyan, Colors.reset });
    } else {
        try ctx.writer.print("{s}↺ {s}Building...{s}\x1b[K\n", .{ Colors.cyan, Colors.bold, Colors.reset });
    }

    const NO_CHANGE_DEBOUNCE_MS = 200;

    while (true) {
        if (sig.interrupted()) break;

        const event = (try builder.next(io)) orelse break;
        switch (event) {
            .change_detected => change: {
                if (rebuilding_shown) break :change;
                last_was_no_change = false;
                if (last_error_formatted) |prev| {
                    allocator.free(prev);
                    last_error_formatted = null;
                }
                rebuild_timer = std.Io.Timestamp.now(io, .awake);
                rebuild_output_epoch = if (runner_output) |*output| output.outputEpoch() else 0;
                dev_server.notify(.{ .type = .building });
                if (use_spinner) {
                    if (rebuilding_shown) {
                        var spinner = ctx.spinner;
                        try spinner.updateMessage("{s}Rebuilding...{s}", .{ Colors.cyan, Colors.reset });
                    } else {
                        try ctx.writer.print("\n", .{});
                        var spinner = ctx.spinner;
                        spinner.updateStyle(.{ .frames = tui.Spinner.SpinnerStyles.dots2, .refresh_rate_ms = 80 });
                        try spinner.start("{s}Rebuilding...{s}", .{ Colors.cyan, Colors.reset });
                    }
                } else {
                    const prefix = if (rebuilding_shown) "\r" else "\n";
                    try ctx.writer.print("{s}{s}↺ {s}Rebuilding...{s}\x1b[K\n", .{ prefix, Colors.cyan, Colors.bold, Colors.reset });
                }
                rebuilding_shown = true;
            },
            .errors => |result_val| {
                last_was_no_change = false;
                var build_result = result_val;
                defer build_result.deinit();

                Diagnostics.remap(allocator, build_result.diagnostics, .{
                    .transpile_dir = transpile_dir,
                });
                const deduped = Diagnostics.dedupe(allocator, build_result.diagnostics);
                const identical_check = try Builder.formatDiagnostics(allocator, deduped);
                defer allocator.free(identical_check);

                const is_identical = if (last_error_formatted) |prev|
                    std.mem.eql(u8, identical_check, prev)
                else
                    false;

                if (!is_identical) {
                    if (last_error_formatted) |prev| allocator.free(prev);
                    last_error_formatted = try allocator.dupe(u8, identical_check);
                }

                const formatted_oxlint = try Diagnostics.formatOxlint(allocator, deduped);
                defer allocator.free(formatted_oxlint);

                if (use_spinner and rebuilding_shown) {
                    var spinner = ctx.spinner;
                    if (rebuild_timer) |_| {
                        try spinner.fail("{s}Error building{s}", .{ Colors.red, Colors.reset });
                    }
                    rebuild_timer = null;
                } else if (rebuild_timer) |_| {
                    const replace_status = if (runner_output) |*output|
                        output.outputEpoch() == rebuild_output_epoch
                    else
                        true;
                    const prefix = if (replace_status) "\x1b[1A\r" else "\r";
                    try ctx.writer.print("{s}{s}✖ {s}Error building{s}\x1b[K\n", .{ prefix, Colors.red, Colors.bold, Colors.reset });
                    rebuild_timer = null;
                }

                if (!is_identical) {
                    try ctx.writer.writeAll(formatted_oxlint);
                }

                notifyBuildError(allocator, &dev_server, formatted_oxlint, deduped);
                rebuilding_shown = false;
            },
            .resolved => {
                last_was_no_change = false;
                try ctx.writer.print("\n{s}✓ {s}All build errors have been resolved!{s}\n", .{ Colors.green, Colors.bold, Colors.reset });
                dev_server.notify(.{ .type = .clear });
            },
            .build_complete_no_change => {
                std.Io.sleep(io, .fromMilliseconds(NO_CHANGE_DEBOUNCE_MS), .awake) catch {};
                const replace_status = if (runner_output) |*output|
                    output.outputEpoch() == rebuild_output_epoch
                else
                    true;
                try settleNoChange(&ctx, &dev_server, use_spinner, rebuilding_shown, replace_status);
                rebuild_timer = null;
                rebuilding_shown = false;
                last_was_no_change = true;
            },
            .assets_installed => |result_val| {
                var result = result_val;
                defer result.deinit();

                if (use_spinner) {
                    ctx.spinner.stop();
                }

                const replace_status = if (runner_output) |*output|
                    output.outputEpoch() == rebuild_output_epoch
                else
                    true;
                const prefix: []const u8 = if (last_was_no_change or (rebuilding_shown and replace_status))
                    "\x1b[1A\r"
                else if (rebuilding_shown)
                    "\r"
                else
                    "";
                if (result.files.len == 1) {
                    try ctx.writer.print("{s}{s}✓ {s}Asset updated{s} {s}{s}{s}\x1b[K\n", .{
                        prefix, Colors.cyan, Colors.bold, Colors.reset, Colors.gray, result.files[0], Colors.reset,
                    });
                } else {
                    try ctx.writer.print("{s}{s}✓ {s}Assets updated{s} {s}({d} files){s}\x1b[K\n", .{
                        prefix, Colors.cyan, Colors.bold, Colors.reset, Colors.gray, result.files.len, Colors.reset,
                    });
                }

                dev_server.notify(.{ .type = .asset_update, .files = result.files });
                rebuild_timer = null;
                rebuilding_shown = false;
                last_was_no_change = true;
            },
            .should_restart => |build_duration_ms| {
                last_was_no_change = false;
                log.debug("Processing startup/restart request...", .{});

                const wall_build_ms: u64 = if (rebuild_timer) |t| @intCast(t.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds()) else build_duration_ms;
                rebuild_timer = null;
                const replace_status = is_first_run or if (runner_output) |*output|
                    output.outputEpoch() == rebuild_output_epoch
                else
                    true;

                var start_time = std.Io.Timestamp.now(io, .awake);

                // Graceful SIGTERM so DebugAllocator can print leaks on
                // restart; SIGKILL only if stop hangs past the timeout.
                if (runner) |*r| {
                    untrackChildGroup(r);
                    stopRunnerGraceful(r, io, inner_port, 3000);
                    runner = null;
                }
                if (runner_output) |*o| {
                    o.wait();
                    o.deinit();
                    runner_output = null;
                }
                _ = waitUntilPortFree(io, inner_port, 2000);

                if (program_path == null) {
                    program_path = util.resolveExePath(io, allocator, install_prefix, binpath) catch |err| {
                        log.debug("Error finding ZX executable: {any}", .{err});
                        continue;
                    };
                }

                if (runnable_path_owned) |p| {
                    allocator.free(p);
                    runnable_path_owned = null;
                }
                if (runner_temp) |*t| {
                    t.deinit(io, allocator);
                    runner_temp = null;
                }

                const runnable_path = if (comptime builtin.os.tag == .windows) blk: {
                    runner_temp = try util.TempDir.init(io, allocator);
                    errdefer {
                        runner_temp.?.deinit(io, allocator);
                        runner_temp = null;
                    }
                    const path = try util.getRunnablePath(io, allocator, program_path.?, runner_temp.?);
                    runnable_path_owned = path;
                    break :blk path;
                } else program_path.?;

                if (clear_on_restart) {
                    try ctx.writer.print("\x1b[2J\x1b[H", .{});
                }

                if (rebuilding_shown and !is_first_run and use_spinner) {
                    var spinner = ctx.spinner;
                    spinner.updateStyle(.{ .frames = tui.Spinner.SpinnerStyles.dots2, .refresh_rate_ms = 80 });
                    try spinner.start("{s}Restarting...{s}", .{ Colors.purple, Colors.reset });
                }

                var runner_args = std.ArrayList([]const u8).empty;
                defer runner_args.deinit(allocator);
                try runner_args.appendSlice(allocator, &.{runnable_path});

                runner = try std.process.spawn(io, .{
                    .argv = runner_args.items,
                    .environ_map = env_map,
                    .stderr = .pipe,
                    .stdout = .pipe,
                    .pgid = ownProcessGroup(),
                });
                trackChildGroup(&runner.?);

                runner_output = try RunnerOutput.init(io, allocator, &runner.?);

                const restart_time_ms: u64 = @intCast(start_time.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());

                if (rebuilding_shown and (!is_first_run or report_initial_build_time)) {
                    const total_ms = wall_build_ms + restart_time_ms;
                    const total_s: f64 = @as(f64, @floatFromInt(total_ms)) / 1000.0;
                    if (use_spinner) {
                        var spinner = ctx.spinner;
                        if (is_first_run) {
                            try spinner.succeed("{s}Built {s}({d:.2}s){s}", .{ Colors.green, Colors.gray, total_s, Colors.reset });
                        } else {
                            try spinner.succeed("{s}Restarted {s}({d:.2}s){s}", .{ Colors.green, Colors.gray, total_s, Colors.reset });
                        }
                    } else {
                        const action = if (is_first_run) "Built" else "Restarted";
                        const prefix = if (replace_status) "\x1b[1A\r" else "\r";
                        try ctx.writer.print("{s}{s}✓ {s}{s} {s}({d:.2}s){s}\x1b[K\n", .{ prefix, Colors.green, Colors.bold, action, Colors.gray, total_s, Colors.reset });
                    }
                }

                if (!is_first_run) {
                    try ctx.writer.print("\n", .{});
                    printApplicationLogsBanner();
                } else if (report_initial_build_time) {
                    try ctx.writer.print("\n", .{});
                } else if (use_spinner) {
                    var spinner = ctx.spinner;
                    spinner.stop();
                    try ctx.writer.print("\r\x1b[2K", .{});
                } else {
                    try ctx.writer.print("\x1b[1A\r\x1b[2K", .{});
                }
                _ = runner_output.?.waitForFirstLine(250);
                printFirstLine(&runner_output.?);
                is_first_run = false;

                _ = dev_server.waitUntilInnerReady(5000);
                dev_server.notify(.{ .type = .reload });

                rebuilding_shown = false;
            },
        }
    }

    fatal_sig.* = sig.received();
}

fn settleNoChange(
    ctx: *const CommandContext,
    dev_server: *DevServer,
    use_spinner: bool,
    rebuilding_shown: bool,
    replace_status: bool,
) !void {
    if (rebuilding_shown) {
        const dim = "\x1b[2m";
        if (use_spinner) {
            var spinner = ctx.spinner;
            try spinner.succeed("{s}No changes{s}", .{ dim, Colors.reset });
        } else {
            const prefix = if (replace_status) "\x1b[1A\r" else "\r";
            try ctx.writer.print("{s}{s}✓ No changes{s}\x1b[K\n", .{ prefix, dim, Colors.reset });
        }
    }
    log.debug("cached watch cycle completed without output changes", .{});
    dev_server.notify(.{ .type = .clear });
}

/// Print the first captured line (prefer stderr, fallback to stdout)
fn printFirstLine(output: *RunnerOutput) void {
    if (output.consumeFirstLine()) |first_line| {
        if (first_line.len > 0) {
            std.debug.print("{s}\n", .{first_line});
        }
    }
}

fn printApplicationLogsBanner() void {
    std.debug.print("{s}╭─{s}[{s}Application Logs{s}]\n", .{ Colors.gray, Colors.reset, Colors.purple, Colors.reset });
}

fn notifyBuildError(
    allocator: std.mem.Allocator,
    dev_server: *DevServer,
    formatted_oxlint: []const u8,
    diagnostics: []const Builder.Diagnostic,
) void {
    if (diagnostics.len > 0) {
        const notification_diagnostics = buildNotificationDiagnostics(allocator, diagnostics) catch null;
        if (notification_diagnostics) |items| {
            defer freeNotificationDiagnostics(allocator, items);
            dev_server.notify(.{
                .type = .@"error",
                .diagnostics = items,
            });
            return;
        }
    }

    const stripped_owned = allocator.dupe(u8, formatted_oxlint) catch return;
    defer allocator.free(stripped_owned);
    const stripped = Builder.stripAnsiInPlace(stripped_owned);

    dev_server.notify(.{
        .type = .@"error",
        .message = stripped,
    });
}

fn buildNotificationDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: []const Builder.Diagnostic,
) ![]DevServer.Notification.Diagnostic {
    const items = try allocator.alloc(DevServer.Notification.Diagnostic, diagnostics.len);
    errdefer allocator.free(items);

    for (diagnostics, 0..) |d, idx| {
        items[idx] = .{
            .file = d.file,
            .line = d.line,
            .col = d.col,
            .kind = switch (d.kind) {
                .@"error" => .@"error",
                .warning => .warning,
                .note => .note,
            },
            .message = d.message,
            .source = null,
        };

        if (d.kind == .@"error") {
            items[idx].source = Diagnostics.readSourceContext(allocator, d.file, d.line, 3);
            items[idx].source_html = Diagnostics.readHighlightedSourceContext(allocator, d.file, d.line, 3, Highlight.highlightZx) catch null;
        }
    }

    return items;
}

fn freeNotificationDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: []DevServer.Notification.Diagnostic,
) void {
    for (diagnostics) |d| {
        if (d.source) |source| allocator.free(source);
        if (d.source_html) |source_html| allocator.free(source_html);
    }
    allocator.free(diagnostics);
}
