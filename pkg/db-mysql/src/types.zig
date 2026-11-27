// Column types and row value decoding for the text and binary result protocols.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const FieldType = struct {
    pub const decimal: u8 = 0x00;
    pub const tiny: u8 = 0x01;
    pub const short: u8 = 0x02;
    pub const long: u8 = 0x03;
    pub const float: u8 = 0x04;
    pub const double: u8 = 0x05;
    pub const null_type: u8 = 0x06;
    pub const timestamp: u8 = 0x07;
    pub const longlong: u8 = 0x08;
    pub const int24: u8 = 0x09;
    pub const date: u8 = 0x0a;
    pub const time: u8 = 0x0b;
    pub const datetime: u8 = 0x0c;
    pub const year: u8 = 0x0d;
    pub const newdate: u8 = 0x0e;
    pub const varchar: u8 = 0x0f;
    pub const bit: u8 = 0x10;
    pub const json: u8 = 0xf5;
    pub const newdecimal: u8 = 0xf6;
    pub const enumeration: u8 = 0xf7;
    pub const set: u8 = 0xf8;
    pub const tiny_blob: u8 = 0xf9;
    pub const medium_blob: u8 = 0xfa;
    pub const long_blob: u8 = 0xfb;
    pub const blob: u8 = 0xfc;
    pub const var_string: u8 = 0xfd;
    pub const string: u8 = 0xfe;
    pub const geometry: u8 = 0xff;
};

pub const Flag = struct {
    pub const unsigned: u16 = 0x0020;
};

/// Charset id MySQL reports for BINARY/VARBINARY/BLOB columns.
pub const binary_charset: u16 = 63;

/// Per-column decoder, resolved once per result set so rows take a single switch.
pub const Kind = enum {
    null,
    tiny,
    utiny,
    short,
    ushort,
    long,
    ulong,
    longlong,
    ulonglong,
    float32,
    float64,
    // binary protocol temporal values
    date,
    datetime,
    time,
    // text protocol numbers
    integer_text,
    float_text,
    // length-encoded strings, both protocols
    text,
    blob,
    bit,
    bit1,
};

pub fn kindOf(col: protocol.Column, binary: bool) Kind {
    const unsigned = col.flags & Flag.unsigned != 0;
    const ty = col.type;
    if (ty == FieldType.null_type) return .null;
    if (ty == FieldType.bit) return if (col.length == 1) .bit1 else .bit;
    if (!binary) return switch (ty) {
        FieldType.tiny, FieldType.short, FieldType.long, FieldType.longlong, FieldType.int24, FieldType.year => .integer_text,
        FieldType.float, FieldType.double => .float_text,
        else => stringKind(col),
    };
    return switch (ty) {
        FieldType.tiny => if (unsigned) .utiny else .tiny,
        FieldType.short => if (unsigned) .ushort else .short,
        FieldType.year => .ushort,
        FieldType.long, FieldType.int24 => if (unsigned) .ulong else .long,
        FieldType.longlong => if (unsigned) .ulonglong else .longlong,
        FieldType.float => .float32,
        FieldType.double => .float64,
        FieldType.date, FieldType.newdate => .date,
        FieldType.datetime, FieldType.timestamp => .datetime,
        FieldType.time => .time,
        else => stringKind(col),
    };
}

fn stringKind(col: protocol.Column) Kind {
    return switch (col.type) {
        FieldType.tiny_blob, FieldType.medium_blob, FieldType.long_blob, FieldType.blob => if (col.charset == binary_charset) .blob else .text,
        FieldType.string, FieldType.var_string, FieldType.varchar => if (col.charset == binary_charset) .blob else .text,
        FieldType.geometry => .blob,
        else => .text,
    };
}

