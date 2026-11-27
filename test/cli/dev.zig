const std = @import("std");
const builtin = @import("builtin");
const builder = @import("builder");

const err_sample = @embedFile("ErrorOutput.txt");
const sample_win = @embedFile("Output_Win.txt");
const sample_err_then_fix = @embedFile("ErrorThenFix.txt");
const sample_first = @embedFile("FirstOutput.txt");
const sample_change = @embedFile("ChangeOutput.txt");

const BuildState = builder.BuildState;
const Event = builder.Event;
const StepStatus = builder.StepStatus;
const parseStatusWord = builder.parseStatusWord;
const parseInstallStatus = builder.parseInstallStatus;
const stripTreePrefix = builder.stripTreePrefix;
const stripAnsiInPlace = builder.stripAnsiInPlace;
const DiagKind = builder.DiagKind;
const parseDiagnostic = builder.parseDiagnostic;
const isBuildCommandForOs = builder.isBuildCommandForOs;
const parseDurationMs = builder.parseDurationMs;
const parseUserAssetInstall = builder.parseUserAssetInstall;

fn feedLines(state: *BuildState, input: []const u8, events: *std.ArrayList(Event)) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const prefix = "info(verbose): ";

    while (lines.next()) |line| {
        const has_prefix = std.mem.startsWith(u8, line, prefix);
        const clean = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (has_prefix) {
            if (try state.processLine(clean[prefix.len..])) |event| {
                try events.append(state.allocator, event);
            }
        } else {
            if (try state.processLine(clean)) |event| {
                try events.append(state.allocator, event);
            }
        }
    }
    if (state.flushPending()) |event| {
        try events.append(state.allocator, event);
    }
}

fn freeEvents(allocator: std.mem.Allocator, events: *std.ArrayList(Event)) void {
    for (events.items) |*e| switch (e.*) {
        .errors => |*r| r.deinit(),
        .assets_installed => |*a| a.deinit(),
        else => {},
    };
    events.deinit(allocator);
}

test "parse > status word recognizes success/cached/failure" {
    try std.testing.expectEqual(StepStatus.success, parseStatusWord("success 35s MaxRSS:964M").?);
    try std.testing.expectEqual(StepStatus.cached, parseStatusWord("cached 102ms MaxRSS:32M").?);
    try std.testing.expectEqual(StepStatus.failure, parseStatusWord("1 errors").?);
    try std.testing.expectEqual(StepStatus.failure, parseStatusWord("transitive failure").?);
    try std.testing.expectEqual(@as(?StepStatus, null), parseStatusWord("(reused)"));
}

test "parse > install status server/client lines" {
    try std.testing.expectEqual(StepStatus.success, parseInstallStatus("install server ziex_app success 35s", "server").?);
    try std.testing.expectEqual(StepStatus.cached, parseInstallStatus("install server ziex_app cached 102ms", "server").?);
    try std.testing.expectEqual(StepStatus.success, parseInstallStatus("install client ziex_app success", "client").?);
    try std.testing.expectEqual(@as(?StepStatus, null), parseInstallStatus("install ziex_app success", "server"));
}

test "strip tree prefix handles unicode and ascii trees" {
    try std.testing.expectEqualStrings("install server x success", stripTreePrefix("│  └─ install server x success"));
    try std.testing.expectEqualStrings("install server x success", stripTreePrefix("|  +- install server x success"));
    try std.testing.expectEqualStrings("install x success", stripTreePrefix("├─ install x success"));
}

// test "stripAnsiInPlace removes dim codes" {
//     const out = stripAnsiInPlace("install [2mserver[0m ziex_app success");
//     try std.testing.expectEqualStrings("install server ziex_app success", out);
// }

test "first output > first cycle is success, second is cached" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    try feedLines(&state, sample_first, &events);

    // Cycle 1: should_restart (first build done).
    // Cycle 2: build_complete_no_change (everything cached) - but FirstOutput
    // doesn't terminate cycle 2's tree with a blank line; the stream just ends.
    // We don't require the second event, but the first must be a restart.
    var found_restart = false;
    for (events.items) |e| {
        if (e == .should_restart) {
            found_restart = true;
            break;
        }
    }
    try std.testing.expect(found_restart);
}

