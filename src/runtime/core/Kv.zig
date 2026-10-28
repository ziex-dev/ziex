/// A Key Value store
///
/// Use this to store small pieces of data that need to be shared across requests or persisted across restarts.
///
/// The default zx.kv implementation is a native filesystem based store,
/// stored inside configurable datadir/kv/
///
/// Builtin bindings are provided for WASI for
///
/// - Cloudflare: Workers KV
///
/// and you can implement your own bindings or storage backends if desired.
const Kv = @This();

const std = @import("std");

const zx = @import("../../root.zig");

userdata: ?*anyopaque = null,
vtable: *const VTable,
namespace: []const u8 = "default",

pub const Fs = @import("Kv/Fs.zig");
pub const Wasm = @import("Kv/Wasm.zig");

pub const VTable = struct {
    get: *const fn (userdata: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8,
    put: *const fn (userdata: ?*anyopaque, ns: []const u8, key: []const u8, value: []const u8, opts: PutOptions) anyerror!void,
    delete: *const fn (userdata: ?*anyopaque, ns: []const u8, key: []const u8) anyerror!void,
    list: *const fn (userdata: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, prefix: []const u8) anyerror![][]u8,
};

pub const PutOptions = struct {
    ttl: ?std.Io.Duration = null,
};

/// Stored values start with one metadata line per layer that adds one: a zxon
/// struct followed by `\n`, e.g. `[1,1730000000]\n`. The line never contains a
/// raw newline, so the value after it can hold any bytes. New fields are
/// appended with defaults so older lines still parse.
pub const Meta = struct {
    /// Upper bound for a metadata line, including the newline.
    pub const max_len = 64;

    /// Expiry, written by backends and caches that track it themselves.
    pub const Expiry = struct {
        version: u8 = 1,
        /// Unix seconds; 0 = never expires.
        expires_at: u64 = 0,
    };

    /// Schema hash for `putAs`/`as`.
    pub const Typed = struct {
        version: u8 = 1,
        hash: u64 = 0,
    };

    pub fn write(writer: *std.Io.Writer, meta: anytype) !void {
        try zx.util.zxon.serialize(meta, writer, .{});
        try writer.writeByte('\n');
    }

    /// Writes `meta` into `buf` and returns the line.
    pub fn line(buf: *[max_len]u8, meta: anytype) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        write(&w, meta) catch unreachable;
        return w.buffered();
    }

    pub fn Split(comptime T: type) type {
        return struct { meta: T, rest: []const u8 };
    }

    /// Parses the leading metadata line of `raw`; null when missing, malformed or
    /// from an unknown version.
    pub fn split(comptime T: type, raw: []const u8) ?Split(T) {
        const nl = std.mem.indexOfScalar(u8, raw[0..@min(raw.len, max_len)], '\n') orelse return null;
        // Metadata is numbers only, so parsing never allocates.
        var fba = std.heap.FixedBufferAllocator.init(&.{});
        const meta = zx.util.zxon.parse(T, fba.allocator(), raw[0..nl], .{}) catch return null;
        if (meta.version != (T{}).version) return null;
        return .{ .meta = meta, .rest = raw[nl + 1 ..] };
    }
};

pub const Error = error{
    GetFailed,
    PutFailed,
    DeleteFailed,
    InvalidType,
    InvalidResponse,
    KeyTooLong,
    Unavailable,
};

pub fn get(self: Kv, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    return self.vtable.get(self.userdata, self.namespace, allocator, key);
}

pub fn as(self: Kv, allocator: std.mem.Allocator, key: []const u8, comptime T: type) !?T {
    const raw = (try self.vtable.get(self.userdata, self.namespace, allocator, key) orelse return null);
    defer allocator.free(raw);
    return try decodeTyped(T, allocator, raw);
}

pub fn put(self: Kv, key: []const u8, value: []const u8, opts: PutOptions) !void {
    return self.vtable.put(self.userdata, self.namespace, key, value, opts);
}

pub fn putAs(self: Kv, key: []const u8, value: anytype, opts: PutOptions) !void {
    var writer = std.Io.Writer.Allocating.init(zx.allocator);
    defer writer.deinit();
    try encodeTyped(&writer.writer, value);
    return self.vtable.put(self.userdata, self.namespace, key, writer.written(), opts);
}

/// Writes `value` as a `Meta.Typed` line followed by its zxon encoding.
pub fn encodeTyped(writer: *std.Io.Writer, value: anytype) !void {
    try Meta.write(writer, Meta.Typed{ .hash = zx.util.zxon.schema(@TypeOf(value)).hash });
    try zx.util.zxon.serialize(value, writer, .{});
}

/// Reverse of `encodeTyped`; `error.InvalidType` when the line is missing or the schema differs.
pub fn decodeTyped(comptime T: type, allocator: std.mem.Allocator, raw: []const u8) !T {
    const typed = Meta.split(Meta.Typed, raw) orelse return error.InvalidType;
    if (typed.meta.hash != zx.util.zxon.schema(T).hash) return error.InvalidType;
    return zx.util.zxon.parse(T, allocator, typed.rest, .{});
}

pub fn delete(self: Kv, key: []const u8) !void {
    return self.vtable.delete(self.userdata, self.namespace, key);
}

pub fn list(self: Kv, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
    return self.vtable.list(self.userdata, self.namespace, allocator, prefix);
}

pub fn scoped(self: Kv, comptime ns: @EnumLiteral()) Kv {
    return .{ .userdata = self.userdata, .vtable = self.vtable, .namespace = @tagName(ns) };
}

fn failingGet(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
    return error.Unavailable;
}
fn failingPut(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: PutOptions) anyerror!void {
    return error.Unavailable;
}
fn failingDelete(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {
    return error.Unavailable;
}
fn failingList(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator, _: []const u8) anyerror![][]u8 {
    return error.Unavailable;
}

pub const failing_vtable = VTable{
    .get = &failingGet,
    .put = &failingPut,
    .delete = &failingDelete,
    .list = &failingList,
};

pub const failing = Kv{ .vtable = &failing_vtable };
