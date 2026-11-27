//! Native side of `zx.websocket.Client`. `std.http.Client` performs the upgrade
//! (and TLS for `wss://`); frames are then read on a concurrent `Io` task, so
//! handlers run off the calling thread.
const std = @import("std");
const Client = @import("Client.zig");

const Opcode = std.http.Server.WebSocket.Opcode;
const Header0 = std.http.Server.WebSocket.Header0;
const Header1 = std.http.Server.WebSocket.Header1;

/// Longest message, possibly fragmented, the reader will buffer.
const max_message_len = 16 * 1024 * 1024;
const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const State = struct {
    conn: ?*Connection = null,
};

const Connection = struct {
    http: std.http.Client,
    request: std.http.Client.Request,
    client: *Client,
    reader: std.Io.Future(void) = .{ .any_future = null, .result = {} },
    write_lock: std.Io.Mutex = .init,

    fn stream(conn: *Connection) *std.http.Client.Connection {
        return conn.request.connection.?;
    }

    /// Closes the socket. `Request.deinit` is not used: after a 101 it would
    /// try to drain a response body until EOF.
    fn release(conn: *Connection) void {
        const stream_conn = conn.stream();
        stream_conn.closing = true;
        conn.http.connection_pool.release(stream_conn, conn.client.io);
    }

    fn destroy(conn: *Connection) void {
        conn.reader.cancel(conn.client.io);
        conn.release();
        conn.http.deinit();
        conn.client.allocator.destroy(conn);
    }

    fn writeFrame(conn: *Connection, opcode: Opcode, payload: []const u8) !void {
        const io = conn.client.io;
        conn.write_lock.lockUncancelable(io);
        defer conn.write_lock.unlock(io);

        const out = conn.stream().writer();
        try out.writeByte(@bitCast(@as(Header0, .{ .opcode = opcode, .fin = true })));
        switch (payload.len) {
            0...125 => try out.writeByte(@bitCast(@as(Header1, .{ .payload_len = @fromBackingInt(@intCast(payload.len)), .mask = true }))),
            126...0xffff => {
                try out.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len16, .mask = true })));
                try out.writeInt(u16, @intCast(payload.len), .big);
            },
            else => {
                try out.writeByte(@bitCast(@as(Header1, .{ .payload_len = .len64, .mask = true })));
                try out.writeInt(u64, payload.len, .big);
            },
        }

        var mask: [4]u8 = undefined;
        io.random(&mask);
        try out.writeAll(&mask);
        // Masked through a small buffer so the caller's bytes stay untouched.
        var chunk: [512]u8 = undefined;
        var start: usize = 0;
        while (start < payload.len) {
            const len = @min(chunk.len, payload.len - start);
            for (chunk[0..len], payload[start..][0..len], start..) |*masked, byte, i| masked.* = byte ^ mask[i % 4];
            try out.writeAll(chunk[0..len]);
            start += len;
        }
        try conn.stream().flush();
    }
};

pub fn connect(client: *Client) Client.Error!void {
    const uri = std.Uri.parse(client.url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "ws") and !std.mem.eql(u8, uri.scheme, "wss")) return error.InvalidUrl;

    const gpa = client.allocator;
    const io = client.io;
    const conn = try gpa.create(Connection);
    errdefer gpa.destroy(conn);
    conn.* = .{
        .http = .{ .allocator = gpa, .io = io },
        .request = undefined,
        .client = client,
    };
    errdefer conn.http.deinit();

    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &nonce);

    const protocols = try std.mem.join(gpa, ", ", client._internal.protocols);
    defer gpa.free(protocols);
    const headers = [_]std.http.Header{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "sec-websocket-key", .value = &key },
        .{ .name = "sec-websocket-protocol", .value = protocols },
    };

    conn.request = conn.http.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .connection = .{ .override = "upgrade" } },
        .extra_headers = if (protocols.len > 0) &headers else headers[0..3],
    }) catch |err| return mapError(err);
    errdefer conn.release();

    conn.request.sendBodiless() catch return error.ConnectionFailed;
    const response = conn.request.receiveHead(&.{}) catch |err| return mapError(err);
    if (response.head.status != .switching_protocols) return error.ConnectionFailed;

    var accepted = false;
    var protocol: []const u8 = "";
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-accept")) {
            accepted = std.mem.eql(u8, h.value, &acceptKey(&key));
        } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-protocol")) {
            protocol = h.value;
        }
    }
    if (!accepted) return error.ConnectionFailed;
    if (protocol.len > 0) client.protocol = try gpa.dupe(u8, protocol);

    client._internal.backend.conn = conn;
    errdefer client._internal.backend = .{};
    client.emitOpen();

    conn.reader = io.concurrent(readLoop, .{conn}) catch return error.ConcurrencyUnavailable;
}

