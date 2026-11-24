// Type OIDs and text-format value decoding.
const std = @import("std");

pub const Oid = struct {
    pub const unspecified: u32 = 0;
    pub const boolean: u32 = 16;
    pub const bytea: u32 = 17;
    pub const char: u32 = 18;
    pub const name: u32 = 19;
    pub const int8: u32 = 20;
    pub const int2: u32 = 21;
    pub const int4: u32 = 23;
    pub const text: u32 = 25;
    pub const oid: u32 = 26;
    pub const json: u32 = 114;
    pub const float4: u32 = 700;
    pub const float8: u32 = 701;
    pub const bpchar: u32 = 1042;
    pub const varchar: u32 = 1043;
    pub const date: u32 = 1082;
    pub const time: u32 = 1083;
    pub const timestamp: u32 = 1114;
    pub const timestamptz: u32 = 1184;
    pub const numeric: u32 = 1700;
    pub const uuid: u32 = 2950;
    pub const jsonb: u32 = 3802;
};

/// `ColumnType` must have the tags integer, float, text, blob, unknown.
pub fn columnType(comptime ColumnType: type, oid: u32) ColumnType {
    return switch (oid) {
        Oid.int2, Oid.int4, Oid.int8, Oid.oid => .integer,
        Oid.float4, Oid.float8 => .float,
        Oid.bytea => .blob,
        Oid.text, Oid.varchar, Oid.bpchar, Oid.char, Oid.name, Oid.json, Oid.jsonb, Oid.uuid => .text,
        else => .unknown,
    };
}

/// Types whose binary wire format we decode; requested in binary when the column types are known.
pub fn binaryResult(oid: u32) bool {
    return switch (oid) {
        Oid.boolean, Oid.int2, Oid.int4, Oid.int8, Oid.oid, Oid.float4, Oid.float8 => true,
        else => false,
    };
}

/// Decode a text-format column into `Value` (null/integer/float/text/blob/boolean).
/// Text and blob payloads are allocated with `gpa`.
pub fn decodeText(comptime Value: type, gpa: std.mem.Allocator, oid: u32, bytes: ?[]const u8) !Value {
    return decode(Value, true, false, gpa, oid, bytes);
}

/// Per-column decoder, resolved once from (oid, binary) so rows take a single switch.
pub const Kind = enum { boolean_bin, int2_bin, int4_bin, int8_bin, oid_bin, float4_bin, float8_bin, boolean, integer, float, bytea, text };

pub fn kindOf(oid: u32, binary: bool) Kind {
    if (binary) switch (oid) {
        Oid.boolean => return .boolean_bin,
        Oid.int2 => return .int2_bin,
        Oid.int4 => return .int4_bin,
        Oid.int8 => return .int8_bin,
        Oid.oid => return .oid_bin,
        Oid.float4 => return .float4_bin,
        Oid.float8 => return .float8_bin,
        else => {},
    };
    return switch (oid) {
        Oid.boolean => .boolean,
        Oid.int2, Oid.int4, Oid.int8, Oid.oid => .integer,
        Oid.float4, Oid.float8 => .float,
        Oid.bytea => .bytea,
        else => .text,
    };
}

/// Decode a column that may be in binary format (when `binary` and `binaryResult(oid)`).
/// With `copy` false, text borrows `bytes`; bytea is always decoded into `gpa`.
pub fn decode(comptime Value: type, comptime copy: bool, binary: bool, gpa: std.mem.Allocator, oid: u32, bytes: ?[]const u8) !Value {
    return decodeKind(Value, copy, gpa, kindOf(oid, binary), bytes);
}

pub inline fn decodeKind(comptime Value: type, comptime copy: bool, gpa: std.mem.Allocator, kind: Kind, bytes: ?[]const u8) !Value {
    const data = bytes orelse return .null;
    return switch (kind) {
        .boolean_bin => .{ .boolean = (try fixed(1, data))[0] != 0 },
        .int2_bin => .{ .integer = std.mem.readInt(i16, try fixed(2, data), .big) },
        .int4_bin => .{ .integer = std.mem.readInt(i32, try fixed(4, data), .big) },
        .oid_bin => .{ .integer = std.mem.readInt(u32, try fixed(4, data), .big) },
        .int8_bin => .{ .integer = std.mem.readInt(i64, try fixed(8, data), .big) },
        .float4_bin => .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, try fixed(4, data), .big))) },
        .float8_bin => .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, try fixed(8, data), .big))) },
        .boolean => .{ .boolean = data.len > 0 and data[0] == 't' },
        .integer => .{ .integer = try parseInt(data) },
        .float => .{ .float = try parseFloat(data) },
        .bytea => .{ .blob = try decodeBytea(gpa, data) },
        .text => .{ .text = if (copy) try gpa.dupe(u8, data) else data },
    };
}

fn fixed(comptime n: usize, data: []const u8) !*const [n]u8 {
    if (data.len != n) return error.InvalidBinaryValue;
    return data[0..n];
}

/// Postgres integer text: optional '-', then digits. Faster than std.fmt.parseInt (no base/underscores).
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

