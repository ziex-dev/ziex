const std = @import("std");
const BuildConfig = @import("../build/init/BuildConfig.zig");
const builtin = @import("builtin");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const build_status = @import("shared/status.zig");
const Builder = @import("dev/Builder.zig");
const tui = @import("../tui/main.zig");
const Diagnostics = @import("dev/Diagnostics.zig");
const DevServer = @import("dev/DevServer.zig");
const Highlight = @import("dev/Highlight.zig");
const RunnerOutput = @import("dev/RunnerOutput.zig");
const Process = @import("dev/Process.zig");
const sig = @import("../util/sig.zig");
const cli_args = @import("root.zig");
const constants = @import("../runtime/core/constants.zig");

const CommandContext = context.CommandContext;
const Colors = tui.Colors;
const log = std.log.scoped(.cli);
pub const command = cli_args.dev;

/// Child process trees that must not outlive `zx dev`. The app is stopped by
/// closing its stdin (works on every OS) so it can exit cleanly and report leaks.
const children = struct {
    /// Held while spawning so a signal can't land between spawn and record.
    var mutex: std.Io.Mutex = .init;
    var builder: ?std.process.Child.Id = null;
    var runner: ?std.process.Child.Id = null;
    var runner_done: ?*const std.atomic.Value(bool) = null;
    var runner_stdin: ?std.Io.File = null;
    var io: std.Io = undefined;
    var inner_port: u16 = 0;
    /// Lock-free copies for `forceKill`, which runs in signal context.
    var force_groups: [2]std.atomic.Value(i32) = .{ .init(0), .init(0) };

    const lock_io = std.Io.Threaded.global_single_threaded.io();

    fn onSignal(signal: std.posix.SIG) void {
        mutex.lockUncancelable(lock_io);
        std.debug.print("\n{s}Stopping dev server...{s}\n", .{ Colors.gray, Colors.reset });
        if (runner) |id| {
            closeRunnerStdin();
            _ = awaitRunnerOutput(2000);
            Process.killTree(id);
        }
        if (builder) |id| Process.killTree(id);
        // `zig build` is still waiting on us; Ctrl+C isn't a failed step.
        if (Process.terminal.held()) {
            Process.terminal.release();
            sig.exitWith(0);
        }
        sig.exit(signal);
    }

    /// Windows children share our console and get the Ctrl+C themselves.
    fn forceKill() void {
        if (comptime builtin.os.tag == .windows) return;
        for (&force_groups) |*g| {
            const pgid = g.load(.acquire);
            if (pgid > 0) _ = std.posix.system.kill(-pgid, .KILL);
        }
        Process.terminal.release();
    }

    fn mirror() void {
        if (comptime builtin.os.tag == .windows) return;
        force_groups[0].store(builder orelse 0, .release);
        force_groups[1].store(runner orelse 0, .release);
    }

    /// Call with `mutex` held.
    fn closeRunnerStdin() void {
        if (runner_stdin) |f| f.close(io);
        runner_stdin = null;
    }

    /// The app's stop doesn't interrupt a blocked accept(); a connection does.
    fn wakeRunner() void {
        if (std.Io.net.IpAddress.parse("127.0.0.1", inner_port)) |addr| {
            if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
    }

    fn setBuilder(id: ?std.process.Child.Id) void {
        mutex.lockUncancelable(lock_io);
        defer mutex.unlock(lock_io);
        builder = id;
        mirror();
    }

    fn spawnRunner(options: std.process.SpawnOptions) !std.process.Child {
        mutex.lockUncancelable(lock_io);
        defer mutex.unlock(lock_io);
        var child = try std.process.spawn(io, options);
        runner = child.id;
        runner_stdin = child.stdin;
        child.stdin = null;
        mirror();
        return child;
    }

    fn watchRunnerOutput(output: *const RunnerOutput) void {
        mutex.lockUncancelable(lock_io);
        defer mutex.unlock(lock_io);
        runner_done = output.doneFlag();
    }

    /// Reaping before the output drains closes the pipes under the reader.
    fn awaitRunnerOutput(timeout_ms: u32) bool {
        const done = runner_done orelse return true;
        var waited: u32 = 0;
        while (!done.load(.acquire)) : (waited += 10) {
            if (waited >= timeout_ms) return false;
            if (waited % 200 == 0) wakeRunner();
            io.sleep(.fromMilliseconds(10), .awake) catch return false;
        }
        return true;
    }

    fn stopRunner(child: *std.process.Child) void {
        if (child.id == null) return;
        mutex.lockUncancelable(lock_io);
        closeRunnerStdin();
        mutex.unlock(lock_io);
        Process.waitOrKill(child, io, if (awaitRunnerOutput(3000)) 1000 else 0);
        mutex.lockUncancelable(lock_io);
        defer mutex.unlock(lock_io);
        runner = null;
        runner_done = null;
        mirror();
    }
};

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

// Wasm has no processes or sockets, so the host drives the dev loop
pub const run = if (builtin.cpu.arch.isWasm()) @import("dev/Host.zig").run else runNative;

fn runNative(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const env_map = app.environ_map;
    var runner: ?std.process.Child = null;

    children.io = io;
    try sig.install(children.onSignal);
    sig.setForceHandler(children.forceKill);
    defer sig.uninstall();
    Process.terminal.take();
    defer Process.terminal.release();

    const allocator = ctx.allocator;
    const binpath = args.@"bin-path";
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
    const config_arg = try (BuildConfig{ .command = .dev, .incremental = incremental }).arg(allocator);
    defer allocator.free(config_arg);
    try build_args_array.appendSlice(allocator, &.{ zig_path, "build", config_arg });

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
    children.inner_port = inner_port;

    const inner_port_str = try std.fmt.allocPrint(allocator, "{d}", .{inner_port});
    defer allocator.free(inner_port_str);
    const outer_port_str = try std.fmt.allocPrint(allocator, "{d}", .{outer_port});
    defer allocator.free(outer_port_str);

    try env_map.put("ZIEX_INNER_PORT", inner_port_str);
    try env_map.put("ZIEX_STOP_ON_EOF", "1");
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
    });
    var builder = builder_impl.builder();
    children.setBuilder(builder.child().id);

    var runner_output: ?RunnerOutput = null;
    var program_path: ?[]const u8 = null;
    var runner_temp: ?util.TempDir = null;
    var runnable_path_owned: ?[]const u8 = null;

    // Release the user-facing port first, then stop child processes.
    defer {
        dev_server.deinit();
        dev_server_active = false;
        if (runner) |*r| children.stopRunner(r);
        if (runner_output) |*o| o.deinit();
        builder.deinit(io);
        children.setBuilder(null);
        if (runnable_path_owned) |p| allocator.free(p);
        if (runner_temp) |*t| t.deinit(io, allocator);
        if (program_path) |p| allocator.free(p);
    }

    // Tracks wall-clock time from "change detected" to runner restart complete.
    var rebuild_timer: ?std.Io.Timestamp = std.Io.Timestamp.now(io, .awake);
    var rebuilding_shown = true;
    var rebuild_output_epoch: usize = 0;
    var is_first_run = true;
    var last_error_formatted: ?[]const u8 = null;
    defer if (last_error_formatted) |prev| allocator.free(prev);
    var build_label: []const u8 = "Building";
    const status = ctx.spinner;
    // Echo rebuilds can request a restart even when the exe is byte-identical.
    var last_exe_fingerprint: ?u64 = null;

    try startStatus(status, use_spinner, "{s}{s}Building...{s}", .{ Colors.cyan, Colors.bold, Colors.reset });

    const NO_CHANGE_DEBOUNCE_MS = 200;

    while (true) {
        const event = (try builder.next(io)) orelse break;
        switch (event) {
            .change_detected => change: {
                if (rebuilding_shown) break :change;
                if (last_error_formatted) |prev| {
                    allocator.free(prev);
                    last_error_formatted = null;
                }
                rebuild_timer = std.Io.Timestamp.now(io, .awake);
                rebuild_output_epoch = if (runner_output) |*output| output.outputEpoch() else 0;
                build_label = "Rebuilding";
                dev_server.notify(.{ .type = .building });
                try startStatus(status, use_spinner, "{s}{s}Rebuilding...{s}", .{ Colors.cyan, Colors.bold, Colors.reset });
                rebuilding_shown = true;
            },
            .step_progress => |progress| {
                if (!rebuilding_shown) continue;
                var status_buf: [256]u8 = undefined;
                try status.updateMessage("{s}", .{build_status.formatStepProgress(&status_buf, build_label, progress)});
            },
            .errors => |result_val| {
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

                if (rebuild_timer != null) {
                    if (status.isSpinning()) {
                        try status.fail("{s}{s}Error building{s}", .{ Colors.red, Colors.bold, Colors.reset });
                    } else {
                        try ctx.writer.print("{s}✖ {s}Error building{s}\n", .{ Colors.red, Colors.bold, Colors.reset });
                    }
                    rebuild_timer = null;
                }

                if (!is_identical) {
                    try ctx.writer.writeAll(formatted_oxlint);
                }

                notifyBuildError(allocator, &dev_server, formatted_oxlint, deduped);
                rebuilding_shown = false;
            },
            .resolved => {
                if (status.isSpinning()) {
                    try status.succeed("{s}{s}All build errors have been resolved!{s}", .{ Colors.green, Colors.bold, Colors.reset });
                } else {
                    try ctx.writer.print("\n{s}✓ {s}All build errors have been resolved!{s}\n", .{ Colors.green, Colors.bold, Colors.reset });
                }
                rebuild_timer = null;
                rebuilding_shown = false;
                dev_server.notify(.{ .type = .clear });
            },
            .build_complete_no_change => {
                std.Io.sleep(io, .fromMilliseconds(NO_CHANGE_DEBOUNCE_MS), .awake) catch {};
                if (rebuilding_shown) status.clear();
                log.debug("cached watch cycle completed without output changes", .{});
                dev_server.notify(.{ .type = .clear });
                rebuild_timer = null;
                rebuilding_shown = false;
            },
            .assets_installed => |result_val| {
                var result = result_val;
                defer result.deinit();

                status.clear();

                if (result.files.len == 1) {
                    try ctx.writer.print("\r{s}✓ {s}Asset updated{s} {s}{s}{s}\x1b[K\n", .{
                        Colors.cyan, Colors.bold, Colors.reset, Colors.gray, result.files[0], Colors.reset,
                    });
                } else {
                    try ctx.writer.print("\r{s}✓ {s}Assets updated{s} {s}({d} files){s}\x1b[K\n", .{
                        Colors.cyan, Colors.bold, Colors.reset, Colors.gray, result.files.len, Colors.reset,
                    });
                }

                dev_server.notify(.{ .type = .asset_update, .files = result.files });
                rebuild_timer = null;
                rebuilding_shown = false;
            },
            .should_restart => |build_duration_ms| {
                log.debug("Processing startup/restart request...", .{});

                // The CLI backend can finish a rebuild without announcing it first.
                if (Builder.default == Builder.Cli and !rebuilding_shown and !is_first_run) {
                    rebuild_timer = std.Io.Timestamp.now(io, .awake);
                    rebuild_output_epoch = if (runner_output) |*output| output.outputEpoch() else 0;
                    build_label = "Rebuilding";
                    try startStatus(status, use_spinner, "{s}{s}Rebuilding...{s}", .{ Colors.cyan, Colors.bold, Colors.reset });
                    rebuilding_shown = true;
                }

                if (program_path == null) {
                    program_path = util.resolveExePath(io, allocator, install_prefix, binpath) catch |err| {
                        log.debug("Error finding Ziex executable: {any}", .{err});
                        continue;
                    };
                }

                const exe_fp = exeContentFingerprint(io, program_path.?);
                const orphan = !is_first_run and !rebuilding_shown;
                const unchanged = !is_first_run and exe_fp != null and last_exe_fingerprint == exe_fp;
                if (orphan or unchanged) {
                    log.debug("skipping duplicate restart (orphan={} unchanged={})", .{ orphan, unchanged });
                    if (rebuilding_shown) status.clear();
                    rebuilding_shown = false;
                    rebuild_timer = null;
                    _ = dev_server.waitUntilInnerReady(1000);
                    dev_server.notify(.{ .type = .reload });
                    continue;
                }

                const wall_build_ms: u64 = if (rebuild_timer) |t| @intCast(t.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds()) else build_duration_ms;
                rebuild_timer = null;

                var separated_epoch: ?usize = null;
                if (rebuilding_shown and !is_first_run) {
                    if (runner_output) |*output| {
                        const epoch = output.outputEpoch();
                        if (epoch != rebuild_output_epoch) {
                            status.writeAbove(io, std.Io.File.stdout(), "\n");
                            separated_epoch = epoch;
                        }
                    }
                    try status.updateMessage("{s}{s}Restarting...{s}", .{ Colors.purple, Colors.bold, Colors.reset });
                }

                var start_time = std.Io.Timestamp.now(io, .awake);

                if (runner) |*r| {
                    children.stopRunner(r);
                    runner = null;
                }
                var final_output_epoch = rebuild_output_epoch;
                if (runner_output) |*o| {
                    final_output_epoch = o.finish();
                    runner_output = null;
                }
                _ = waitUntilPortFree(io, inner_port, 2000);

                if (runnable_path_owned) |p| {
                    allocator.free(p);
                    runnable_path_owned = null;
                }
                if (runner_temp) |*t| {
                    t.deinit(io, allocator);
                    runner_temp = null;
                }

                const runnable_path = blk: {
                    runner_temp = try util.TempDir.init(io, allocator);
                    errdefer {
                        runner_temp.?.deinit(io, allocator);
                        runner_temp = null;
                    }
                    const path = try util.getRunnablePath(io, allocator, program_path.?, runner_temp.?);
                    runnable_path_owned = path;
                    break :blk path;
                };

                if (clear_on_restart) {
                    try ctx.writer.print("\x1b[2J\x1b[H", .{});
                }

                var runner_args = std.ArrayList([]const u8).empty;
                defer runner_args.deinit(allocator);
                try runner_args.appendSlice(allocator, &.{runnable_path});

                runner = try children.spawnRunner(.{
                    .argv = runner_args.items,
                    .environ_map = env_map,
                    .stdin = .pipe,
                    .stderr = .pipe,
                    .stdout = .pipe,
                    .pgid = Process.own_group,
                });

                runner_output = try RunnerOutput.init(io, allocator, &runner.?, status, transpile_dir);
                children.watchRunnerOutput(&runner_output.?);

                const restart_time_ms: u64 = @intCast(start_time.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());

                const total_ms = wall_build_ms + restart_time_ms;
                const total_s: f64 = @as(f64, @floatFromInt(total_ms)) / 1000.0;
                if (rebuilding_shown and is_first_run and report_initial_build_time) {
                    try status.succeed("{s}{s}Built {s}({d:.2}s){s}", .{ Colors.green, Colors.bold, Colors.gray, total_s, Colors.reset });
                }
                status.clear();

                if (!is_first_run) {
                    const printed_since_gap = if (separated_epoch) |epoch|
                        final_output_epoch != epoch
                    else
                        final_output_epoch != rebuild_output_epoch;
                    if (printed_since_gap) try ctx.writer.print("\n", .{});
                    try ctx.writer.print("\n", .{});
                    printAppLogsBanner(if (rebuilding_shown) total_s else null);
                } else if (report_initial_build_time) {
                    try ctx.writer.print("\n", .{});
                }
                _ = runner_output.?.waitForFirstLine(250);
                printFirstLine(&runner_output.?);
                is_first_run = false;

                _ = dev_server.waitUntilInnerReady(5000);
                dev_server.notify(.{ .type = .reload });

                last_exe_fingerprint = exe_fp orelse exeContentFingerprint(io, program_path.?);
                rebuilding_shown = false;
            },
        }
    }
}

