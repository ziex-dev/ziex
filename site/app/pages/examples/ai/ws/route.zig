//! Streams `zx.ai.gen.stream` / `streamImage` over a WebSocket for the AI chat example.
//!
//! Client sends one JSON text frame:
//!   `{"mode":"text","messages":[{"role":"user","content":"..."}],"api_key":"...?"}`
//!   `{"mode":"image","prompt":"...","api_key":"...?"}`
//! Text: plain delta frames, then `[DONE]` (or `error:Name`).
//! Image: for each partial/final PNG: text `image-bin` then one binary frame, then `[DONE]`.

pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.socket.upgrade({});
}

pub fn Socket(ctx: zx.SocketContext) !void {
    handle(ctx) catch |err| sendError(ctx, err) catch {};
}

fn handle(ctx: zx.SocketContext) !void {
    const req = std.json.parseFromSliceLeaky(Request, ctx.arena, ctx.message.bytes(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidRequest;
    const key = std.mem.trim(u8, req.api_key orelse "", " \t\r\n");
    const api_key = if (key.len > 0) key else null;

    if (std.mem.eql(u8, req.mode, "image")) return handleImage(ctx, req.prompt orelse "", api_key);
    try handleText(ctx, req.messages, api_key);
}

fn handleText(ctx: zx.SocketContext, wire: []const zx.Ai.ui.Message, api_key: ?[]const u8) !void {
    const messages = try zx.Ai.ui.messages(ctx.arena, wire);
    if (messages.len == 0) return error.InvalidRequest;

    const stream = try zx.ai.gen.stream(ctx.allocator, .{
        .model = "gpt-4o-mini",
        .system = "You are a helpful assistant in a short chat demo. Keep replies concise.",
        .messages = messages,
        .max_tokens = 400,
        .api_key = api_key,
    });
    defer stream.deinit();

    while (try stream.next()) |event| switch (event) {
        .text => |delta| try ctx.socket.send(.{ .text = delta }),
        .image => {},
    };
    try ctx.socket.send(.{ .text = "[DONE]" });
}

fn handleImage(ctx: zx.SocketContext, prompt_raw: []const u8, api_key: ?[]const u8) !void {
    const prompt = std.mem.trim(u8, prompt_raw, " \t\r\n");
    if (prompt.len == 0) return error.InvalidRequest;

    const stream = try zx.ai.gen.streamImage(ctx.allocator, .{
        .model = "gpt-image-1-mini",
        .prompt = prompt,
        .size = "1024x1024",
        .quality = "low",
        .partial_images = 2,
        .api_key = api_key,
    });
    defer stream.deinit();

    var sent: usize = 0;
    while (try stream.next()) |event| switch (event) {
        .text => {},
        .image => |img| {
            const bytes = try img.decode(ctx.allocator);
            defer ctx.allocator.free(bytes);
            // Raw bytes in a binary frame rather than megabytes of base64 text.
            try ctx.socket.send(.{ .text = "image-bin" });
            try ctx.socket.send(.{ .binary = bytes });
            sent += 1;
        },
    };
    if (sent == 0) return error.InvalidResponse;
    try ctx.socket.send(.{ .text = "[DONE]" });
}

fn sendError(ctx: zx.SocketContext, err: anyerror) !void {
    try ctx.socket.send(.{ .text = try ctx.fmt("error:{s}", .{@errorName(err)}) });
}

const Request = struct {
    mode: []const u8 = "text",
    messages: []const zx.Ai.ui.Message = &.{},
    prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

const std = @import("std");
const zx = @import("zx");
