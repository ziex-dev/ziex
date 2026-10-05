const std = @import("std");
const zx = @import("../../../../root.zig");

const Router = zx.Router;
const Component = zx.Component;
const Allocator = std.mem.Allocator;
const Request = @import("../../Http/Request.zig");
const Response = @import("../../Http/Response.zig");
const server_dispatch = @import("../../../server/dispatch.zig");
const render = @import("../../../server/render.zig");
const injections = @import("injections.zig");
const tree = @import("../../tree.zig");

pub const ServerApp = zx.server.App;
pub const Route = ServerApp.Route;
pub const ProxyResult = Router.ProxyResult;

pub const Options = struct {
    is_dev: bool = false,
};

/// Result of page handling.
pub const PageResult = union(enum) {
    /// Successfully rendered page component (with layouts + injections applied).
    component: Component,
    /// Request was handled by JS action dispatch. Response body is set.
    action_handled: struct { body: ?[]u8 = null },
    /// Request was handled by server event dispatch.
    event_handled: struct { body: ?[]u8 = null },
    /// No page handler for this route.
    not_found: void,
    /// Error during page rendering.
    page_error: anyerror,
    /// Action handler not found.
    action_not_found: void,
    /// Event handler not found.
    event_not_found: void,
};

/// Result of API handling.
pub const ApiResult = union(enum) {
    /// Request handled successfully.
    handled: void,
    /// No route handlers defined.
    not_found: void,
    /// Error during handler execution.
    handler_error: anyerror,
};

/// Execute cascading + page-local proxy chain for a page route.
pub fn executePageProxy(route: *const Route, request: Request, response: Response, arena: Allocator, io: std.Io) ProxyResult {
    return Router.executeProxyChain(route.path, route.page_proxy, request, response, arena, io);
}

/// Execute cascading + route-local proxy chain for an API route.
pub fn executeRouteProxy(route: *const Route, request: Request, response: Response, arena: Allocator, io: std.Io) ProxyResult {
    return Router.executeProxyChain(route.path, route.route_proxy, request, response, arena, io);
}

/// Execute cascading proxy chain for not-found handling (no local proxy).
pub fn executeNotFoundProxy(pathname: []const u8, request: Request, response: Response, arena: Allocator, io: std.Io) ProxyResult {
    return Router.executeProxyChain(pathname, null, request, response, arena, io);
}

fn pageMethodAllowed(route: *const Route, method: Request.Method) bool {
    const methods = if (route.page_opts) |opts| opts.methods else &[_]zx.PageOptions.Method{.GET};
    for (methods) |m| {
        if (pageMethodEquals(m, method)) return true;
    }
    return false;
}

fn pageMethodEquals(page_method: zx.PageOptions.Method, method: Request.Method) bool {
    return switch (page_method) {
        .GET => method == .GET,
        .POST => method == .POST,
        .PUT => method == .PUT,
        .DELETE => method == .DELETE,
        .PATCH => method == .PATCH,
        .OPTIONS => method == .OPTIONS,
        .HEAD => method == .HEAD,
        .CONNECT => method == .CONNECT,
        .TRACE => method == .TRACE,
        .ALL => true,
    };
}

/// Handle a page request.
///
/// Performs action/event dispatch, renders the page component, applies
/// layout hierarchy, and injects build-time HTML. Returns the final
/// component ready to be serialized by the backend.
///
/// The caller is responsible for:
/// - Proxy execution (call `executePageProxy` before this)
/// - Writing the component to the response (streaming or buffered)
/// - Dev-mode features (dev script injection, logging)
/// - Caching
pub fn handlePage(
    comptime options: Options,
    route: *const Route,
    request: Request,
    response: Response,
    allocator: Allocator,
    arena: Allocator,
    io: std.Io,
    app_ctx: ?*anyopaque,
    proxy_state_ptr: ?*const anyopaque,
    base_path: ?[]const u8,
) !PageResult {
    const app_ptr: ?*const anyopaque = if (app_ctx) |p| @ptrCast(p) else null;
    const pagectx = zx.PageContext.init(request, response, allocator, io);

    const page_fn = route.page orelse return .not_found;

    // -- Server action dispatch --
    switch (try server_dispatch.dispatchAction(request, response, allocator, arena, route.path, pagectx, page_fn, app_ptr, proxy_state_ptr, base_path)) {
        .not_triggered => {},
        .ok => |r| return .{ .action_handled = .{ .body = r.body } },
        .ok_native => {},
        .not_found => return .action_not_found,
        .page_error => |err| return .{ .page_error = err },
    }

    // -- Server event dispatch --
    switch (try server_dispatch.dispatchServerEvent(request, allocator, arena, route.path, pagectx, page_fn, app_ptr, proxy_state_ptr, base_path)) {
        .not_triggered => {},
        .ok => |r| return .{ .event_handled = .{ .body = r.body } },
        .ok_native => {},
        .not_found => return .event_not_found,
        .page_error => |err| return .{ .page_error = err },
    }

    if (!pageMethodAllowed(route, request.method)) return .not_found;

    // -- Render page --
    render.current_route_path = route.path;

    var page_component = page_fn(pagectx, app_ptr, proxy_state_ptr) catch |err| {
        render.current_route_path = null;
        return .{ .page_error = err };
    };

    if (comptime options.is_dev) {
        page_component = zx.util.devtool.namedBoundary(arena, "Page", page_component);
    }

    const layoutctx: zx.LayoutContext = pagectx;
    var used_layout = false;
    page_component = Router.applyLayouts(
        route,
        request.pathname,
        layoutctx,
        page_component,
        app_ptr,
        proxy_state_ptr,
        if (comptime options.is_dev) &used_layout else null,
    );

    injectZxInjections(arena, &page_component, request.pathname);

    if (comptime options.is_dev) {
        if (used_layout) {
            page_component = zx.util.devtool.namedBoundary(arena, "Layout", page_component);
        }
    }

    return .{ .component = page_component };
}

