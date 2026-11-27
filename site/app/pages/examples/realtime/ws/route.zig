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

    // Replay persisted history (KV on Cloudflare / native FS backend).
    const history = loadHistory(ctx.arena);
    for (history) |msg| {
        try ctx.socket.send(.{ .text = try ctx.fmt(
            "{s}: {s}",
            .{ msg.username, msg.text },
        ) });
    }
}

pub fn Socket(ctx: zx.SocketCtx(SocketData)) !void {
    const raw = ctx.message.bytes();

    // Live typing drafts — not persisted to history.
    // Client: `typing:0` clears; `typing:1:` + draft publishes the pending text.
    if (std.mem.eql(u8, raw, "typing:0") or std.mem.startsWith(u8, raw, "typing:1:")) {
        const draft: []const u8 = if (std.mem.eql(u8, raw, "typing:0"))
            ""
        else
            raw["typing:1:".len..];
        _ = ctx.socket.publish(CHAT_TOPIC, try ctx.fmt(
            "typing:{s}:{s}",
            .{ ctx.data.username(), draft },
        ));
        return;
    }

    const formatted = try ctx.fmt(
        "{s}: {s}",
        .{ ctx.data.username(), raw },
    );

    _ = ctx.socket.publish(CHAT_TOPIC, formatted);
    appendHistory(ctx.arena, ctx.data.username(), raw);
}

pub fn SocketClose(ctx: zx.SocketCloseCtx(SocketData)) void {
    const msg = ctx.fmt(
        "system: {s} left the chat",
        .{ctx.data.username()},
    ) catch return;
    _ = ctx.socket.publish(CHAT_TOPIC, msg);
}

fn chatKv() zx.Kv {
    return zx.kv.scoped(.@"examples/realtime");
}

fn loadHistory(allocator: std.mem.Allocator) []Message {
    return chatKv().as(allocator, HISTORY_KEY, []Message) catch null orelse &.{};
}

fn appendHistory(allocator: std.mem.Allocator, username: []const u8, text: []const u8) void {
    const prev = loadHistory(allocator);
    const start: usize = if (prev.len >= MAX_MESSAGES) prev.len - (MAX_MESSAGES - 1) else 0;
    const kept = prev[start..];

    const next = allocator.alloc(Message, kept.len + 1) catch return;
    for (kept, 0..) |msg, i| {
        next[i] = .{
            .username = allocator.dupe(u8, msg.username) catch return,
            .text = allocator.dupe(u8, msg.text) catch return,
        };
    }
    next[kept.len] = .{
        .username = allocator.dupe(u8, username) catch return,
        .text = allocator.dupe(u8, text) catch return,
    };

    chatKv().putAs(HISTORY_KEY, next, .{}) catch {};
}

const HISTORY_KEY = "messages";
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
