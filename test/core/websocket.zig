const std = @import("std");
const zx = @import("zx");

const Client = zx.websocket.Client;
const Harness = zx.testing.Harness;
const Backend = zx.testing.Backend;

const io = std.testing.io;
const gpa = std.testing.allocator;

const backends = [_]Backend{ .httpz, .std };

test "websocket > close rejects reserved codes" {
    var ws: Client = .{ .io = io, .allocator = gpa };
    defer ws.deinit();

    try std.testing.expectError(error.InvalidCloseCode, ws.close(.{ .code = 1001 }));
    try std.testing.expectError(error.InvalidCloseCode, ws.close(.{ .code = 5000 }));
    try ws.close(.{ .code = 1000 });
    try ws.close(.{ .code = 4000 });
}

test "websocket > close rejects long reason" {
    var ws: Client = .{ .io = io, .allocator = gpa };
    defer ws.deinit();

    try std.testing.expectError(error.ReasonTooLong, ws.close(.{ .reason = &(@as([124]u8, @splat('x'))) }));
    try ws.close(.{ .reason = &(@as([123]u8, @splat('x'))) });
}

test "websocket > send before connect" {
    var ws: Client = .{ .io = io, .allocator = gpa };
    defer ws.deinit();

    try std.testing.expect(!ws.isConnected());
    try std.testing.expectError(error.ConnectionClosed, ws.send(.{ .text = "hi" }));
}

test "websocket > failed connect resets state" {
    var ws: Client = .{ .io = io, .allocator = gpa };
    defer ws.deinit();

    if (ws.connect(.{ .url = "http://example.com" })) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqual(Client.ReadyState.closed, ws.ready_state);
}

test "websocket > message accessors" {
    const text: zx.websocket.MessageEvent = .{ .data = .{ .text = "a" } };
    const binary: zx.websocket.MessageEvent = .{ .data = .{ .binary = "b" } };

    try std.testing.expectEqualStrings("a", text.text().?);
    try std.testing.expectEqual(null, text.binary());
    try std.testing.expectEqualStrings("b", binary.binary().?);
    try std.testing.expectEqualStrings("b", binary.data.bytes());
}

// --- Native client against the test server's `/ws` echo route --- //

const Recorder = struct {
    io: std.Io,
    text: [512]u8 = undefined,
    text_len: usize = 0,
    binary: [32]u8 = undefined,
    binary_len: usize = 0,
    close_code: u16 = 0,
    echoed: std.Io.Event = .unset,
    closed: std.Io.Event = .unset,

    fn onMessage(client: *Client, event: zx.websocket.MessageEvent) void {
        const recorder = client.userData(Recorder).?;
        switch (event.data) {
            .text => |data| {
                @memcpy(recorder.text[0..data.len], data);
                recorder.text_len = data.len;
            },
            .binary => |data| {
                @memcpy(recorder.binary[0..data.len], data);
                recorder.binary_len = data.len;
                recorder.echoed.set(recorder.io);
            },
        }
    }

    fn onClose(client: *Client, event: zx.websocket.CloseEvent) void {
        const recorder = client.userData(Recorder).?;
        recorder.close_code = event.code;
        recorder.closed.set(recorder.io);
    }
};

test "websocket > echo through each server backend" {
    inline for (backends) |backend| {
        echo(backend) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

fn echo(backend: Backend) !void {
    var harness = try Harness.start(backend, io, gpa, .{});
    defer harness.stop();

    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "ws://127.0.0.1:{d}/ws", .{harness.tcp.?.port});

    var recorder: Recorder = .{ .io = io };
    var ws: Client = .{ .io = io, .allocator = gpa, .onmessage = &Recorder.onMessage, .onclose = &Recorder.onClose };
    defer ws.deinit();

    try ws.connect(.{ .url = url, .user_data = &recorder });
    try std.testing.expect(ws.isConnected());

    // Larger than 125 bytes, so it takes the 16-bit length form.
    const long: [300]u8 = @splat('x');
    try ws.send(.{ .text = &long });
    try ws.send(.{ .text = "hello" });
    try ws.send(.{ .binary = &.{ 1, 2, 3 } });
    try recorder.echoed.waitTimeout(io, after(2_000));
    try std.testing.expectEqualStrings("hello", recorder.text[0..recorder.text_len]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, recorder.binary[0..recorder.binary_len]);

    try ws.close(.{});
    try recorder.closed.waitTimeout(io, after(2_000));
    try std.testing.expectEqual(Client.ReadyState.closed, ws.ready_state);
    try std.testing.expectEqual(1000, recorder.close_code);
}

fn after(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

// A frame far larger than the socket's send buffer must arrive whole.
test "websocket > large frame through each server backend" {
    inline for (backends) |backend| {
        large(backend) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

const Large = struct {
    io: std.Io,
    len: usize = 0,
    intact: bool = false,
    done: std.Io.Event = .unset,

    fn onMessage(client: *Client, event: zx.websocket.MessageEvent) void {
        const self = client.userData(Large).?;
        switch (event.data) {
            .binary => |data| {
                self.len = data.len;
                self.intact = for (data, 0..) |b, i| {
                    if (b != @as(u8, @truncate(i *% 31))) break false;
                } else true;
            },
            .text => |data| if (std.mem.eql(u8, data, "done")) self.done.set(self.io),
        }
    }
};

fn large(backend: Backend) !void {
    var harness = try Harness.start(backend, io, gpa, .{});
    defer harness.stop();

    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "ws://127.0.0.1:{d}/ws", .{harness.tcp.?.port});

    var state: Large = .{ .io = io };
    var ws: Client = .{ .io = io, .allocator = gpa, .onmessage = &Large.onMessage };
    defer ws.deinit();

    try ws.connect(.{ .url = url, .user_data = &state });
    try ws.send(.{ .text = "big" });
    try state.done.waitTimeout(io, after(10_000));
    try std.testing.expectEqual(8 * 1024 * 1024, state.len);
    try std.testing.expect(state.intact);
    try ws.close(.{});
}
