/// ZXON - Ziex Object Notation
///
/// A compact positional serialization format for Zig types. Structs are encoded
/// as ordered value arrays `[field1, field2, ...]` - field names are known at
/// comptime on both ends, so only values are transmitted.
///
/// Compared to `std.json`, this pulls in ~78 KB less code in WASM builds.
const zxon = @This();

const std = @import("std");

/// Options for serialize/parse - reserved for future use.
pub const Options = struct {};

/// Serialize `value` into ZXON positional format.
pub fn serialize(value: anytype, writer: *std.Io.Writer, options: Options) anyerror!void {
    _ = options;
    return writeValue(@TypeOf(value), value, writer);
}

fn writeValue(comptime T: type, value: T, w: *std.Io.Writer) anyerror!void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            try w.writeByte('[');
            inline for (s.field_names, s.field_types, 0..) |field_name, field_type, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(field_type, @field(value, field_name), w);
            }
            try w.writeByte(']');
        },
        .optional => |opt| {
            if (value) |v| try writeValue(opt.child, v, w) else try w.writeAll("null");
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writeStr(w, value);
            } else if (ptr.size == .slice) {
                try w.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try w.writeByte(',');
                    try writeValue(ptr.child, item, w);
                }
                try w.writeByte(']');
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                try writeStrLiteral(w, value);
            } else {
                try w.writeAll("null");
            }
        },
        .array => |arr| {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(arr.child, item, w);
            }
            try w.writeByte(']');
        },
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => try w.print("{d}", .{value}),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .@"enum" => try w.print("{d}", .{@backingInt(value)}),
        else => try w.writeAll("null"),
    }
}

fn writeStr(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |c| try escapeByte(w, c);
    try w.writeByte('"');
}

fn writeStrLiteral(w: *std.Io.Writer, value: anytype) !void {
    try w.writeByte('"');
    for (value) |c| {
        if (c == 0) break;
        try escapeByte(w, c);
    }
    try w.writeByte('"');
}

inline fn escapeByte(w: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

/// Parse a ZXON-encoded `string` into a value of type `T`.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, data: []const u8, options: Options) !T {
    _ = options;
    var pos: usize = 0;
    skip(data, &pos);
    return readValue(T, allocator, data, &pos);
}

fn readValue(comptime T: type, allocator: std.mem.Allocator, d: []const u8, p: *usize) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (peek(d, p) != '[') return error.ExpectedArrayStart;
            p.* += 1;
            skip(d, p);

            var result: T = undefined;
            var filling_defaults = false;
            inline for (s.field_names, s.field_types, s.field_attrs, 0..) |field_name, field_type, field_attr, i| {
                skip(d, p);
                if (filling_defaults or peek(d, p) == ']') {
                    filling_defaults = true;
                    if (field_attr.defaultValue(field_type)) |default_value| {
                        @field(result, field_name) = default_value;
                    } else {
                        return error.MissingRequiredField;
                    }
                } else {
                    if (i > 0) {
                        if (peek(d, p) != ',') return error.ExpectedComma;
                        p.* += 1;
                        skip(d, p);
                    }
                    @field(result, field_name) = try readValue(field_type, allocator, d, p);
                }
            }

            skip(d, p);
            if (peek(d, p) != ']') return error.ExpectedArrayEnd;
            p.* += 1;
            return result;
        },
        .optional => |opt| {
            if (literal(d, p, "null")) return null;
            return try readValue(opt.child, allocator, d, p);
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) return error.UnsupportedType;
            if (ptr.child == u8) return readStr(allocator, d, p);
            return readSlice(ptr.child, allocator, d, p);
        },
        .array => |arr| {
            if (peek(d, p) != '[') return error.ExpectedArrayStart;
            p.* += 1;
            skip(d, p);

            var result: T = undefined;
            for (&result, 0..) |*item, i| {
                if (i > 0) comma(d, p);
                item.* = try readValue(arr.child, allocator, d, p);
            }

            skip(d, p);
            if (peek(d, p) != ']') return error.ExpectedArrayEnd;
            p.* += 1;
            return result;
        },
        .int => return readInt(T, d, p),
        .float => return readFloat(T, d, p),
        .bool => {
            if (literal(d, p, "true")) return true;
            if (literal(d, p, "false")) return false;
            return false;
        },
        .@"enum" => |e| return @fromBackingInt(@intCast(readInt(e.tag_type, d, p) catch 0)),
        else => return error.UnsupportedType,
    }
}

fn readSlice(comptime Child: type, allocator: std.mem.Allocator, d: []const u8, p: *usize) anyerror![]Child {
    if (peek(d, p) != '[') return error.ExpectedArrayStart;
    p.* += 1;
    skip(d, p);

    if (peek(d, p) == ']') {
        p.* += 1;
        return try allocator.alloc(Child, 0);
    }

    var list = std.array_list.Managed(Child).init(allocator);
    errdefer list.deinit();

    while (p.* < d.len) {
        try list.append(try readValue(Child, allocator, d, p));
        skip(d, p);

        if (peek(d, p) == ',') {
            p.* += 1;
            skip(d, p);
        } else if (peek(d, p) == ']') {
            p.* += 1;
            return list.toOwnedSlice();
        } else {
            return error.ExpectedArrayEnd;
        }
    }
    return error.UnexpectedEnd;
}

