const std = @import("std");
const zx = @import("zx");

const ServerApp = zx.server.App;
const Route = ServerApp.Route;

fn pageStatic(ctx: *zx.StaticContext) !void {
    try ctx.params.add(.{ .slug = "from-page" });
}

fn routeStatic(ctx: *zx.StaticContext) !void {
    try ctx.params.add(.{ .slug = "from-route" });
    try ctx.params.add(.{ .slug = "also-route" });
}

fn emptyRoute(path: []const u8) Route {
    return .{ .path = path };
}

test "Route.staticFn: null when neither page nor route sets static" {
    const route = emptyRoute("/posts/:slug");
    try std.testing.expect(route.staticFn() == null);
}

test "Route.staticFn: returns page_opts.static" {
    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
    };
    try std.testing.expect(route.staticFn() == pageStatic);
}

test "Route.staticFn: returns route_opts.static when page unset" {
    const route = Route{
        .path = "/api/:id",
        .route_opts = .{ .static = routeStatic },
    };
    try std.testing.expect(route.staticFn() == routeStatic);
}

test "Route.staticFn: prefers page_opts over route_opts" {
    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
        .route_opts = .{ .static = routeStatic },
    };
    try std.testing.expect(route.staticFn() == pageStatic);
}

test "Route.isDynamic: false by default" {
    const route = emptyRoute("/about");
    try std.testing.expect(!route.isDynamic());
}

test "Route.isDynamic: true from page_opts" {
    const route = Route{
        .path = "/dashboard",
        .page_opts = .{ .dynamic = true },
    };
    try std.testing.expect(route.isDynamic());
}

test "Route.isDynamic: true from route_opts" {
    const route = Route{
        .path = "/api/stream",
        .route_opts = .{ .dynamic = true },
    };
    try std.testing.expect(route.isDynamic());
}

test "Route.isDynamic: true when either opts flag is set" {
    const route = Route{
        .path = "/mixed",
        .page_opts = .{ .dynamic = false },
        .route_opts = .{ .dynamic = true },
    };
    try std.testing.expect(route.isDynamic());
}

test "Route.resolveStaticParams: null when no static fn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const route = emptyRoute("/static");
    try std.testing.expect(try route.resolveStaticParams(arena, std.testing.io) == null);
}

test "Route.resolveStaticParams: runs page static fn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
    };
    const params = (try route.resolveStaticParams(arena, std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqual(@as(usize, 1), params[0].len);
    try std.testing.expectEqualStrings("slug", params[0][0].key);
    try std.testing.expectEqualStrings("from-page", params[0][0].value);
}

test "Route.resolveStaticParams: prefers page static over route static" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
        .route_opts = .{ .static = routeStatic },
    };
    const params = (try route.resolveStaticParams(arena, std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("from-page", params[0][0].value);
}

test "Route.resolveStaticParams: uses route static when page unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const route = Route{
        .path = "/api/:id",
        .route_opts = .{ .static = routeStatic },
    };
    const params = (try route.resolveStaticParams(arena, std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("from-route", params[0][0].value);
    try std.testing.expectEqualStrings("also-route", params[1][0].value);
}
