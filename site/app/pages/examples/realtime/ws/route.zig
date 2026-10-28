pub fn GET(ctx: zx.RouteContext) !void {
    const uname = ctx.request.cookies.get("username") orelse "";
    if (uname.len == 0) {
        ctx.response.setStatus(.bad_request);
        return ctx.response.text("Missing username cookie");
    }

    // Copy username into fixed-size buffer so it's embedded in the struct bytes
    var data = SocketData{};
    const len = @min(uname.len, data.buf.len);
    @memcpy(data.buf[0..len], uname[0..len]);
    data.len = len;

    try ctx.socket.upgrade(data);
}

const MAX_MESSAGES = 100;
pub fn SocketOpen(ctx: zx.SocketOpenCtx(SocketData)) !void {
    ctx.socket.configure(.{ .publish_to_self = true });
    ctx.socket.subscribe(CHAT_TOPIC);

    _ = ctx.socket.publish(CHAT_TOPIC, try ctx.fmt(
        "system: {s} joined the chat",
        .{ctx.data.username()},
    ));

    // Send last 5 messages (oldest to newest for correct display with column-reverse)
    const msg_count = messages.items.len;
    const start_idx = if (msg_count > MAX_MESSAGES) msg_count - MAX_MESSAGES else 0;
    for (messages.items[start_idx..]) |msg| {
        try ctx.socket.send(.{ .text = try ctx.fmt(
            "{s}: {s}",
            .{ msg.username, msg.text },
        ) });
    }
}

pub fn Socket(ctx: zx.SocketCtx(SocketData)) !void {
    const formatted = try ctx.fmt(
        "{s}: {s}",
        .{ ctx.data.username(), ctx.message.bytes() },
    );

    _ = ctx.socket.publish(CHAT_TOPIC, formatted);

    const gpa = std.heap.page_allocator;
    const text = gpa.dupe(u8, ctx.message.bytes()) catch return;
    const username = gpa.dupe(u8, ctx.data.username()) catch {
        gpa.free(text);
        return;
    };
    messages.append(gpa, .{ .text = text, .username = username }) catch {
        gpa.free(text);
        gpa.free(username);
        return;
    };
    while (messages.items.len > MAX_MESSAGES) {
        const old = messages.orderedRemove(0);
        gpa.free(old.text);
        gpa.free(old.username);
    }
}

pub fn SocketClose(ctx: zx.SocketCloseCtx(SocketData)) void {
    const msg = ctx.fmt(
        "system: {s} left the chat",
        .{ctx.data.username()},
    ) catch return;
    _ = ctx.socket.publish(CHAT_TOPIC, msg);
}

var messages = std.ArrayList(Message).empty;

const CHAT_TOPIC = "chat-room";
const Message = struct { text: []const u8, username: []const u8 };

/// Socket data with fixed-size buffer so username bytes are embedded in struct
const SocketData = struct {
    buf: [32]u8 = @splat(0),
    len: usize = 0,

    pub fn username(self: *const SocketData) []const u8 {
        return self.buf[0..self.len];
    }
};

const std = @import("std");
const zx = @import("zx");
