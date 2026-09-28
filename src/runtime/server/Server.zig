const std = @import("std");
const builtin = @import("builtin");
const app = @import("app");

const zx = @import("../../root.zig");
const constants = @import("../core/constants.zig");
const AppConfig = @import("../core/App/Config.zig");

const Allocator = std.mem.Allocator;
const Component = zx.Component;

pub const SerilizableAppMeta = struct {
    pub const Opts = struct {
        rendering: ?[]const u8 = null,
        caching_ttl_s: ?i64 = null,
        caching_key: ?[]const u8 = null,
        streaming: bool = false,
        dynamic: bool = false,
        has_static: bool = false,
    };

    pub const Route = struct {
        path: []const u8,
        kind: []const u8 = "Page",
        methods: []const []const u8 = &.{},
        has_page: bool = false,
        has_route: bool = false,
        has_layout: bool = false,
        has_notfound: bool = false,
        has_error: bool = false,
        has_proxy: bool = false,
        is_dynamic: bool = false,
        page_opts: ?Opts = null,
        route_opts: ?Opts = null,
        layout_opts: ?Opts = null,
    };
    pub const Config = struct {
        server: AppConfig.ServerConfig,
    };

    routes: []const Route,
    config: SerilizableAppMeta.Config,
    version: []const u8,

    pub fn init(allocator: std.mem.Allocator, meta: *ServerApp, config: AppConfig.ServerConfig) !SerilizableAppMeta {
        var routes = try allocator.alloc(Route, meta.routes.len);

        for (meta.routes, 0..) |route, i| {
            const is_dynamic = std.mem.indexOf(u8, route.path, ":") != null;
            const kind, const methods = try getRouteKindAndMethods(allocator, route);
            routes[i] = Route{
                .path = try allocator.dupe(u8, route.path),
                .kind = kind,
                .methods = methods,
                .has_page = route.page != null,
                .has_route = route.route != null,
                .has_layout = route.layout != null,
                .has_notfound = route.notfound != null,
                .has_error = route.@"error" != null,
                .has_proxy = route.proxy != null,
                .is_dynamic = is_dynamic,
                .page_opts = try serializePageOpts(allocator, route.page_opts),
                .route_opts = try serializeRouteOpts(allocator, route.route_opts),
                .layout_opts = try serializeLayoutOpts(allocator, route.layout_opts),
            };
        }

        const version = try allocator.dupe(u8, zx.info.version);

        return SerilizableAppMeta{
            .routes = routes,
            .config = SerilizableAppMeta.Config{
                .server = config,
            },
            .version = version,
        };
    }

    pub fn deinit(self: *SerilizableAppMeta, allocator: std.mem.Allocator) void {
        for (self.routes) |route| {
            allocator.free(route.path);
            allocator.free(route.methods);
        }
        allocator.free(self.routes);
        allocator.free(self.version);
    }

    pub fn serializeRoutes(self: SerilizableAppMeta, writer: anytype) !void {
        try zx.util.zxon.serialize(self.routes, writer, .{});
    }
    pub fn serializeInfo(self: SerilizableAppMeta, writer: anytype) !void {
        const Info = struct {
            version: []const u8,
            route_count: usize,
            address: ?[]const u8 = null,
            port: ?u16 = null,
            workers: ?u16 = null,
            thread_pool: ?u16 = null,
        };
        try zx.util.zxon.serialize(Info{
            .version = self.version,
            .route_count = self.routes.len,
            .address = self.config.server.address,
            .port = self.config.server.port,
            .workers = self.config.server.workers.count,
            .thread_pool = self.config.server.thread_pool.count,
        }, writer, .{});
    }

    fn serializeCaching(allocator: std.mem.Allocator, caching: ?zx.BuiltinAttribute.Caching) !struct { ?i64, ?[]const u8 } {
        const c = caching orelse return .{ null, null };
        const ttl_s: i64 = @intCast(c.ttl.toSeconds());
        const key = if (c.key) |k| try allocator.dupe(u8, k) else null;
        return .{ ttl_s, key };
    }

    fn serializePageOpts(allocator: std.mem.Allocator, opts: ?zx.PageOptions) !?Opts {
        const o = opts orelse return null;
        const ttl_s, const key = try serializeCaching(allocator, o.caching);
        return Opts{
            .rendering = if (o.rendering) |r| @tagName(r) else null,
            .caching_ttl_s = ttl_s,
            .caching_key = key,
            .streaming = o.streaming,
            .dynamic = o.dynamic,
            .has_static = o.static != null,
        };
    }

    fn serializeRouteOpts(allocator: std.mem.Allocator, opts: ?zx.RouteOptions) !?Opts {
        const o = opts orelse return null;
        const ttl_s, const key = try serializeCaching(allocator, o.caching);
        return Opts{
            .caching_ttl_s = ttl_s,
            .caching_key = key,
            .dynamic = o.dynamic,
            .has_static = o.static != null,
        };
    }

    fn serializeLayoutOpts(allocator: std.mem.Allocator, opts: ?zx.LayoutOptions) !?Opts {
        const o = opts orelse return null;
        const ttl_s, const key = try serializeCaching(allocator, o.caching);
        return Opts{
            .rendering = if (o.rendering) |r| @tagName(r) else null,
            .caching_ttl_s = ttl_s,
            .caching_key = key,
        };
    }

    fn getRouteKindAndMethods(allocator: std.mem.Allocator, route: ServerApp.Route) !struct { []const u8, []const []const u8 } {
        var methods = std.ArrayList([]const u8).empty;
        defer methods.deinit(allocator);

        if (route.route) |handlers| {
            if (handlers.handler != null) try methods.append(allocator, "ANY");
            if (handlers.get != null) try methods.append(allocator, "GET");
            if (handlers.post != null) try methods.append(allocator, "POST");
            if (handlers.put != null) try methods.append(allocator, "PUT");
            if (handlers.delete != null) try methods.append(allocator, "DELETE");
            if (handlers.patch != null) try methods.append(allocator, "PATCH");
            if (handlers.head != null) try methods.append(allocator, "HEAD");
            if (handlers.options != null) try methods.append(allocator, "OPTIONS");

            if (handlers.custom_methods) |custom_methods| {
                for (custom_methods) |custom| {
                    try methods.append(allocator, custom.method);
                }
            }

            return .{ "Route", try methods.toOwnedSlice(allocator) };
        }

        if (route.page_opts) |page_opts| {
            for (page_opts.methods) |method| {
                try methods.append(allocator, @tagName(method));
            }
        }

        if (methods.items.len == 0) {
            try methods.append(allocator, "GET");
        }

        return .{ "Page", try methods.toOwnedSlice(allocator) };
    }
};

