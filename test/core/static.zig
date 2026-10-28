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

test "static fn > null when neither page nor route sets static" {
    const route = emptyRoute("/posts/:slug");
    try std.testing.expect(route.staticFn() == null);
}

test "static fn > returns page_opts.static" {
    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
    };
    try std.testing.expect(route.staticFn() == pageStatic);
}

test "static fn > returns route_opts.static when page unset" {
    const route = Route{
        .path = "/api/:id",
        .route_opts = .{ .static = routeStatic },
    };
    try std.testing.expect(route.staticFn() == routeStatic);
}

test "static fn > prefers page_opts over route_opts" {
    const route = Route{
        .path = "/posts/:slug",
        .page_opts = .{ .static = pageStatic },
        .route_opts = .{ .static = routeStatic },
    };
    try std.testing.expect(route.staticFn() == pageStatic);
}

test "dynamic > false by default" {
    const route = emptyRoute("/about");
    try std.testing.expect(!route.isDynamic());
}

test "dynamic > true from rendering" {
    const route = Route{
        .path = "/dashboard",
        .rendering = .request,
    };
    try std.testing.expect(route.isDynamic());
}

test "prerender > default route exported only in full static builds" {
    const route = emptyRoute("/about");
    try std.testing.expect(!route.skipsStatic(false));
    try std.testing.expect(route.skipsStatic(true));
}

test "prerender > prerendered rendering exported in prerender builds" {
    const route = Route{
        .path = "/about",
        .rendering = .prerendered,
    };
    try std.testing.expect(!route.skipsStatic(false));
    try std.testing.expect(!route.skipsStatic(true));
}

test "prerender > request rendering never exported" {
    const route = Route{
        .path = "/dashboard",
        .rendering = .request,
    };
    try std.testing.expect(route.skipsStatic(false));
    try std.testing.expect(route.skipsStatic(true));
}

test "static params > null when no static fn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const route = emptyRoute("/static");
    try std.testing.expect(try route.resolveStaticParams(arena, std.testing.io) == null);
}

test "static params > runs page static fn" {
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

test "static params > prefers page static over route static" {
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

test "static params > uses route static when page unset" {
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
