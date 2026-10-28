const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch.isWasm();

// Host imports live in `__zx_<domain>` modules with flat method names
// (same pattern as `__zx_http.commit` / `__zx_net.fetch`).
const ws_ext = struct {
    extern "__zx_ws" fn upgrade() void;
    extern "__zx_ws" fn write(ptr: [*]const u8, len: usize, binary: bool) void;
    extern "__zx_ws" fn close(code: u16, reason_ptr: [*]const u8, reason_len: usize) void;
    extern "__zx_ws" fn recv(buf_ptr: [*]u8, buf_max: usize) i32;
    extern "__zx_ws" fn subscribe(topic_ptr: [*]const u8, topic_len: usize) void;
    extern "__zx_ws" fn unsubscribe(topic_ptr: [*]const u8, topic_len: usize) void;
    extern "__zx_ws" fn publish(topic_ptr: [*]const u8, topic_len: usize, data_ptr: [*]const u8, data_len: usize) usize;
    extern "__zx_ws" fn is_subscribed(topic_ptr: [*]const u8, topic_len: usize) i32;
};

const http_ext = struct {
    extern "__zx_http" fn commit(status: u16, meta_ptr: [*]const u8, meta_len: usize) void;
    extern "__zx_http" fn write(ptr: [*]const u8, len: usize) void;
    extern "__zx_http" fn end() void;
};

const sys_ext = struct {
    extern "__zx_sys" fn park() void;
};

const zx_ext = struct {
    extern "__zx" fn _log(level: u8, ptr: [*]const u8, len: usize) void;
};

pub const ws = struct {
    pub fn upgrade() void {
        if (is_wasm) ws_ext.upgrade();
    }

    pub fn write(data: []const u8, binary: bool) void {
        if (is_wasm) ws_ext.write(data.ptr, data.len, binary);
    }

    pub fn close(code: u16, reason: []const u8) void {
        if (is_wasm) ws_ext.close(code, reason.ptr, reason.len);
    }

    // Null once the socket is closed.
    pub fn recv(buf: []u8) ?usize {
        if (!is_wasm) return null;
        const n = ws_ext.recv(buf.ptr, buf.len);
        return if (n < 0) null else @intCast(n);
    }

    pub fn subscribe(topic: []const u8) void {
        if (is_wasm) ws_ext.subscribe(topic.ptr, topic.len);
    }

    pub fn unsubscribe(topic: []const u8) void {
        if (is_wasm) ws_ext.unsubscribe(topic.ptr, topic.len);
    }

    pub fn publish(topic: []const u8, data: []const u8) usize {
        return if (is_wasm) ws_ext.publish(topic.ptr, topic.len, data.ptr, data.len) else 0;
    }

    pub fn isSubscribed(topic: []const u8) bool {
        if (!is_wasm) return false;
        return ws_ext.is_subscribed(topic.ptr, topic.len) != 0;
    }
};

pub const http = struct {
    // meta: {"streaming":bool,"headers":[[name,value],...]}
    pub fn commit(status: u16, meta: []const u8) void {
        if (is_wasm) http_ext.commit(status, meta.ptr, meta.len);
    }

    pub fn write(bytes: []const u8) void {
        if (is_wasm and bytes.len > 0) http_ext.write(bytes.ptr, bytes.len);
    }

    pub fn end() void {
        if (is_wasm) http_ext.end();
    }
};

pub const sys = struct {
    // Never resumes; the host then serves requests via `__zx_serve`.
    pub fn park() void {
        if (is_wasm) sys_ext.park();
    }
};

pub fn log(level: std.log.Level, message: []const u8) void {
    if (!is_wasm) return;
    const code: u8 = switch (level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    zx_ext._log(code, message.ptr, message.len);
}
