/// Runs before every page and route in /examples/auth/*
pub fn Proxy(ctx: *zx.ProxyContext) !void {
    const session = ctx.request.cookies.get("session");
    ctx.state(AuthState{
        .username = session,
        .is_authenticated = session != null,
    });

    if (isProtectedRoute(ctx.request.pathname) and session == null)
        return ctx.response.redirect("/examples/auth?msg=You must be logged in to access /examples/auth/protected route", .found);

    ctx.next();
}

const protected_routes: []const []const u8 = &.{"/examples/auth/protected"};
fn isProtectedRoute(path: []const u8) bool {
    for (protected_routes) |route|
        if (std.mem.eql(u8, path, route))
            return true;

    return false;
}

pub const AuthState = struct {
    username: ?[]const u8,
    is_authenticated: bool = false,
};

const zx = @import("zx");
const std = @import("std");
