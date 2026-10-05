const std = @import("std");

const zx = @import("../../../root.zig");
const core_handler = @import("Router/Handler.zig");
const render = @import("../../server/render.zig");
const Http = @import("../Http.zig");
const server = @import("../../server/Server.zig");

const Component = zx.Component;
const ServerApp = zx.server.App;
const Route = ServerApp.Route;

const app = .{
    .meta = server.server_app,
};

pub const FindRouteOptions = struct {
    match: enum { closest, exact } = .exact,
    has_notfound: bool = false,
    has_error: bool = false,
};

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Holds the result of a pattern-matched route lookup, including any extracted URL params.
pub const RouteMatch = struct {
    route: *const Route,
    params: [8]Param = undefined,
    param_count: usize = 0,

    pub fn getParam(self: *const RouteMatch, name: []const u8) ?[]const u8 {
        for (self.params[0..self.param_count]) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }
};

pub const ProxyResult = struct {
    aborted: bool = false,
    state_ptr: ?*const anyopaque = null,
};

/// Execute cascading Proxy() handlers from root "/" down to the target path, plus optional local proxy.
pub fn executeProxyChain(
    path: []const u8,
    local_proxy: ?ServerApp.ProxyHandler,
    req: zx.server.Request,
    res: zx.server.Response,
    arena: std.mem.Allocator,
    io: std.Io,
) ProxyResult {
    var proxy_ctx = zx.ProxyContext.init(req, res, arena, arena, io);
    var proxies: [16]ServerApp.ProxyHandler = undefined;
    var count: usize = 0;

    // Root "/" proxy
    for (app.meta.routes) |*route| {
        if (std.mem.eql(u8, route.path, "/")) {
            if (route.proxy) |proxy_fn| {
                if (count < proxies.len) {
                    proxies[count] = proxy_fn;
                    count += 1;
                }
            }
            break;
        }
    }

    // Build path segments and check each intermediate path
    var segments: [32][]const u8 = undefined;
    var seg_count: usize = 0;
    var seg_iter = std.mem.splitScalar(u8, path, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len > 0 and seg_count < segments.len) {
            segments[seg_count] = seg;
            seg_count += 1;
        }
    }

    for (1..seg_count + 1) |depth| {
        var path_buf: [256]u8 = undefined;
        var offset: usize = 0;
        for (0..depth) |d| {
            path_buf[offset] = '/';
            offset += 1;
            const seg = segments[d];
            @memcpy(path_buf[offset .. offset + seg.len], seg);
            offset += seg.len;
        }
        const check_path = path_buf[0..offset];
        if (std.mem.eql(u8, check_path, "/")) continue;

        for (app.meta.routes) |*route| {
            if (std.mem.eql(u8, route.path, check_path)) {
                if (route.proxy) |proxy_fn| {
                    if (count < proxies.len) {
                        proxies[count] = proxy_fn;
                        count += 1;
                    }
                }
                break;
            }
        }
    }

    // Execute collected proxies in order (root to leaf)
    for (proxies[0..count]) |proxy_fn| {
        proxy_fn(&proxy_ctx) catch {};
        if (proxy_ctx.isAborted()) {
            return .{ .aborted = true, .state_ptr = proxy_ctx._internal.state_ptr };
        }
    }

    // Execute local proxy (page_proxy or route_proxy). Returns updated ProxyResult.
    if (local_proxy) |proxy_fn| {
        proxy_ctx._internal.state_ptr = proxy_ctx._internal.state_ptr;
        proxy_fn(&proxy_ctx) catch {};
        if (proxy_ctx.isAborted()) {
            return .{ .aborted = true, .state_ptr = proxy_ctx._internal.state_ptr };
        }
    }

    return .{ .aborted = false, .state_ptr = proxy_ctx._internal.state_ptr };
}

/// Registry for server actions and events (for streaming and event dispatch)
pub const ActionRegistry = struct {
    // ...implementation placeholder...
    // Add lookup, registration, and event dispatch logic as needed
};

/// Streaming support for server actions and async components
pub fn renderStreaming() void {
    // ...implementation placeholder...
    // Add streaming logic for async components
}

