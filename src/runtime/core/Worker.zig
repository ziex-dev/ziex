// Runs a module's `pub fn`s in a browser Worker. The main wasm gets proxies that
// send arguments with `codec`, wait for the result (JSPI) and decode it; the worker
// wasm exports `serve`'s dispatcher. A first `std.mem.Allocator` parameter is not
// sent: the caller's allocator owns the decoded result, the worker's is per call.
const std = @import("std");
const host = @import("../wasm/imports.zig");
const js = @import("../client/js.zig");

pub const codec = @import("Worker/codec.zig");
pub const name = @import("Worker/name.zig");

pub const Error = error{
    // No JSPI, no worker support in the host, or the worker failed to start.
    WorkerUnavailable,
    // The call didn't complete: the worker crashed or the reply was malformed.
    WorkerFailed,
    OutOfMemory,
};

// Reply: one status byte, then the encoded result or the error's name.
const status_ok: u8 = 0;
const status_error: u8 = 1;
const status_failed: u8 = 2;

// The functions a worker exposes, in declaration order on both sides.
pub fn functions(comptime M: type) []const [:0]const u8 {
    return comptime blk: {
        var out: []const [:0]const u8 = &.{};
        for (@typeInfo(M).@"struct".decl_names) |decl| {
            if (std.mem.eql(u8, decl, "init")) continue;
            const info = @typeInfo(@TypeOf(@field(M, decl)));
            if (info != .@"fn" or info.@"fn".is_generic) continue;
            out = out ++ .{decl};
        }
        const final: [out.len][:0]const u8 = out[0..out.len].*;
        break :blk &final;
    };
}

fn paramTypes(comptime F: type) []const type {
    return comptime blk: {
        const info = @typeInfo(F).@"fn";
        var params: [info.param_types.len]type = undefined;
        for (info.param_types, &params) |p, *out| out.* = p orelse @compileError("worker: generic parameter");
        const final = params;
        break :blk &final;
    };
}

fn takesAllocator(comptime F: type) bool {
    const params = @typeInfo(F).@"fn".param_types;
    return params.len > 0 and params[0] == std.mem.Allocator;
}

fn Payload(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

// Explicit error sets come through by name. Inferred ones (`!T`) can't be listed without
// compiling the worker's body into the page, so those errors arrive as `WorkerFailed`.
fn ErrorSet(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |eu| if (isInferred(eu.error_set)) Error else eu.error_set || Error,
        else => Error,
    };
}

fn isInferred(comptime E: type) bool {
    return std.mem.startsWith(u8, @typeName(E), "@typeInfo(");
}

// The proxy for `f`: same parameters, its error set widened with `Error`.
fn ProxyFn(comptime F: type) type {
    const info = @typeInfo(F).@"fn";
    const R = ErrorSet(info.return_type.?)!Payload(info.return_type.?);
    return @TypeOf(makeFn(paramTypes(F), R, struct {}));
}

// A function with exactly `params` that forwards its arguments as a tuple to `Impl.call`.
fn makeFn(comptime params: []const type, comptime R: type, comptime Impl: type) switch (params.len) {
    0 => fn () R,
    1 => fn (params[0]) R,
    2 => fn (params[0], params[1]) R,
    3 => fn (params[0], params[1], params[2]) R,
    4 => fn (params[0], params[1], params[2], params[3]) R,
    5 => fn (params[0], params[1], params[2], params[3], params[4]) R,
    6 => fn (params[0], params[1], params[2], params[3], params[4], params[5]) R,
    else => @compileError("worker: functions take at most 6 parameters"),
} {
    const P = params;
    return switch (P.len) {
        0 => struct {
            fn f() R {
                return Impl.call(.{});
            }
        }.f,
        1 => struct {
            fn f(a: P[0]) R {
                return Impl.call(.{a});
            }
        }.f,
        2 => struct {
            fn f(a: P[0], b: P[1]) R {
                return Impl.call(.{ a, b });
            }
        }.f,
        3 => struct {
            fn f(a: P[0], b: P[1], c: P[2]) R {
                return Impl.call(.{ a, b, c });
            }
        }.f,
        4 => struct {
            fn f(a: P[0], b: P[1], c: P[2], d: P[3]) R {
                return Impl.call(.{ a, b, c, d });
            }
        }.f,
        5 => struct {
            fn f(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4]) R {
                return Impl.call(.{ a, b, c, d, e });
            }
        }.f,
        6 => struct {
            fn f(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5]) R {
                return Impl.call(.{ a, b, c, d, e, g });
            }
        }.f,
        else => unreachable,
    };
}