/// Hashes the whole file; partial hashing misses small edits in the middle of large binaries.
fn exeContentFingerprint(io: std.Io, path: []const u8) ?u64 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var hasher = std.hash.Wyhash.init(0);
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositional(io, &.{&buf}, offset) catch return null;
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
        if (n < buf.len) break;
    }
    return hasher.final();
}

/// The status line is always drawn by the spinner so it stays pinned below
/// application logs; without `--tui-spinner` it just doesn't animate.
fn startStatus(status: *tui.Spinner, animated: bool, comptime format: []const u8, args: anytype) !void {
    status.updateStyle(if (animated)
        .{ .frames = tui.Spinner.SpinnerStyles.dots2, .refresh_rate_ms = 80 }
    else
        .{ .frames = &.{Colors.cyan ++ "↺ " ++ Colors.reset}, .refresh_rate_ms = 100 });
    try status.start(format, args);
}

/// Print the first captured line (prefer stderr, fallback to stdout)
fn printFirstLine(output: *RunnerOutput) void {
    if (output.consumeFirstLine()) |first_line| {
        if (first_line.len > 0) {
            std.debug.print("{s}\n", .{first_line});
        }
    }
}

pub fn printAppLogsBanner(restart_s: ?f64) void {
    std.debug.print("{s}╭─{s}[{s}App Logs{s}]", .{ Colors.gray, Colors.reset, Colors.purple, Colors.reset });
    if (restart_s) |s| std.debug.print(" {s}↻ {d:.2}s{s}", .{ Colors.gray, s, Colors.reset });
    std.debug.print("\n", .{});
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
