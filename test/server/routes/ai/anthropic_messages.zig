const std = @import("std");
const zx = @import("zx");
const sse = @import("sse.zig");

const Body = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    messages: []const struct { role: []const u8, content: []const u8 },
    stream: bool = false,
};

// Replies `<model>|<system>|<role initials>|` then `<last message>` as a second text block.
pub fn POST(ctx: zx.RouteContext) !void {
    const key = ctx.request.headers.get("x-api-key") orelse "";
    if (!std.mem.eql(u8, key, "test-key") or ctx.request.headers.get("anthropic-version") == null) {
        ctx.response.setStatus(.unauthorized);
        return ctx.response.text("unauthorized");
    }

    const body = try std.json.parseFromSliceLeaky(Body, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });
    var roles: std.ArrayList(u8) = .empty;
    for (body.messages) |m| try roles.append(ctx.arena, m.role[0]);

    const head = try ctx.arena.print("{s}|{s}|{s}|", .{ body.model, body.system orelse "-", roles.items });
    const last = body.messages[body.messages.len - 1].content;
    const stop = if (body.max_tokens == 4096) "end_turn" else "max_tokens";

    if (!body.stream) return ctx.response.json(.{
        .content = .{
            .{ .type = "text", .text = head },
            .{ .type = "tool_use", .id = "toolu_1" },
            .{ .type = "text", .text = last },
        },
        .stop_reason = stop,
        .usage = .{ .input_tokens = 3, .output_tokens = 5 },
    }, .{});

    // `claude-error` fails after the first delta.
    const fail = std.mem.eql(u8, body.model, "claude-error");
    var out: std.ArrayList(u8) = .empty;
    try sse.event(ctx.arena, &out, "message_start", .{ .type = "message_start", .message = .{ .usage = .{ .input_tokens = 3, .output_tokens = 1 } } });
    try sse.event(ctx.arena, &out, "ping", .{ .type = "ping" });
    var it = sse.chunks(try std.mem.concat(ctx.arena, u8, &.{ head, last }));
    while (it.next()) |delta| {
        try sse.event(ctx.arena, &out, "content_block_delta", .{ .type = "content_block_delta", .index = 0, .delta = .{ .type = "text_delta", .text = delta } });
        if (fail) {
            try sse.event(ctx.arena, &out, "error", .{ .type = "error", .@"error" = .{ .type = "overloaded_error", .message = "Overloaded" } });
            break;
        }
    }
    try sse.event(ctx.arena, &out, "message_delta", .{ .type = "message_delta", .delta = .{ .stop_reason = stop }, .usage = .{ .output_tokens = 5 } });
    try sse.event(ctx.arena, &out, "message_stop", .{ .type = "message_stop" });
    ctx.response.text(out.items);
}