/// Flexible handler resolution (custom HTTP methods, event handlers)
pub fn resolveCustomHandler(
    handlers: ServerApp.RouteHandlers,
    method: zx.server.Request.Method,
    method_string: ?[]const u8,
) ?ServerApp.RouteHandler {
    return switch (method) {
        .GET => handlers.get orelse handlers.handler,
        .POST => handlers.post orelse handlers.handler,
        .PUT => handlers.put orelse handlers.handler,
        .DELETE => handlers.delete orelse handlers.handler,
        .PATCH => handlers.patch orelse handlers.handler,
        .HEAD => handlers.head orelse handlers.handler,
        .OPTIONS => handlers.options orelse handlers.handler,
        else => blk: {
            if (handlers.custom_methods) |custom_methods| {
                if (method_string) |ms| {
                    for (custom_methods) |custom| {
                        if (std.mem.eql(u8, custom.method, ms)) {
                            break :blk custom.handler;
                        }
                    }
                }
            }
            break :blk handlers.handler;
        },
    };
}

/// Match a route by path with support for :param and * glob patterns.
/// Returns the matched route and any extracted URL parameters.
pub fn matchRoute(path: []const u8, opts: FindRouteOptions) ?RouteMatch {
    switch (opts.match) {
        .exact => return findBestRouteMatch(path, opts),
        .closest => {
            var current = path;
            while (true) {
                if (findBestRouteMatch(current, opts)) |m| return m;
                if (std.mem.lastIndexOfScalar(u8, current[0 .. @max(current.len, 1) - 1], '/')) |last_slash| {
                    current = if (last_slash == 0) "/" else current[0..last_slash];
                } else {
                    if (!std.mem.eql(u8, current, "/")) {
                        current = "/";
                    } else {
                        break;
                    }
                }
            }
            return null;
        },
    }
}

fn findBestRouteMatch(path: []const u8, opts: FindRouteOptions) ?RouteMatch {
    var best: ?RouteMatch = null;
    var best_score: usize = 0;

    for (app.meta.routes) |*route| {
        var m = RouteMatch{ .route = route };
        if (!tryExtractParams(route.path, path, &m)) continue;
        if (opts.has_notfound and route.notfound == null) continue;
        if (opts.has_error and route.@"error" == null) continue;

        const score = patternMatchScore(route.path);
        if (best == null or score > best_score) {
            best = m;
            best_score = score;
        }
    }

    return best;
}

/// Find a route by path. Supports exact match or closest ancestor match.
/// Supports :param and * glob patterns in route paths.
pub fn findRoute(path: []const u8, opts: FindRouteOptions) ?*const Route {
    return if (matchRoute(path, opts)) |m| m.route else null;
}

/// Score a route pattern for match priority. Static segments outrank params and globs,
/// matching httpz router behavior where literal path parts win over :param/* branches.
pub fn patternMatchScore(pattern: []const u8) usize {
    var score: usize = 0;
    var pat = pattern;

    if (pat.len > 0 and pat[0] == '/') pat = pat[1..];
    if (pat.len > 0 and pat[pat.len - 1] == '/') pat = pat[0 .. pat.len - 1];
    if (pat.len == 0) return 1000;

    var pat_pos: usize = 0;
    while (pat_pos < pat.len) {
        const pat_end = std.mem.indexOfScalarPos(u8, pat, pat_pos, '/') orelse pat.len;
        const pseg = pat[pat_pos..pat_end];

        if (pseg.len == 1 and pseg[0] == '*') {
            score += 1;
        } else if (pseg.len > 0 and pseg[0] == ':') {
            score += 1;
        } else {
            score += 1000;
        }

        pat_pos = pat_end + 1;
    }

    return score;
}

