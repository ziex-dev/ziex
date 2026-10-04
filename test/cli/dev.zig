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

test "parseStatusWord recognizes success/cached/failure" {
    try std.testing.expectEqual(StepStatus.success, parseStatusWord("success 35s MaxRSS:964M").?);
    try std.testing.expectEqual(StepStatus.cached, parseStatusWord("cached 102ms MaxRSS:32M").?);
    try std.testing.expectEqual(StepStatus.failure, parseStatusWord("1 errors").?);
    try std.testing.expectEqual(StepStatus.failure, parseStatusWord("transitive failure").?);
    try std.testing.expectEqual(@as(?StepStatus, null), parseStatusWord("(reused)"));
}

test "parseInstallStatus parses server/client lines" {
    try std.testing.expectEqual(StepStatus.success, parseInstallStatus("install server ziex_app success 35s", "server").?);
    try std.testing.expectEqual(StepStatus.cached, parseInstallStatus("install server ziex_app cached 102ms", "server").?);
    try std.testing.expectEqual(StepStatus.success, parseInstallStatus("install client ziex_app success", "client").?);
    try std.testing.expectEqual(@as(?StepStatus, null), parseInstallStatus("install ziex_app success", "server"));
}

test "stripTreePrefix handles unicode and ascii trees" {
    try std.testing.expectEqualStrings("install server x success", stripTreePrefix("│  └─ install server x success"));
    try std.testing.expectEqualStrings("install server x success", stripTreePrefix("|  +- install server x success"));
    try std.testing.expectEqualStrings("install x success", stripTreePrefix("├─ install x success"));
}

// test "stripAnsiInPlace removes dim codes" {
//     const out = stripAnsiInPlace("install [2mserver[0m ziex_app success");
//     try std.testing.expectEqualStrings("install server ziex_app success", out);
// }

test "FirstOutput.txt: first cycle is success, second is cached" {
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

test "FirstOutput.txt: second cycle is no-change (all cached)" {
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

test "ChangeOutput.txt: server+client success triggers should_restart" {
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

test "synthetic: all-cached tree emits no_change, not restart" {
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

test "synthetic: server success only (zx edit rebuilds server)" {
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

test "synthetic: client success only (zx edit rebuilds wasm)" {
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

test "synthetic: asset-only change emits assets_installed" {
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

test "parseDiagnostic - errors" {
    const allocator = std.testing.allocator;
    const diag = parseDiagnostic(allocator, ".zig-cache/app/pages/page.zig:95:12: error: expected ',' after field").?;
    defer allocator.free(diag.file);
    defer allocator.free(diag.message);
    try std.testing.expectEqualStrings(".zig-cache/app/pages/page.zig", diag.file);
    try std.testing.expectEqual(@as(u32, 95), diag.line);
    try std.testing.expectEqual(@as(u32, 12), diag.col);
}

test "isBuildCommand handles windows zig path and rejects other tools" {
    try std.testing.expect(isBuildCommandForOs(.windows, "\"C:\\\\Users\\\\x\\\\zig.exe\" build-exe -ODebug"));
    try std.testing.expect(isBuildCommandForOs(.macos, "/Users/x/.asdf/installs/zig/0.17.0/zig build-lib -ODebug"));
    try std.testing.expect(!isBuildCommandForOs(.windows, "install -C foo bar"));
}

test "parseDurationMs handles common units" {
    try std.testing.expectEqual(@as(?u64, 23), parseDurationMs("23ms"));
    try std.testing.expectEqual(@as(?u64, 1500), parseDurationMs("1.5s"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("cached"));
}

test "parseUserAssetInstall extracts web path" {
    const a = parseUserAssetInstall("install -C /proj/app/public/favicon.ico /proj/zig-out/static/favicon.ico").?;
    try std.testing.expectEqualStrings("favicon.ico", a.web_path);
    try std.testing.expect(parseUserAssetInstall("install -C .zig-cache/o/abc/main.wasm /proj/zig-out/static/assets/_/main.wasm") == null);
}