test "first output > second cycle is no-change (all cached)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    // Append a trailing blank line so the second tree finalizes.
    const padded = try std.mem.concat(allocator, u8, &.{ sample_first, "\n\n" });
    defer allocator.free(padded);

    try feedLines(&state, padded, &events);

    var restart_count: usize = 0;
    var no_change_count: usize = 0;
    for (events.items) |e| switch (e) {
        .should_restart => restart_count += 1,
        .build_complete_no_change => no_change_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), restart_count);
    try std.testing.expectEqual(@as(usize, 1), no_change_count);
}

test "change output > server+client success triggers should_restart" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    // Trailing blank to finalize the tree.
    const padded = try std.mem.concat(allocator, u8, &.{ sample_change, "\n\n" });
    defer allocator.free(padded);

    try feedLines(&state, padded, &events);

    var found_restart = false;
    var found_no_change = false;
    for (events.items) |e| switch (e) {
        .should_restart => found_restart = true,
        .build_complete_no_change => found_no_change = true,
        else => {},
    };
    try std.testing.expect(found_restart);
    try std.testing.expect(!found_no_change);
}

test "synthetic > all-cached tree emits no_change, not restart" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const input =
        "/usr/bin/zig build-exe -ODebug --name x\n" ++
        "install -C .zig-cache/o/abc/main.wasm /proj/zig-out/static/assets/_/main.wasm\n" ++
        "install -C .zig-cache/o/abc/ziex_app /proj/zig-out/bin/ziex_app\n" ++
        "Build Summary: 32/32 steps succeeded\n" ++
        "install cached\n" ++
        "├─ install ziex_app cached\n" ++
        "│  └─ install server ziex_app cached 102ms MaxRSS:32M\n" ++
        "└─ install client ziex_app cached\n" ++
        "   └─ compile exe main Debug wasm32-freestanding-none cached 80ms\n" ++
        "\n";

    try feedLines(&state, input, &events);

    var found_restart = false;
    var found_no_change = false;
    for (events.items) |e| switch (e) {
        .should_restart => found_restart = true,
        .build_complete_no_change => found_no_change = true,
        else => {},
    };
    try std.testing.expect(!found_restart);
    try std.testing.expect(found_no_change);
}

test "synthetic > server success only (zx edit rebuilds server)" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const input =
        "/usr/bin/zig build-exe -ODebug --name x\n" ++
        "Build Summary: 32/32 steps succeeded\n" ++
        "install success\n" ++
        "├─ install ziex_app success\n" ++
        "│  └─ install server ziex_app success 5s MaxRSS:680M\n" ++
        "└─ install client ziex_app cached\n" ++
        "\n";

    try feedLines(&state, input, &events);

    var found_restart = false;
    for (events.items) |e| if (e == .should_restart) {
        found_restart = true;
    };
    try std.testing.expect(found_restart);
}

test "synthetic > client success only (zx edit rebuilds wasm)" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const input =
        "/usr/bin/zig build-exe -ODebug --name x\n" ++
        "Build Summary: 32/32 steps succeeded\n" ++
        "install success\n" ++
        "├─ install ziex_app success\n" ++
        "│  └─ install server ziex_app cached 102ms\n" ++
        "└─ install client ziex_app success 928ms\n" ++
        "\n";

    try feedLines(&state, input, &events);

    var found_restart = false;
    var found_no_change = false;
    for (events.items) |e| switch (e) {
        .should_restart => found_restart = true,
        .build_complete_no_change => found_no_change = true,
        else => {},
    };
    try std.testing.expect(found_restart);
    try std.testing.expect(!found_no_change);
}