/// Match a URL segment-by-segment against a route pattern.
/// Supports :name (named param) and * (glob) segments.
/// Populates match.params and match.param_count on success.
pub fn tryExtractParams(pattern: []const u8, path: []const u8, match: *RouteMatch) bool {
    match.param_count = 0;

    // Paths ending in '*' are catch-alls (httpz glob_all), e.g. "/*" or "/:*".
    const glob_all = pattern.len > 0 and pattern[pattern.len - 1] == '*';

    var pat = pattern;
    var url = path;

    if (pat.len > 0 and pat[0] == '/') pat = pat[1..];
    if (pat.len > 0 and pat[pat.len - 1] == '/') pat = pat[0 .. pat.len - 1];
    if (url.len > 0 and url[0] == '/') url = url[1..];
    if (url.len > 0 and url[url.len - 1] == '/') url = url[0 .. url.len - 1];

    // Both empty → root path match
    if (pat.len == 0 and url.len == 0) return true;
    if (pat.len == 0) return false;

    var pat_pos: usize = 0;
    var url_pos: usize = 0;

    while (pat_pos < pat.len) {
        const pat_end = std.mem.indexOfScalarPos(u8, pat, pat_pos, '/') orelse pat.len;
        const pseg = pat[pat_pos..pat_end];
        const is_last = (pat_end == pat.len);

        if (pseg.len == 1 and pseg[0] == '*') {
            // Trailing glob: matches everything remaining (including empty)
            if (is_last) return true;
            // Intermediate glob: matches exactly one URL segment
            if (url_pos >= url.len) return false;
            const url_end = std.mem.indexOfScalarPos(u8, url, url_pos, '/') orelse url.len;
            url_pos = url_end + 1;
            pat_pos = pat_end + 1;
            continue;
        }

        if (url_pos >= url.len) return false;
        const url_end = std.mem.indexOfScalarPos(u8, url, url_pos, '/') orelse url.len;
        const useg = url[url_pos..url_end];

        if (pseg.len > 0 and pseg[0] == ':') {
            // Named param: capture the URL segment value
            if (match.param_count < match.params.len) {
                match.params[match.param_count] = .{ .name = pseg[1..], .value = useg };
                match.param_count += 1;
            }
        } else if (!std.mem.eql(u8, pseg, useg)) {
            return false;
        }

        url_pos = url_end + 1;
        pat_pos = pat_end + 1;
    }

    // All pattern segments consumed; URL must also be fully consumed unless catch-all.
    if (url_pos >= url.len + 1) return true;
    return glob_all;
}

/// Resolve the API route handler for a given HTTP method.
pub fn resolveRouteHandler(handlers: ServerApp.RouteHandlers, method: zx.server.Request.Method) ?ServerApp.RouteHandler {
    return switch (method) {
        .GET => handlers.get orelse handlers.handler,
        .POST => handlers.post orelse handlers.handler,
        .PUT => handlers.put orelse handlers.handler,
        .DELETE => handlers.delete orelse handlers.handler,
        .PATCH => handlers.patch orelse handlers.handler,
        .HEAD => handlers.head orelse handlers.handler,
        .OPTIONS => handlers.options orelse handlers.handler,
        else => handlers.handler,
    };
}

/// Execute cascading Proxy() handlers from root "/" down to the target path.
/// Does NOT execute local page_proxy/route_proxy - those are handled by the caller.
pub fn executeCascadingProxies(
    path: []const u8,
    req: zx.server.Request,
    res: zx.server.Response,
    arena: std.mem.Allocator,
    io: std.Io,
) ProxyResult {
    var proxy_ctx = zx.ProxyContext.init(req, res, arena, arena, io);

    var proxies: [16]ServerApp.ProxyHandler = undefined;
    var count: usize = 0;

    // Root "/" proxy
    for (app.meta.routes) |*route| {
        if (std.mem.eql(u8, route.path, "/")) {
            if (route.proxy) |proxy_fn| {
                if (count < proxies.len) {
                    proxies[count] = proxy_fn;
                    count += 1;
                }
            }
            break;
        }
    }

    // Build path segments and check each intermediate path
    var segments: [32][]const u8 = undefined;
    var seg_count: usize = 0;
    var seg_iter = std.mem.splitScalar(u8, path, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len > 0 and seg_count < segments.len) {
            segments[seg_count] = seg;
            seg_count += 1;
        }
    }

    for (1..seg_count + 1) |depth| {
        var path_buf: [256]u8 = undefined;
        var offset: usize = 0;
        for (0..depth) |d| {
            path_buf[offset] = '/';
            offset += 1;
            const seg = segments[d];
            @memcpy(path_buf[offset .. offset + seg.len], seg);
            offset += seg.len;
        }
        const check_path = path_buf[0..offset];
        if (std.mem.eql(u8, check_path, "/")) continue;

        for (app.meta.routes) |*route| {
            if (std.mem.eql(u8, route.path, check_path)) {
                if (route.proxy) |proxy_fn| {
                    if (count < proxies.len) {
                        proxies[count] = proxy_fn;
                        count += 1;
                    }
                }
                break;
            }
        }
    }

    // Execute collected proxies in order (root to leaf)
    for (proxies[0..count]) |proxy_fn| {
        proxy_fn(&proxy_ctx) catch {};
        if (proxy_ctx.isAborted()) {
            return .{ .aborted = true, .state_ptr = proxy_ctx._internal.state_ptr };
        }
    }

    return .{ .aborted = false, .state_ptr = proxy_ctx._internal.state_ptr };
}