fn parseFloat(data: []const u8) !f64 {
    if (std.mem.eql(u8, data, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, data, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, data);
}

/// bytea text output: hex (`\x0a1b`) or, for old servers, escape format.
fn decodeBytea(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, data, "\\x")) {
        const hex = data[2..];
        if (hex.len % 2 != 0) return error.InvalidBytea;
        const out = try gpa.alloc(u8, hex.len / 2);
        errdefer gpa.free(out);
        _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidBytea;
        return out;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] != '\\') {
            try out.append(gpa, data[i]);
            i += 1;
        } else if (i + 1 < data.len and data[i + 1] == '\\') {
            try out.append(gpa, '\\');
            i += 2;
        } else if (i + 3 < data.len) {
            try out.append(gpa, std.fmt.parseInt(u8, data[i + 1 .. i + 4], 8) catch return error.InvalidBytea);
            i += 4;
        } else return error.InvalidBytea;
    }
    return out.toOwnedSlice(gpa);
}

/// Text form of a float that the server parses back exactly.
pub fn formatFloat(buf: []u8, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isInf(value)) return if (value > 0) "Infinity" else "-Infinity";
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

test "decode text values" {
    try t.expectEqual(TestValue.null, try decodeText(TestValue, t.allocator, Oid.int4, null));
    try t.expectEqual(TestValue{ .integer = -42 }, try decodeText(TestValue, t.allocator, Oid.int8, "-42"));
    try t.expectEqual(TestValue{ .boolean = true }, try decodeText(TestValue, t.allocator, Oid.boolean, "t"));
    try t.expectEqual(TestValue{ .boolean = false }, try decodeText(TestValue, t.allocator, Oid.boolean, "f"));
    try t.expectEqual(TestValue{ .float = 1.5 }, try decodeText(TestValue, t.allocator, Oid.float8, "1.5"));
    try t.expect(std.math.isNan((try decodeText(TestValue, t.allocator, Oid.float8, "NaN")).float));
    try t.expect(std.math.isNegativeInf((try decodeText(TestValue, t.allocator, Oid.float4, "-Infinity")).float));

    const numeric = try decodeText(TestValue, t.allocator, Oid.numeric, "12345678901234567890.5");
    defer t.allocator.free(numeric.text);
    try t.expectEqualStrings("12345678901234567890.5", numeric.text);
}

test "decode binary values" {
    try t.expectEqual(TestValue{ .integer = -2 }, try decode(TestValue, false, true, t.allocator, Oid.int4, "\xff\xff\xff\xfe"));
    try t.expectEqual(TestValue{ .integer = 258 }, try decode(TestValue, false, true, t.allocator, Oid.int2, "\x01\x02"));
    try t.expectEqual(TestValue{ .integer = std.math.minInt(i64) }, try decode(TestValue, false, true, t.allocator, Oid.int8, "\x80\x00\x00\x00\x00\x00\x00\x00"));
    try t.expectEqual(TestValue{ .float = 1.5 }, try decode(TestValue, false, true, t.allocator, Oid.float8, "\x3f\xf8\x00\x00\x00\x00\x00\x00"));
    try t.expectEqual(TestValue{ .float = -0.25 }, try decode(TestValue, false, true, t.allocator, Oid.float4, "\xbe\x80\x00\x00"));
    try t.expectEqual(TestValue{ .boolean = true }, try decode(TestValue, false, true, t.allocator, Oid.boolean, "\x01"));
    try t.expectError(error.InvalidBinaryValue, decode(TestValue, false, true, t.allocator, Oid.int4, "\x01"));
    // text-only types ignore the binary flag
    try t.expectEqualStrings("x", (try decode(TestValue, false, true, t.allocator, Oid.text, "x")).text);
}

test "integer parsing edge cases" {
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), try parseInt("9223372036854775807"));
    try t.expectEqual(@as(i64, std.math.minInt(i64)), try parseInt("-9223372036854775808"));
    try t.expectEqual(@as(i64, 0), try parseInt("-0"));
    try t.expectError(error.Overflow, parseInt("9223372036854775808"));
    try t.expectError(error.InvalidCharacter, parseInt("-"));
    try t.expectError(error.InvalidCharacter, parseInt("1_000"));
    try t.expectError(error.InvalidCharacter, parseInt(""));
}

test "decode bytea hex and escape formats" {
    const hex = try decodeText(TestValue, t.allocator, Oid.bytea, "\\x00ff10");
    defer t.allocator.free(hex.blob);
    try t.expectEqualSlices(u8, &.{ 0x00, 0xff, 0x10 }, hex.blob);

    const esc = try decodeText(TestValue, t.allocator, Oid.bytea, "a\\\\b\\000");
    defer t.allocator.free(esc.blob);
    try t.expectEqualSlices(u8, "a\\b\x00", esc.blob);

    try t.expectError(error.InvalidBytea, decodeText(TestValue, t.allocator, Oid.bytea, "\\x0"));
}

test "format floats round-trip" {
    var buf: [64]u8 = undefined;
    for ([_]f64{ 0.1, -2.5e-300, 1.7976931348623157e308, 3 }) |v| {
        try t.expectEqual(v, try std.fmt.parseFloat(f64, try formatFloat(&buf, v)));
    }
    try t.expectEqualStrings("NaN", try formatFloat(&buf, std.math.nan(f64)));
    try t.expectEqualStrings("-Infinity", try formatFloat(&buf, -std.math.inf(f64)));
}
