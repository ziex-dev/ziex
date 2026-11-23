const std = @import("std");
const zx = @import("zx");
const app = @import("app.zig");

pub const start = struct {
    pub fn GET(ctx: zx.RouteContext) !void {
        const auth = try app.of(ctx);
        const url = try auth.startOAuth(ctx.arena, ctx.request.params.get("provider") orelse "", ctx.request.query.get("next"));
        ctx.response.redirect(url, .see_other);
    }
};

pub const callback = struct {
    pub fn GET(ctx: zx.RouteContext) !void {
        const auth = try app.of(ctx);
        const q = ctx.request.query;
        const next = auth.finishOAuth(ctx.arena, ctx.request.params.get("provider") orelse "", .{
            .state = q.get("state"),
            .code = q.get("code"),
            .@"error" = q.get("error"),
        }) catch |err| {
            ctx.response.setStatus(.forbidden);
            return ctx.response.text(@errorName(err));
        };
        ctx.response.redirect(next, .see_other);
    }
};

pub const logout = struct {
    pub fn POST(ctx: zx.RouteContext) !void {
        (try app.of(ctx)).signOut();
        ctx.response.redirect("/auth/me", .see_other);
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
