//! The AI chat example over the AI SDK UI message stream protocol, so
//! `useChat({ transport: new DefaultChatTransport({ api: "/examples/ai/api" }) })`
//! can talk to it. Extra body fields: `mode` ("text" or "image") and `api_key`.

pub fn POST(ctx: zx.RouteContext) !void {
    const body = try ctx.request.json(Body, .{ .ignore_unknown_fields = true }) orelse
        return zx.Ai.ui.respond(ctx.response, error.InvalidRequest);

    const messages = try zx.Ai.ui.messages(ctx.arena, body.messages);
    if (messages.len == 0) return zx.Ai.ui.respond(ctx.response, error.InvalidRequest);
    const api_key = if (body.api_key) |k| if (k.len > 0) k else null else null;

    if (std.mem.eql(u8, body.mode, "image")) {
        return zx.Ai.ui.respond(ctx.response, zx.ai.gen.streamImage(ctx.allocator, .{
            .model = "gpt-image-1-mini",
            .prompt = messages[messages.len - 1].content,
            .size = "1024x1024",
            .quality = "low",
            .api_key = api_key,
        }));
    }

    try zx.Ai.ui.respond(ctx.response, zx.ai.gen.stream(ctx.allocator, .{
        .model = "gpt-4o-mini",
        .system = "You are a helpful assistant in a short chat demo. Keep replies concise.",
        .messages = messages,
        .max_tokens = 400,
        .api_key = api_key,
    }));
}

const Body = struct {
    messages: []const zx.Ai.ui.Message = &.{},
    mode: []const u8 = "text",
    api_key: ?[]const u8 = null,
};

const std = @import("std");
const zx = @import("zx");
