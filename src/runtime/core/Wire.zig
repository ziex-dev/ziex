const Wire = @This();

const std = @import("std");

pub const magic: u32 = 0x3142445a;

pub const Kind = enum(u8) {
    records = 1,
    pair = 2,
    rows = 3,
    args = 4,
    strings = 5,
};

pub const Tag = enum(u8) {
    null = 0,
    integer = 1,
    float = 2,
    text = 3,
    blob = 4,
    boolean = 5,
};

pub const Value = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    boolean: bool,

    pub fn of(value: anytype) Value {
        const T = @TypeOf(value);
        if (T == Value) return value;

        return switch (@typeInfo(T)) {
            .null => .null,
            .bool => .{ .boolean = value },
            .int, .comptime_int => .{ .integer = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            .optional => if (value) |inner| Value.of(inner) else .null,
            .pointer, .array => .{ .text = stringBytes(value) },
            else => @compileError("Db bindings: unsupported value type " ++ @typeName(T)),
        };
    }
};

fn stringBytes(value: anytype) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) return value,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| if (arr.child == u8) return value,
                else => {},
            },
            else => {},
        },
        .array => |arr| if (arr.child == u8) return &value,
        else => {},
    }
    @compileError("Db bindings: expected []const u8 / string for text value, got " ++ @typeName(T));
}

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Record = struct {
    fields: []const Field,
};

pub const Pair = struct {
    a: i64,
    b: i64,
};

pub const Args = union(enum) {
    none,
    list: []const Value,
};

fn header(w: *std.Io.Writer, kind: Kind) !void {
    try w.writeInt(u32, magic, .little);
    try w.writeByte(@backingInt(kind));
}

fn expect(r: *std.Io.Reader, kind: Kind) !void {
    if (try r.takeInt(u32, .little) != magic) return error.BadMagic;
    if (try r.takeEnum(Kind, .little) != kind) return error.BadKind;
}

fn writeLenBytes(w: *std.Io.Writer, comptime Len: type, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(Len)) return error.Unsupported;
    try w.writeInt(Len, @intCast(bytes.len), .little);
    try w.writeAll(bytes);
}

fn takeLenBytes(r: *std.Io.Reader, comptime Len: type) ![]const u8 {
    return r.take(try r.takeInt(Len, .little));
}

pub fn writeValue(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try w.writeByte(@backingInt(Tag.null)),
        .integer => |v| {
            try w.writeByte(@backingInt(Tag.integer));
            try w.writeInt(i64, v, .little);
        },
        .float => |v| {
            try w.writeByte(@backingInt(Tag.float));
            try w.writeInt(u64, @bitCast(v), .little);
        },
        .text => |v| {
            try w.writeByte(@backingInt(Tag.text));
            try writeLenBytes(w, u32, v);
        },
        .blob => |v| {
            try w.writeByte(@backingInt(Tag.blob));
            try writeLenBytes(w, u32, v);
        },
        .boolean => |v| {
            try w.writeByte(@backingInt(Tag.boolean));
            try w.writeByte(@intFromBool(v));
        },
    }
}

pub fn readValue(r: *std.Io.Reader, gpa: std.mem.Allocator) !Value {
    return switch (try r.takeEnum(Tag, .little)) {
        .null => .null,
        .integer => .{ .integer = try r.takeInt(i64, .little) },
        .float => .{ .float = @bitCast(try r.takeInt(u64, .little)) },
        .text => .{ .text = try gpa.dupe(u8, try takeLenBytes(r, u32)) },
        .blob => .{ .blob = try gpa.dupe(u8, try takeLenBytes(r, u32)) },
        .boolean => .{ .boolean = (try r.takeByte()) != 0 },
    };
}

pub fn encodePair(w: *std.Io.Writer, a: i64, b: i64) !void {
    try header(w, .pair);
    try w.writeInt(i64, a, .little);
    try w.writeInt(i64, b, .little);
}

