const std = @import("std");
const zx = @import("zx");

pub fn POST(ctx: zx.RouteContext) !void {
    const auth = ctx.request.headers.get("authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer cf-token")) {
        ctx.response.setStatus(.forbidden);
        return ctx.response.text("forbidden");
    }
    if (!std.mem.endsWith(u8, ctx.request.pathname, "/accounts/acc/flagship/apps/app/evaluate")) {
        ctx.response.setStatus(.not_found);
        return ctx.response.text("no such app");
    }

    const Body = struct { flagKey: []const u8, context: struct { targetingKey: ?[]const u8 = null } };
    const body = try std.json.parseFromSliceLeaky(Body, ctx.arena, ctx.request.text() orelse "", .{ .ignore_unknown_fields = true });

    const Key = enum { checkout, wrapped, mismatch, missing, bad };
    switch (std.meta.stringToEnum(Key, body.flagKey) orelse .missing) {
        .checkout => try ctx.response.json(.{
            .flagKey = body.flagKey,
            .value = body.context.targetingKey != null,
            .variant = "new",
            .reason = "TARGETING_MATCH",
        }, .{}),
        .wrapped => try ctx.response.json(.{
            .success = true,
            .result = .{ .flagKey = body.flagKey, .value = "v2", .variant = "new", .reason = "DEFAULT" },
        }, .{}),
        .mismatch => try ctx.response.json(.{ .flagKey = body.flagKey, .value = false, .errorCode = "TYPE_MISMATCH" }, .{}),
        .missing => {
            ctx.response.setStatus(.not_found);
            try ctx.response.json(.{ .success = false }, .{});
        },
        .bad => {
            ctx.response.setStatus(.bad_request);
            try ctx.response.json(.{ .success = false }, .{});
        },
    }
}
