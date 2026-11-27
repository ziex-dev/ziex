// Guest-to-host calls. Every host function goes through `__zx.call` (never
// suspends) or `__zx.wait` (may suspend via JSPI), selected by `Op`.
// Arguments are packed into seven u32 slots: slices take two (ptr, len) and
// 64-bit integers two (lo, hi).
const std = @import("std");

// Append only: ops are stable so older hosts can answer `unsupported`.
// Mirrored in `pkg/ziex/src/runtime/host.ts`.
pub const Op = enum(u32) {
    io_now,
    io_resolution,
    io_sleep,
    io_random,
    net_fetch,
    net_take,
    net_open,
    net_read,
    net_close,
    http_commit,
    http_write,
    http_end,
    ws_upgrade,
    ws_write,
    ws_close,
    ws_recv,
    ws_subscribe,
    ws_unsubscribe,
    ws_publish,
    ws_is_subscribed,
    sys_park,
    kv_get,
    kv_put,
    kv_delete,
    kv_list,
    db_open,
    db_run,
    db_get,
    db_all,
    db_values,
    env_call,
    email_send,
    fs_open,
    fs_close,
    fs_read,
    fs_write,
    fs_stat,
    fs_set_len,
    fs_seek,
    fs_mkdir,
    fs_remove,
    fs_rename,
    fs_readdir,
    fs_sync,
    worker_call,
    bucket_head,
    bucket_get,
    bucket_put,
    bucket_delete,
    bucket_list,
    bucket_open,
    bucket_read,
    bucket_close,
    bucket_upload,
    bucket_upload_part,
    bucket_upload_finish,
    bucket_upload_abort,
    worker_post,
    ws_set_publish_to_self,
};

// Returned by hosts that don't implement an op.
pub const unsupported: i32 = -38;
// `env_call`: the Worker env has no such binding or method.
pub const missing: i32 = -2;

pub fn call(op: Op, args: anytype) i32 {
    const s = slots(args);
    return ext.call(@backingInt(op), s[0], s[1], s[2], s[3], s[4], s[5], s[6]);
}

pub fn wait(op: Op, args: anytype) i32 {
    const s = slots(args);
    return ext.wait(@backingInt(op), s[0], s[1], s[2], s[3], s[4], s[5], s[6]);
}

pub const Bytes = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn of(s: []const u8) Bytes {
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

// Bytes the host allocated with `__zx_alloc`; `n` is the call's result.
pub fn owned(ptr: [*]u8, n: i32) []u8 {
    return ptr[0..@intCast(n)];
}

pub fn free(bytes: []u8) void {
    if (bytes.len > 0) std.heap.wasm_allocator.free(bytes);
}

fn slots(args: anytype) [7]u32 {
    var s: [7]u32 = @splat(0);
    comptime var i: usize = 0;
    inline for (args) |arg| {
        const T = @TypeOf(arg);
        switch (@typeInfo(T)) {
            .pointer => |p| if (p.size == .slice or (p.size == .one and @typeInfo(p.child) == .array)) {
                const slice: []const u8 = arg;
                s[i] = @truncate(@intFromPtr(slice.ptr));
                s[i + 1] = @intCast(slice.len);
                i += 2;
            } else {
                s[i] = @truncate(@intFromPtr(arg));
                i += 1;
            },
            .int => |int| if (int.bits > 32) {
                const v: u64 = @bitCast(@as(i64, arg));
                s[i] = @truncate(v);
                s[i + 1] = @truncate(v >> 32);
                i += 2;
            } else {
                s[i] = if (int.signedness == .signed) @bitCast(@as(i32, arg)) else arg;
                i += 1;
            },
            .comptime_int => {
                s[i] = arg;
                i += 1;
            },
            .bool => {
                s[i] = @intFromBool(arg);
                i += 1;
            },
            .@"enum" => {
                s[i] = @backingInt(arg);
                i += 1;
            },
            else => @compileError("unsupported host argument: " ++ @typeName(T)),
        }
        if (i > s.len) @compileError("too many host arguments");
    }
    return s;
}

const ext = if (@import("builtin").cpu.arch.isWasm()) struct {
    extern "__zx" fn call(op: u32, a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32) i32;
    extern "__zx" fn wait(op: u32, a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32) i32;
} else struct {
    // Native builds never reach a host; this only lets them compile code that could.
    fn call(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) i32 {
        return unsupported;
    }
    fn wait(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) i32 {
        return unsupported;
    }
};
