//! Dynamic JS interop over u32 handles (replaces vendored jsz).
//! Args cross as tagged `Raw` slots, so numbers/strings never allocate a handle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../../platform.zig");

const is_client = platform.platform.role == .client;

pub const enabled = is_client;

// JS hands buffers over via `__zx_alloc`; native builds only reach the stubs.
pub const gpa_ = if (is_client) std.heap.wasm_allocator else std.heap.page_allocator;

pub const Error = error{ InvalidType, JsException };

pub const Type = enum(u8) { undefined, null, boolean, number, string, object, function, symbol, bigint };

// Must match `pkg/ziex/src/wasm/js.ts`.
pub const Raw = extern struct {
    tag: Tag,
    // bool, handle, callback id, or string/json ptr
    a: u32 = 0,
    // number, string/json len, or `Type` of a handle
    n: f64 = 0,

    pub const Tag = enum(u32) { undefined, null, boolean, number, string, ref, json, callback, bytes };

    pub const undef: Raw = .{ .tag = .undefined };
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
    extern "__zx_js" fn bytes(h: u32, ptr: [*]u8, len: usize) usize;
    extern "__zx_js" fn exports() u32;
    extern "__zx_js" fn @"await"(h: u32, out: *Raw) bool;
} else struct {
    fn @"await"(_: u32, out: *Raw) bool {
        out.* = Raw.undef;
        return false;
    }
    fn exports() u32 {
        return 0;
    }
    fn bytes(_: u32, _: [*]u8, _: usize) usize {
        return 0;
    }
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

/// Bytes passed to JS as a copied `Uint8Array` (see `bytes`).
pub const Bytes = struct { data: []const u8 };

/// Marks a slice as binary data for `anytype` args, e.g. a fetch body.
pub fn bytes(data: anytype) Bytes {
    return .{ .data = std.mem.sliceAsBytes(data) };
}

/// A retained JS value. Release with `deinit`.
pub const Value = enum(u32) {
    undefined = 0,
    null = 1,
    global = 2,
    _,

    pub fn init(x: anytype) Value {
        const r = toRaw(x);
        defer freeTemps();
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

    /// In JSON args (dictionaries), `{"$h":id}`, which JS swaps for the object.
    pub fn jsonStringify(self: Value, jw: anytype) !void {
        switch (self) {
            .undefined, .null => try jw.write(null),
            else => try jw.write(.{ .@"$h" = @backingInt(self) }),
        }
    }

    /// A second handle to the same value (e.g. to keep a callback arg).
    pub fn dup(self: Value) Value {
        if (@backingInt(self) <= 2) return self;
        const r = refRaw(self);
        return @fromBackingInt(ext.toRef(&r));
    }

    /// `this[i]` for arrays and array-likes.
    pub fn at(self: Value, i: usize) Value {
        var buf: [20]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        return self.get(key) catch .undefined;
    }

    /// Copies an ArrayBuffer or typed array into `dst`; returns its full byte length.
    pub fn copyBytes(self: Value, dst: []u8) usize {
        return ext.bytes(@backingInt(self), dst.ptr, dst.len);
    }

    /// The bytes of an ArrayBuffer or typed array, e.g. `ImageData.data()`.
    pub fn bytesAlloc(self: Value, allocator: Allocator) ![]u8 {
        const n = ext.bytes(@backingInt(self), undefined, 0);
        const out = try allocator.alloc(u8, n);
        _ = ext.bytes(@backingInt(self), out.ptr, out.len);
        return out;
    }

    pub fn len(self: Value) usize {
        const o: Object = .{ .value = self };
        return o.get(usize, "length") catch 0;
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

    pub fn jsonStringify(self: Object, jw: anytype) !void {
        try self.value.jsonStringify(jw);
    }

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
        defer freeTemps();
        ext.set(@backingInt(self.value), n.ptr, n.len, &r);
    }

    /// Calls method `n` with `this` bound to the object.
    pub fn call(self: Object, comptime T: type, n: []const u8, args: anytype) !Result(T) {
        if (comptime allocs(T)) @compileError("use callAlloc for types that require allocations");
        return self.callAlloc(T, undefined, n, args);
    }

    pub fn callAlloc(self: Object, comptime T: type, alloc: Allocator, n: []const u8, args: anytype) !Result(T) {
        const raws = argsRaw(args);
        defer freeTemps();
        var out: Raw = undefined;
        if (!ext.call(@backingInt(self.value), n.ptr, n.len, &raws, raws.len, &out, comptime modeFor(T))) return Error.JsException;
        return convert(T, alloc, out);
    }

    /// Calls `new this(...args)`.
    pub fn new(self: Object, args: anytype) !Object {
        const raws = argsRaw(args);
        defer freeTemps();
        var out: Raw = undefined;
        if (!ext.construct(@backingInt(self.value), &raws, raws.len, &out)) return Error.JsException;
        return convert(Object, undefined, out);
    }
};

/// `globalThis`.
pub const global: Object = .{ .value = .global };

/// Waits for a JS promise, suspending the caller through JSPI (any page event handler,
/// callback or `zx.worker` function can), and returns what it resolved to; a plain value
/// comes back as is. Rejections are `error.JsException`. Start several promises before
/// awaiting the first to have them run concurrently. Release the result with `deinit`.
pub fn awaitValue(v: Value) Error!Value {
    var out: Raw = undefined;
    const ok = ext.@"await"(@backingInt(v), &out);
    const result = fromHandleRaw(out);
    if (!ok) {
        result.deinit();
        return Error.JsException;
    }
    return result;
}

/// This wasm instance's exports. An `export fn` taken from here is a real wasm
/// function, so it can be another module's import (e.g. a WASI host written in Zig).
/// Release with `deinit`.
pub fn exports() Object {
    return .{ .value = @fromBackingInt(ext.exports()) };
}

/// Converts a tuple of args to `Raw` slots. Call `freeTemps` after the JS call.
pub fn argsRaw(args: anytype) [@typeInfo(@TypeOf(args)).@"struct".field_types.len]Raw {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    var raws: [info.field_types.len]Raw = undefined;
    inline for (info.field_names, 0..) |name, i| raws[i] = toRaw(@field(args, name));
    return raws;
}

/// Converts a Zig value to a `Raw` slot. Byte slices become strings; other
/// slices, arrays and structs become JSON (freed by `freeTemps`).
pub fn toRaw(x: anytype) Raw {
    const T = @TypeOf(x);
    if (T == Object) return refRaw(x.value);
    if (T == Value) return refRaw(x);
    if (T == String) return strRaw(x.ptr[0..x.len]);
    if (T == Undefined) return Raw.undef;
    if (T == Callback) return .{ .tag = .callback, .a = x.id };
    if (T == Bytes) return .{ .tag = .bytes, .a = @intCast(@intFromPtr(x.data.ptr)), .n = @floatFromInt(x.data.len) };
    switch (@typeInfo(T)) {
        .null => return .{ .tag = .null },
        .optional => return if (x) |v| toRaw(v) else .{ .tag = .null },
        .bool => return .{ .tag = .boolean, .a = @intFromBool(x) },
        .int, .comptime_int => return .{ .tag = .number, .n = @floatFromInt(x) },
        .float, .comptime_float => return .{ .tag = .number, .n = @floatCast(x) },
        .@"enum" => {
            if (comptime @hasDecl(T, "str")) return strRaw(x.str());
            return .{ .tag = .number, .n = @floatFromInt(@backingInt(x)) };
        },
        .@"struct" => if (comptime @hasField(T, "h") and @FieldType(T, "h") == Value) return refRaw(x.h),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return strRaw(x);
            if (p.size == .one) switch (@typeInfo(p.child)) {
                .array => |arr| if (arr.child == u8) return strRaw(x),
                else => {},
            };
        },
        else => {},
    }
    return jsonRaw(x);
}

fn strRaw(s: []const u8) Raw {
    return .{ .tag = .string, .a = @intCast(@intFromPtr(s.ptr)), .n = @floatFromInt(s.len) };
}

var temps: std.ArrayListUnmanaged([]u8) = .empty;

fn jsonRaw(x: anytype) Raw {
    const gpa = gpa_;
    const json = std.json.Stringify.valueAlloc(gpa, x, .{ .emit_null_optional_fields = false }) catch return Raw.undef;
    temps.append(gpa, json) catch {
        gpa.free(json);
        return Raw.undef;
    };
    return .{ .tag = .json, .a = @intCast(@intFromPtr(json.ptr)), .n = @floatFromInt(json.len) };
}

/// Frees JSON buffers made by `toRaw`.
pub fn freeTemps() void {
    if (temps.items.len == 0) return;
    for (temps.items) |b| gpa_.free(b);
    temps.clearRetainingCapacity();
}

/// A Zig function callable from JS. Args are handles valid for the duration of the call.
/// Made with `returning`/`bindReturning`, the JS function returns the Zig result: a plain
/// value, or a Promise of it when the call goes through JSPI (any page callback), so the
/// Zig side may suspend (e.g. on a `zx.worker` call) before answering.
pub const Callback = struct {
    id: u32,

    pub const Fn = *const fn (ctx: ?*anyopaque, args: []const Value) void;
    /// The returned value is handed to JS, which releases it.
    pub const ReturnFn = *const fn (ctx: ?*anyopaque, args: []const Value) Value;

    /// Set in `id` when the JS function returns the Zig result (see `js.ts`).
    pub const returns_bit: u32 = 1 << 31;

    const Slot = struct { func: ?Fn = null, ret: ?ReturnFn = null, ctx: ?*anyopaque, once: bool };
    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    var free_ids: std.ArrayListUnmanaged(u32) = .empty;

    pub const Options = struct {
        /// Unregister after the first call (e.g. requestAnimationFrame).
        once: bool = false,
    };

    fn register(slot: Slot) u32 {
        if (free_ids.pop()) |id| {
            slots.items[id - 1] = slot;
            return id;
        }
        slots.append(gpa_, slot) catch @panic("OOM");
        return @intCast(slots.items.len);
    }

    /// Registers `func(ctx, args)`; id 0 is never used, so JS sees it as null.
    pub fn init(ctx: ?*anyopaque, func: Fn, opts: Options) Callback {
        return .{ .id = register(.{ .func = func, .ctx = ctx, .once = opts.once }) };
    }

    /// Registers `func(ctx, args)`, whose result the JS function returns.
    pub fn initReturning(ctx: ?*anyopaque, func: ReturnFn, opts: Options) Callback {
        return .{ .id = register(.{ .ret = func, .ctx = ctx, .once = opts.once }) | returns_bit };
    }

    /// Registers a context-free function.
    pub fn fromFn(comptime f: fn ([]const Value) void, opts: Options) Callback {
        const S = struct {
            fn call(_: ?*anyopaque, args: []const Value) void {
                f(args);
            }
        };
        return init(null, S.call, opts);
    }

    /// Registers a context-free function whose result JS receives, e.g. a source of
    /// completions a JS library awaits.
    pub fn returning(comptime f: fn ([]const Value) Value, opts: Options) Callback {
        const S = struct {
            fn call(_: ?*anyopaque, args: []const Value) Value {
                return f(args);
            }
        };
        return initReturning(null, S.call, opts);
    }

    /// Registers `f(ctx, args)` with a typed context pointer.
    pub fn bind(ctx: anytype, comptime f: fn (@TypeOf(ctx), []const Value) void, opts: Options) Callback {
        if (@typeInfo(@TypeOf(ctx)) != .pointer) @compileError("Callback.bind expects a pointer context");
        const S = struct {
            fn call(c: ?*anyopaque, args: []const Value) void {
                f(@ptrCast(@alignCast(c)), args);
            }
        };
        return init(@ptrCast(@constCast(ctx)), S.call, opts);
    }

    /// `bind`, returning `f`'s result to JS.
    pub fn bindReturning(ctx: anytype, comptime f: fn (@TypeOf(ctx), []const Value) Value, opts: Options) Callback {
        if (@typeInfo(@TypeOf(ctx)) != .pointer) @compileError("Callback.bindReturning expects a pointer context");
        const S = struct {
            fn call(c: ?*anyopaque, args: []const Value) Value {
                return f(@ptrCast(@alignCast(c)), args);
            }
        };
        return initReturning(@ptrCast(@constCast(ctx)), S.call, opts);
    }

    /// In JSON args (dictionaries), `{"$f":id}`, which JS swaps for the function.
    pub fn jsonStringify(self: Callback, jw: anytype) !void {
        try jw.write(.{ .@"$f" = self.id });
    }

    pub fn release(self: Callback) void {
        const id = self.id & ~returns_bit;
        if (id == 0 or id > slots.items.len) return;
        const slot = &slots.items[id - 1];
        if (slot.func == null and slot.ret == null) return;
        slot.func = null;
        slot.ret = null;
        free_ids.append(gpa_, id) catch {};
    }

    /// Returns a handle JS takes ownership of (0 = undefined) for returning callbacks.
    fn dispatch(raw_id: u32, n: u32, a0: u32, a1: u32, a2: u32) callconv(.c) u32 {
        const id = raw_id & ~returns_bit;
        if (id == 0 or id > slots.items.len) return 0;
        const slot = slots.items[id - 1];
        if (slot.once) (Callback{ .id = id }).release();
        const all = [3]Value{ @fromBackingInt(a0), @fromBackingInt(a1), @fromBackingInt(a2) };
        const args = all[0..@min(n, 3)];
        if (slot.ret) |ret| return @backingInt(ret(slot.ctx, args));
        if (slot.func) |func| func(slot.ctx, args);
        return 0;
    }

    comptime {
        if (is_client) @export(&dispatch, .{ .name = "__zx_js_cb" });
    }
};

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
        .string, .json => .string,
        .bytes => .object,
        .callback => .function,
        .ref => @fromBackingInt(@as(u8, @intFromFloat(r.n))),
    };
}

fn takeBytes(alloc: Allocator, r: Raw) ![]u8 {
    const len: usize = @intFromFloat(r.n);
    if (len == 0) return alloc.alloc(u8, 0);
    const src: [*]u8 = @ptrFromInt(r.a);
    defer gpa_.free(src[0..len]);
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
