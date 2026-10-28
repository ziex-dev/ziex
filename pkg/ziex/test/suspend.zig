//! Fixture for `src/runtime/jspi.test.ts`: exports that keep a stack buffer alive
//! across suspending imports, so shadow-stack corruption shows up as changed values.
const std = @import("std");

extern "env" fn wait(id: u32) void;
extern "env" fn fail(id: u32) u32;

fn fill(buf: []u32, id: u32) void {
    for (buf, 0..) |*b, i| b.* = id * 1000 + @as(u32, @intCast(i));
    std.mem.doNotOptimizeAway(buf.ptr);
}

fn changed(buf: []const u32, id: u32) u32 {
    var n: u32 = 0;
    for (buf, 0..) |b, i| n += @intFromBool(b != id * 1000 + @as(u32, @intCast(i)));
    return n;
}

/// Suspends once; returns how many values changed while suspended.
export fn run(id: u32) u32 {
    var buf: [64]u32 = undefined;
    fill(&buf, id);
    wait(id);
    return changed(&buf, id);
}

/// Suspends twice on the same stack.
export fn runTwice(id: u32) u32 {
    var buf: [64]u32 = undefined;
    fill(&buf, id);
    wait(id);
    wait(id + 100);
    return changed(&buf, id);
}

/// Calls an import that rejects; returns the stack check if it ever resumes.
export fn runFailing(id: u32) u32 {
    var buf: [64]u32 = undefined;
    fill(&buf, id);
    _ = fail(id);
    return changed(&buf, id);
}

/// A plain call that overwrites whatever stack space is free.
export fn scribble() void {
    var junk: [256]u32 = undefined;
    @memset(&junk, 0xdeadbeef);
    std.mem.doNotOptimizeAway(&junk);
}