/// Handle an API request.
///
/// Resolves the handler based on HTTP method and calls it.
/// For WebSocket routes, the caller should pass a backend-specific Socket
/// and check for upgrades after this returns.
///
/// The caller is responsible for:
/// - Proxy execution (call `executeRouteProxy` before this)
/// - WebSocket upgrade detection and completion
/// - Error rendering on handler_error
pub fn handleApi(
    route: *const Route,
    request: Request,
    response: Response,
    allocator: Allocator,
    io: std.Io,
    app_ctx: ?*anyopaque,
    proxy_state_ptr: ?*const anyopaque,
    socket: zx.Socket,
) ApiResult {
    const handlers = route.route orelse return .not_found;

    // Resolve handler for HTTP method
    const route_fn = Router.resolveCustomHandler(handlers, request.method, request.method_str) orelse return .not_found;

    const app_ptr: ?*const anyopaque = if (app_ctx) |p| @ptrCast(p) else null;
    if (handlers.socket != null) {
        const routectx = zx.RouteContext.initWithSocket(request, response, socket, allocator, io);
        route_fn(routectx, app_ptr, proxy_state_ptr) catch |err| return .{ .handler_error = err };
    } else {
        const routectx = zx.RouteContext.init(request, response, allocator, io);
        route_fn(routectx, app_ptr, proxy_state_ptr) catch |err| return .{ .handler_error = err };
    }

    return .handled;
}

/// Render a not-found page with layout hierarchy.
/// Returns the rendered component, or null if no notfound handler found.
pub fn renderNotFound(
    pathname: []const u8,
    request: Request,
    response: Response,
    allocator: Allocator,
    io: std.Io,
    matched_route: ?*const Route,
) ?Component {
    return Router.renderNotFoundComponent(allocator, request, response, io, pathname, matched_route);
}

/// Render an error page with layout hierarchy.
/// Returns the rendered component, or null if no error handler found.
pub fn renderError(
    pathname: []const u8,
    request: Request,
    response: Response,
    allocator: Allocator,
    io: std.Io,
    err: anyerror,
) ?Component {
    return Router.renderErrorComponent(allocator, request, response, io, pathname, err);
}

/// Set 404 status/content-type and build the notfound component (if any).
/// When no notfound page exists, sets the plain-text fallback body.
pub fn prepareNotFound(
    http: zx.Http,
    pathname: []const u8,
    request: Request,
    response: Response,
    allocator: Allocator,
    io: std.Io,
    matched_route: ?*const Route,
) ?Component {
    http.resSetStatus(404);
    http.resHeaderSet("Content-Type", "text/html");
    if (renderNotFound(pathname, request, response, allocator, io, matched_route)) |cmp| {
        return cmp;
    }
    http.resSetBody("404 Not Found");
    return null;
}

/// Set 500 status/content-type and build the error component (if any).
/// When no error page exists, sets the plain-text fallback body.
pub fn prepareError(
    http: zx.Http,
    pathname: []const u8,
    request: Request,
    response: Response,
    allocator: Allocator,
    io: std.Io,
    err: anyerror,
) ?Component {
    std.log.err("handler error at {s}: {t}", .{ pathname, err });
    // Wasm/WASI has no @returnAddress, so traces are always empty there.
    if (comptime std.debug.sys_can_stack_trace) {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    }
    http.resSetStatus(500);
    http.resHeaderSet("Content-Type", "text/html");
    if (renderError(pathname, request, response, allocator, io, err)) |cmp| {
        return cmp;
    }
    http.resSetBody("500 Internal Server Error");
    return null;
}

/// Write `<!DOCTYPE html>` followed by the rendered component.
pub fn renderHtmlDocument(writer: *std.Io.Writer, component: *Component, base_path: ?[]const u8) !void {
    try writer.writeAll("<!DOCTYPE html>\n");
    try component.render(writer, .{ .base_path = base_path });
}

/// Inject build-time HTML (scripts, styles, etc.) into head/body elements.
/// See `injections.zig` for the comptime rendering of structured injections.
/// Only injections whose `pathname` filter matches are applied.
pub fn injectZxInjections(allocator: Allocator, page: *Component, pathname: []const u8) void {
    injections.inject(allocator, page, pathname);
}

/// Inject the DevServer client script (`/.well-known/_zx/devscript.js`) into `<body>`.
pub fn injectDevScript(allocator: Allocator, page: *Component) void {
    const body_element = tree.getElementByName(page, allocator, .body) orelse return;
    const attributes = allocator.alloc(zx.Element.Attribute, 1) catch return;
    attributes[0] = .{ .name = "src", .value = "/.well-known/_zx/devscript.js" };
    const script_element = Component{ .element = .{ .tag = .script, .attributes = attributes } };
    tree.appendChild(body_element, allocator, script_element) catch {
        allocator.free(attributes);
    };
}

/// Check if streaming is enabled for a route.
pub fn isStreamingEnabled(route: *const Route) bool {
    if (route.page_opts) |opts| return opts.streaming;
    return false;
}