// A value whose fields are `fields(fn name)` for every function of `M`, so `handle.foo(...)` calls one.
fn Handle(comptime M: type, comptime Field: fn (comptime [:0]const u8) type, comptime value: anytype) type {
    const names = functions(M);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (names, &types, &attrs) |n, *t, *a| {
        t.* = Field(n);
        a.* = .{ .@"comptime" = true, .default_value_ptr = value(n) };
    }
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, names, &final_types, &final_attrs);
}

// Calls `M`'s functions directly (server, or inside the worker itself).
pub fn direct(comptime M: type) Handle(M, struct {
    fn field(comptime n: [:0]const u8) type {
        return if (optionsOf(M).calls == .post) PostFn(M, n) else @TypeOf(@field(M, n));
    }
}.field, struct {
    fn value(comptime n: [:0]const u8) *const anyopaque {
        return if (optionsOf(M).calls == .post) &postDirectFn(M, n) else &@field(M, n);
    }
}.value) {
    return .{};
}

// Calls `M`'s functions in the worker loaded from `url`.
pub fn proxy(comptime M: type, comptime url: []const u8) Handle(M, struct {
    fn field(comptime n: [:0]const u8) type {
        return if (optionsOf(M).calls == .post) PostFn(M, n) else ProxyFn(@TypeOf(@field(M, n)));
    }
}.field, struct {
    fn value(comptime n: [:0]const u8) *const anyopaque {
        return if (optionsOf(M).calls == .post) &postFn(M, url, n) else &proxyFn(M, url, n);
    }
}.value) {
    return .{};
}

fn proxyFn(comptime M: type, comptime url: []const u8, comptime n: [:0]const u8) ProxyFn(@TypeOf(@field(M, n))) {
    const F = @TypeOf(@field(M, n));
    const info = @typeInfo(F).@"fn";
    const Ret = info.return_type.?;
    const R = ErrorSet(Ret)!Payload(Ret);
    const index = indexOf(M, n);
    return makeFn(paramTypes(F), R, struct {
        fn call(args: anytype) R {
            return invoke(url, index, takesAllocator(F), Payload(Ret), ErrorSet(Ret), args);
        }
    });
}

fn invoke(
    comptime url: []const u8,
    comptime index: u32,
    comptime with_allocator: bool,
    comptime T: type,
    comptime E: type,
    args: anytype,
) E!T {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    inline for (args, 0..) |arg, i| {
        if (!(with_allocator and i == 0)) codec.encode(&aw.writer, arg) catch return error.OutOfMemory;
    }

    var out: [*]u8 = undefined;
    const n = host.wait(.worker_call, .{ url, index, aw.written(), &out });
    if (n < 0) return if (n == host.unsupported) error.WorkerUnavailable else error.WorkerFailed;
    // The host allocates the reply with `__zx_alloc`.
    const reply = out[0..@intCast(n)];
    defer if (reply.len > 0) gpa.free(reply);
    const allocator = if (with_allocator) args[0] else std.mem.Allocator.failing;
    return decodeReply(url, T, E, with_allocator, reply, allocator);
}

