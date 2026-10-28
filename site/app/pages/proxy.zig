const zx = @import("zx");

var _count: usize = 0;
/// Global proxy - cascades to all child routes (like layouts)
/// Called before page/route handlers - can intercept requests
pub fn Proxy(ctx: *zx.ProxyContext) !void {
    // Example: Log all requests
    // _ = ctx;
    _count += 1;
    // std.log.info("Proxy count: {d}", .{_count});
    // Example: Check authentication for all routes
    // if (ctx.request.headers.get("Authorization") == null) {
    //     ctx.response.setStatus(.unauthorized);
    //     ctx.abort(); // Stop chain - no further handlers will run
    //     return;
    // }
    // ctx.next(); // Continue to next handler (optional, continues by default)

    if (_count > 2) {
        // _count = 0;
        // ctx.response.setStatus(.unauthorized);
        // ctx.response.headers.set("Content-Type", "text/plain");
        // ctx.response.text("Unauthorized");
        // return ctx.abort(); // Stop chain - no further handlers will run
    }
    ctx.next(); // Continue to next handler
}

/// Executed before API route handlers (route.zig) - does NOT cascade
pub fn RouteProxy(ctx: *zx.ProxyContext) !void {
    // Example: API-specific authentication
    if (ctx.request.headers.get("Authorization") == null) {
        ctx.response.setStatus(.unauthorized);
        // ctx.abort(); // Uncomment to stop the chain
    }
    ctx.next(); // Continue to route handler
}

/// Executed before page handlers (page.zig) - does NOT cascade
pub fn PageProxy(ctx: *zx.ProxyContext) !void {
    // Example: Log all requests
    // _ = ctx;
    _count += 1;
    // std.log.info("Proxy count: {d}", .{_count});
    // Example: Check authentication for all routes
    // if (ctx.request.headers.get("Authorization") == null) {
    //     ctx.response.setStatus(.unauthorized);
    //     ctx.abort(); // Stop chain - no further handlers will run
    //     return;
    // }
    // ctx.next(); // Continue to next handler (optional, continues by default)

    // if (_count > 2) {
    //     _count = 0;
    //     ctx.response.setStatus(.unauthorized);
    //     ctx.response.headers.set("Content-Type", "text/plain");
    //     ctx.response.text("Unauthorized");
    //     return ctx.abort(); // Stop chain - no further handlers will run
    // }
    ctx.next(); // Continue to next handler
}

pub const options: zx.ProxyOptions = .{
    .pass_through = true,
};
