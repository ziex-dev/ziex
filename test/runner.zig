// This is for the Zig 0.15.
// See https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b/1f317ebc9cd09bc50fd5591d09c34255e15d1d85
// for a version that workson Zig 0.14.1.

// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
// });

const std = @import("std");
const builtin = @import("builtin");

pub const std_options = std.Options{
    .log_level = .warn, // Suppress debug and info logs
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .zx_transpiler, .level = .warn }, // Only show warnings and errors for zx_transpiler
        .{ .scope = .auth, .level = .err }, // Refused sign-ins are expected in auth tests
    },
};

const Allocator = std.mem.Allocator;

const BORDER: [80]u8 = @splat('=');

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = std.testing.io;

    if (comptime builtin.os.tag == .windows) {
        _ = SetConsoleOutputCP(65001);
    }

    const env = Env.init(allocator, init.minimal.environ);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, io, 15);
    defer slowest.deinit(allocator);
    var failures = FailureTracker.init();
    defer failures.deinit(allocator);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var todo: usize = 0;
    var leak: usize = 0;
    var header_printed: bool = false;
    var total_ns: u64 = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }
        if (is_unnamed_test) continue;

        var scope_name: []const u8 = "";
        const friendly_name = blk: {
            const name = t.name;

            var segments: [16][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test") or std.mem.eql(u8, value, "decltest")) {
                    const path = if (count > 1) segments[1..count] else segments[0..count];
                    scope_name = try std.mem.join(allocator, " > ", path);
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
                if (count < segments.len) {
                    segments[count] = value;
                    count += 1;
                }
            }
            break :blk name;
        };

        // Check if this is a flaky test (name starts with "flaky:")
        const is_flaky_test = isFlaky(friendly_name);
        const max_attempts: u32 = if (is_flaky_test) env.flaky_retries else 1;
        var attempt: u32 = 0;
        var final_result: anyerror!void = {};
        var final_ns_taken: u64 = 0;

        while (attempt < max_attempts) : (attempt += 1) {
            current_test = friendly_name;
            std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
            std.testing.io_instance = .init(std.testing.allocator, .{
                .argv0 = .init(init.minimal.args),
                .environ = init.minimal.environ,
            });
            final_result = t.func();
            std.testing.io_instance.deinit();
            current_test = null;

            final_ns_taken = slowest.endTiming(allocator, scope_name, friendly_name);

            if (std.testing.allocator_instance.deinit() != 0) {
                leak += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
            }

            // If test passed or it's a skip/todo, don't retry
            if (final_result) |_| {
                break;
            } else |err| {
                if (err == error.SkipZigTest or err == error.Todo) {
                    break;
                }
                // For flaky tests, retry on failure
                if (is_flaky_test and attempt + 1 < max_attempts) {
                    slowest.startTiming();
                    continue;
                }
            }
            break;
        }

        total_ns += final_ns_taken;
        const retried = is_flaky_test and attempt > 0;

        if (final_result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            error.Todo => {
                todo += 1;
                status = .todo;
            },
            else => {
                status = .fail;
                fail += 1;
                failures.add(allocator, scope_name, friendly_name, err, if (retried) attempt else 0);
                if (retried) {
                    Printer.status(.fail, "\n{s}\n\"{s}\" - {s} (after {d} retries)\n{s}\n", .{ BORDER, friendly_name, @errorName(err), attempt, BORDER });
                } else {
                    Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                }
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        const ns_taken = final_ns_taken;

        if (env.verbose) {
            if (!header_printed) {
                Printer.fmt("\x1b[1mRunning:\x1b[0m \n", .{});
                header_printed = true;
            }
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;

            const checkmark = switch (status) {
                .pass => "✓",
                .fail => "✗",
                .skip => "⚠",
                .todo => "○",
                else => " ",
            };
            Printer.status(status, "{s}", .{checkmark});
            Printer.fmt(" ", .{});
            Printer.name(scope_name);
            Printer.name(" > ");
            Printer.name(friendly_name);
            Printer.fmt(" ", .{});
            Printer.fmt("\x1b[90m[{d:.2}ms]", .{ms});
            if (retried) {
                Printer.fmt(" \x1b[33m⟳{d}\x1b[90m", .{attempt + 1});
            }
            Printer.fmt("\x1b[0m\n", .{});
        } else {
            Printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail + skip + todo;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const avg_ms = if (total_tests > 0) total_ms / @as(f64, @floatFromInt(total_tests)) else 0.0;

    Printer.fmt("\n", .{});
    Printer.status(.pass, "{d:<3} pass\n", .{pass});
    if (fail > 0) {
        Printer.status(.fail, "{d:<3} fail\n", .{fail});
    } else {
        Printer.fmt("{d:<3} fail\n", .{fail});
    }
    if (skip > 0) {
        Printer.status(.skip, "{d:<3} skipped\n", .{skip});
    }
    if (todo > 0) {
        Printer.status(.todo, "{d:<3} todo\n", .{todo});
    }
    if (leak > 0) {
        Printer.status(.fail, "{d:<3} leaked\n", .{leak});
    }
    if (total_tests > 0) {
        Printer.fmt("\x1b[90m{d} test{s} | {d:.2}ms total | {d:.2}ms avg\x1b[0m\n", .{ total_tests, if (total_tests != 1) "s" else "", total_ms, avg_ms });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    failures.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn name(test_name: []const u8) void {
        var start: usize = 0;
        var i: usize = 0;
        while (i + 3 <= test_name.len) {
            const sep = test_name[i..][0..3];
            if (std.mem.eql(u8, sep, " > ") or std.mem.eql(u8, sep, " | ")) {
                std.debug.print("{s} \x1b[90m{c}\x1b[0m ", .{ test_name[start..i], sep[1] });
                i += 3;
                start = i;
            } else i += 1;
        }
        std.debug.print("{s}", .{test_name[start..]});
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            .todo => std.debug.print("\x1b[36m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    todo,
    text,
};

const FailureTracker = struct {
    failures: std.ArrayList(FailureInfo),

    const FailureInfo = struct {
        scope: []const u8,
        name: []const u8,
        err: anyerror,
        retries: u32,
    };

    fn init() FailureTracker {
        return .{ .failures = .empty };
    }

    fn deinit(self: *FailureTracker, allocator: Allocator) void {
        self.failures.deinit(allocator);
    }

    fn add(
        self: *FailureTracker,
        allocator: Allocator,
        scope: []const u8,
        name: []const u8,
        err: anyerror,
        retries: u32,
    ) void {
        self.failures.append(allocator, .{
            .scope = scope,
            .name = name,
            .err = err,
            .retries = retries,
        }) catch @panic("failed to track failing test");
    }

    fn display(self: *const FailureTracker) void {
        if (self.failures.items.len == 0) return;

        Printer.fmt("\n\x1b[1mFailed\x1b[0m \x1b[90m({d})\x1b[0m:\n", .{self.failures.items.len});
        for (self.failures.items) |failure| {
            Printer.status(.fail, "  ✗ ", .{});
            if (failure.scope.len > 0) {
                Printer.fmt("{s} > {s}", .{ failure.scope, failure.name });
            } else {
                Printer.fmt("{s}", .{failure.name});
            }
            Printer.fmt(" \x1b[90m({s}", .{@errorName(failure.err)});
            if (failure.retries > 0) {
                Printer.fmt(", after {d} retries", .{failure.retries});
            }
            Printer.fmt(")\x1b[0m\n", .{});
        }
    }
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    io: std.Io,
    start_ts: std.Io.Timestamp,

    fn init(allocator: Allocator, io: std.Io, count: u32) SlowTracker {
        var slowest = SlowestQueue.empty;
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .io = io,
            .start_ts = .zero,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        scope: []const u8,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: Allocator) void {
        var slowest = &self.slowest;
        slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.start_ts = std.Io.Timestamp.now(self.io, .awake);
    }

    fn endTiming(self: *SlowTracker, allocator: Allocator, scope_name: []const u8, test_name: []const u8) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const ns: u64 = @intCast(now.nanoseconds -| self.start_ts.nanoseconds);

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(allocator, TestInfo{ .ns = ns, .scope = scope_name, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(allocator, TestInfo{ .ns = ns, .scope = scope_name, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("\x1b[1mSlowest\x1b[0m \x1b[90m({d})\x1b[0m:\n", .{count});
        while (slowest.popMax()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            if (info.scope.len > 0) {
                Printer.fmt("  {d:.2}ms\t\x1b[90m{s} > {s}\x1b[0m\n", .{ ms, info.scope, info.name });
            } else {
                Printer.fmt("  {d:.2}ms\t\x1b[90m{s}\x1b[0m\n", .{ ms, info.name });
            }
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,
    flaky_retries: u32,
    environ: std.process.Environ,

    fn init(allocator: Allocator, environ: std.process.Environ) Env {
        std.testing.environ = environ;

        return .{
            .verbose = readEnvBool(environ, allocator, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(environ, allocator, "TEST_FAIL_FIRST", false),
            .filter = readEnv(environ, allocator, "TEST_FILTER"),
            .flaky_retries = readEnvInt(environ, allocator, "TEST_FLAKY_RETRIES", 3),
            .environ = environ,
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(environ: std.process.Environ, allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = environ.getAlloc(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableMissing) return null;
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(environ: std.process.Environ, allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(environ, allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }

    fn readEnvInt(environ: std.process.Environ, allocator: Allocator, key: []const u8, deflt: u32) u32 {
        const value = readEnv(environ, allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.fmt.parseInt(u32, value, 10) catch deflt;
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

fn isFlaky(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "flaky:");
}

extern "kernel32" fn SetConsoleOutputCP(wCodePageID: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