pub fn send(client: *Client, message: Client.Message) Client.Error!void {
    const conn = client._internal.backend.conn orelse return error.NotConnected;
    const opcode: Opcode = switch (message) {
        .text => .text,
        .binary => .binary,
    };
    conn.writeFrame(opcode, message.bytes()) catch return error.SendFailed;
}

/// Sends a close frame; `onclose` fires when the server echoes it.
pub fn close(client: *Client, options: Client.CloseOptions) void {
    const conn = client._internal.backend.conn orelse return;
    writeClose(conn, options.code orelse 1000, options.reason orelse "") catch {};
}

pub fn deinit(client: *Client) void {
    const conn = client._internal.backend.conn orelse return;
    conn.destroy();
    client._internal.backend = .{};
}

fn readLoop(conn: *Connection) void {
    const client = conn.client;
    readFrames(conn) catch |err| {
        if (client.ready_state == .open) client.emitError(.{ .message = @errorName(err) });
        client.emitClose(.{ .code = 1006, .reason = "", .was_clean = false });
    };
}

fn readFrames(conn: *Connection) !void {
    const client = conn.client;
    const in = conn.stream().reader();
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(client.allocator);
    var message_opcode: ?Opcode = null;
    var control: [125]u8 = undefined;

    while (true) {
        const header = try in.takeArray(2);
        const h0: Header0 = @bitCast(header[0]);
        const h1: Header1 = @bitCast(header[1]);
        if (h1.mask) return error.MaskedServerFrame;
        const len = switch (h1.payload_len) {
            .len16 => try in.takeInt(u16, .big),
            .len64 => try in.takeInt(u64, .big),
            else => @backingInt(h1.payload_len),
        };

        switch (h0.opcode) {
            .text, .binary, .continuation => {
                if ((h0.opcode == .continuation) != (message_opcode != null)) return error.UnexpectedOpcode;
                if (message.items.len + len > max_message_len) return error.MessageTooLong;
                if (message_opcode == null) {
                    message.clearRetainingCapacity();
                    message_opcode = h0.opcode;
                }
                try in.readSliceAll(try message.addManyAsSlice(client.allocator, @intCast(len)));
                if (!h0.fin) continue;

                const data = message.items;
                client.emitMessage(.{ .data = if (message_opcode.? == .binary) .{ .binary = data } else .{ .text = data } });
                message_opcode = null;
            },
            .ping, .pong, .connection_close => {
                if (!h0.fin or len > control.len) return error.InvalidControlFrame;
                const payload = control[0..@intCast(len)];
                try in.readSliceAll(payload);
                switch (h0.opcode) {
                    .ping => try conn.writeFrame(.pong, payload),
                    .connection_close => {
                        const code = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                        const reason = if (payload.len > 2) payload[2..] else "";
                        // Echo the server's close unless this side started the handshake.
                        if (client.ready_state == .open) writeClose(conn, if (code == 1005) 1000 else code, "") catch {};
                        client.emitClose(.{ .code = code, .reason = reason, .was_clean = true });
                        return;
                    },
                    else => {},
                }
            },
            _ => return error.UnexpectedOpcode,
        }
    }
}

fn writeClose(conn: *Connection, code: u16, reason: []const u8) !void {
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    @memcpy(payload[2..][0..reason.len], reason);
    try conn.writeFrame(.connection_close, payload[0 .. 2 + reason.len]);
}

fn acceptKey(key: []const u8) [28]u8 {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(key);
    sha1.update(accept_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

fn mapError(err: anyerror) Client.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong, error.InvalidHostName => error.InvalidUrl,
        else => error.ConnectionFailed,
    };
}
