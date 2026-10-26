const std = @import("std");
const zx = @import("zx");
const Wire = zx.Wire;

test "wire module surface" {
    try std.testing.expectEqual(@as(u32, 0x3142445a), Wire.magic);
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Wire.Kind.strings));
}

test "wire pair roundtrip and golden" {
    const expected = [_]u8{
        0x5a, 0x44, 0x42, 0x31,
        0x02,
        0x2a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try Wire.encodePair(&buf.writer, 42, 3);
    try std.testing.expectEqualSlices(u8, &expected, buf.written());

    const decoded = try Wire.decodePair(buf.written());
    try std.testing.expectEqual(@as(i64, 42), decoded.a);
    try std.testing.expectEqual(@as(i64, 3), decoded.b);
}

test "wire strings roundtrip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const input = [_][]const u8{ "alpha", "beta/γ", "" };
    try Wire.encodeStrings(&buf.writer, &input);
    const decoded = try Wire.decodeStrings(std.testing.allocator, buf.written());
    defer {
        for (decoded) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(decoded);
    }
    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqualSlices(u8, "alpha", decoded[0]);
    try std.testing.expectEqualSlices(u8, "beta/γ", decoded[1]);
    try std.testing.expectEqualSlices(u8, "", decoded[2]);
}

test "wire records roundtrip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();

    const cols = [_][]const u8{ "id", "name", "flag", "blob", "n" };
    const row0 = [_]Wire.Value{
        .{ .integer = 7 },
        .{ .text = "hi" },
        .{ .boolean = true },
        .{ .blob = &[_]u8{ 1, 2, 3 } },
        .null,
    };
    const row1 = [_]Wire.Value{
        .{ .float = 1.5 },
        .{ .text = "" },
        .{ .boolean = false },
        .{ .blob = &[_]u8{} },
        .{ .integer = -1 },
    };
    try Wire.encodeRecords(&buf.writer, &cols, &.{ &row0, &row1 });

    const rows = try Wire.decodeRecords(std.testing.allocator, buf.written());
    defer freeRecords(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualSlices(u8, "id", rows[0].fields[0].name);
    try std.testing.expectEqual(@as(i64, 7), rows[0].fields[0].value.integer);
    try std.testing.expectEqualSlices(u8, "hi", rows[0].fields[1].value.text);
    try std.testing.expect(rows[0].fields[2].value.boolean);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, rows[0].fields[3].value.blob);
    try std.testing.expect(rows[0].fields[4].value == .null);
    try std.testing.expectEqual(@as(f64, 1.5), rows[1].fields[0].value.float);
}

test "wire args and rows roundtrip" {
    {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        const list = [_]Wire.Value{ .{ .integer = 9 }, .{ .text = "x" }, .null };
        try Wire.encodeArgs(&buf.writer, .{ .list = &list });
        const decoded = try Wire.decodeArgs(std.testing.allocator, buf.written());
        defer {
            for (decoded) |v| freeValue(v);
            std.testing.allocator.free(decoded);
        }
        try std.testing.expectEqual(@as(usize, 3), decoded.len);
        try std.testing.expectEqual(@as(i64, 9), decoded[0].integer);
        try std.testing.expectEqualSlices(u8, "x", decoded[1].text);
        try std.testing.expect(decoded[2] == .null);
    }
    {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        const r0 = [_]Wire.Value{ .{ .integer = 1 }, .{ .integer = 2 } };
        const r1 = [_]Wire.Value{.{ .text = "a" }};
        try Wire.encodeRows(&buf.writer, &.{ &r0, &r1 });
        const decoded = try Wire.decodeRows(std.testing.allocator, buf.written());
        defer {
            for (decoded) |row| {
                for (row) |v| freeValue(v);
                std.testing.allocator.free(row);
            }
            std.testing.allocator.free(decoded);
        }
        try std.testing.expectEqual(@as(usize, 2), decoded.len);
        try std.testing.expectEqual(@as(i64, 1), decoded[0][0].integer);
        try std.testing.expectEqualSlices(u8, "a", decoded[1][0].text);
    }
}

test "wire rejects bad magic" {
    const bad = [_]u8{ 0, 0, 0, 0, 2 };
    try std.testing.expectError(error.BadMagic, Wire.decodePair(&bad));
}

fn freeValue(value: Wire.Value) void {
    switch (value) {
        .text => |t| std.testing.allocator.free(t),
        .blob => |b| std.testing.allocator.free(b),
        else => {},
    }
}

fn freeRecords(rows: []const Wire.Record) void {
    if (rows.len > 0) {
        for (rows[0].fields) |f| {
            std.testing.allocator.free(f.name);
            freeValue(f.value);
        }
        std.testing.allocator.free(rows[0].fields);
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            for (rows[i].fields) |f| freeValue(f.value);
            std.testing.allocator.free(rows[i].fields);
        }
    }
    std.testing.allocator.free(rows);
}
