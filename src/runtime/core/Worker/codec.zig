// Binary codec for worker calls. Both ends are the same wasm32 build of the same
// types, so pointer-free values are copied as raw bytes; only slices, pointers,
// optionals and unions are walked. Lengths are u32.
const std = @import("std");

pub const Error = std.Io.Writer.Error;
pub const DecodeError = std.Io.Reader.Error || std.mem.Allocator.Error || error{InvalidData};

pub fn encode(w: *std.Io.Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime isPlain(T)) return w.writeAll(std.mem.asBytes(&value));
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => try encode(w, value.*),
            .slice => {
                try w.writeAll(std.mem.asBytes(&@as(u32, @intCast(value.len))));
                if (comptime isPlain(p.child)) {
                    try w.writeAll(std.mem.sliceAsBytes(value));
                } else for (value) |item| try encode(w, item);
            },
            else => @compileError("worker: unsupported pointer type " ++ @typeName(T)),
        },
        .array => for (value) |item| try encode(w, item),
        .optional => if (value) |v| {
            try w.writeByte(1);
            try encode(w, v);
        } else try w.writeByte(0),
        .@"struct" => |s| inline for (s.field_names, s.field_attrs) |name, attr| {
            if (!attr.@"comptime") try encode(w, @field(value, name));
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("worker: untagged union " ++ @typeName(T));
            const tag = std.meta.activeTag(value);
            try encode(w, tag);
            switch (value) {
                inline else => |payload| try encode(w, payload),
            }
        },
        else => @compileError("worker: cannot send " ++ @typeName(T)),
    }
}

// Pointers in the result are allocated with `gpa`.
pub fn decode(comptime T: type, r: *std.Io.Reader, gpa: std.mem.Allocator) DecodeError!T {
    if (comptime isPlain(T)) {
        var value: T = undefined;
        try r.readSliceAll(std.mem.asBytes(&value));
        return value;
    }
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => {
                const ptr = try gpa.create(p.child);
                errdefer gpa.destroy(ptr);
                ptr.* = try decode(p.child, r, gpa);
                return ptr;
            },
            .slice => {
                var len: u32 = undefined;
                try r.readSliceAll(std.mem.asBytes(&len));
                const items = if (p.sentinel()) |s|
                    try gpa.allocSentinel(p.child, len, s)
                else
                    try gpa.alloc(p.child, len);
                errdefer gpa.free(items);
                if (comptime isPlain(p.child)) {
                    try r.readSliceAll(std.mem.sliceAsBytes(items));
                } else for (items) |*item| {
                    item.* = try decode(p.child, r, gpa);
                }
                return items;
            },
            else => @compileError("worker: unsupported pointer type " ++ @typeName(T)),
        },
        .array => |a| {
            var value: T = undefined;
            for (&value) |*item| item.* = try decode(a.child, r, gpa);
            return value;
        },
        .optional => |o| return switch (try r.takeByte()) {
            0 => null,
            1 => try decode(o.child, r, gpa),
            else => error.InvalidData,
        },
        .@"struct" => |s| {
            var value: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attr| {
                if (!attr.@"comptime") @field(value, name) = try decode(FT, r, gpa);
            }
            return value;
        },
        .@"union" => |u| {
            const tag = try decode(u.tag_type.?, r, gpa);
            switch (tag) {
                inline else => |t| return @unionInit(T, @tagName(t), try decode(@FieldType(T, @tagName(t)), r, gpa)),
            }
        },
        else => @compileError("worker: cannot receive " ++ @typeName(T)),
    }
}

// Copyable as raw bytes: no pointers anywhere, and every bit pattern written is valid on the other end.
pub fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => true,
        .array => |a| isPlain(a.child),
        .@"struct" => |s| {
            if (s.layout == .@"packed") return true;
            for (s.field_types, s.field_attrs) |FT, attr| if (attr.@"comptime" or !isPlain(FT)) return false;
            return true;
        },
        else => false,
    };
}

test "plain values round-trip as raw bytes" {
    const P = struct { a: u8, b: f64, c: [3]i16, e: enum { x, y } };
    const v: P = .{ .a = 7, .b = 1.5, .c = .{ 1, -2, 3 }, .e = .y };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encode(&w, v);
    try std.testing.expectEqual(@sizeOf(P), w.end);
    var r = std.Io.Reader.fixed(w.buffered());
    try std.testing.expectEqual(v, try decode(P, &r, std.testing.failing_allocator));
}

test "slices, optionals, unions and nested structs" {
    const U = union(enum) { n: u32, s: []const u8 };
    const T = struct {
        name: []const u8,
        tags: []const []const u8,
        maybe: ?u16,
        none: ?[]const u8,
        u: U,
        z: [:0]const u8,
    };
    const v: T = .{ .name = "héllo", .tags = &.{ "a", "", "ccc" }, .maybe = 9, .none = null, .u = .{ .s = "x" }, .z = "zz" };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(&aw.writer, v);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = std.Io.Reader.fixed(aw.written());
    const got = try decode(T, &r, arena.allocator());
    try std.testing.expectEqualStrings("héllo", got.name);
    try std.testing.expectEqual(@as(usize, 3), got.tags.len);
    try std.testing.expectEqualStrings("ccc", got.tags[2]);
    try std.testing.expectEqual(@as(?u16, 9), got.maybe);
    try std.testing.expectEqual(@as(?[]const u8, null), got.none);
    try std.testing.expectEqualStrings("x", got.u.s);
    try std.testing.expectEqualStrings("zz", got.z);
    try std.testing.expectEqual(@as(u8, 0), got.z.ptr[2]);
}

test "truncated input fails instead of reading garbage" {
    var r = std.Io.Reader.fixed(&.{ 5, 0, 0, 0, 'a' });
    try std.testing.expectError(error.EndOfStream, decode([]const u8, &r, std.testing.allocator));
}
