// `zig build test`: one run over every test binary, `all <test binary>...`.
//
// Zig runs only a test build's root-module tests, so build.zig makes one test binary per
// module (all with test/runner.zig). Each runs with `--report`: it lists its tests as they
// run and reports them on stdout, and this prints one summary for all of them.
const std = @import("std");

const slowest_count = 15;

const Test = struct {
    status: []const u8,
    ns: u64,
    scope: []const u8,
    name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const binaries = (try init.minimal.args.toSlice(arena))[1..];

    var tests: std.ArrayList(Test) = .empty;
    var failed: std.ArrayList(Test) = .empty;
    var counts: struct { pass: usize = 0, fail: usize = 0, skip: usize = 0, todo: usize = 0, leak: usize = 0, crashed: usize = 0 } = .{};

    std.debug.print("\r\x1b[0K\x1b[1mRunning:\x1b[0m\n", .{});
    for (binaries) |bin| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ bin, "--report", try std.fmt.allocPrint(arena, "--scope={s}", .{std.fs.path.stem(bin)}) },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        const out = try reader.interface.allocRemaining(arena, .unlimited);
        const term = try child.wait(io);

        var finished = false;
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            const status = fields.next() orelse continue;
            const n = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
            if (std.mem.eql(u8, status, "leak")) {
                counts.leak += n;
                finished = true;
                continue;
            }
            const t: Test = .{ .status = status, .ns = n, .scope = fields.next() orelse "", .name = fields.rest() };
            try tests.append(arena, t);
            if (std.mem.eql(u8, status, "pass")) {
                counts.pass += 1;
            } else if (std.mem.eql(u8, status, "fail")) {
                counts.fail += 1;
                try failed.append(arena, t);
            } else if (std.mem.eql(u8, status, "skip")) {
                counts.skip += 1;
            } else if (std.mem.eql(u8, status, "todo")) {
                counts.todo += 1;
            }
        }
        // A panic or crash ends the binary before its closing `leak` line.
        if (!finished) {
            counts.crashed += 1;
            std.debug.print("\x1b[31m✗ {s} did not finish ({any})\x1b[0m\n", .{ std.fs.path.basename(bin), term });
        }
    }

    var total_ns: u64 = 0;
    for (tests.items) |t| total_ns += t.ns;
    const total = tests.items.len;

    std.debug.print("\n\x1b[32m{d:<3} pass\x1b[0m\n", .{counts.pass});
    if (counts.fail > 0) std.debug.print("\x1b[31m{d:<3} fail\x1b[0m\n", .{counts.fail}) else std.debug.print("{d:<3} fail\n", .{counts.fail});
    if (counts.skip > 0) std.debug.print("\x1b[33m{d:<3} skipped\x1b[0m\n", .{counts.skip});
    if (counts.todo > 0) std.debug.print("\x1b[36m{d:<3} todo\x1b[0m\n", .{counts.todo});
    if (counts.leak > 0) std.debug.print("\x1b[31m{d:<3} leaked\x1b[0m\n", .{counts.leak});
    if (counts.crashed > 0) std.debug.print("\x1b[31m{d:<3} crashed\x1b[0m\n", .{counts.crashed});
    std.debug.print("\x1b[90m{d} test{s} in {d} binaries | {d:.2}ms total\x1b[0m\n", .{
        total,
        if (total != 1) "s" else "",
        binaries.len,
        @as(f64, @floatFromInt(total_ns)) / std.time.ns_per_ms,
    });

    if (total > 0) {
        std.mem.sort(Test, tests.items, {}, struct {
            fn slower(_: void, a: Test, b: Test) bool {
                return a.ns > b.ns;
            }
        }.slower);
        const n = @min(slowest_count, total);
        std.debug.print("\n\x1b[1mSlowest\x1b[0m \x1b[90m({d})\x1b[0m:\n", .{n});
        for (tests.items[0..n]) |t| std.debug.print("  {d:.2}ms\t\x1b[90m{s} > {s}\x1b[0m\n", .{ @as(f64, @floatFromInt(t.ns)) / std.time.ns_per_ms, t.scope, t.name });
    }
    if (failed.items.len > 0) {
        std.debug.print("\n\x1b[1mFailed\x1b[0m \x1b[90m({d})\x1b[0m:\n", .{failed.items.len});
        for (failed.items) |t| std.debug.print("\x1b[31m  ✗\x1b[0m {s} > {s}\n", .{ t.scope, t.name });
    }
    std.debug.print("\n", .{});
    std.process.exit(if (counts.fail == 0 and counts.leak == 0 and counts.crashed == 0) 0 else 1);
}
