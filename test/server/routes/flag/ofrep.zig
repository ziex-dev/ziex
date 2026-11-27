const std = @import("std");
const zx = @import("zx");

const Context = struct {
    targetingKey: ?[]const u8 = null,
    plan: ?[]const u8 = null,
};

// Flags are picked by the last path segment.
pub fn POST(ctx: zx.RouteContext) !void {
    const auth = ctx.request.headers.get("authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer test-key")) {
        ctx.response.setStatus(.unauthorized);
        return ctx.response.text("unauthorized");
    }

    const key = ctx.request.pathname[std.mem.findScalarLast(u8, ctx.request.pathname, '/').? + 1 ..];
    const body = try std.json.parseFromSliceLeaky(struct { context: Context }, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });
    const pro = std.mem.eql(u8, body.context.plan orelse "", "pro");

    const Key = enum { @"new-ui", title, limit, ratio, echo, off, missing, @"needs-key" };
    switch (std.meta.stringToEnum(Key, key) orelse .missing) {
        .@"new-ui" => try ctx.response.json(.{
            .key = key,
            .value = pro,
            .variant = if (pro) "on" else "off",
            .reason = if (pro) "TARGETING_MATCH" else "STATIC",
            .metadata = .{ .team = "web" },
        }, .{}),
        .title => try ctx.response.json(.{ .key = key, .value = "Hello", .reason = "STATIC" }, .{}),
        .limit => try ctx.response.json(.{ .key = key, .value = 42, .reason = "STATIC" }, .{}),
        .ratio => try ctx.response.json(.{ .key = key, .value = 0.5, .reason = "SPLIT" }, .{}),
        .echo => try ctx.response.json(.{ .key = key, .value = body.context, .reason = "STATIC" }, .{}),
        .off => try ctx.response.json(.{ .key = key, .reason = "DISABLED" }, .{}),
        .missing => {
            ctx.response.setStatus(.not_found);
            try ctx.response.json(.{ .key = key, .errorCode = "FLAG_NOT_FOUND" }, .{});
        },
        .@"needs-key" => {
            ctx.response.setStatus(.bad_request);
            try ctx.response.json(.{ .key = key, .errorCode = "TARGETING_KEY_MISSING", .errorDetails = "targetingKey is required" }, .{});
        },
    }
}
