const std = @import("std");
const zx = @import("zx");
const sse = @import("sse.zig");

const Body = struct {
    model: []const u8,
    messages: []const struct { role: []const u8, content: []const u8 },
    max_tokens: ?u32 = null,
    stream: bool = false,
};

// Replies `<model>|<role initials>|<last message>`.
pub fn POST(ctx: zx.RouteContext) !void {
    const auth = ctx.request.headers.get("authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer test-key")) {
        ctx.response.setStatus(.unauthorized);
        return ctx.response.text("unauthorized");
    }

    const body = try std.json.parseFromSliceLeaky(Body, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });
    var roles: std.ArrayList(u8) = .empty;
    for (body.messages) |m| try roles.append(ctx.arena, m.role[0]);
    const last = body.messages[body.messages.len - 1].content;

    const reply = try std.fmt.allocPrint(ctx.arena, "{s}|{s}|{s}", .{ body.model, roles.items, last });
    const finish = if (body.max_tokens != null) "length" else "stop";
    const usage = .{ .prompt_tokens = body.messages.len, .completion_tokens = 2 };

    if (!body.stream) return ctx.response.json(.{
        .choices = .{.{ .message = .{ .content = reply }, .finish_reason = finish }},
        .usage = usage,
    }, .{});

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.arena, ": keep-alive\n\n");
    var it = sse.chunks(reply);
    while (it.next()) |delta| try sse.event(ctx.arena, &out, null, .{ .choices = .{.{ .delta = .{ .content = delta } }} });
    try sse.event(ctx.arena, &out, null, .{ .choices = .{.{ .delta = .{ .content = @as(?[]const u8, null) }, .finish_reason = finish }} });
    try sse.event(ctx.arena, &out, null, .{ .choices = [_]u32{}, .usage = usage });
    try out.appendSlice(ctx.arena, "data: [DONE]\n\n");
    ctx.response.text(out.items);
}
