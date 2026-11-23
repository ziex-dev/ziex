const std = @import("std");
const zx = @import("zx");
const app = @import("app.zig");

// Every sign-in endpoint, through `Auth.handle`.
pub const handler = struct {
    pub fn Route(ctx: zx.RouteContext) !void {
        return (try app.of(ctx)).handle(ctx);
    }
};

pub const me = struct {
    pub fn RouteProxy(ctx: *zx.ProxyContext) void {
        const auth = app.of(ctx) catch return ctx.abort();
        if (auth.guard(ctx, "/auth/login")) |owner| ctx.state(owner);
    }

    pub fn GET(ctx: zx.RouteContext) !void {
        const owner = (try app.of(ctx)).account(ctx.arena) orelse return error.Unreachable;
        ctx.response.text(owner.name);
    }

    pub fn POST(ctx: zx.RouteContext) !void {
        return GET(ctx);
    }
};

// The fake provider: code "good" buys token "tok", which reads user 42.
pub const provider_token = struct {
    pub fn POST(ctx: zx.RouteContext) !void {
        const form = ctx.request.formData();
        const verifier: []const u8 = form.get("code_verifier") orelse "";
        const ok = std.mem.eql(u8, form.get("code") orelse "", "good") and
            std.mem.eql(u8, form.get("client_secret") orelse "", "secret") and
            verifier.len == 43;
        if (!ok) return ctx.response.json(.{ .@"error" = "bad_verification_code" }, .{});
        try ctx.response.json(.{ .access_token = "tok", .token_type = "bearer" }, .{});
    }
};

pub const provider_user = struct {
    pub fn GET(ctx: zx.RouteContext) !void {
        if (!std.mem.eql(u8, ctx.request.headers.get("authorization") orelse "", "Bearer tok")) {
            ctx.response.setStatus(.unauthorized);
            return ctx.response.text("unauthorized");
        }
        try ctx.response.json(.{ .id = 42, .login = "octo" }, .{});
    }
};