/// Execute a single local proxy (page_proxy or route_proxy). Returns updated ProxyResult.
pub fn executeLocalProxy(
    proxy_fn: ServerApp.ProxyHandler,
    parent_result: ProxyResult,
    req: zx.server.Request,
    res: zx.server.Response,
    arena: std.mem.Allocator,
    io: std.Io,
) ProxyResult {
    var proxy_ctx = zx.ProxyContext.init(req, res, arena, arena, io);
    proxy_ctx._internal.state_ptr = parent_result.state_ptr;
    proxy_fn(&proxy_ctx) catch {};
    if (proxy_ctx.isAborted()) {
        return .{ .aborted = true, .state_ptr = proxy_ctx._internal.state_ptr };
    }
    return .{ .aborted = false, .state_ptr = proxy_ctx._internal.state_ptr };
}

/// Apply layout hierarchy for a matched route.
/// Order: route's own layout wraps the page first, then parent layouts wrap outside (leaf to root).
pub fn applyLayouts(
    route: *const Route,
    pathname: []const u8,
    layoutctx: zx.LayoutContext,
    page_component: Component,
    app_ptr: ?*const anyopaque,
    state_ptr: ?*const anyopaque,
    used_layout: ?*bool,
) Component {
    var component = page_component;

    // Apply this route's own layout first
    if (route.layout) |layout_fn| {
        component = layout_fn(layoutctx, component, app_ptr, state_ptr);
        if (used_layout) |flag| flag.* = true;
    }

    // Collect parent layouts (root to deepest, excluding current route)
    var layouts: [10]ServerApp.LayoutHandler = undefined;
    var layout_count: usize = 0;

    const is_root = std.mem.eql(u8, pathname, "/");

    // Root layout (only if current route is not root)
    if (!is_root) {
        for (app.meta.routes) |*r| {
            if (std.mem.eql(u8, r.path, "/")) {
                if (r.layout) |layout_fn| {
                    if (layout_count < layouts.len) {
                        layouts[layout_count] = layout_fn;
                        layout_count += 1;
                    }
                }
                break;
            }
        }
    }

    // Intermediate path layouts
    var segments: [32][]const u8 = undefined;
    var seg_count: usize = 0;
    var seg_iter = std.mem.splitScalar(u8, pathname, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len > 0 and seg_count < segments.len) {
            segments[seg_count] = seg;
            seg_count += 1;
        }
    }

    if (seg_count > 1) {
        for (1..seg_count) |depth| {
            var path_buf: [256]u8 = undefined;
            var offset: usize = 0;
            for (0..depth) |i| {
                path_buf[offset] = '/';
                offset += 1;
                const seg = segments[i];
                @memcpy(path_buf[offset .. offset + seg.len], seg);
                offset += seg.len;
            }
            const parent_path = path_buf[0..offset];

            // Skip if this is the current route's own path (already applied)
            if (std.mem.eql(u8, parent_path, route.path)) continue;

            for (app.meta.routes) |*r| {
                if (std.mem.eql(u8, r.path, parent_path)) {
                    if (r.layout) |layout_fn| {
                        if (layout_count < layouts.len) {
                            layouts[layout_count] = layout_fn;
                            layout_count += 1;
                        }
                    }
                    break;
                }
            }
        }
    }

    // Apply parent layouts in reverse order (deepest parent first, root last)
    var j: usize = layout_count;
    while (j > 0) {
        j -= 1;
        component = layouts[j](layoutctx, component, app_ptr, state_ptr);
        if (used_layout) |flag| flag.* = true;
    }

    return component;
}