fn decodeReply(
    comptime url: []const u8,
    comptime T: type,
    comptime E: type,
    comptime with_allocator: bool,
    reply: []const u8,
    allocator: std.mem.Allocator,
) E!T {
    if (reply.len == 0) return error.WorkerFailed;
    var r = std.Io.Reader.fixed(reply[1..]);
    switch (reply[0]) {
        status_ok => {
            if (comptime !with_allocator and !codec.isPlain(T) and T != void)
                @compileError("worker: return pointers only from functions taking an Allocator first");
            return codec.decode(T, &r, allocator) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.WorkerFailed,
            };
        },
        status_error => {
            const err_name = reply[1..];
            inline for (@typeInfo(E).error_set.error_names.?) |e| {
                if (std.mem.eql(u8, e, err_name)) return @field(E, e);
            }
            std.log.err("worker {s}: error.{s}", .{ url, err_name });
            return error.WorkerFailed;
        },
        else => return error.WorkerFailed,
    }
}

/// How the page calls a worker's functions. A worker file opts in with
/// `pub const options: zx.Worker.Options = .{ .calls = .post };`.
pub const Options = struct {
    calls: Calls = .wait,

    pub const Calls = enum {
        /// `handle.f(args)` returns the result; the caller suspends (JSPI) until the
        /// worker replies. Simple, but suspended calls resume in reverse order, so a
        /// long call holds up the replies of calls made after it.
        wait,
        /// `handle.f(args, &done)` returns at once and `done(result)` runs when the
        /// worker replies. Needs no JSPI and calls never hold each other up; use it
        /// for long jobs (builds) or chatty ones (a language server).
        post,
    };
};

fn optionsOf(comptime M: type) Options {
    if (@hasDecl(M, "options") and @TypeOf(M.options) == Options) return M.options;
    return .{};
}

/// What a `.post` worker's `done` receives for `M.n`: the result, widened with `Error`.
/// Slices in it are allocated with the wasm allocator (`zx.allocator`) and owned by `done`.
pub fn Result(comptime M: type, comptime n: [:0]const u8) type {
    const Ret = @typeInfo(@TypeOf(@field(M, n))).@"fn".return_type.?;
    return ErrorSet(Ret)!Payload(Ret);
}

/// The callback a `.post` worker's `M.n` takes last.
pub fn Done(comptime M: type, comptime n: [:0]const u8) type {
    return *const fn (Result(M, n)) void;
}

// `M.n`'s parameters as a `.post` call takes them: no leading allocator, then `done`.
fn postParams(comptime M: type, comptime n: [:0]const u8) []const type {
    const F = @TypeOf(@field(M, n));
    const params = paramTypes(F);
    const sent = if (takesAllocator(F)) params[1..] else params;
    return sent ++ &[_]type{Done(M, n)};
}

fn PostFn(comptime M: type, comptime n: [:0]const u8) type {
    return @TypeOf(makeFn(postParams(M, n), void, struct {}));
}

fn indexOf(comptime M: type, comptime n: [:0]const u8) u32 {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        for (functions(M), 0..) |f, i| {
            if (std.mem.eql(u8, f, n)) break :blk i;
        } else unreachable;
    };
}

fn postFn(comptime M: type, comptime url: []const u8, comptime n: [:0]const u8) PostFn(M, n) {
    return makeFn(postParams(M, n), void, struct {
        fn call(args: anytype) void {
            post(M, url, n, args);
        }
    });
}

// Sends `args` (all but the trailing `done`) and returns; the reply runs `done`.
fn post(comptime M: type, comptime url: []const u8, comptime n: [:0]const u8, args: anytype) void {
    const F = @TypeOf(@field(M, n));
    const Ret = @typeInfo(F).@"fn".return_type.?;
    const done: Done(M, n) = args[args.len - 1];

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    inline for (0..args.len - 1) |i| codec.encode(&aw.writer, args[i]) catch return done(error.OutOfMemory);

    const Reply = struct {
        fn onReply(ctx: ?*anyopaque, vals: []const js.Value) void {
            const d: Done(M, n) = @ptrFromInt(@intFromPtr(ctx));
            const v = if (vals.len > 0) vals[0] else js.Value.undefined;
            if (v.typeOf() == .number) return d(error.WorkerFailed);
            const reply = v.bytesAlloc(gpa) catch return d(error.OutOfMemory);
            defer gpa.free(reply);
            d(decodeReply(url, Payload(Ret), ErrorSet(Ret), takesAllocator(F), reply, gpa));
        }
    };
    const cb = js.Callback.init(@ptrFromInt(@intFromPtr(done)), Reply.onReply, .{ .once = true });
    const rc = host.call(.worker_post, .{ url, indexOf(M, n), aw.written(), cb.id });
    if (rc < 0) {
        cb.release();
        done(if (rc == host.unsupported) error.WorkerUnavailable else error.WorkerFailed);
    }
}

