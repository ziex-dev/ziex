const std = @import("std");
const zx = @import("zx");

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    response_format: ?[]const u8 = null,
};

// `dall-e*` replies with a URL to the prompt, other models with it as base64 webp.
pub fn POST(ctx: zx.RouteContext) !void {
    const body = try std.json.parseFromSliceLeaky(Body, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });
    if (body.response_format != null) {
        ctx.response.setStatus(.bad_request);
        return ctx.response.text("Unknown parameter: 'response_format'.");
    }

    if (std.mem.startsWith(u8, body.model, "dall-e")) {
        const host = ctx.request.headers.get("host") orelse "";
        const link = try std.fmt.allocPrint(ctx.arena, "http://{s}/echo?q={s}", .{ host, body.prompt });
        return ctx.response.json(.{ .data = .{.{ .url = link }} }, .{});
    }

    const encoder = std.base64.standard.Encoder;
    const encoded = try ctx.arena.alloc(u8, encoder.calcSize(body.prompt.len));
    try ctx.response.json(.{ .data = .{.{ .b64_json = encoder.encode(encoded, body.prompt) }}, .output_format = "webp" }, .{});
}
