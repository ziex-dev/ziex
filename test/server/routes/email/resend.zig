const std = @import("std");
const zx = @import("zx");

const Body = struct {
    from: []const u8,
    to: []const []const u8 = &.{},
    cc: []const []const u8 = &.{},
    reply_to: []const []const u8 = &.{},
    subject: []const u8,
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    attachments: []const struct { filename: []const u8, content: []const u8, content_type: ?[]const u8 = null } = &.{},
};

// Replies with an id that echoes what was received:
// `<from>|<to,...>|<cc,...>|<reply_to,...>|<subject>|<X-Tag>|<idempotency-key>|<filename>=<decoded content>`.
pub fn POST(ctx: zx.RouteContext) !void {
    const auth = ctx.request.headers.get("authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer test-key")) {
        ctx.response.setStatus(.unauthorized);
        return ctx.response.json(.{ .name = "validation_error", .message = "API key is invalid" }, .{});
    }

    const body = try std.json.parseFromSliceLeaky(Body, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });
    if (std.mem.eql(u8, body.subject, "limit")) {
        ctx.response.setStatus(.too_many_requests);
        return ctx.response.json(.{ .name = "rate_limit_exceeded" }, .{});
    }
    if (std.mem.eql(u8, body.subject, "reject")) {
        ctx.response.setStatus(.unprocessable_entity);
        return ctx.response.json(.{ .name = "validation_error" }, .{});
    }

    var att: []const u8 = "";
    if (body.attachments.len > 0) {
        const a = body.attachments[0];
        const decoder = std.base64.standard.Decoder;
        const bytes = try ctx.arena.alloc(u8, try decoder.calcSizeForSlice(a.content));
        try decoder.decode(bytes, a.content);
        att = try ctx.arena.print("{s}={s}", .{ a.filename, bytes });
    }
    const tag = if (body.headers) |h| h.map.get("X-Tag") orelse "" else "";

    const id = try ctx.arena.print("{s}|{s}|{s}|{s}|{s}|{s}|{s}|{s}", .{
        body.from,
        try std.mem.join(ctx.arena, ",", body.to),
        try std.mem.join(ctx.arena, ",", body.cc),
        try std.mem.join(ctx.arena, ",", body.reply_to),
        body.subject,
        tag,
        ctx.request.headers.get("idempotency-key") orelse "",
        att,
    });
    try ctx.response.json(.{ .id = id }, .{});
}
