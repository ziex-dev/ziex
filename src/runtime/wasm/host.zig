const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../../platform.zig");

const is_wasm_arch = builtin.cpu.arch.isWasm();
const is_client = platform.platform.role == .client;

const fetch = @import("../client/fetch.zig");
const window = @import("../client/window.zig");
const websocket = @import("../client/websocket.zig");

// Must match CallbackType_* in `pkg/ziex/src/wasm/core.ts`.
pub const HostMsg = enum(u8) {
    event = 0,
    fetch_success = 1,
    fetch_error = 2,
    timeout = 3,
    interval = 4,
    ws_open = 5,
    ws_message = 6,
    ws_error = 7,
    ws_close = 8,
};

// JS passes empty payloads as (0, 0) and `@ptrFromInt(0)` panics.
fn hostBytes(addr: u64, len: usize) []const u8 {
    if (len == 0) return &.{};
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @truncate(addr)));
    return ptr[0..len];
}

fn hostCb(msg_type: u8, id: u64, a: u64, b: u64, c: u64) callconv(.c) void {
    const msg: HostMsg = @enumFromInt(msg_type);
    switch (msg) {
        .fetch_success, .fetch_error => {
            fetch.onFetchComplete(id, a, hostBytes(b, @truncate(c)), msg == .fetch_error);
        },
        // Browser-only callbacks.
        else => if (comptime is_client) dispatchClient(msg, id, a, b, c),
    }
}

fn dispatchClient(msg: HostMsg, id: u64, a: u64, b: u64, c: u64) void {
    switch (msg) {
        .timeout, .interval, .event => {
            const cb_type: window.CallbackType = @enumFromInt(@intFromEnum(msg));
            _ = window.dispatchCallback(cb_type, id, a, std.heap.wasm_allocator);
        },
        .ws_open => {
            const protocol = hostBytes(a, @truncate(b));
            websocket.onOpen(id, protocol.ptr, protocol.len);
        },
        .ws_message => {
            const data = hostBytes(a, @truncate(b));
            websocket.onMessage(id, data.ptr, data.len, @truncate(c));
        },
        .ws_error => {
            const message = hostBytes(a, @truncate(b));
            websocket.onError(id, message.ptr, message.len);
        },
        .ws_close => {
            // c: reason length (low 32 bits) | wasClean (high bits).
            const reason = hostBytes(b, @truncate(c));
            const was_clean: u8 = @truncate(c >> 32);
            websocket.onClose(id, @truncate(a), reason.ptr, reason.len, was_clean);
        },
        .fetch_success, .fetch_error => unreachable,
    }
}

comptime {
    if (is_wasm_arch) {
        @export(&hostCb, .{ .name = "__zx_cb" });
    }
}