test "synthetic > asset-only change emits assets_installed" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const input =
        "/usr/bin/zig build-exe -ODebug --name x\n" ++
        "install -C /proj/app/assets/style.css /proj/zig-out/static/assets/style.css\n" ++
        "Build Summary: 32/32 steps succeeded\n" ++
        "install success\n" ++
        "├─ install ziex_app cached\n" ++
        "│  └─ install server ziex_app cached 102ms\n" ++
        "│     ├─ install app/assets/ success\n" ++
        "└─ install client ziex_app cached\n" ++
        "\n";

    try feedLines(&state, input, &events);

    var found_assets = false;
    var found_restart = false;
    for (events.items) |e| switch (e) {
        .assets_installed => |a| {
            try std.testing.expect(a.files.len >= 1);
            found_assets = true;
        },
        .should_restart => found_restart = true,
        else => {},
    };
    try std.testing.expect(found_assets);
    try std.testing.expect(!found_restart);
}

test "error build cycle emits errors" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    try feedLines(&state, err_sample, &events);

    var found_errors = false;
    for (events.items) |*e| switch (e.*) {
        .errors => |r| {
            try std.testing.expect(r.diagnostics.len > 0);
            try std.testing.expectEqualStrings("expected ',' after field", r.diagnostics[0].message);
            try std.testing.expectEqual(DiagKind.@"error", r.diagnostics[0].kind);
            found_errors = true;
        },
        else => {},
    };
    try std.testing.expect(found_errors);
}

test "error then fix: error event then later resolved" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    try feedLines(&state, sample_err_then_fix, &events);

    var saw_error = false;
    var saw_restart_or_resolved = false;
    for (events.items) |e| switch (e) {
        .errors => saw_error = true,
        .should_restart, .resolved => saw_restart_or_resolved = true,
        else => {},
    };
    try std.testing.expect(saw_error);
    try std.testing.expect(saw_restart_or_resolved);
}

test "windows watch output detects build start and restart" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.os_tag = .windows;
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    // Pad with a trailing blank line to finalize the tree.
    const padded = try std.mem.concat(allocator, u8, &.{ sample_win, "\n\n" });
    defer allocator.free(padded);

    try feedLines(&state, padded, &events);

    // Output_Win.txt is two cycles glued together with the summary tree of
    // the FIRST cycle showing all-cached, then a new build-exe starts cycle 2.
    var change_count: usize = 0;
    for (events.items) |e| if (e == .change_detected) {
        change_count += 1;
    };
    try std.testing.expect(change_count >= 1);
}

test "summary tree without blank line still emits change_detected" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.os_tag = .windows;
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const input =
        \\Build Summary: 2/2 steps succeeded
        \\+- install server app success
        \\"C:\\zig\\zig.exe" build-exe -ODebug --name app
        \\Build Summary: 2/2 steps succeeded
        \\+- install server app success
        \\
        \\
    ;
    try feedLines(&state, input, &events);
    while (state.takePending()) |event| {
        try events.append(allocator, event);
    }

    var saw_change = false;
    var saw_restart = false;
    for (events.items) |e| switch (e) {
        .change_detected => saw_change = true,
        .should_restart => saw_restart = true,
        else => {},
    };
    try std.testing.expect(saw_change);
    try std.testing.expect(saw_restart);
}

test "parse > diagnostic errors" {
    const allocator = std.testing.allocator;
    const diag = parseDiagnostic(allocator, ".zig-cache/app/pages/page.zig:95:12: error: expected ',' after field").?;
    defer allocator.free(diag.file);
    defer allocator.free(diag.message);
    try std.testing.expectEqualStrings(".zig-cache/app/pages/page.zig", diag.file);
    try std.testing.expectEqual(@as(u32, 95), diag.line);
    try std.testing.expectEqual(@as(u32, 12), diag.col);
}

test "is build cmd handles windows zig path and rejects other tools" {
    try std.testing.expect(isBuildCommandForOs(.windows, "\"C:\\\\Users\\\\x\\\\zig.exe\" build-exe -ODebug"));
    try std.testing.expect(isBuildCommandForOs(.macos, "/Users/x/.asdf/installs/zig/0.17.0/zig build-lib -ODebug"));
    try std.testing.expect(!isBuildCommandForOs(.windows, "install -C foo bar"));
    try std.testing.expect(isBuildCommandForOs(
        .windows,
        "ZIEX_INNER_PORT=1 ZIEX_OUTER_PORT=2 \"C:\\\\zig\\\\zig.exe\" build-exe -ODebug --name app",
    ));
}

