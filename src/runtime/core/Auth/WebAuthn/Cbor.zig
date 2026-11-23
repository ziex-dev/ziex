// Just enough CBOR (RFC 8949) to read WebAuthn attestation objects and COSE keys.
// Authenticators only emit definite lengths, so indefinite ones are rejected.
const Cbor = @This();

const std = @import("std");

data: []const u8,
pos: usize = 0,

pub const Error = error{ InvalidCbor, UnexpectedEnd };

pub const Item = union(enum) {
    int: i64,
    bytes: []const u8,
    text: []const u8,
    // Containers carry their element (or pair) count; the elements follow.
    array: usize,
    map: usize,
    simple: u8,
};

// Bounds `skip`, so hostile nesting can't exhaust the stack.
const max_depth = 16;

pub fn next(r: *Cbor) Error!Item {
    const head = try r.byte();
    const arg = try r.argument(@truncate(head));
    return switch (head >> 5) {
        0 => .{ .int = std.math.cast(i64, arg) orelse return error.InvalidCbor },
        1 => .{ .int = -1 - (std.math.cast(i64, arg) orelse return error.InvalidCbor) },
        2 => .{ .bytes = try r.take(arg) },
        3 => .{ .text = try r.take(arg) },
        4 => .{ .array = try r.count(arg, 1) },
        5 => .{ .map = try r.count(arg, 2) },
        7 => .{ .simple = std.math.cast(u8, arg) orelse return error.InvalidCbor },
        else => error.InvalidCbor,
    };
}

pub fn expect(r: *Cbor, comptime tag: std.meta.Tag(Item)) Error!@FieldType(Item, @tagName(tag)) {
    const item = try r.next();
    return if (item == tag) @field(item, @tagName(tag)) else error.InvalidCbor;
}

pub fn skip(r: *Cbor) Error!void {
    return r.skipDepth(0);
}

fn skipDepth(r: *Cbor, depth: usize) Error!void {
    if (depth > max_depth) return error.InvalidCbor;
    switch (try r.next()) {
        .array => |n| for (0..n) |_| try r.skipDepth(depth + 1),
        .map => |n| for (0..n * 2) |_| try r.skipDepth(depth + 1),
        else => {},
    }
}

// Every element takes at least a byte, so a count beyond what is left is a lie;
// refusing it up front also keeps `n * 2` from overflowing.
fn count(r: *Cbor, arg: u64, per_entry: u64) Error!usize {
    if (arg > (r.data.len - r.pos) / per_entry) return error.UnexpectedEnd;
    return @intCast(arg);
}

fn byte(r: *Cbor) Error!u8 {
    return (try r.take(1))[0];
}

fn take(r: *Cbor, len: u64) Error![]const u8 {
    if (len > r.data.len - r.pos) return error.UnexpectedEnd;
    const n: usize = @intCast(len);
    defer r.pos += n;
    return r.data[r.pos..][0..n];
}

fn argument(r: *Cbor, info: u5) Error!u64 {
    return switch (info) {
        0...23 => info,
        24 => try r.byte(),
        25 => std.mem.readInt(u16, (try r.take(2))[0..2], .big),
        26 => std.mem.readInt(u32, (try r.take(4))[0..4], .big),
        27 => std.mem.readInt(u64, (try r.take(8))[0..8], .big),
        else => error.InvalidCbor,
    };
}