pub fn decodePair(bytes: []const u8) !Pair {
    var r = std.Io.Reader.fixed(bytes);
    try expect(&r, .pair);
    return .{ .a = try r.takeInt(i64, .little), .b = try r.takeInt(i64, .little) };
}

pub fn encodeStrings(w: *std.Io.Writer, items: []const []const u8) !void {
    try header(w, .strings);
    try w.writeInt(u32, @intCast(items.len), .little);
    for (items) |s| try writeLenBytes(w, u32, s);
}

pub fn decodeStrings(gpa: std.mem.Allocator, bytes: []const u8) ![][]u8 {
    var r = std.Io.Reader.fixed(bytes);
    try expect(&r, .strings);
    const n = try r.takeInt(u32, .little);
    const out = try gpa.alloc([]u8, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (out) |*slot| {
        slot.* = try gpa.dupe(u8, try takeLenBytes(&r, u32));
        filled += 1;
    }
    return out;
}

pub fn encodeRecords(w: *std.Io.Writer, columns: []const []const u8, rows: []const []const Value) !void {
    try header(w, .records);
    try w.writeInt(u32, @intCast(columns.len), .little);
    try w.writeInt(u32, @intCast(rows.len), .little);
    for (columns) |col| try writeLenBytes(w, u16, col);
    for (rows) |row| {
        if (row.len != columns.len) return error.Unsupported;
        for (row) |cell| try writeValue(w, cell);
    }
}

pub fn decodeRecords(gpa: std.mem.Allocator, bytes: []const u8) ![]const Record {
    var r = std.Io.Reader.fixed(bytes);
    try expect(&r, .records);
    const ncols = try r.takeInt(u32, .little);
    const nrows = try r.takeInt(u32, .little);
    if (nrows == 0) return &.{};

    const names = try gpa.alloc([]const u8, ncols);
    errdefer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |*n| n.* = try gpa.dupe(u8, try takeLenBytes(&r, u16));

    const records = try gpa.alloc(Record, nrows);
    errdefer gpa.free(records);
    for (records) |*rec| {
        const fields = try gpa.alloc(Field, ncols);
        for (fields, names) |*f, name| f.* = .{ .name = name, .value = try readValue(&r, gpa) };
        rec.* = .{ .fields = fields };
    }
    gpa.free(names);
    return records;
}

pub fn encodeRows(w: *std.Io.Writer, rows: []const []const Value) !void {
    try header(w, .rows);
    try w.writeInt(u32, @intCast(rows.len), .little);
    for (rows) |row| {
        try w.writeInt(u32, @intCast(row.len), .little);
        for (row) |cell| try writeValue(w, cell);
    }
}

pub fn decodeRows(gpa: std.mem.Allocator, bytes: []const u8) ![]const []const Value {
    var r = std.Io.Reader.fixed(bytes);
    try expect(&r, .rows);
    const nrows = try r.takeInt(u32, .little);
    const out = try gpa.alloc([]const Value, nrows);
    for (out) |*row| {
        const ncols = try r.takeInt(u32, .little);
        const cells = try gpa.alloc(Value, ncols);
        for (cells) |*cell| cell.* = try readValue(&r, gpa);
        row.* = cells;
    }
    return out;
}

pub fn encodeArgs(w: *std.Io.Writer, args: Args) !void {
    try header(w, .args);
    switch (args) {
        .none => try w.writeByte(0),
        .list => |values| {
            try w.writeByte(1);
            try w.writeInt(u32, @intCast(values.len), .little);
            for (values) |v| try writeValue(w, v);
        },
    }
}

pub fn decodeArgs(gpa: std.mem.Allocator, bytes: []const u8) ![]const Value {
    var r = std.Io.Reader.fixed(bytes);
    try expect(&r, .args);
    switch (try r.takeByte()) {
        0 => return &.{},
        1 => {
            const n = try r.takeInt(u32, .little);
            const values = try gpa.alloc(Value, n);
            for (values) |*v| v.* = try readValue(&r, gpa);
            return values;
        },
        else => return error.Unsupported,
    }
}