test "verbose env-prefixed transpile announces rebuild" {
    const allocator = std.testing.allocator;
    var state = BuildState.init(allocator);
    state.os_tag = .windows;
    state.first_build_done = true;
    defer state.deinit();

    var events = std.ArrayList(Event).empty;
    defer freeEvents(allocator, &events);

    const line =
        \\ZIEX_INNER_PORT=49822 ZIEX_OUTER_PORT=3000 ".\.zig-cache\o\abc\zx.exe" transpile ".\app" --outdir ".\.zig-cache\tnsn"
    ;
    if (try state.processLine(line)) |event| {
        try events.append(allocator, event);
    }
    while (state.takePending()) |event| {
        try events.append(allocator, event);
    }
    try std.testing.expect(events.items.len >= 1);
    try std.testing.expect(events.items[0] == .change_detected);
}

test "parse > duration ms handles common units" {
    try std.testing.expectEqual(@as(?u64, 23), parseDurationMs("23ms"));
    try std.testing.expectEqual(@as(?u64, 1500), parseDurationMs("1.5s"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("cached"));
}

test "parse > user asset install extracts web path" {
    const a = parseUserAssetInstall("install -C /proj/app/public/favicon.ico /proj/zig-out/static/favicon.ico").?;
    try std.testing.expectEqualStrings("favicon.ico", a.web_path);
    try std.testing.expect(parseUserAssetInstall("install -C .zig-cache/o/abc/main.wasm /proj/zig-out/static/assets/_/main.wasm") == null);
}

const Process = builder.Process;

fn spawnSleeper(io: std.Io) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "sleep 60; true" },
        .pgid = Process.own_group,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn expectGroupGone(pgid: std.posix.pid_t) !void {
    var waited: u32 = 0;
    while (waited < 1000) : (waited += 10) {
        if (std.posix.errno(std.posix.system.kill(-pgid, @fromBackingInt(0))) == .SRCH) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "process > stop" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try spawnSleeper(io);
    const pgid = child.id.?;
    Process.stop(&child, io, 2000);

    try std.testing.expect(child.id == null);
    try expectGroupGone(pgid);
}

test "process > waitOrKill escalates" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; sleep 60; true" },
        .pgid = Process.own_group,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pgid = child.id.?;
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    const start = std.Io.Timestamp.now(io, .awake);
    Process.stop(&child, io, 200);
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    try std.testing.expect(child.id == null);
    try std.testing.expect(elapsed >= 150 and elapsed < 2000);
    try expectGroupGone(pgid);
}

test "process > killTree" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try spawnSleeper(io);
    const pgid = child.id.?;
    Process.killTree(pgid);
    const term = try child.wait(io);

    try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, term);
    try expectGroupGone(pgid);
}

const LeakReport = builder.LeakReport;

const leak_sample =
    \\error(SafeAllocator): leaked [addr: 10a4803f0, len: 16 (0x10) align: 1] allocated at: 
    \\.zig-cache/ziex/tnsn/pages/page.zig:19:27: 0x104fa170b in Page (ziex_app)
    \\    _ = zx.allocator.alloc(u8, 16) catch {};
    \\                          ^
    \\/proj/../../src/runtime/server/Server.zig:580:82: 0x104fa3b7b in wrapper (ziex_app)
    \\                    if (R == Component) return pageFn(ctx) else return try pageFn(ctx);
    \\                                                                                 ^
    \\???:?:?: 0x195c91cff in __pthread_exit (/usr/lib/system/libsystem_pthread.dylib)
    \\???:?:?: 0x195c8cceb in _pthread_cond_broadcast (/usr/lib/system/libsystem_pthread.dylib)
    \\error(SafeAllocator): leaked [addr: 10a480400, len: 16 (0x10) align: 1] allocated at: 
    \\C:\proj\app\main.zig:7:5: 0x1400 in main (ziex_app.exe)
    \\
    \\info: after the report
