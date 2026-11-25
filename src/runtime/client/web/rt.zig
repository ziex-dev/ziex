//! Conversions used by the generated bindings in `generated.zig`.
const std = @import("std");
const js = @import("../js.zig");
const gpa_ = js.gpa_;

/// String result slot written by JS; `len == null_len` means null.
pub const Str = extern struct { ptr: u32 = 0, len: u32 = 0 };
const null_len = std.math.maxInt(u32);

/// Handle of a generated interface, `js.Value`, `js.Object`, or null.
pub fn h(x: anytype) u32 {
    const T = @TypeOf(x);
    if (T == js.Value) return @backingInt(x);
    if (T == js.Object) return @backingInt(x.value);
    if (T == @TypeOf(null)) return @backingInt(js.Value.null);
    switch (@typeInfo(T)) {
        .optional => return if (x) |v| h(v) else @backingInt(js.Value.null),
        .@"struct" => if (@hasField(T, "h")) return @backingInt(x.h),
        else => {},
    }
    @compileError("expected a web interface, js.Value or js.Object, got " ++ @typeName(T));
}

pub fn cb(x: anytype) u32 {
    return switch (@typeInfo(@TypeOf(x))) {
        .optional => if (x) |c| c.id else 0,
        else => x.id,
    };
}

pub const Buf = struct { ptr: [*]const u8, len: usize };

/// Typed-array / BufferSource argument: any slice or array pointer, viewed as
/// bytes without copying. `null` means absent.
pub fn buf(x: anytype) Buf {
    const T = @TypeOf(x);
    const absent: Buf = .{ .ptr = "".ptr, .len = null_len };
    if (T == @TypeOf(null)) return absent;
    switch (@typeInfo(T)) {
        .optional => return if (x) |v| buf(v) else absent,
        .pointer => |p| switch (p.size) {
            .slice => {
                const b = std.mem.sliceAsBytes(x);
                return .{ .ptr = b.ptr, .len = b.len };
            },
            .one => {
                const b = std.mem.asBytes(x);
                return .{ .ptr = b.ptr, .len = b.len };
            },
            else => {},
        },
        else => {},
    }
    @compileError("expected a slice for a buffer argument, got " ++ @typeName(T));
}

pub fn sp(x: ?[]const u8) [*]const u8 {
    return if (x) |s| s.ptr else "".ptr;
}

pub fn sl(x: ?[]const u8) usize {
    return if (x) |s| s.len else null_len;
}

/// Optional IDL argument: null means "not passed" (JS `undefined`).
pub fn opt(x: anytype) js.Raw {
    const T = @TypeOf(x);
    if (T == @TypeOf(null)) return js.Raw.undef;
    if (@typeInfo(T) == .optional) return if (x) |v| js.toRaw(v) else js.Raw.undef;
    return js.toRaw(x);
}

pub fn str(allocator: std.mem.Allocator, out: Str) ![]u8 {
    return (try strOpt(allocator, out)) orelse try allocator.alloc(u8, 0);
}

/// JS allocates with `__zx_alloc`; hand it over directly when the caller uses the same allocator.
pub fn strOpt(allocator: std.mem.Allocator, out: Str) !?[]u8 {
    if (out.len == null_len) return null;
    if (out.len == 0) return try allocator.alloc(u8, 0);
    const src: [*]u8 = @ptrFromInt(out.ptr);
    const bytes = src[0..out.len];
    if (allocator.vtable == gpa_.vtable) return bytes;
    defer gpa_.free(bytes);
    return try allocator.dupe(u8, bytes);
}

pub fn enumOf(comptime E: type, v: i32) E {
    return @fromBackingInt(@as(u32, @bitCast(v)));
}

pub fn enumOpt(comptime E: type, v: i32) ?E {
    if (v < 0) return null;
    return @fromBackingInt(@as(u32, @intCast(v)));
}

pub fn wrap(comptime T: type, v: u32) T {
    return .{ .h = @fromBackingInt(v) };
}

pub fn wrapOpt(comptime T: type, v: u32) ?T {
    if (v <= 1) return null;
    return .{ .h = @fromBackingInt(v) };
}

pub const Promise = struct {
    h: js.Value,

    pub fn deinit(self: Promise) void {
        self.h.deinit();
    }

    /// Runs `ok(value)` or `err(reason)` once settled; pass `.once = true` callbacks.
    pub fn then(self: Promise, ok: ?js.Callback, err: ?js.Callback) void {
        ext.@"$.then"(@backingInt(self.h), cb(ok), cb(err));
    }
};

const ext = if (js.enabled) struct {
    extern "__zx_web" fn @"$.then"(p: u32, ok: u32, err: u32) void;
} else struct {
    fn @"$.then"(_: u32, _: u32, _: u32) void {}
};