/// `ColumnType` must have the tags integer, float, text, blob, null, unknown.
pub fn columnType(comptime ColumnType: type, col: protocol.Column) ColumnType {
    return switch (kindOf(col, true)) {
        .null => .null,
        .tiny, .utiny, .short, .ushort, .long, .ulong, .longlong, .ulonglong, .bit, .bit1 => .integer,
        .float32, .float64 => .float,
        .blob => .blob,
        .text, .date, .datetime, .time => .text,
        else => .unknown,
    };
}

/// Walks one row packet column by column.
pub const RowReader = struct {
    cur: protocol.Cursor,
    nulls: []const u8 = &.{},
    binary: bool,
    index: usize = 0,

    pub fn init(body: []const u8, binary: bool, columns: usize) !RowReader {
        var cur: protocol.Cursor = .{ .data = body };
        if (!binary) return .{ .cur = cur, .binary = false };
        // 0x00 header, then a NULL bitmap with a 2 bit offset
        if (try cur.int1() != 0) return error.ProtocolViolation;
        const nulls = try cur.take((columns + 9) / 8);
        return .{ .cur = cur, .nulls = nulls, .binary = true };
    }

    /// With `copy` false, text and blobs borrow the row packet; values built from several bytes
    /// (dates, large unsigned integers) are allocated with `gpa` either way.
    pub inline fn next(self: *RowReader, comptime Value: type, comptime copy: bool, gpa: std.mem.Allocator, kind: Kind) !Value {
        const i = self.index;
        self.index += 1;
        if (self.binary) {
            if (self.nulls[(i + 2) / 8] & (@as(u8, 1) << @intCast((i + 2) % 8)) != 0) return .null;
            return decodeBinary(Value, copy, gpa, kind, &self.cur);
        }
        if (self.cur.peek() == 0xfb) {
            try self.cur.skip(1);
            return .null;
        }
        return decodeText(Value, copy, gpa, kind, try self.cur.lenencStr());
    }
};

inline fn str(comptime Value: type, comptime copy: bool, gpa: std.mem.Allocator, kind: Kind, data: []const u8) !Value {
    const owned = if (copy) try gpa.dupe(u8, data) else data;
    return if (kind == .blob) .{ .blob = owned } else .{ .text = owned };
}

pub fn decodeText(comptime Value: type, comptime copy: bool, gpa: std.mem.Allocator, kind: Kind, data: []const u8) !Value {
    return switch (kind) {
        .null => .null,
        .integer_text => if (parseInt(data)) |v| .{ .integer = v } else |err| switch (err) {
            // unsigned BIGINT above i64: keep the exact digits
            error.Overflow => .{ .text = if (copy) try gpa.dupe(u8, data) else data },
            else => err,
        },
        .float_text => .{ .float = try std.fmt.parseFloat(f64, data) },
        .bit => .{ .integer = bitValue(data) },
        .bit1 => .{ .boolean = bitValue(data) != 0 },
        .text, .blob => str(Value, copy, gpa, kind, data),
        // binary-only kinds never appear in text results
        else => error.ProtocolViolation,
    };
}

pub fn decodeBinary(comptime Value: type, comptime copy: bool, gpa: std.mem.Allocator, kind: Kind, cur: *protocol.Cursor) !Value {
    return switch (kind) {
        .null => .null,
        .tiny => .{ .integer = @as(i8, @bitCast(try cur.int1())) },
        .utiny => .{ .integer = try cur.int1() },
        .short => .{ .integer = @as(i16, @bitCast(try cur.int2())) },
        .ushort => .{ .integer = try cur.int2() },
        .long => .{ .integer = @as(i32, @bitCast(try cur.int4())) },
        .ulong => .{ .integer = try cur.int4() },
        .longlong => .{ .integer = @bitCast(try cur.int8()) },
        .ulonglong => blk: {
            const v = try cur.int8();
            if (v <= std.math.maxInt(i64)) break :blk .{ .integer = @intCast(v) };
            break :blk .{ .text = try std.fmt.allocPrint(gpa, "{d}", .{v}) };
        },
        .float32 => .{ .float = @as(f32, @bitCast(try cur.int4())) },
        .float64 => .{ .float = @as(f64, @bitCast(try cur.int8())) },
        .date, .datetime => .{ .text = try decodeDateTime(gpa, cur, kind == .date) },
        .time => .{ .text = try decodeTime(gpa, cur) },
        .bit => .{ .integer = bitValue(try cur.lenencStr()) },
        .bit1 => .{ .boolean = bitValue(try cur.lenencStr()) != 0 },
        .text, .blob => str(Value, copy, gpa, kind, try cur.lenencStr()),
        .integer_text, .float_text => error.ProtocolViolation,
    };
}

