const std = @import("std");
const builtin = @import("builtin");
const ext = @import("window/extern.zig");
const WebSocket = @import("../core/WebSocket.zig");

const CloseOptions = WebSocket.CloseOptions;
const MessageEvent = WebSocket.MessageEvent;
const CloseEvent = WebSocket.CloseEvent;
const ErrorEvent = WebSocket.ErrorEvent;

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

var next_ws_id: u64 = 1;
const MAX_WEBSOCKETS = 32;

const WebSocketSlot = struct {
    active: bool = false,
    ws_id: u64 = 0,
    ws: ?*WebSocket = null,
};

var ws_slots: [MAX_WEBSOCKETS]WebSocketSlot = @splat(WebSocketSlot{});

fn findOrAllocSlot(ws_id: u64) ?usize {
    const preferred: usize = @intCast(ws_id % MAX_WEBSOCKETS);
    if (!ws_slots[preferred].active) {
        return preferred;
    }
    for (&ws_slots, 0..) |*slot, i| {
        if (!slot.active) return i;
    }
    return null;
}

fn findSlotByWsId(ws_id: u64) ?usize {
    const preferred: usize = @intCast(ws_id % MAX_WEBSOCKETS);
    if (ws_slots[preferred].active and ws_slots[preferred].ws_id == ws_id) {
        return preferred;
    }
    for (&ws_slots, 0..) |*slot, i| {
        if (slot.active and slot.ws_id == ws_id) return i;
    }
    return null;
}

fn getWebSocketById(ws_id: u64) ?*WebSocket {
    if (findSlotByWsId(ws_id)) |idx| {
        return ws_slots[idx].ws;
    }
    return null;
}

pub fn connect(ws: *WebSocket) WebSocket.Error!void {
    const ws_id = next_ws_id;
    next_ws_id +%= 1;

    // Store in registry
    const slot_index = findOrAllocSlot(ws_id) orelse return error.OutOfMemory;

    ws_slots[slot_index] = WebSocketSlot{
        .active = true,
        .ws_id = ws_id,
        .ws = ws,
    };

    // Store ws_id in backend context (truncate to usize for 32-bit WASM)
    ws.userdata = @ptrFromInt(@as(usize, @truncate(ws_id)));

    // Serialize protocols if any
    var protocols_buf: [1024]u8 = undefined;
    var protocols_len: usize = 0;

    if (ws._requested_protocols) |protocols| {
        for (protocols, 0..) |proto, i| {
            if (i > 0) {
                protocols_buf[protocols_len] = ',';
                protocols_len += 1;
            }
            const end = @min(protocols_len + proto.len, protocols_buf.len);
            @memcpy(protocols_buf[protocols_len..end], proto[0..@min(proto.len, end - protocols_len)]);
            protocols_len = end;
        }
    }

    // Call JS to create WebSocket
    ext._wsConnect(
        ws_id,
        ws.url.ptr,
        ws.url.len,
        &protocols_buf,
        protocols_len,
    );
}

pub fn send(ws: *WebSocket, data: []const u8) WebSocket.Error!void {
    const ws_id = getWsId(ws) orelse return error.NotConnected;
    ext._wsSend(ws_id, data.ptr, data.len, 0);
}

pub fn sendBinary(ws: *WebSocket, data: []const u8) WebSocket.Error!void {
    const ws_id = getWsId(ws) orelse return error.NotConnected;
    ext._wsSend(ws_id, data.ptr, data.len, 1);
}

pub fn close(ws: *WebSocket, options: CloseOptions) void {
    const ws_id = getWsId(ws) orelse return;
    const code = options.code orelse 1000;
    const reason = options.reason orelse "";

    ext._wsClose(ws_id, code, reason.ptr, reason.len);
}

pub fn deinit(ws: *WebSocket) void {
    const ws_id = getWsId(ws) orelse return;

    if (findSlotByWsId(ws_id)) |idx| {
        ws_slots[idx].active = false;
        ws_slots[idx].ws = null;
    }

    ws.userdata = null;
}

fn getWsId(ws: *WebSocket) ?u64 {
    if (ws.userdata) |ptr| {
        return @intFromPtr(ptr);
    }
    return null;
}

/// Called via `__zx_cb` when WebSocket connection opens
pub fn onOpen(ws_id: u64, protocol_ptr: [*]const u8, protocol_len: usize) void {
    const ws = getWebSocketById(ws_id) orelse {
        if (comptime is_wasm) {
            if (protocol_len > 0) std.heap.wasm_allocator.free(protocol_ptr[0..protocol_len]);
        }
        return;
    };
    defer if (comptime is_wasm) {
        if (protocol_len > 0) std.heap.wasm_allocator.free(protocol_ptr[0..protocol_len]);
    };

    // Dupe protocol string as it needs to persist
    if (protocol_len > 0) {
        ws.protocol = ws._allocator.dupe(u8, protocol_ptr[0..protocol_len]) catch "";
    }
    ws._handleOpen();
}

/// Called via `__zx_cb` when a text/binary message is received
pub fn onMessage(ws_id: u64, data_ptr: [*]const u8, data_len: usize, is_binary: u8) void {
    const ws = getWebSocketById(ws_id) orelse {
        if (comptime is_wasm) {
            if (data_len > 0) std.heap.wasm_allocator.free(data_ptr[0..data_len]);
        }
        return;
    };
    defer if (comptime is_wasm) {
        if (data_len > 0) std.heap.wasm_allocator.free(data_ptr[0..data_len]);
    };

    const data = data_ptr[0..data_len];

    if (is_binary != 0) {
        ws._handleMessage(.{ .data = .{ .binary = data } });
    } else {
        ws._handleMessage(.{ .data = .{ .text = data } });
    }
}

/// Called via `__zx_cb` when an error occurs
pub fn onError(ws_id: u64, msg_ptr: [*]const u8, msg_len: usize) void {
    const ws = getWebSocketById(ws_id) orelse {
        if (comptime is_wasm) {
            if (msg_len > 0) std.heap.wasm_allocator.free(msg_ptr[0..msg_len]);
        }
        return;
    };
    defer if (comptime is_wasm) {
        if (msg_len > 0) std.heap.wasm_allocator.free(msg_ptr[0..msg_len]);
    };

    ws._handleError(.{ .message = msg_ptr[0..msg_len] });
}

/// Called via `__zx_cb` when connection closes
pub fn onClose(ws_id: u64, code: u16, reason_ptr: [*]const u8, reason_len: usize, was_clean: u8) void {
    const ws = getWebSocketById(ws_id) orelse {
        if (comptime is_wasm) {
            if (reason_len > 0) std.heap.wasm_allocator.free(reason_ptr[0..reason_len]);
        }
        return;
    };
    defer if (comptime is_wasm) {
        if (reason_len > 0) std.heap.wasm_allocator.free(reason_ptr[0..reason_len]);
    };

    ws._handleClose(.{
        .code = code,
        .reason = reason_ptr[0..reason_len],
        .was_clean = was_clean != 0,
    });

    // Clean up slot
    if (findSlotByWsId(ws_id)) |idx| {
        ws_slots[idx].active = false;
        ws_slots[idx].ws = null;
    }
}