/// Apply layouts for an arbitrary path (used for notfound/error pages).
/// Collects all layouts from root to deepest matching ancestor.
pub fn applyLayoutsForPath(
    path: []const u8,
    layoutctx: zx.LayoutContext,
    page_component: Component,
    app_ptr: ?*const anyopaque,
    state_ptr: ?*const anyopaque,
) Component {
    var component = page_component;

    var layouts: [10]ServerApp.LayoutHandler = undefined;
    var layout_count: usize = 0;

    // Build paths from deepest to shallowest
    var paths_to_check: [32][]const u8 = undefined;
    var path_count: usize = 0;

    if (path.len > 1) {
        paths_to_check[path_count] = path;
        path_count += 1;
    }

    var current_path = path;
    while (current_path.len > 1) {
        if (std.mem.lastIndexOfScalar(u8, current_path[0 .. current_path.len - 1], '/')) |last_slash| {
            if (last_slash == 0) {
                if (path_count < paths_to_check.len) {
                    paths_to_check[path_count] = "/";
                    path_count += 1;
                }
                break;
            } else {
                current_path = current_path[0..last_slash];
                if (path_count < paths_to_check.len) {
                    paths_to_check[path_count] = current_path;
                    path_count += 1;
                }
            }
        } else break;
    }

    if (path_count == 0 or !std.mem.eql(u8, paths_to_check[path_count - 1], "/")) {
        if (path_count < paths_to_check.len) {
            paths_to_check[path_count] = "/";
            path_count += 1;
        }
    }

    // Collect layouts from shallowest (root) to deepest (reverse iteration)
    var i: usize = path_count;
    while (i > 0) {
        i -= 1;
        if (findRoute(paths_to_check[i], .{ .match = .exact })) |r| {
            if (r.layout) |layout_fn| {
                if (layout_count < layouts.len) {
                    layouts[layout_count] = layout_fn;
                    layout_count += 1;
                }
            }
        }
    }

    // Apply in reverse (deepest first, root wraps outermost)
    var j: usize = layout_count;
    while (j > 0) {
        j -= 1;
        component = layouts[j](layoutctx, component, app_ptr, state_ptr);
    }

    return component;
}

/// Find the closest error handler and render it wrapped in layouts.
/// Returns the rendered error component, or null if no error handler found.
pub fn renderErrorComponent(
    arena: std.mem.Allocator,
    req: zx.server.Request,
    res: zx.server.Response,
    io: std.Io,
    path: []const u8,
    err: anyerror,
) ?Component {
    const route = findRoute(path, .{ .match = .closest, .has_error = true }) orelse return null;
    const err_fn = route.@"error" orelse return null;

    const errorctx = zx.ErrorContext.init(req, res, arena, io, err);
    const layoutctx: zx.LayoutContext = .{
        .request = errorctx.request,
        .response = errorctx.response,
        .allocator = errorctx.allocator,
        .arena = errorctx.arena,
        .io = errorctx.io,
        .data = errorctx.data,
    };

    var component = err_fn(errorctx);
    component = applyLayoutsForPath(path, layoutctx, component, null, null);
    return component;
}

/// Find the closest notfound handler and render it wrapped in layouts.
/// Returns the rendered notfound component, or null if no handler found.
pub fn renderNotFoundComponent(
    arena: std.mem.Allocator,
    req: zx.server.Request,
    res: zx.server.Response,
    io: std.Io,
    path: []const u8,
    matched_route: ?*const Route,
) ?Component {
    // First try the matched route's own notfound handler
    var notfound_fn: ?*const fn (zx.NotFoundContext) Component = null;
    if (matched_route) |r| notfound_fn = r.notfound;

    // Walk up the hierarchy
    if (notfound_fn == null) {
        if (findRoute(path, .{ .match = .closest, .has_notfound = true })) |r| {
            notfound_fn = r.notfound;
        }
    }

    const nf_fn = notfound_fn orelse return null;

    const notfoundctx = zx.NotFoundContext.init(req, res, arena, io);
    const layoutctx: zx.LayoutContext = notfoundctx;

    var component = nf_fn(notfoundctx);
    component = applyLayoutsForPath(path, layoutctx, component, null, null);
    return component;
}

pub const HandleOptions = struct {
    http: Http,
    request: zx.server.Request,
    response: zx.server.Response,
    pathname: []const u8,
    method: zx.server.Request.Method,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    base_path: ?[]const u8 = null,
    /// App context pointer (native server). WASI passes null.
    app_ctx: ?*anyopaque = null,
    /// When the route has a socket handler, the caller supplies a Socket bound
    /// to the same backend so `handle` can dispatch the upgrade.
    socket: zx.Socket = .{},
};

pub const Outcome = union(enum) {
    /// Response (status/headers/body) is set on the backend. Emit as-is.
    response_ready: void,
    /// A full page component is ready; render it to the response writer.
    /// `streaming` indicates the route opted into HTML streaming.
    component: struct { component: Component, streaming: bool },
    /// The route handler upgraded to a WebSocket. The caller must run the
    /// receive loop and the open/close lifecycle.
    ws_upgraded: void,
    /// No route/handler matched. Component is pre-built when a notfound
    /// page exists; otherwise the caller should emit plain "404 Not Found".
    not_found: struct { component: ?Component },
};

pub const HandleResult = struct {
    outcome: Outcome,
    proxy: ProxyResult = .{},
};

