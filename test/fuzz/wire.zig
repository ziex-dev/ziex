const std = @import("std");
const zx = @import("zx");
const Wire = zx.Wire;
const Smith = std.testing.Smith;
const util = @import("util.zig");

fn header(comptime kind: Wire.Kind) [5]u8 {
    var out: [5]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], Wire.magic, .little);
    out[4] = @backingInt(kind);
    return out;
}

const corpus = util.seeds(&.{
    &header(.pair) ++ "\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00",
    &header(.strings) ++ "\x02\x00\x00\x00\x01\x00\x00\x00a\x00\x00\x00\x00",
    &header(.records) ++ "\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00id\x01\x07\x00\x00\x00\x00\x00\x00\x00",
    &header(.rows) ++ "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x02\x00\x00\x00hi\x05\x01",
    &header(.args) ++ "\x01\x02\x00\x00\x00\x00\x04\x01\x00\x00\x00z",
});

// Decoders read bytes coming back from the host (D1/KV bindings): malformed or
// truncated payloads must fail cleanly, without leaking or over-allocating.
test "fuzz: wire decoders" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [4096]u8 = undefined;
            const bytes = util.bytes(s, &buf);
            const gpa = std.testing.allocator;

            _ = Wire.decodePair(bytes) catch {};

            if (Wire.decodeStrings(gpa, bytes)) |items| {
                for (items) |item| gpa.free(item);
                gpa.free(items);
            } else |_| {}

            if (Wire.decodeRecords(gpa, bytes)) |records| {
                // Field names are shared across rows.
                if (records.len > 0) for (records[0].fields) |f| gpa.free(f.name);
                for (records) |rec| {
                    for (rec.fields) |f| freeValue(gpa, f.value);
                    gpa.free(rec.fields);
                }
                gpa.free(records);
            } else |_| {}

            if (Wire.decodeRows(gpa, bytes)) |rows| {
                for (rows) |row| freeValues(gpa, row);
                gpa.free(rows);
            } else |_| {}

            if (Wire.decodeArgs(gpa, bytes)) |args| freeValues(gpa, args) else |_| {}
        }
    }.run, .{ .corpus = corpus });
}

fn freeValue(gpa: std.mem.Allocator, v: Wire.Value) void {
    switch (v) {
        .text, .blob => |b| gpa.free(b),
        else => {},
    }
}

fn freeValues(gpa: std.mem.Allocator, values: []const Wire.Value) void {
    for (values) |v| freeValue(gpa, v);
    gpa.free(values);
}

fn genValue(s: *Smith, text: []u8) Wire.Value {
    return switch (s.valueRangeAtMost(u8, 0, 5)) {
        0 => .null,
        1 => .{ .integer = s.value(i64) },
        2 => .{ .float = s.value(f64) },
        3 => .{ .text = util.bytes(s, text) },
        4 => .{ .blob = util.bytes(s, text) },
        else => .{ .boolean = s.value(bool) },
    };
}

fn expectValue(want: Wire.Value, got: Wire.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .null => {},
        .integer => |v| try std.testing.expectEqual(v, got.integer),
        .float => |v| try std.testing.expectEqual(@as(u64, @bitCast(v)), @as(u64, @bitCast(got.float))),
        .text => |v| try std.testing.expectEqualSlices(u8, v, got.text),
        .blob => |v| try std.testing.expectEqualSlices(u8, v, got.blob),
        .boolean => |v| try std.testing.expectEqual(v, got.boolean),
    }
}

test "fuzz: wire roundtrip" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var texts: [8][64]u8 = undefined;
            var values: [8]Wire.Value = undefined;
            const n = s.valueRangeAtMost(u8, 0, values.len);
            for (values[0..n], texts[0..n]) |*v, *t| v.* = genValue(s, t);

            var w: std.Io.Writer.Allocating = .init(a);
            try Wire.encodeArgs(&w.writer, .{ .list = values[0..n] });
            const args = try Wire.decodeArgs(a, w.written());
            try std.testing.expectEqual(n, args.len);
            for (values[0..n], args) |want, got| try expectValue(want, got);

            w.clearRetainingCapacity();
            const rows: []const []const Wire.Value = &.{ values[0..n], values[0..n] };
            try Wire.encodeRows(&w.writer, rows);
            const got_rows = try Wire.decodeRows(a, w.written());
            try std.testing.expectEqual(2, got_rows.len);
            for (got_rows) |row| for (values[0..n], row) |want, got| try expectValue(want, got);

            var strs: [8][]const u8 = undefined;
            for (strs[0..n], texts[0..n]) |*str, *t| str.* = util.bytes(s, t);
            w.clearRetainingCapacity();
            try Wire.encodeStrings(&w.writer, strs[0..n]);
            const got_strs = try Wire.decodeStrings(a, w.written());
            for (strs[0..n], got_strs) |want, got| try std.testing.expectEqualSlices(u8, want, got);
        }
    }.run, .{});
}