;

test "leak report > parse" {
    var report = LeakReport.init(std.testing.allocator);
    defer report.deinit();

    var passed = std.ArrayList([]const u8).empty;
    defer passed.deinit(std.testing.allocator);
    var lines = std.mem.splitScalar(u8, leak_sample, '\n');
    while (lines.next()) |line| {
        if (try report.feed(line) == .pass) try passed.append(std.testing.allocator, line);
    }

    try std.testing.expectEqual(@as(usize, 1), passed.items.len);
    try std.testing.expectEqualStrings("info: after the report", passed.items[0]);
    try std.testing.expectEqual(@as(usize, 2), report.leaks.items.len);

    const first = report.leaks.items[0].frames.items;
    try std.testing.expectEqual(@as(usize, 4), first.len);
    try std.testing.expectEqualStrings(".zig-cache/ziex/tnsn/pages/page.zig", first[0].file);
    try std.testing.expectEqual(@as(u32, 19), first[0].line);
    try std.testing.expectEqual(@as(u32, 27), first[0].col);
    try std.testing.expectEqualStrings("Page", first[0].function);
    try std.testing.expectEqualStrings("", first[2].file);
    try std.testing.expectEqual(@as(u32, 0), first[2].line);

    const second = report.leaks.items[1].frames.items;
    try std.testing.expectEqualStrings("C:\\proj\\app\\main.zig", second[0].file);
    try std.testing.expectEqual(@as(u32, 7), second[0].line);
}

test "leak report > passthrough" {
    var report = LeakReport.init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expectEqual(LeakReport.Feed.pass, try report.feed("info: GET / 200"));
    try std.testing.expectEqual(LeakReport.Feed.pass, try report.feed("src/x.zig:1:2: 0x10 in foo (app)"));
    try std.testing.expectEqual(@as(usize, 0), report.leaks.items.len);
}

test "leak report > ansi" {
    var report = LeakReport.init(std.testing.allocator);
    defer report.deinit();

    const colored = [_][]const u8{
        "\x1b[31m\x1b[1merror\x1b[0m\x1b[2m\x1b[1m(SafeAllocator): \x1b[0mleaked [addr: 109620180, len: 16 (0x10) align: 1] allocated at: ",
        "\x1b[1m/proj/src/x.zig:353:43\x1b[0m: \x1b[2m0x1046ae68b in attrs__func_1608 (ziex_app)\x1b[0m",
        "            const result = allocator.alloc(Element.Attribute, count) catch @panic(\"OOM\");",
        "\x1b[32m                                          ^\x1b[0m",
    };
    for (colored) |line| try std.testing.expectEqual(LeakReport.Feed.consumed, try report.feed(line));

    const frame = report.leaks.items[0].frames.items[0];
    try std.testing.expectEqualStrings("/proj/src/x.zig", frame.file);
    try std.testing.expectEqual(@as(u32, 353), frame.line);
    try std.testing.expectEqualStrings("attrs__func_1608", frame.function);
}

test "leak report > no stack trace" {
    var report = LeakReport.init(std.testing.allocator);
    defer report.deinit();

    try std.testing.expectEqual(LeakReport.Feed.consumed, try report.feed("error(SafeAllocator): leaked [addr: 7f0000001000, len: 16 (0x10) align: 1] allocated at "));
    try std.testing.expectEqual(LeakReport.Feed.consumed, try report.feed("error(SafeAllocator): leaked [addr: 7f0000002000, len: 16 (0x10) align: 1] allocated at "));
    try std.testing.expectEqual(LeakReport.Feed.pass, try report.feed("info: next"));

    try std.testing.expectEqual(@as(usize, 2), report.leaks.items.len);
    try std.testing.expectEqual(@as(usize, 0), report.leaks.items[0].frames.items.len);
}
