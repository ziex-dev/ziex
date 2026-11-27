const std = @import("std");
const zx = @import("zx");
const Worker = zx.Worker;

const M = struct {
    pub const Note = struct { id: u32, body: []const u8, tags: []const []const u8 };

    pub fn add(a: i32, b: i32) i32 {
        return a + b;
    }

    pub fn notes(gpa: std.mem.Allocator, prefix: []const u8, n: u32) ![]const Note {
        const out = try gpa.alloc(Note, n);
        for (out, 0..) |*note, i| note.* = .{
            .id = @intCast(i),
            .body = try gpa.print("{s}-{d}", .{ prefix, i }),
            .tags = &.{ "a", "b" },
        };
        return out;
    }

    pub fn fail(code: u8) error{ Nope, Other }!void {
        if (code == 1) return error.Nope;
        return error.Other;
    }

    pub fn init() void {}
    pub fn generic(x: anytype) @TypeOf(x) {
        return x;
    }
    pub const not_a_fn = 1;
};

fn call(index: usize, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    inline for (args) |a| try Worker.codec.encode(&aw.writer, a);
    var out: [*]u8 = undefined;
    const n = Worker.Server(M).call(@intCast(index), aw.written().ptr, aw.written().len, &out);
    try std.testing.expect(n >= 1);
    return out[0..@intCast(n)];
}

fn freeReply(reply: []u8) void {
    std.heap.page_allocator.free(reply);
}

test "functions lists non-generic pub fns in order, minus init" {
    const fns = Worker.functions(M);
    try std.testing.expectEqual(@as(usize, 3), fns.len);
    try std.testing.expectEqualStrings("add", fns[0]);
    try std.testing.expectEqualStrings("notes", fns[1]);
    try std.testing.expectEqualStrings("fail", fns[2]);
}

test "native builds call worker functions directly" {
    const w = zx.worker(M);
    try std.testing.expectEqual(@as(i32, 5), w.add(2, 3));
    try std.testing.expectError(error.Nope, w.fail(1));
}

test "proxies keep parameters and widen the error set" {
    const P = @TypeOf(Worker.proxy(M, "/w.wasm"));
    const notes = @typeInfo(@FieldType(P, "notes")).@"fn";
    try std.testing.expectEqual(std.mem.Allocator, notes.param_types[0].?);
    try std.testing.expectEqual([]const u8, notes.param_types[1].?);
    const add = @typeInfo(@FieldType(P, "add")).@"fn";
    const E = @typeInfo(add.return_type.?).error_union.error_set;
    try std.testing.expect(@typeInfo(E).error_set.error_names.?.len == @typeInfo(Worker.Error).error_set.error_names.?.len);
    // Inferred error sets aren't resolved, so the worker's body isn't compiled here.
    const notes_err = @typeInfo(notes.return_type.?).error_union.error_set;
    try std.testing.expect(notes_err == Worker.Error);
    const fail = @typeInfo(@FieldType(P, "fail")).@"fn";
    const FE = @typeInfo(fail.return_type.?).error_union.error_set;
    try std.testing.expect(@as(FE, error.Nope) == error.Nope);
    try std.testing.expect(@as(FE, error.WorkerFailed) == error.WorkerFailed);
}

test "dispatch decodes arguments and encodes results" {
    const reply = try call(0, .{ @as(i32, 40), @as(i32, 2) });
    defer freeReply(reply);
    try std.testing.expectEqual(@as(u8, 0), reply[0]);
    var r = std.Io.Reader.fixed(reply[1..]);
    try std.testing.expectEqual(@as(i32, 42), try Worker.codec.decode(i32, &r, std.testing.allocator));
}

test "dispatch skips the allocator parameter and returns nested data" {
    const reply = try call(1, .{ @as([]const u8, "n"), @as(u32, 3) });
    defer freeReply(reply);
    try std.testing.expectEqual(@as(u8, 0), reply[0]);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = std.Io.Reader.fixed(reply[1..]);
    const notes = try Worker.codec.decode([]const M.Note, &r, arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), notes.len);
    try std.testing.expectEqualStrings("n-2", notes[2].body);
    try std.testing.expectEqualStrings("b", notes[1].tags[1]);
}

test "dispatch reports errors by name and rejects bad input" {
    const reply = try call(2, .{@as(u8, 1)});
    defer freeReply(reply);
    try std.testing.expectEqual(@as(u8, 1), reply[0]);
    try std.testing.expectEqualStrings("Nope", reply[1..]);

    const bad = try call(1, .{@as(u8, 1)});
    defer freeReply(bad);
    try std.testing.expectEqual(@as(u8, 2), bad[0]);

    const unknown = try call(9, .{});
    defer freeReply(unknown);
    try std.testing.expectEqual(@as(u8, 2), unknown[0]);
}

test {
    _ = Worker;
}
