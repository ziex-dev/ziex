const RunnerOutput = @This();

const std = @import("std");
const Spinner = @import("../../tui/Spinner.zig");
const Builder = @import("Builder.zig");
const Diagnostics = @import("Diagnostics.zig");
const LeakReport = @import("LeakReport.zig");
const Colors = @import("../../tui/main.zig").Colors;

const Io = std.Io;

state: *State,
thread: std.Thread,

const max_held_partial_line = 4096;

const State = struct {
    io: Io,
    allocator: std.mem.Allocator,
    stdout: Io.File,
    stderr: Io.File,
    spinner: ?*Spinner,
    mutex: Io.Mutex = .init,
    first_line: ?[]u8 = null,
    first_line_captured: std.atomic.Value(bool) = .init(false),
    main_done_waiting: bool = false,
    main_claimed_first_line: bool = false,
    first_line_forwarded: bool = false,
    output_epoch: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    leaks: LeakReport,
    transpile_dir: []const u8,
    cwd: [:0]u8,
};

pub fn init(
    io: Io,
    allocator: std.mem.Allocator,
    child: *const std.process.Child,
    spinner: ?*Spinner,
    transpile_dir: []const u8,
) !RunnerOutput {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    errdefer allocator.free(cwd);
    state.* = .{
        .io = io,
        .allocator = allocator,
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
        .spinner = spinner,
        .leaks = .init(allocator),
        .transpile_dir = transpile_dir,
        .cwd = cwd,
    };
    return .{
        .state = state,
        .thread = try std.Thread.spawn(.{}, run, .{state}),
    };
}

pub fn waitForFirstLine(self: *const RunnerOutput, timeout_ms: u64) bool {
    var elapsed_ms: u64 = 0;
    while (!self.state.first_line_captured.load(.acquire) and
        !self.state.done.load(.acquire) and
        elapsed_ms < timeout_ms)
    {
        self.state.io.sleep(.fromMilliseconds(1), .awake) catch {};
        elapsed_ms += 1;
    }

    const captured = self.state.first_line_captured.load(.acquire);
    self.state.mutex.lockUncancelable(self.state.io);
    self.state.main_done_waiting = true;
    self.state.main_claimed_first_line = captured;
    self.state.mutex.unlock(self.state.io);
    return captured;
}

pub fn consumeFirstLine(self: *RunnerOutput) ?[]const u8 {
    self.state.mutex.lockUncancelable(self.state.io);
    defer self.state.mutex.unlock(self.state.io);
    if (!self.state.main_claimed_first_line or self.state.first_line_forwarded) return null;
    self.state.first_line_forwarded = true;
    return self.state.first_line;
}

/// Valid until `finish`/`deinit`.
pub fn doneFlag(self: *const RunnerOutput) *const std.atomic.Value(bool) {
    return &self.state.done;
}

pub fn outputEpoch(self: *const RunnerOutput) usize {
    return self.state.output_epoch.load(.acquire);
}

pub fn deinit(self: *RunnerOutput) void {
    _ = self.finish();
}

pub fn finish(self: *RunnerOutput) usize {
    self.thread.join();
    const epoch = self.outputEpoch();
    if (self.state.first_line) |line| self.state.allocator.free(line);
    self.state.leaks.deinit();
    self.state.allocator.free(self.state.cwd);
    self.state.allocator.destroy(self.state);
    self.* = undefined;
    return epoch;
}

fn run(state: *State) void {
    defer state.done.store(true, .release);

    var streams_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(
        state.allocator,
        state.io,
        streams_buffer.toStreams(),
        &.{ state.stderr, state.stdout },
    );
    defer multi_reader.deinit();

    const stderr = multi_reader.reader(0);
    const stdout = multi_reader.reader(1);

    while (true) {
        drainStdout(state, stdout, false);
        drainStderr(state, stderr, false);
        multi_reader.fill(1, .none) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.debug("runner output read failed: {any}", .{err});
                break;
            },
        };
    }

    drainStdout(state, stdout, true);
    drainStderr(state, stderr, true);
    multi_reader.checkAnyError() catch |err| {
        if (err != error.Canceled) std.log.debug("runner output stream failed: {any}", .{err});
    };
}

fn forward(state: *State, file: Io.File, bytes: []const u8) void {
    if (state.spinner) |spinner| {
        spinner.writeAbove(state.io, file, bytes);
    } else {
        file.writeStreamingAll(state.io, bytes) catch {};
    }
}