fn getOptions(comptime T: type, comptime R: type) ?R {
    return if (@hasDecl(T, "options")) T.options else null;
}

pub const ServerApp = struct {
    pub const StdInput = struct {
        const Header = struct {
            name: []const u8,
            value: []const u8,
        };
        url: []const u8,
        method: zx.server.Request.Method,
        headers: []const Header,
        body: []const u8,
    };

    /// Route handler function type for API routes
    pub const RouteHandler = *const fn (ctx: zx.RouteContext, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) anyerror!void;

    /// Socket message handler function type for WebSocket connections
    /// Called for each message received from the client
    pub const SocketHandler = *const fn (
        socket: zx.Socket,
        message: []const u8,
        message_type: zx.SocketMessageType,
        upgrade_data: ?[]const u8,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: std.Io,
    ) anyerror!void;

    /// Socket open handler function type (optional)
    /// Called once when the WebSocket connection is established
    pub const SocketOpenHandler = *const fn (
        socket: zx.Socket,
        upgrade_data: ?[]const u8,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: std.Io,
    ) anyerror!void;

    /// Socket close handler function type (optional)
    /// Called once when the WebSocket connection is closed
    pub const SocketCloseHandler = *const fn (
        socket: zx.Socket,
        upgrade_data: ?[]const u8,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void;

    /// Custom method entry for non-standard HTTP methods
    pub const CustomMethod = struct {
        method: []const u8,
        handler: RouteHandler,
    };

    /// Struct containing all HTTP method handlers for an API route
    pub const RouteHandlers = struct {
        handler: ?RouteHandler = null, // Catch-all undefined standard HTTP method
        get: ?RouteHandler = null,
        post: ?RouteHandler = null,
        put: ?RouteHandler = null,
        delete: ?RouteHandler = null,
        patch: ?RouteHandler = null,
        head: ?RouteHandler = null,
        options: ?RouteHandler = null,
        custom_methods: ?[]const CustomMethod = null, // Arbitrary uppercase methods
        socket: ?SocketHandler = null,
        socket_open: ?SocketOpenHandler = null,
        socket_close: ?SocketCloseHandler = null,
    };

    // Standard HTTP methods to exclude from custom detection
    fn isStandardMethod(name: []const u8) bool {
        const standard_methods = [_][]const u8{ "Route", "Socket", "SocketOpen", "SocketClose", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" };
        for (standard_methods) |std_method| {
            if (std.mem.eql(u8, name, std_method)) return true;
        }
        return false;
    }

    fn isAllUppercase(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |c| if (!std.ascii.isUpper(c)) return false;
        return true;
    }

    /// Comptime function to build RouteHandlers from a route module
    /// Optionally takes a page module to validate for method conflicts
    pub fn route(comptime T: type, comptime PageModule: ?type) RouteHandlers {
        @setEvalBranchQuota(20_000);

        // Validate for method conflicts when page module is provided
        if (PageModule) |P| {
            const page_methods = if (@hasDecl(P, "options") and @hasField(@TypeOf(P.options), "methods"))
                P.options.methods
            else
                &[_]zx.PageOptions.Method{.GET};

            // Check for specific method conflicts
            inline for (page_methods) |method| {
                const method_name = @tagName(method);
                if (@hasDecl(T, method_name)) {
                    @compileError("route.zig cannot define " ++ method_name ++ " handler when page.zx handles it. Remove the method from route.zig or page_opts.methods.");
                }
            }

            // Check for Route() catch-all conflict when page handles non-GET methods
            // Route() would intercept methods that page.zx should handle
            if (@hasDecl(T, "Route")) {
                inline for (page_methods) |method| {
                    if (method != .GET) {
                        @compileError("route.zig cannot define Route() catch-all handler when page.zx handles " ++ @tagName(method) ++ ". Use specific method handlers (POST, PUT, etc.) in route.zig instead.");
                    }
                }
            }
        }

        // Count custom methods first
        comptime var custom_count: usize = 0;
        const decls = @typeInfo(T).@"struct".decl_names;
        for (decls) |decl| {
            if (!isStandardMethod(decl) and isAllUppercase(decl)) {
                const field = @field(T, decl);
                const FieldType = @TypeOf(field);
                if (@typeInfo(FieldType) == .@"fn") {
                    custom_count += 1;
                }
            }
        }

        // Build custom methods array as const
        const custom_methods = comptime blk: {
            var methods: [custom_count]CustomMethod = undefined;
            var idx: usize = 0;
            for (decls) |decl| {
                if (!isStandardMethod(decl) and isAllUppercase(decl)) {
                    const field = @field(T, decl);
                    const FieldType = @TypeOf(field);
                    if (@typeInfo(FieldType) == .@"fn") {
                        methods[idx] = .{
                            .method = decl,
                            .handler = wrapRoute(field),
                        };
                        idx += 1;
                    }
                }
            }
            break :blk methods;
        };

        return .{
            .handler = if (@hasDecl(T, "Route")) wrapRoute(T.Route) else null,
            .get = if (@hasDecl(T, "GET")) wrapRoute(T.GET) else null,
            .post = if (@hasDecl(T, "POST")) wrapRoute(T.POST) else null,
            .put = if (@hasDecl(T, "PUT")) wrapRoute(T.PUT) else null,
            .delete = if (@hasDecl(T, "DELETE")) wrapRoute(T.DELETE) else null,
            .patch = if (@hasDecl(T, "PATCH")) wrapRoute(T.PATCH) else null,
            .head = if (@hasDecl(T, "HEAD")) wrapRoute(T.HEAD) else null,
            .options = if (@hasDecl(T, "OPTIONS")) wrapRoute(T.OPTIONS) else null,
            .custom_methods = if (custom_count > 0) &custom_methods else null,
            .socket = if (@hasDecl(T, "Socket")) wrapSocket(T.Socket) else null,
            .socket_open = if (@hasDecl(T, "SocketOpen")) wrapSocketOpen(T.SocketOpen) else null,
            .socket_close = if (@hasDecl(T, "SocketClose")) wrapSocketClose(T.SocketClose) else null,
        };
    }

    /// Wrapper to allow socket message handlers to return void or !void
    /// Supports both SocketContext (simple) and SocketCtx(T) (with custom data)
    fn wrapSocket(comptime socketFn: anytype) SocketHandler {
        const FnInfo = @typeInfo(@TypeOf(socketFn)).@"fn";
        const R = FnInfo.return_type.?;
        const CtxType = FnInfo.param_types[0].?;
        const DataType = @TypeOf(@as(CtxType, undefined).data);

        return struct {
            fn wrapper(socket: zx.Socket, message: []const u8, message_type: zx.SocketMessageType, upgrade_data: ?[]const u8, allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io) anyerror!void {
                _ = arena;
                const data: DataType = if (upgrade_data) |bytes|
                    std.mem.bytesToValue(DataType, bytes[0..@sizeOf(DataType)])
                else
                    std.mem.zeroes(DataType);

                var arena_instance = std.heap.ArenaAllocator.init(allocator);
                defer arena_instance.deinit();

                const ctx = CtxType{
                    .socket = socket,
                    .message = message,
                    .message_type = message_type,
                    .data = data,
                    .allocator = allocator,
                    .arena = arena_instance.allocator(),
                    .io = io,
                };
                if (R == void) {
                    socketFn(ctx);
                } else {
                    try socketFn(ctx);
                }
            }
        }.wrapper;
    }

    /// Wrapper for SocketOpen handlers
    fn wrapSocketOpen(comptime socketOpenFn: anytype) SocketOpenHandler {
        const FnInfo = @typeInfo(@TypeOf(socketOpenFn)).@"fn";
        const R = FnInfo.return_type.?;
        const CtxType = FnInfo.param_types[0].?;
        const DataType = @TypeOf(@as(CtxType, undefined).data);

        return struct {
            fn wrapper(socket: zx.Socket, upgrade_data: ?[]const u8, allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io) anyerror!void {
                _ = arena;
                const data: DataType = if (upgrade_data) |bytes|
                    std.mem.bytesToValue(DataType, bytes[0..@sizeOf(DataType)])
                else
                    std.mem.zeroes(DataType);

                var arena_instance = std.heap.ArenaAllocator.init(allocator);
                defer arena_instance.deinit();

                const ctx = CtxType{
                    .socket = socket,
                    .data = data,
                    .allocator = allocator,
                    .arena = arena_instance.allocator(),
                    .io = io,
                };
                if (R == void) {
                    socketOpenFn(ctx);
                } else {
                    try socketOpenFn(ctx);
                }
            }
        }.wrapper;
    }

    /// Wrapper for SocketClose handlers
    fn wrapSocketClose(comptime socketCloseFn: anytype) SocketCloseHandler {
        const CtxType = @typeInfo(@TypeOf(socketCloseFn)).@"fn".param_types[0].?;
        const DataType = @TypeOf(@as(CtxType, undefined).data);

        return struct {
            fn wrapper(socket: zx.Socket, upgrade_data: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) void {
                const data: DataType = if (upgrade_data) |bytes|
                    std.mem.bytesToValue(DataType, bytes[0..@sizeOf(DataType)])
                else
                    std.mem.zeroes(DataType);

                var arena_instance = std.heap.ArenaAllocator.init(allocator);
                defer arena_instance.deinit();

                const ctx = CtxType{
                    .socket = socket,
                    .data = data,
                    .allocator = allocator,
                    .arena = arena_instance.allocator(),
                    .io = io,
                };
                socketCloseFn(ctx);
            }
        }.wrapper;
    }

    fn injectApp(comptime AppType: type, app_ptr: ?*const anyopaque) AppType {
        if (AppType == void) return {};

        if (app_ptr == null) {
            if (comptime @typeInfo(AppType) == .optional) return null;
            @panic("Missing app context for non-optional app parameter");
        }
        const ptr = app_ptr.?;

        if (@typeInfo(AppType) == .pointer) {
            const addr = @intFromPtr(ptr);
            const typed: AppType = @ptrFromInt(addr);
            return typed;
        } else {
            const loose: *align(1) const AppType = @ptrCast(ptr);
            return loose.*;
        }
    }

    fn injectState(comptime StateType: type, state_ptr: ?*const anyopaque) StateType {
        if (StateType == void) return {};

        if (state_ptr == null) {
            if (comptime @typeInfo(StateType) == .optional) return null;
            if (comptime @typeInfo(StateType) == .pointer) @panic("Missing proxy state for non-optional state parameter");
            return std.mem.zeroes(StateType);
        }
        const ptr = state_ptr.?;

        if (@typeInfo(StateType) == .pointer) {
            const addr = @intFromPtr(ptr);
            const typed: StateType = @ptrFromInt(addr);
            return typed;
        } else {
            const loose: *align(1) const StateType = @ptrCast(ptr);
            return loose.*;
        }
    }

    /// Wrapper to allow routes to return void or !void.
    /// Route function shape: `(ctx: zx.RouteContext, app?: App, state?: State)` - positional.
    fn wrapRoute(comptime routeFn: anytype) RouteHandler {
        const FnInfo = @typeInfo(@TypeOf(routeFn)).@"fn";
        const R = FnInfo.return_type.?;
        const n_params = FnInfo.param_types.len;

        return struct {
            fn wrapper(ctx: zx.RouteContext, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) anyerror!void {
                if (n_params == 1) {
                    if (R == void) routeFn(ctx) else try routeFn(ctx);
                    return;
                }
                if (n_params == 2) {
                    const app_with_ctx = injectApp(FnInfo.params[1].type.?, app_ptr);
                    if (R == void) routeFn(ctx, app_with_ctx) else try routeFn(ctx, app_with_ctx);
                    return;
                }
                if (n_params == 3) {
                    const app_with_ctx = injectApp(FnInfo.param_types[1].?, app_ptr);
                    const state = injectState(FnInfo.param_types[2].?, state_ptr);
                    if (R == void) routeFn(ctx, app_with_ctx, state) else try routeFn(ctx, app_with_ctx, state);
                    return;
                }
                @compileError("Route function must have 1-3 parameters: (ctx, app?, state?)");
            }
        }.wrapper;
    }

    /// Proxy handler function type - called before page/route handlers
    pub const ProxyHandler = *const fn (ctx: *zx.ProxyContext) anyerror!void;

    /// Wrapper to allow proxy handlers to return void or !void
    fn wrapProxy(comptime proxyFn: anytype) ProxyHandler {
        const R = @typeInfo(@TypeOf(proxyFn)).@"fn".return_type.?;
        return struct {
            fn wrapper(ctx: *zx.ProxyContext) anyerror!void {
                if (R == void) {
                    proxyFn(ctx);
                } else {
                    try proxyFn(ctx);
                }
            }
        }.wrapper;
    }

    /// Comptime function to extract global Proxy handler from a proxy module (cascades to child routes)
    pub fn proxy(comptime T: type) ?ProxyHandler {
        if (@hasDecl(T, "Proxy")) {
            return wrapProxy(T.Proxy);
        }
        return null;
    }

    /// Comptime function to extract PageProxy handler from a proxy module (does NOT cascade)
    pub fn pageProxy(comptime T: type) ?ProxyHandler {
        if (@hasDecl(T, "PageProxy")) {
            return wrapProxy(T.PageProxy);
        }
        return null;
    }

    /// Comptime function to extract RouteProxy handler from a proxy module (does NOT cascade)
    pub fn routeProxy(comptime T: type) ?ProxyHandler {
        if (@hasDecl(T, "RouteProxy")) {
            return wrapProxy(T.RouteProxy);
        }
        return null;
    }

    /// Page handler function type
    pub const PageHandler = *const fn (ctx: zx.PageContext, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) anyerror!Component;

    /// Layout handler function type
    pub const LayoutHandler = *const fn (ctx: zx.LayoutContext, component: Component, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) Component;

    /// Comptime function to wrap a page module's Page function.
    /// The app context and state are read from type-erased pointers in ctx and cast to the appropriate types.
    pub fn page(comptime T: type) PageHandler {
        const pageFn = T.Page;

        const FnType = @TypeOf(pageFn);
        const fn_info = @typeInfo(FnType).@"fn";
        const R = fn_info.return_type.?;
        const n_params = fn_info.param_types.len;

        return struct {
            fn wrapper(ctx: zx.PageContext, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) anyerror!Component {
                if (n_params == 1) {
                    if (R == Component) return pageFn(ctx) else return try pageFn(ctx);
                }
                if (n_params == 2) {
                    const app_with_ctx = injectApp(fn_info.param_types[1].?, app_ptr);
                    if (R == Component) return pageFn(ctx, app_with_ctx) else return try pageFn(ctx, app_with_ctx);
                }
                if (n_params == 3) {
                    const app_with_ctx = injectApp(fn_info.param_types[1].?, app_ptr);
                    const state = injectState(fn_info.param_types[2].?, state_ptr);
                    if (R == Component) return pageFn(ctx, app_with_ctx, state) else return try pageFn(ctx, app_with_ctx, state);
                }
                @compileError("Page function must have 1-3 parameters: (ctx, app?, state?)");
            }
        }.wrapper;
    }

    /// Comptime function to wrap a layout module's Layout function.
    /// Layout signature (positional): `(ctx: zx.LayoutContext, children: Component, app?, state?)`
    pub fn layout(comptime T: type) LayoutHandler {
        const layoutFn = T.Layout;
        const FnType = @TypeOf(layoutFn);
        const fn_info = @typeInfo(FnType).@"fn";
        const n_params = fn_info.param_types.len;

        return struct {
            fn wrapper(ctx: zx.LayoutContext, component: Component, app_ptr: ?*const anyopaque, state_ptr: ?*const anyopaque) Component {
                if (n_params == 2) {
                    return layoutFn(ctx, component);
                }
                if (n_params == 3) {
                    const app_with_ctx = injectApp(fn_info.param_types[2].?, app_ptr);
                    return layoutFn(ctx, component, app_with_ctx);
                }
                if (n_params == 4) {
                    const app_with_ctx = injectApp(fn_info.param_types[2].?, app_ptr);
                    const state = injectState(fn_info.param_types[3].?, state_ptr);
                    return layoutFn(ctx, component, app_with_ctx, state);
                }
                @compileError("Layout function must have 2-4 parameters: (ctx, children, app?, state?)");
            }
        }.wrapper;
    }

    pub fn notfound(comptime T: type) ?*const fn (ctx: zx.NotFoundContext) Component {
        if (@hasDecl(T, "NotFound")) {
            return T.NotFound;
        }
        return null;
    }
    pub fn @"error"(comptime T: type) ?*const fn (ctx: zx.ErrorContext) Component {
        if (@hasDecl(T, "Error")) {
            return T.Error;
        }
        return null;
    }

    pub const Route = struct {
        path: []const u8,
        page: ?PageHandler = null,
        layout: ?LayoutHandler = null,
        notfound: ?*const fn (ctx: zx.NotFoundContext) Component = null,
        @"error": ?*const fn (ctx: zx.ErrorContext) Component = null,
        page_opts: ?zx.PageOptions = null,
        layout_opts: ?zx.LayoutOptions = null,
        notfound_opts: ?zx.NotFoundOptions = null,
        error_opts: ?zx.ErrorOptions = null,
        route: ?RouteHandlers = null,
        route_opts: ?zx.RouteOptions = null,
        proxy: ?ProxyHandler = null,
        page_proxy: ?ProxyHandler = null,
        route_proxy: ?ProxyHandler = null,

        /// Prefer `page_opts.static` over `route_opts.static` when both are set.
        pub fn staticFn(self: *const Route) ?zx.StaticFn {
            if (self.page_opts) |page_opts| {
                if (page_opts.static) |s| return s;
            }
            if (self.route_opts) |route_opts| {
                if (route_opts.static) |s| return s;
            }
            return null;
        }

        /// True when export should skip static generation for this route.
        pub fn isDynamic(self: *const Route) bool {
            if (self.page_opts) |page_opts| {
                if (page_opts.dynamic) return true;
            }
            if (self.route_opts) |route_opts| {
                if (route_opts.dynamic) return true;
            }
            return false;
        }

        /// Run the route's `static` fn and return ZON-ready param sets, or null if unset.
        pub fn resolveStaticParams(self: *const Route, allocator: Allocator, io: std.Io) !?[]const []const zx.StaticParam {
            const static_fn = self.staticFn() orelse return null;
            var ctx = zx.StaticContext.init(allocator, io);
            try static_fn(&ctx);
            return try ctx.params.entries.toOwnedSlice(allocator);
        }
    };

    routes: []const Route,
};

const server_routes = blk: {
    var routes: [app.routes.len]ServerApp.Route = undefined;
    for (app.routes, 0..) |route, i| {
        routes[i] = ServerApp.Route{
            .path = route.path,

            .page = if (route.page) |page| ServerApp.page(page) else null,
            .layout = if (route.layout) |layout| ServerApp.layout(layout) else null,
            .notfound = if (route.notfound) |notfound| ServerApp.notfound(notfound) else null,
            .@"error" = if (route.@"error") |err| ServerApp.@"error"(err) else null,
            .route = if (route.route) |rt| ServerApp.route(rt, if (route.page) |page| page else null) else null,

            .route_opts = if (route.route) |o| getOptions(o, zx.RouteOptions) else null,
            .page_opts = if (route.page) |o| getOptions(o, zx.PageOptions) else null,
            .layout_opts = if (route.layout) |o| getOptions(o, zx.LayoutOptions) else null,
            .notfound_opts = if (route.notfound) |o| getOptions(o, zx.NotFoundOptions) else null,
            .error_opts = if (route.@"error") |o| getOptions(o, zx.ErrorOptions) else null,

            .proxy = if (route.proxy) |proxy| ServerApp.proxy(proxy) else null,
            .page_proxy = if (route.proxy) |proxy| ServerApp.pageProxy(proxy) else null,
            .route_proxy = if (route.proxy) |proxy| ServerApp.routeProxy(proxy) else null,
        };
    }

    break :blk routes;
};

pub const server_app = ServerApp{
    .routes = &server_routes,
};
