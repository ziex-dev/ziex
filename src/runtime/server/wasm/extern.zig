const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch.isWasm();

const host = @import("../../wasm/imports.zig");

const zx_ext = struct {
    extern "__zx" fn _log(level: u8, ptr: [*]const u8, len: usize) void;
};

pub const ws = struct {
    pub fn upgrade() void {
        if (is_wasm) _ = host.call(.ws_upgrade, .{});
    }

    pub fn write(data: []const u8, binary: bool) void {
        if (is_wasm) _ = host.call(.ws_write, .{ data, binary });
    }

    pub fn close(code: u16, reason: []const u8) void {
        if (is_wasm) _ = host.call(.ws_close, .{ code, reason });
    }

    // Null once the socket is closed.
    pub fn recv(buf: []u8) ?usize {
        if (!is_wasm) return null;
        const n = host.wait(.ws_recv, .{buf});
        return if (n < 0) null else @intCast(n);
    }

    pub fn subscribe(topic: []const u8) void {
        if (is_wasm) _ = host.call(.ws_subscribe, .{topic});
    }

    pub fn unsubscribe(topic: []const u8) void {
        if (is_wasm) _ = host.call(.ws_unsubscribe, .{topic});
    }

    pub fn publish(topic: []const u8, data: []const u8) usize {
        return if (is_wasm) @intCast(@max(0, host.call(.ws_publish, .{ topic, data }))) else 0;
    }

    pub fn isSubscribed(topic: []const u8) bool {
        if (!is_wasm) return false;
        return host.call(.ws_is_subscribed, .{topic}) > 0;
    }

    pub fn setPublishToSelf(value: bool) void {
        if (is_wasm) _ = host.call(.ws_set_publish_to_self, .{value});
    }
};

pub const http = struct {
    // meta: {"streaming":bool,"headers":[[name,value],...]}
    pub fn commit(status: u16, meta: []const u8) void {
        if (is_wasm) _ = host.call(.http_commit, .{ status, meta });
    }

    pub fn write(bytes: []const u8) void {
        if (is_wasm and bytes.len > 0) _ = host.call(.http_write, .{bytes});
    }

    pub fn end() void {
        if (is_wasm) _ = host.call(.http_end, .{});
    }
};

pub const sys = struct {
    // Never resumes; the host then serves requests via `__zx_serve`.
    pub fn park() void {
        if (is_wasm) _ = host.wait(.sys_park, .{});
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