fn forwardableLen(state: *const State, bytes: []const u8, final: bool) usize {
    const spinner = state.spinner orelse return bytes.len;
    if (final or !spinner.isSpinning() or bytes.len >= max_held_partial_line) return bytes.len;
    return if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |i| i + 1 else 0;
}

fn drainBuffered(state: *State, reader: *Io.Reader, file: Io.File, final: bool) void {
    const bytes = reader.buffered();
    const len = forwardableLen(state, bytes, final);
    if (len == 0) return;
    _ = state.output_epoch.fetchAdd(1, .release);
    forward(state, file, bytes[0..len]);
    reader.toss(len);
}

fn drainStdout(state: *State, reader: *Io.Reader, final: bool) void {
    drainBuffered(state, reader, Io.File.stdout(), final);
}

fn drainStderr(state: *State, reader: *Io.Reader, final: bool) void {
    if (!state.first_line_captured.load(.acquire)) {
        const bytes = reader.buffered();
        const newline = std.mem.indexOfScalar(u8, bytes, '\n');
        if (newline == null and !final) return;
        if (newline == null and bytes.len == 0) return;

        const consumed_len = if (newline) |index| index + 1 else bytes.len;
        var line = bytes[0 .. consumed_len - @intFromBool(newline != null)];
        if (line.len > 0 and line[line.len - 1] == '\r') line.len -= 1;
        const owned = state.allocator.dupe(u8, line) catch return;
        reader.toss(consumed_len);

        state.mutex.lockUncancelable(state.io);
        state.first_line = owned;
        state.first_line_captured.store(true, .release);
        state.mutex.unlock(state.io);

        while (true) {
            state.mutex.lockUncancelable(state.io);
            const done_waiting = state.main_done_waiting;
            if (done_waiting and !state.main_claimed_first_line and !state.first_line_forwarded) {
                _ = state.output_epoch.fetchAdd(1, .release);
                if (state.allocator.print("{s}\n", .{owned})) |line_nl| {
                    defer state.allocator.free(line_nl);
                    forward(state, Io.File.stderr(), line_nl);
                } else |_| {}
                state.first_line_forwarded = true;
            }
            state.mutex.unlock(state.io);
            if (done_waiting) break;
            state.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    drainStderrLines(state, reader, final);
}

fn drainStderrLines(state: *State, reader: *Io.Reader, final: bool) void {
    const allocator = state.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const bytes = reader.buffered();
    const complete = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |i| i + 1 else 0;
    var lines = std.mem.splitScalar(u8, bytes[0..complete -| 1], '\n');
    if (complete > 0) while (lines.next()) |line| {
        switch (state.leaks.feed(line) catch .pass) {
            .consumed => {},
            .pass => {
                appendLeakSummary(state, &out);
                out.appendSlice(allocator, line) catch {};
                out.append(allocator, '\n') catch {};
            },
        }
    };
    reader.toss(complete);

    if (final) appendLeakSummary(state, &out);

    // Line-buffered: a report's first line can arrive in pieces.
    const tail = reader.buffered();
    const tail_len = if (final or tail.len >= max_held_partial_line) tail.len else 0;
    out.appendSlice(allocator, tail[0..tail_len]) catch {};
    reader.toss(tail_len);

    if (out.items.len == 0) return;
    _ = state.output_epoch.fetchAdd(1, .release);
    forward(state, Io.File.stderr(), out.items);
}

fn appendLeakSummary(state: *State, out: *std.ArrayList(u8)) void {
    defer state.leaks.clear();
    if (state.leaks.leaks.items.len == 0) return;
    const allocator = state.allocator;

    // One entry per function, else a leaked tree prints one per element.
    const Group = struct {
        file: []u8,
        function: []const u8,
        line: u32,
        col: u32,
        count: u32 = 0,
        places: std.ArrayList(u64) = .empty,
    };
    var groups = std.ArrayList(Group).empty;
    defer {
        for (groups.items) |*g| {
            allocator.free(g.file);
            g.places.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    // Leaks without debug info (e.g. a stripped build) have no location.
    var unlocated: u32 = 0;
    for (state.leaks.leaks.items) |leak| {
        const loc = leakLocation(state, leak.frames.items) orelse {
            unlocated += 1;
            continue;
        };
        const group = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.file, loc.file) and std.mem.eql(u8, g.function, loc.function)) {
                allocator.free(loc.file);
                break g;
            }
        } else blk: {
            groups.append(allocator, .{ .file = loc.file, .function = loc.function, .line = loc.line, .col = loc.col }) catch {
                allocator.free(loc.file);
                continue;
            };
            break :blk &groups.items[groups.items.len - 1];
        };
        group.count += 1;
        if (loc.line < group.line or (loc.line == group.line and loc.col < group.col)) {
            group.line = loc.line;
            group.col = loc.col;
        }
        const place = @as(u64, loc.line) << 32 | loc.col;
        if (std.mem.indexOfScalar(u64, group.places.items, place) == null) group.places.append(allocator, place) catch {};
    }

    // Same locations as last time (counts vary with traffic): one-line reminder.
    var signature: u64 = 0;
    for (groups.items) |g| {
        var h = std.hash.Wyhash.init(0);
        h.update(g.file);
        h.update(g.function);
        h.update(std.mem.asBytes(&[2]u32{ g.line, g.col }));
        signature +%= h.final();
    }
    if (unlocated > 0) signature +%= 1;
    if (signature == last_leak_signature) {
        for (groups.items) |g| {
            const line = allocator.print("   {s}memory leak in `{s}` unchanged ({s}:{d}:{d}){s}\n", .{ Colors.gray, g.function, g.file, g.line, g.col, Colors.reset }) catch continue;
            defer allocator.free(line);
            out.appendSlice(allocator, line) catch {};
        }
        if (unlocated > 0) out.appendSlice(allocator, "   " ++ Colors.gray ++ "memory leak unchanged (no stack trace)" ++ Colors.reset ++ "\n") catch {};
        return;
    }
    last_leak_signature = signature;

    var diagnostics = std.ArrayList(Builder.Diagnostic).empty;
    defer {
        for (diagnostics.items) |d| allocator.free(d.message);
        diagnostics.deinit(allocator);
    }
    for (groups.items) |g| {
        const message = if (g.places.items.len > 1)
            allocator.print("memory leak in `{s}` ({d} allocations at {d} places, first shown)", .{ g.function, g.count, g.places.items.len })
        else if (g.count > 1)
            allocator.print("memory leak in `{s}` ({d}×)", .{ g.function, g.count })
        else
            allocator.print("memory leak in `{s}`", .{g.function});
        diagnostics.append(allocator, .{
            .file = g.file,
            .line = g.line,
            .col = g.col,
            .kind = .@"error",
            .message = message catch continue,
        }) catch {};
    }

    const formatted = Diagnostics.formatOxlint(allocator, diagnostics.items) catch return;
    defer allocator.free(formatted);
    out.appendSlice(allocator, formatted) catch {};

    if (unlocated > 0) {
        const line = allocator.print("   {s}{s}error{s}: memory leak ({d}×, no stack trace)\n\n", .{ Colors.red, Colors.bold, Colors.reset, unlocated }) catch return;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch {};
    }
}

/// Outlives each `RunnerOutput` so restarts can be compared.
var last_leak_signature: u64 = 0;

const LeakLocation = struct { file: []u8, line: u32, col: u32, function: []const u8 };

/// First frame in user code (a `.zx` page or project file), else the innermost known.
fn leakLocation(state: *State, frames: []const LeakReport.Frame) ?LeakLocation {
    const allocator = state.allocator;
    for (frames) |f| {
        if (f.line == 0) continue;
        if (Diagnostics.remapLocation(allocator, f.file, f.line, f.col, .{ .transpile_dir = state.transpile_dir }) catch null) |m| {
            const rel = projectPath(state, m.file, false) orelse return .{ .file = m.file, .line = m.line, .col = m.col, .function = f.function };
            allocator.free(m.file);
            return .{ .file = rel, .line = m.line, .col = m.col, .function = f.function };
        }
        if (projectPath(state, f.file, true)) |rel| return .{ .file = rel, .line = f.line, .col = f.col, .function = f.function };
    }
    for (frames) |f| {
        if (f.line == 0) continue;
        const file = allocator.dupe(u8, f.file) catch return null;
        return .{ .file = file, .line = f.line, .col = f.col, .function = f.function };
    }
    return null;
}

fn projectPath(state: *State, file: []const u8, user_only: bool) ?[]u8 {
    const allocator = state.allocator;
    const abs = std.fs.path.resolve(allocator, &.{ state.cwd, file }) catch return null;
    defer allocator.free(abs);
    if (abs.len <= state.cwd.len or !std.mem.startsWith(u8, abs, state.cwd) or !std.fs.path.isSep(abs[state.cwd.len])) return null;
    const rel = abs[state.cwd.len + 1 ..];
    if (user_only and (std.mem.startsWith(u8, rel, "zig-pkg") or std.mem.startsWith(u8, rel, ".zig-cache"))) return null;
    return allocator.dupe(u8, rel) catch null;
}
