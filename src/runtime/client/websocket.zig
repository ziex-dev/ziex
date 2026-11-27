//! Browser side of `zx.websocket.Client`: sockets live in JS and report back
//! through `__zx_cb(ws_open | ws_message | ws_error | ws_close)`.
const std = @import("std");
const builtin = @import("builtin");
const ext = @import("window/extern.zig");
const Client = @import("../core/websocket/Client.zig");

const is_wasm = builtin.cpu.arch.isWasm();

const max_sockets = 32;

pub const State = struct {
    id: ?u64 = null,
};

const Socket = struct {
    id: u64,
    client: *Client,
};

var sockets: [max_sockets]?Socket = @splat(null);
var next_id: u64 = 1;

pub fn connect(client: *Client) Client.Error!void {
    const slot = for (&sockets) |*slot| {
        if (slot.* == null) break slot;
    } else return error.OutOfMemory;

    // JS splits this back into a list for `new WebSocket(url, protocols)`.
    const protocols = try std.mem.join(client.allocator, ",", client._internal.protocols);
    defer client.allocator.free(protocols);

    const id = next_id;
    next_id +%= 1;
    slot.* = .{ .id = id, .client = client };
    client._internal.backend.id = id;

    ext._wsConnect(id, client.url.ptr, client.url.len, protocols.ptr, protocols.len);
}

pub fn send(client: *Client, message: Client.Message) Client.Error!void {
    const id = client._internal.backend.id orelse return error.NotConnected;
    const data = message.bytes();
    ext._wsSend(id, data.ptr, data.len, @intFromBool(message == .binary));
}

pub fn close(client: *Client, options: Client.CloseOptions) void {
    const id = client._internal.backend.id orelse return;
    const reason = options.reason orelse "";
    ext._wsClose(id, options.code orelse 1000, reason.ptr, reason.len);
}

/// Events JS still sends for this socket are dropped.
pub fn deinit(client: *Client) void {
    const id = client._internal.backend.id orelse return;
    release(id);
    client._internal.backend = .{};
}

// Called from `__zx_cb`. Byte arguments were allocated by JS with the wasm allocator.

pub fn onOpen(id: u64, protocol: []const u8) void {
    defer freeHost(protocol);
    const client = find(id) orelse return;
    if (protocol.len > 0) client.protocol = client.allocator.dupe(u8, protocol) catch "";
    client.emitOpen();
}

pub fn onMessage(id: u64, data: []const u8, is_binary: bool) void {
    defer freeHost(data);
    const client = find(id) orelse return;
    client.emitMessage(.{ .data = if (is_binary) .{ .binary = data } else .{ .text = data } });
}

pub fn onError(id: u64, message: []const u8) void {
    defer freeHost(message);
    const client = find(id) orelse return;
    client.emitError(.{ .message = message });
}

pub fn onClose(id: u64, code: u16, reason: []const u8, was_clean: bool) void {
    defer freeHost(reason);
    const client = find(id) orelse return;
    // Released first so `onclose` may reconnect.
    release(id);
    client._internal.backend = .{};
    client.emitClose(.{ .code = code, .reason = reason, .was_clean = was_clean });
}

fn find(id: u64) ?*Client {
    for (sockets) |slot| {
        const socket = slot orelse continue;
        if (socket.id == id) return socket.client;
    }
    return null;
}

fn release(id: u64) void {
    for (&sockets) |*slot| {
        const socket = slot.* orelse continue;
        if (socket.id == id) slot.* = null;
    }
}

fn freeHost(bytes: []const u8) void {
    if (is_wasm and bytes.len > 0) std.heap.wasm_allocator.free(bytes);
}