// `.post` on the server and inside workers: runs `M.n` now, then `done`.
fn postDirectFn(comptime M: type, comptime n: [:0]const u8) PostFn(M, n) {
    return makeFn(postParams(M, n), void, struct {
        fn call(args: anytype) void {
            const f = @field(M, n);
            const F = @TypeOf(f);
            const done: Done(M, n) = args[args.len - 1];
            var call_args: std.meta.ArgsTuple(F) = undefined;
            const skip = if (comptime takesAllocator(F)) 1 else 0;
            if (skip == 1) call_args[0] = gpa;
            inline for (0..args.len - 1) |i| call_args[i + skip] = args[i];
            const result = @call(.auto, f, call_args);
            if (@typeInfo(@TypeOf(result)) != .error_union) return done(result);
            const E = @typeInfo(Result(M, n)).error_union.error_set;
            if (result) |v| done(v) else |err| {
                // As from a worker reply: errors outside `E` (inferred sets) become `WorkerFailed`.
                inline for (@typeInfo(E).error_set.error_names.?) |e| {
                    if (std.mem.eql(u8, e, @errorName(err))) return done(@field(E, e));
                }
                done(error.WorkerFailed);
            }
        }
    });
}

// Exports the worker side of `M` (see `Server`).
pub fn serve(comptime M: type) void {
    @export(&Server(M).init, .{ .name = "__zx_worker_init" });
    @export(&Server(M).call, .{ .name = "__zx_worker_call" });
}

// `init` runs `M.init` if it has one; `call` runs function `index` on encoded arguments
// and hands back the reply, allocated with `gpa`.
pub fn Server(comptime M: type) type {
    return struct {
        pub fn init() callconv(.c) i32 {
            if (@hasDecl(M, "init")) {
                const result = M.init();
                if (@typeInfo(@TypeOf(result)) == .error_union) _ = result catch |err| {
                    std.log.err("worker init: {t}", .{err});
                    return -1;
                };
            }
            return 0;
        }

        pub fn call(index: u32, ptr: [*]const u8, len: usize, out: *[*]u8) callconv(.c) i32 {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            dispatch(index, ptr[0..len], arena.allocator(), &aw.writer) catch return -1;
            const reply = aw.toOwnedSlice() catch return -1;
            out.* = reply.ptr;
            return @intCast(reply.len);
        }

        fn dispatch(index: u32, input: []const u8, arena: std.mem.Allocator, w: *std.Io.Writer) !void {
            inline for (comptime functions(M), 0..) |n, i| if (i == index) {
                const f = @field(M, n);
                const F = @TypeOf(f);
                var args: std.meta.ArgsTuple(F) = undefined;
                var r = std.Io.Reader.fixed(input);
                inline for (@typeInfo(F).@"fn".param_types, 0..) |P, a| {
                    args[a] = if (comptime a == 0 and takesAllocator(F))
                        arena
                    else
                        codec.decode(P.?, &r, arena) catch {
                            try w.writeByte(status_failed);
                            return;
                        };
                }
                const result = @call(.auto, f, args);
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    const value = result catch |err| {
                        try w.writeByte(status_error);
                        try w.writeAll(@errorName(err));
                        return;
                    };
                    try w.writeByte(status_ok);
                    try codec.encode(w, value);
                } else {
                    try w.writeByte(status_ok);
                    try codec.encode(w, result);
                }
                return;
            };
            try w.writeByte(status_failed);
        }
    };
}

// `__zx_alloc`'s allocator on wasm, so replies cross the host boundary either way.
const gpa = if (@import("builtin").cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;

test {
    _ = codec;
    _ = name;
}