/// BIT(n) arrives as big-endian bytes.
fn bitValue(data: []const u8) i64 {
    var v: u64 = 0;
    for (data[0..@min(data.len, 8)]) |b| v = (v << 8) | b;
    return @bitCast(v);
}

fn decodeDateTime(gpa: std.mem.Allocator, cur: *protocol.Cursor, date_only: bool) ![]u8 {
    const len = try cur.int1();
    var year: u16 = 0;
    var month: u8 = 0;
    var day: u8 = 0;
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var micro: u32 = 0;
    switch (len) {
        0 => {},
        4, 7, 11 => {
            year = try cur.int2();
            month = try cur.int1();
            day = try cur.int1();
            if (len >= 7) {
                hour = try cur.int1();
                minute = try cur.int1();
                second = try cur.int1();
            }
            if (len == 11) micro = try cur.int4();
        },
        else => return error.InvalidBinaryValue,
    }
    if (date_only) return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
    if (micro != 0) return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ year, month, day, hour, minute, second, micro });
    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, month, day, hour, minute, second });
}

fn decodeTime(gpa: std.mem.Allocator, cur: *protocol.Cursor) ![]u8 {
    const len = try cur.int1();
    var negative = false;
    var hours: u32 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var micro: u32 = 0;
    switch (len) {
        0 => {},
        8, 12 => {
            negative = try cur.int1() != 0;
            const days = try cur.int4();
            hours = days * 24 + try cur.int1();
            minute = try cur.int1();
            second = try cur.int1();
            if (len == 12) micro = try cur.int4();
        },
        else => return error.InvalidBinaryValue,
    }
    const sign = if (negative) "-" else "";
    if (micro != 0) return std.fmt.allocPrint(gpa, "{s}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ sign, hours, minute, second, micro });
    return std.fmt.allocPrint(gpa, "{s}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hours, minute, second });
}

/// Integer text: optional sign, then digits. Faster than std.fmt.parseInt (no base/underscores).
fn parseInt(data: []const u8) !i64 {
    if (data.len == 0) return error.InvalidCharacter;
    const neg = data[0] == '-';
    const digits = data[@intFromBool(neg)..];
    if (digits.len == 0) return error.InvalidCharacter;
    // accumulate negatively so minInt(i64) parses
    var acc: i64 = 0;
    for (digits) |ch| {
        const d = ch -% '0';
        if (d > 9) return error.InvalidCharacter;
        const mul = @mulWithOverflow(acc, 10);
        const sub = @subWithOverflow(mul[0], @as(i64, d));
        if (mul[1] != 0 or sub[1] != 0) return error.Overflow;
        acc = sub[0];
    }
    if (neg) return acc;
    return std.math.negate(acc) catch error.Overflow;
}

/// Text form of a float that the server parses back exactly.
pub fn formatFloat(buf: []u8, value: f64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{e}", .{value});
}

// --- Tests --- //

const t = std.testing;

const TestValue = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    boolean: bool,
};

fn mk(ty: u8, flags: u16, charset: u16, length: u32) protocol.Column {
    return .{ .name = "c", .charset = charset, .length = length, .type = ty, .flags = flags, .decimals = 0 };
}

fn binaryOne(c: protocol.Column, bytes: []const u8) !TestValue {
    var cur: protocol.Cursor = .{ .data = bytes };
    const v = try decodeBinary(TestValue, false, t.allocator, kindOf(c, true), &cur);
    try t.expect(cur.atEnd());
    return v;
}

fn freeText(v: TestValue) void {
    switch (v) {
        .text => |s| t.allocator.free(s),
        else => {},
    }
}

test "kinds by column type, flags and charset" {
    try t.expectEqual(Kind.utiny, kindOf(mk(FieldType.tiny, Flag.unsigned, 63, 3), true));
    try t.expectEqual(Kind.long, kindOf(mk(FieldType.int24, 0, 63, 9), true));
    try t.expectEqual(Kind.integer_text, kindOf(mk(FieldType.longlong, 0, 63, 20), false));
    try t.expectEqual(Kind.blob, kindOf(mk(FieldType.blob, 0x80, binary_charset, 65535), true));
    try t.expectEqual(Kind.text, kindOf(mk(FieldType.blob, 0, 255, 262140), true));
    // _bin collations carry the BINARY flag but are still text
    try t.expectEqual(Kind.text, kindOf(mk(FieldType.var_string, 0x80, 46, 400), true));
    try t.expectEqual(Kind.blob, kindOf(mk(FieldType.var_string, 0x80, binary_charset, 16), true));
    try t.expectEqual(Kind.text, kindOf(mk(FieldType.json, 0x80, binary_charset, 4294967295), true));
    try t.expectEqual(Kind.text, kindOf(mk(FieldType.newdecimal, 0, 63, 12), false));
    try t.expectEqual(Kind.bit1, kindOf(mk(FieldType.bit, 0, 63, 1), true));
    try t.expectEqual(Kind.bit, kindOf(mk(FieldType.bit, 0, 63, 8), true));
    try t.expectEqual(Kind.null, kindOf(mk(FieldType.null_type, 0, 63, 0), true));
}

test "column types map to the shared tags" {
    const Tag = enum { integer, float, text, blob, null, unknown };
    try t.expectEqual(Tag.integer, columnType(Tag, mk(FieldType.longlong, 0, 63, 20)));
    try t.expectEqual(Tag.float, columnType(Tag, mk(FieldType.double, 0, 63, 22)));
    try t.expectEqual(Tag.text, columnType(Tag, mk(FieldType.datetime, 0, 63, 19)));
    try t.expectEqual(Tag.blob, columnType(Tag, mk(FieldType.blob, 0x80, binary_charset, 65535)));
    try t.expectEqual(Tag.null, columnType(Tag, mk(FieldType.null_type, 0, 63, 0)));
}

test "binary integers and floats" {
    try t.expectEqual(TestValue{ .integer = -1 }, try binaryOne(mk(FieldType.tiny, 0, 63, 4), &.{0xff}));
    try t.expectEqual(TestValue{ .integer = 255 }, try binaryOne(mk(FieldType.tiny, Flag.unsigned, 63, 3), &.{0xff}));
    try t.expectEqual(TestValue{ .integer = -2 }, try binaryOne(mk(FieldType.short, 0, 63, 6), &.{ 0xfe, 0xff }));
    try t.expectEqual(TestValue{ .integer = 2024 }, try binaryOne(mk(FieldType.year, Flag.unsigned, 63, 4), &.{ 0xe8, 0x07 }));
    // MEDIUMINT travels as 4 bytes
    try t.expectEqual(TestValue{ .integer = -3 }, try binaryOne(mk(FieldType.int24, 0, 63, 9), &.{ 0xfd, 0xff, 0xff, 0xff }));
    try t.expectEqual(TestValue{ .integer = 4294967295 }, try binaryOne(mk(FieldType.long, Flag.unsigned, 63, 10), &.{ 0xff, 0xff, 0xff, 0xff }));
    try t.expectEqual(TestValue{ .integer = std.math.minInt(i64) }, try binaryOne(mk(FieldType.longlong, 0, 63, 20), &.{ 0, 0, 0, 0, 0, 0, 0, 0x80 }));
    try t.expectEqual(TestValue{ .float = 1.5 }, try binaryOne(mk(FieldType.double, 0, 63, 22), &.{ 0, 0, 0, 0, 0, 0, 0xf8, 0x3f }));
    try t.expectEqual(TestValue{ .float = -0.25 }, try binaryOne(mk(FieldType.float, 0, 63, 12), &.{ 0, 0, 0x80, 0xbe }));
    try t.expectError(error.ProtocolViolation, binaryOne(mk(FieldType.long, 0, 63, 10), &.{0}));
}

test "unsigned bigint above i64 becomes exact text" {
    const big = try binaryOne(mk(FieldType.longlong, Flag.unsigned, 63, 20), &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    defer freeText(big);
    try t.expectEqualStrings("18446744073709551615", big.text);
    try t.expectEqual(TestValue{ .integer = 7 }, try binaryOne(mk(FieldType.longlong, Flag.unsigned, 63, 20), &.{ 7, 0, 0, 0, 0, 0, 0, 0 }));

    const text = try decodeText(TestValue, true, t.allocator, .integer_text, "18446744073709551615");
    defer freeText(text);
    try t.expectEqualStrings("18446744073709551615", text.text);
}

test "binary strings, blobs and bit" {
    try t.expectEqualStrings("héllo", (try binaryOne(mk(FieldType.var_string, 0, 255, 20), "\x06h\xc3\xa9llo")).text);
    try t.expectEqualSlices(u8, "\x00\x01", (try binaryOne(mk(FieldType.blob, 0x80, binary_charset, 10), "\x02\x00\x01")).blob);
    try t.expectEqual(TestValue{ .boolean = true }, try binaryOne(mk(FieldType.bit, 0, 63, 1), "\x01\x01"));
    try t.expectEqual(TestValue{ .integer = 0x0102 }, try binaryOne(mk(FieldType.bit, 0, 63, 16), "\x02\x01\x02"));
}

test "binary date, datetime and time" {
    const date = try binaryOne(mk(FieldType.date, 0, 63, 10), &.{ 4, 0xe8, 0x07, 2, 29 });
    defer freeText(date);
    try t.expectEqualStrings("2024-02-29", date.text);

    const zero = try binaryOne(mk(FieldType.date, 0, 63, 10), &.{0});
    defer freeText(zero);
    try t.expectEqualStrings("0000-00-00", zero.text);

    const dt = try binaryOne(mk(FieldType.datetime, 0, 63, 19), &.{ 7, 0xe8, 0x07, 1, 2, 3, 4, 5 });
    defer freeText(dt);
    try t.expectEqualStrings("2024-01-02 03:04:05", dt.text);

    const midnight = try binaryOne(mk(FieldType.timestamp, 0, 63, 19), &.{ 4, 0xe8, 0x07, 1, 2 });
    defer freeText(midnight);
    try t.expectEqualStrings("2024-01-02 00:00:00", midnight.text);

    const micro = try binaryOne(mk(FieldType.datetime, 0, 63, 26), &.{ 11, 0xe8, 0x07, 1, 2, 3, 4, 5, 0x40, 0xe2, 0x01, 0 });
    defer freeText(micro);
    try t.expectEqualStrings("2024-01-02 03:04:05.123456", micro.text);

    const neg = try binaryOne(mk(FieldType.time, 0, 63, 10), &.{ 8, 1, 4, 0, 0, 0, 2, 3, 4 });
    defer freeText(neg);
    try t.expectEqualStrings("-98:03:04", neg.text);

    const frac = try binaryOne(mk(FieldType.time, 0, 63, 17), &.{ 12, 0, 0, 0, 0, 0, 1, 2, 3, 1, 0, 0, 0 });
    defer freeText(frac);
    try t.expectEqualStrings("01:02:03.000001", frac.text);

    const empty = try binaryOne(mk(FieldType.time, 0, 63, 10), &.{0});
    defer freeText(empty);
    try t.expectEqualStrings("00:00:00", empty.text);

    var bad: protocol.Cursor = .{ .data = &.{ 5, 0, 0, 0, 0, 0 } };
    try t.expectError(error.InvalidBinaryValue, decodeBinary(TestValue, false, t.allocator, .datetime, &bad));
}

test "text protocol values" {
    try t.expectEqual(TestValue{ .integer = -42 }, try decodeText(TestValue, false, t.allocator, .integer_text, "-42"));
    try t.expectEqual(TestValue{ .float = 1.5 }, try decodeText(TestValue, false, t.allocator, .float_text, "1.5"));
    try t.expectEqual(TestValue{ .boolean = true }, try decodeText(TestValue, false, t.allocator, .bit1, "\x01"));
    try t.expectEqualStrings("12345678901234567890.5", (try decodeText(TestValue, false, t.allocator, .text, "12345678901234567890.5")).text);
    try t.expectEqualSlices(u8, "\x00\xff", (try decodeText(TestValue, false, t.allocator, .blob, "\x00\xff")).blob);
    try t.expectError(error.InvalidCharacter, decodeText(TestValue, false, t.allocator, .integer_text, "1_000"));
    try t.expectError(error.ProtocolViolation, decodeText(TestValue, false, t.allocator, .datetime, "x"));

    const copied = try decodeText(TestValue, true, t.allocator, .text, "abc");
    defer freeText(copied);
    try t.expectEqualStrings("abc", copied.text);
}

test "row reader: text rows with NULL" {
    var w: protocol.Writer = .init(t.allocator);
    defer w.deinit();
    try w.lenencStr("7");
    try w.int1(0xfb);
    try w.lenencStr("hi");
    var r = try RowReader.init(w.bytes(), false, 3);
    const kinds = [_]Kind{ .integer_text, .text, .text };
    try t.expectEqual(TestValue{ .integer = 7 }, try r.next(TestValue, false, t.allocator, kinds[0]));
    try t.expectEqual(TestValue.null, try r.next(TestValue, false, t.allocator, kinds[1]));
    try t.expectEqualStrings("hi", (try r.next(TestValue, false, t.allocator, kinds[2])).text);
}

test "row reader: binary rows with NULL bitmap" {
    // 3 columns, column 1 NULL: bit (1 + 2) of the bitmap
    var w: protocol.Writer = .init(t.allocator);
    defer w.deinit();
    try w.int1(0);
    try w.int1(0b0000_1000);
    try w.int4(@bitCast(@as(i32, -9)));
    try w.lenencStr("x");
    var r = try RowReader.init(w.bytes(), true, 3);
    try t.expectEqual(TestValue{ .integer = -9 }, try r.next(TestValue, false, t.allocator, .long));
    try t.expectEqual(TestValue.null, try r.next(TestValue, false, t.allocator, .text));
    try t.expectEqualStrings("x", (try r.next(TestValue, false, t.allocator, .text)).text);

    try t.expectError(error.ProtocolViolation, RowReader.init(&.{ 1, 0 }, true, 1));
}

test "integer parsing edge cases" {
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), try parseInt("9223372036854775807"));
    try t.expectEqual(@as(i64, std.math.minInt(i64)), try parseInt("-9223372036854775808"));
    try t.expectEqual(@as(i64, 0), try parseInt("-0"));
    try t.expectError(error.Overflow, parseInt("9223372036854775808"));
    try t.expectError(error.InvalidCharacter, parseInt("-"));
    try t.expectError(error.InvalidCharacter, parseInt(""));
}

test "format floats round-trip" {
    var buf: [64]u8 = undefined;
    for ([_]f64{ 0.1, -2.5e-300, 1.7976931348623157e308, 3 }) |v| {
        try t.expectEqual(v, try std.fmt.parseFloat(f64, try formatFloat(&buf, v)));
    }
}