pub fn handle(comptime options: core_handler.Options, opts: HandleOptions) !HandleResult {
    const http = opts.http;
    const request = opts.request;
    const response = opts.response;
    const pathname = opts.pathname;
    const allocator = opts.allocator;
    const arena = opts.arena;
    const io = opts.io;

    const route_match = matchRoute(pathname, .{ .match = .exact });
    const matched_route = if (route_match) |m| m.route else null;

    var proxy_result: ProxyResult = .{};

    if (matched_route) |route| {
        // -- Proxy chain --
        const local_proxy = route.page_proxy orelse route.route_proxy;
        proxy_result = executeProxyChain(pathname, local_proxy, request, response, arena, io);
        if (proxy_result.aborted) return .{ .outcome = .response_ready, .proxy = proxy_result };

        // -- Page (action/event dispatch + render) --
        const page_result = try core_handler.handlePage(
            options,
            route,
            request,
            response,
            allocator,
            arena,
            io,
            opts.app_ctx,
            proxy_result.state_ptr,
            opts.base_path,
        );

        switch (page_result) {
            .action_handled => |r| {
                if (r.body) |body| {
                    http.resHeaderSet("Content-Type", "application/json");
                    http.resSetBody(body);
                }
                return .{ .outcome = .response_ready, .proxy = proxy_result };
            },
            .action_not_found => {
                http.resSetStatus(400);
                http.resSetBody("No action handler registered for this route");
                return .{ .outcome = .response_ready, .proxy = proxy_result };
            },
            .event_handled => |r| {
                http.resHeaderSet("Content-Type", "application/json");
                http.resSetBody(r.body orelse "{}");
                return .{ .outcome = .response_ready, .proxy = proxy_result };
            },
            .event_not_found => {
                http.resSetStatus(404);
                http.resSetBody("No server event handler registered for this route");
                return .{ .outcome = .response_ready, .proxy = proxy_result };
            },
            .page_error => |err| {
                if (core_handler.prepareError(http, pathname, request, response, arena, io, err)) |cmp| {
                    return .{ .outcome = .{ .component = .{ .component = cmp, .streaming = false } }, .proxy = proxy_result };
                }
                return .{ .outcome = .response_ready, .proxy = proxy_result };
            },
            .component => |cmp| {
                return .{
                    .outcome = .{ .component = .{
                        .component = cmp,
                        .streaming = core_handler.isStreamingEnabled(route),
                    } },
                    .proxy = proxy_result,
                };
            },
            .not_found => {
                // Fall through to API route dispatch below.
            },
        }

        // -- API route dispatch --
        if (route.route) |handlers| {
            if (resolveCustomHandler(handlers, opts.method, null)) |_| {
                const api_result = core_handler.handleApi(
                    route,
                    request,
                    response,
                    allocator,
                    io,
                    opts.app_ctx,
                    proxy_result.state_ptr,
                    opts.socket,
                );

                switch (api_result) {
                    .handler_error => |err| {
                        if (!opts.socket.isUpgraded()) {
                            if (core_handler.prepareError(http, pathname, request, response, arena, io, err)) |cmp| {
                                return .{ .outcome = .{ .component = .{ .component = cmp, .streaming = false } }, .proxy = proxy_result };
                            }
                            return .{ .outcome = .response_ready, .proxy = proxy_result };
                        }
                    },
                    .not_found => {},
                    .handled => {},
                }

                if (opts.socket.isUpgraded()) return .{ .outcome = .ws_upgraded, .proxy = proxy_result };
                if (api_result != .not_found) return .{ .outcome = .response_ready, .proxy = proxy_result };
            }
        }
    }

    // -- Not found --
    const nf_proxy = core_handler.executeNotFoundProxy(pathname, request, response, arena, io);
    if (nf_proxy.aborted) {
        return .{ .outcome = .response_ready, .proxy = nf_proxy };
    }
    if (nf_proxy.state_ptr != null) proxy_result = nf_proxy;

    const nf_component = core_handler.prepareNotFound(http, pathname, request, response, arena, io, matched_route);
    return .{ .outcome = .{ .not_found = .{ .component = nf_component } }, .proxy = proxy_result };
}

pub fn streamComponent(component: Component, allocator: std.mem.Allocator, writer: *std.Io.Writer, base_path: ?[]const u8) ![]render.AsyncComponent {
    render.current_route_path = null;
    return render.stream(component, allocator, writer, .{ .base_path = base_path });
}