fn readStr(allocator: std.mem.Allocator, d: []const u8, p: *usize) ![]u8 {
    if (peek(d, p) != '"') return error.ExpectedString;
    p.* += 1;

    const start = p.*;
    var has_escapes = false;

    while (p.* < d.len and d[p.*] != '"') {
        if (d[p.*] == '\\') {
            has_escapes = true;
            p.* += 2;
        } else {
            p.* += 1;
        }
    }

    const end = p.*;
    if (p.* < d.len) p.* += 1; // closing quote

    if (!has_escapes) return allocator.dupe(u8, d[start..end]);

    var out: std.ArrayList(u8) = try .initCapacity(allocator, end - start);
    errdefer out.deinit(allocator);
    var i = start;
    while (i < end) {
        if (d[i] != '\\' or i + 1 >= end) {
            out.appendAssumeCapacity(d[i]);
            i += 1;
            continue;
        }
        const e = d[i + 1];
        i += 2;
        if (e == 'u') {
            var cp: u21 = try hex4(d, i, end);
            i += 4;
            if (cp >= 0xd800 and cp <= 0xdbff and i + 6 <= end and d[i] == '\\' and d[i + 1] == 'u') {
                const lo = try hex4(d, i + 2, end);
                if (lo >= 0xdc00 and lo <= 0xdfff) {
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                    i += 6;
                }
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xfffd, &buf) catch unreachable;
            try out.appendSlice(allocator, buf[0..n]);
            continue;
        }
        out.appendAssumeCapacity(switch (e) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'b' => 0x08,
            'f' => 0x0c,
            else => e,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn hex4(d: []const u8, at: usize, end: usize) !u21 {
    if (at + 4 > end) return error.InvalidEscape;
    return std.fmt.parseInt(u16, d[at..][0..4], 16) catch error.InvalidEscape;
}

fn readInt(comptime T: type, d: []const u8, p: *usize) !T {
    skip(d, p);
    const start = p.*;

    if (peek(d, p) == '-') p.* += 1;
    while (p.* < d.len and d[p.*] >= '0' and d[p.*] <= '9') p.* += 1;

    if (p.* == start or (d[start] == '-' and p.* == start + 1)) return 0;
    return std.fmt.parseInt(T, d[start..p.*], 10) catch 0;
}

fn readFloat(comptime T: type, d: []const u8, p: *usize) !T {
    skip(d, p);
    const start = p.*;

    if (peek(d, p) == '-') p.* += 1;
    while (p.* < d.len) {
        switch (d[p.*]) {
            '0'...'9', '.', 'e', 'E', '+', '-' => p.* += 1,
            else => break,
        }
    }

    if (p.* == start) return 0;
    return std.fmt.parseFloat(T, d[start..p.*]) catch 0;
}

fn peek(d: []const u8, p: *const usize) u8 {
    return if (p.* < d.len) d[p.*] else 0;
}

fn skip(d: []const u8, p: *usize) void {
    while (p.* < d.len) {
        switch (d[p.*]) {
            ' ', '\t', '\n', '\r' => p.* += 1,
            else => break,
        }
    }
}

fn comma(d: []const u8, p: *usize) void {
    skip(d, p);
    if (peek(d, p) == ',') p.* += 1;
    skip(d, p);
}

fn literal(d: []const u8, p: *usize, lit: []const u8) bool {
    if (p.* + lit.len <= d.len and std.mem.eql(u8, d[p.*..][0..lit.len], lit)) {
        p.* += lit.len;
        return true;
    }
    return false;
}

/// Returns a comptime structural schema descriptor for `T`.
/// The hash uniquely identifies the field-name / type structure so that
/// mismatched serializer–parser pairs can be detected.
pub fn schema(comptime T: type) struct { hash: u64 } {
    return comptime .{ .hash = computeHash(T) };
}

fn computeHash(comptime T: type) u64 {
    comptime {
        const s = typeSignature(T);
        var hash: u64 = 14695981039346656037; // FNV-1a offset basis
        for (s) |b| {
            hash ^= b;
            hash *%= 1099511628211;
        }
        return hash;
    }
}

fn typeSignature(comptime T: type) []const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                var r: []const u8 = "struct{";
                for (s.field_names, s.field_types) |f_name, f_type| r = r ++ f_name ++ ":" ++ typeSignature(f_type) ++ ";";
                break :blk r ++ "}";
            },
            .optional => |opt| "?" ++ typeSignature(opt.child),
            .pointer => |ptr| if (ptr.size == .slice) "[]" ++ typeSignature(ptr.child) else "*" ++ typeSignature(ptr.child),
            .array => |arr| "[N]" ++ typeSignature(arr.child),
            else => @typeName(T),
        };
    }
}
