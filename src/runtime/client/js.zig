//! Dynamic JS interop over u32 handles (replaces vendored jsz).
//! Args cross as tagged `Raw` slots, so numbers/strings never allocate a handle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../../platform.zig");

const is_client = platform.platform.role == .client;

pub const Error = error{ InvalidType, JsException };

pub const Type = enum(u8) { undefined, null, boolean, number, string, object, function, symbol, bigint };

// Must match `pkg/ziex/src/wasm/js.ts`.
pub const Raw = extern struct {
    tag: Tag,
    // bool, handle, or string ptr
    a: u32 = 0,
    // number, string len, or `Type` of a handle
    n: f64 = 0,

    pub const Tag = enum(u32) { undefined, null, boolean, number, string, ref };

    const undef: Raw = .{ .tag = .undefined };
};

// How JS returns values: primitives inline, strings as bytes, or always a handle.
const Mode = enum(u32) { inline_values, string_bytes, handle };

const ext = if (is_client) struct {
    extern "__zx_js" fn get(h: u32, np: [*]const u8, nl: usize, out: *Raw, mode: Mode) void;
    extern "__zx_js" fn set(h: u32, np: [*]const u8, nl: usize, v: *const Raw) void;
    extern "__zx_js" fn call(h: u32, np: [*]const u8, nl: usize, args: [*]const Raw, n: usize, out: *Raw, mode: Mode) bool;
    extern "__zx_js" fn apply(f: u32, this: u32, args: [*]const Raw, n: usize, out: *Raw, mode: Mode) bool;
    extern "__zx_js" fn construct(f: u32, args: [*]const Raw, n: usize, out: *Raw) bool;
    extern "__zx_js" fn read(h: u32, out: *Raw, mode: Mode) void;
    extern "__zx_js" fn toRef(v: *const Raw) u32;
    extern "__zx_js" fn release(h: u32) void;
} else struct {
    fn get(_: u32, _: [*]const u8, _: usize, out: *Raw, _: Mode) void {
        out.* = Raw.undef;
    }
    fn set(_: u32, _: [*]const u8, _: usize, _: *const Raw) void {}
    fn call(_: u32, _: [*]const u8, _: usize, _: [*]const Raw, _: usize, out: *Raw, _: Mode) bool {
        out.* = Raw.undef;
        return false;
    }
    fn apply(_: u32, _: u32, _: [*]const Raw, _: usize, out: *Raw, _: Mode) bool {
        out.* = Raw.undef;
        return false;
    }
    fn construct(_: u32, _: [*]const Raw, _: usize, out: *Raw) bool {
        out.* = Raw.undef;
        return false;
    }
    fn read(_: u32, out: *Raw, _: Mode) void {
        out.* = Raw.undef;
    }
    fn toRef(_: *const Raw) u32 {
        return 0;
    }
    fn release(_: u32) void {}
};

