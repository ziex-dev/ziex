const std = @import("std");
const zx = @import("zx");
const sse = @import("sse.zig");

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    response_format: ?[]const u8 = null,
    stream: bool = false,
    partial_images: u8 = 0,
};

// `dall-e*` replies with a URL to the prompt, other models with it as base64 webp.
// Streaming sends `partial_images` previews of the prompt's prefix, then the prompt.
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

    if (!body.stream) return ctx.response.json(.{ .data = .{.{ .b64_json = try encode(ctx.arena, body.prompt) }}, .output_format = "webp" }, .{});

    var out: std.ArrayList(u8) = .empty;
    for (0..body.partial_images) |i| try sse.event(ctx.arena, &out, "image_generation.partial_image", .{
        .type = "image_generation.partial_image",
        .partial_image_index = i,
        .b64_json = try encode(ctx.arena, body.prompt[0 .. (i + 1) * body.prompt.len / (body.partial_images + 1)]),
        .output_format = "webp",
    });
    try sse.event(ctx.arena, &out, "image_generation.completed", .{
        .type = "image_generation.completed",
        .b64_json = try encode(ctx.arena, body.prompt),
        .output_format = "webp",
        .usage = .{ .input_tokens = 3, .output_tokens = 7 },
    });
    ctx.response.text(out.items);
}

fn encode(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try arena.alloc(u8, encoder.calcSize(raw.len)), raw);
}