/// Marks a byte slice as a JS string (vs. an array) when converting.
pub const String = struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(x: anytype) String {
        const s: []const u8 = x;
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

pub inline fn string(v: anytype) String {
    return String.init(v);
}

/// Sentinel for passing `undefined` to JS.
pub const Undefined = struct {};

/// A retained JS value. Release with `deinit`.
pub const Value = enum(u32) {
    undefined = 0,
    null = 1,
    global = 2,
    _,

    pub fn init(x: anytype) Value {
        const r = toRaw(x);
        return switch (r.tag) {
            .undefined => .undefined,
            .null => .null,
            .ref => @fromBackingInt(r.a),
            else => @fromBackingInt(ext.toRef(&r)),
        };
    }

    pub fn deinit(self: Value) void {
        if (@backingInt(self) > 2) ext.release(@backingInt(self));
    }

    pub fn get(self: Value, n: []const u8) !Value {
        var out: Raw = undefined;
        ext.get(@backingInt(self), n.ptr, n.len, &out, .handle);
        return fromHandleRaw(out);
    }

    pub fn set(self: Value, n: []const u8, v: Value) !void {
        const r = refRaw(v);
        ext.set(@backingInt(self), n.ptr, n.len, &r);
    }

    pub fn apply(self: Value, this: Value, args: []Value) !Value {
        var buf: [16]Raw = undefined;
        if (args.len > buf.len) return Error.InvalidType;
        for (args, 0..) |a, i| buf[i] = refRaw(a);
        var out: Raw = undefined;
        if (!ext.apply(@backingInt(self), @backingInt(this), &buf, args.len, &out, .handle)) return Error.JsException;
        return fromHandleRaw(out);
    }

    pub fn new(self: Value, args: []Value) !Value {
        var buf: [16]Raw = undefined;
        if (args.len > buf.len) return Error.InvalidType;
        for (args, 0..) |a, i| buf[i] = refRaw(a);
        var out: Raw = undefined;
        if (!ext.construct(@backingInt(self), &buf, args.len, &out)) return Error.JsException;
        return fromHandleRaw(out);
    }

    pub fn boolean(self: Value) !bool {
        const r = self.read(.inline_values);
        if (r.tag != .boolean) return Error.InvalidType;
        return r.a != 0;
    }

    pub fn float(self: Value) !f64 {
        const r = self.read(.inline_values);
        if (r.tag != .number) return Error.InvalidType;
        return r.n;
    }

    pub fn string(self: Value, alloc: Allocator) ![]u8 {
        const r = self.read(.string_bytes);
        if (r.tag != .string) return Error.InvalidType;
        return takeBytes(alloc, r);
    }

    pub fn typeOf(self: Value) Type {
        return switch (self) {
            .undefined => .undefined,
            .null => .null,
            .global => .object,
            _ => {
                var out: Raw = undefined;
                ext.read(@backingInt(self), &out, .handle);
                return rawType(out);
            },
        };
    }

    fn read(self: Value, mode: Mode) Raw {
        var out: Raw = undefined;
        ext.read(@backingInt(self), &out, mode);
        return out;
    }
};

/// High-level wrapper over `Value`.
pub const Object = struct {
    value: Value,

    pub fn deinit(self: Object) void {
        self.value.deinit();
    }

    /// Non-allocating property read; use `getAlloc` for strings.
    pub fn get(self: Object, comptime T: type, n: []const u8) !Result(T) {
        if (comptime allocs(T)) @compileError("use getAlloc for types that require allocations");
        return self.getAlloc(T, undefined, n);
    }

    pub fn getAlloc(self: Object, comptime T: type, alloc: Allocator, n: []const u8) !Result(T) {
        var out: Raw = undefined;
        ext.get(@backingInt(self.value), n.ptr, n.len, &out, comptime modeFor(T));
        return convert(T, alloc, out);
    }

    pub fn set(self: Object, n: []const u8, v: anytype) !void {
        const r = toRaw(v);
        ext.set(@backingInt(self.value), n.ptr, n.len, &r);
    }

    /// Calls method `n` with `this` bound to the object.
    pub fn call(self: Object, comptime T: type, n: []const u8, args: anytype) !Result(T) {
        if (comptime allocs(T)) @compileError("use callAlloc for types that require allocations");
        return self.callAlloc(T, undefined, n, args);
    }

    pub fn callAlloc(self: Object, comptime T: type, alloc: Allocator, n: []const u8, args: anytype) !Result(T) {
        const raws = argsRaw(args);
        var out: Raw = undefined;
        if (!ext.call(@backingInt(self.value), n.ptr, n.len, &raws, raws.len, &out, comptime modeFor(T))) return Error.JsException;
        return convert(T, alloc, out);
    }

    /// Calls `new this(...args)`.
    pub fn new(self: Object, args: anytype) !Object {
        const raws = argsRaw(args);
        var out: Raw = undefined;
        if (!ext.construct(@backingInt(self.value), &raws, raws.len, &out)) return Error.JsException;
        return convert(Object, undefined, out);
    }
};

/// `globalThis`.
pub const global: Object = .{ .value = .global };

fn argsRaw(args: anytype) [@typeInfo(@TypeOf(args)).@"struct".field_types.len]Raw {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    var raws: [info.field_types.len]Raw = undefined;
    inline for (info.field_names, 0..) |name, i| raws[i] = toRaw(@field(args, name));
    return raws;
}

fn toRaw(x: anytype) Raw {
    const T = @TypeOf(x);
    if (T == Object) return refRaw(x.value);
    if (T == Value) return refRaw(x);
    if (T == String) return .{ .tag = .string, .a = @intCast(@intFromPtr(x.ptr)), .n = @floatFromInt(x.len) };
    if (T == Undefined) return Raw.undef;
    return switch (@typeInfo(T)) {
        .null => .{ .tag = .null },
        .optional => if (x) |v| toRaw(v) else .{ .tag = .null },
        .bool => .{ .tag = .boolean, .a = @intFromBool(x) },
        .int, .comptime_int => .{ .tag = .number, .n = @floatFromInt(x) },
        .float, .comptime_float => .{ .tag = .number, .n = @floatCast(x) },
        .@"enum" => .{ .tag = .number, .n = @floatFromInt(@backingInt(x)) },
        else => @compileError("unsupported JS value type: " ++ @typeName(T)),
    };
}

fn refRaw(v: Value) Raw {
    return switch (v) {
        .undefined => Raw.undef,
        .null => .{ .tag = .null },
        else => .{ .tag = .ref, .a = @backingInt(v) },
    };
}

fn fromHandleRaw(r: Raw) Value {
    return switch (r.tag) {
        .ref => @fromBackingInt(r.a),
        .null => .null,
        else => .undefined,
    };
}

fn rawType(r: Raw) Type {
    return switch (r.tag) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .ref => @fromBackingInt(@as(u8, @intFromFloat(r.n))),
    };
}

fn takeBytes(alloc: Allocator, r: Raw) ![]u8 {
    const len: usize = @intFromFloat(r.n);
    if (len == 0) return alloc.alloc(u8, 0);
    const src: [*]u8 = @ptrFromInt(r.a);
    defer std.heap.wasm_allocator.free(src[0..len]);
    return alloc.dupe(u8, src[0..len]);
}

// Only `.string_bytes` mode yields inline strings, and only `String` results request it.
fn releaseRaw(r: Raw) void {
    if (r.tag == .ref) ext.release(r.a);
}

fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn Result(comptime T: type) type {
    const U = Unwrapped(T);
    const R = if (U == String) []u8 else U;
    return if (@typeInfo(T) == .optional) ?R else R;
}

fn allocs(comptime T: type) bool {
    return Unwrapped(T) == String;
}

fn modeFor(comptime T: type) Mode {
    const U = Unwrapped(T);
    if (U == String) return .string_bytes;
    if (U == Value or U == Object) return .handle;
    return .inline_values;
}

fn convert(comptime T: type, alloc: Allocator, r: Raw) !Result(T) {
    const U = Unwrapped(T);
    const optional = @typeInfo(T) == .optional;

    if (r.tag == .undefined or r.tag == .null) {
        if (optional) return null;
        if (U == void) return;
        return Error.InvalidType;
    }
    errdefer releaseRaw(r);

    switch (U) {
        void => {
            releaseRaw(r);
            return;
        },
        Value => return fromHandleRaw(r),
        Object => {
            const t = rawType(r);
            if (r.tag != .ref or (t != .object and t != .function)) return Error.InvalidType;
            return .{ .value = @fromBackingInt(r.a) };
        },
        String => {
            if (r.tag != .string) return Error.InvalidType;
            return try takeBytes(alloc, r);
        },
        bool => {
            if (r.tag != .boolean) return Error.InvalidType;
            return r.a != 0;
        },
        else => switch (@typeInfo(U)) {
            .float => {
                if (r.tag != .number) return Error.InvalidType;
                return @floatCast(r.n);
            },
            .int => {
                if (r.tag != .number) return Error.InvalidType;
                return @intFromFloat(r.n);
            },
            else => @compileError("unsupported JS result type: " ++ @typeName(T)),
        },
    }
}
