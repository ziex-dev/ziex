const Pipeline = @This();

const std = @import("std");

const zx = @import("../../../../root.zig");
const App = @import("../../App.zig");
const constants = @import("../../constants.zig");
const AppConfig = @import("../Config.zig");
const core_handler = @import("../Router/Handler.zig");
const render = @import("../../../server/render.zig");
const server_meta = @import("../../../server/Server.zig");
const AccessLog = @import("AccessLog.zig");
const Devtool = @import("Devtool.zig");

const Router = zx.Router;

pub const Config = AppConfig;
pub const Conn = zx.Http.Conn;
pub const Component = zx.Component;
pub const HeaderEntry = Conn.HeaderEntry;
pub const PubSub = @import("PubSub.zig");
pub const Socket = zx.Socket;
pub const SocketMessageType = zx.SocketMessageType;
pub const RouteHandlers = server_meta.ServerApp.RouteHandlers;
pub const Meta = server_meta.ServerApp;

/// App route metadata used by dispatch / devtool.
var app_meta: Meta = server_meta.server_app;

pub fn meta() *Meta {
    return &app_meta;
}

pub const Opts = struct {
    is_dev: bool,
    is_export: bool = false,
    base_path: ?[]const u8 = null,
};

/// Default pipeline options from the current App mode / base path.
pub const opts: Opts = .{
    .is_dev = App.mode == .dev,
    .is_export = App.mode == .@"export",
    .base_path = App.base_path,
};

pub const renderHtml = core_handler.renderHtmlDocument;

pub const Result = struct {
    /// When false, the HTTP connection must not accept further requests (WebSocket upgrade).
    keep_http: bool = true,
};

pub const Ctx = struct {
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    meta: *Meta,
    server_config: Config.ServerConfig,
    app_ctx: ?*anyopaque,
    start_time: std.Io.Timestamp = .zero,
};

/// Build a `Ctx` with shared app metadata and optional access-log timing.
pub fn context(
    comptime o: Opts,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    server_config: Config.ServerConfig,
    app_ctx: ?*anyopaque,
) Ctx {
    return .{
        .arena = arena,
        .allocator = allocator,
        .io = io,
        .meta = meta(),
        .server_config = server_config,
        .app_ctx = app_ctx,
        .start_time = if (comptime o.is_dev) std.Io.Timestamp.now(io, .awake) else .zero,
    };
}

/// Transport hooks. Implementations must not free arena-owned response bytes
/// before the transport has finished sending them (Dusty writes after return).
pub const Transport = struct {
    ptr: *anyopaque,

    flush: *const fn (ptr: *anyopaque, backend: *Conn) anyerror!void,
    write: *const fn (ptr: *anyopaque, backend: *Conn, body: []const u8) anyerror!void,
    html: *const fn (ptr: *anyopaque, backend: *Conn, component: *Component) anyerror!void,
    /// Stream DOCTYPE + shell + optional async bootstrap/scripts.
    ssr: *const fn (
        ptr: *anyopaque,
        backend: *Conn,
        shell: []const u8,
        async_components: []render.AsyncComponent,
    ) anyerror!void,
    static: *const fn (ptr: *anyopaque, pathname: []const u8) anyerror!bool,
    /// Run WebSocket handshake + open/message/close. Null → bad request on upgrade.
    upgrade: ?*const fn (
        ptr: *anyopaque,
        handlers: RouteHandlers,
        upgrade_data: ?[]const u8,
    ) anyerror!void = null,
};

/// Parse headers/url/body into a Conn and run the full request pipeline.
pub fn serve(
    comptime o: Opts,
    ctx: Ctx,
    method: std.http.Method,
    url: []const u8,
    headers: []const HeaderEntry,
    body: []const u8,
    transport: Transport,
    comptime token: []const u8,
) !Result {
    const parts = web.target(url);
    const hints = web.headers(headers);
    var backend = Conn.init(ctx.arena);
    backend.headers = headers;
    backend.search = parts.search;
    backend.body = body;
    backend.content_type = hints.content_type;
    backend.cookie_header = hints.cookie;
    backend.route_match = Router.matchRoute(parts.path, .{ .match = .exact });
    backend.http().resHeaderSet("Server", token);
    return dispatch(o, ctx, &backend, method, parts.path, url, transport);
}

/// Full request dispatch after the transport has filled `backend` (headers/body/search/route_match).
pub fn dispatch(
    comptime o: Opts,
    ctx: Ctx,
    backend: *Conn,
    method: std.http.Method,
    pathname: []const u8,
    url: []const u8,
    transport: Transport,
) !Result {
    if (comptime o.is_dev) AccessLog.ProxyStatus.reset();

    const req_obj = backend.request(method, pathname, url);
    const res_obj = backend.response();
    const http = backend.http();

    if (comptime o.is_dev) {
        if (try handleDevtool(ctx, backend, http, method, transport)) {
            return .{};
        }
    }

    const matched = if (backend.route_match) |m| m.route else null;
    const handlers = if (matched) |r| r.route else null;
    const sock = socket(http, handlers);

    if (comptime o.is_export) {
        if (try handleExportProbes(ctx, backend, http, pathname, req_obj, res_obj, matched, transport)) {
            return .{};
        }
    }

    const result = try Router.handle(.{ .is_dev = o.is_dev }, .{
        .http = http,
        .request = req_obj,
        .response = res_obj,
        .pathname = pathname,
        .method = method,
        .allocator = ctx.allocator,
        .arena = ctx.arena,
        .io = ctx.io,
        .base_path = o.base_path,
        .app_ctx = ctx.app_ctx,
        .socket = sock,
    });
    if (comptime o.is_dev) proxyStatus(result.proxy);

    const out = try runOutcome(o, ctx, backend, http, pathname, req_obj, res_obj, matched, handlers, result.outcome, transport);

    if ((comptime o.is_dev) and !AccessLog.isNoisyPath(pathname)) {
        AccessLog.log(ctx.arena, ctx.io, .{
            .method = @tagName(method),
            .path = pathname,
            .status = backend.status,
            .start_time = ctx.start_time,
            .cache_status = .disabled,
        });
    }

    return out;
}

fn runOutcome(
    comptime o: Opts,
    ctx: Ctx,
    backend: *Conn,
    http: zx.Http,
    pathname: []const u8,
    req_obj: zx.Http.Request,
    res_obj: zx.Http.Response,
    matched: ?*const Meta.Route,
    handlers: ?RouteHandlers,
    outcome: Router.Outcome,
    transport: Transport,
) !Result {
    switch (outcome) {
        .response_ready => {
            try transport.flush(transport.ptr, backend);
            return .{};
        },

        .component => |c| {
            var component = c.component;
            if (comptime o.is_dev) {
                if (Devtool.isComponentsMode(http.reqHeaderGet(Devtool.header_mode))) {
                    try respondDevtoolComponents(ctx, backend, http, &component, transport);
                    return .{};
                }
                core_handler.injectDevScript(ctx.arena, &component);
            }
            if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
            if (c.streaming) {
                try streamComponentSsr(o, ctx, backend, component, http, pathname, req_obj, res_obj, matched, transport);
            } else {
                try transport.html(transport.ptr, backend, &component);
            }
            return .{};
        },

        .ws_upgraded => {
            if (!backend.upgraded) {
                try transport.flush(transport.ptr, backend);
                return .{};
            }
            const hs = handlers orelse {
                backend.status = 400;
                try transport.write(transport.ptr, backend, "Invalid WebSocket handshake");
                return .{};
            };
            if (transport.upgrade) |upgrade| {
                try upgrade(transport.ptr, hs, backend.upgradeData());
                return .{ .keep_http = false };
            }
            backend.status = 501;
            try transport.write(transport.ptr, backend, "WebSocket not supported");
            return .{};
        },

        .not_found => |nf| {
            if (try transport.static(transport.ptr, pathname)) {
                backend.status = 200;
                return .{};
            }
            if (nf.component) |cmp| {
                var page = cmp;
                if (comptime o.is_dev) core_handler.injectDevScript(ctx.arena, &page);
                if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
                try transport.html(transport.ptr, backend, &page);
            } else {
                try transport.flush(transport.ptr, backend);
            }
            return .{};
        },
    }
}

fn streamComponentSsr(
    comptime o: Opts,
    ctx: Ctx,
    backend: *Conn,
    component: Component,
    http: zx.Http,
    pathname: []const u8,
    req_obj: zx.Http.Request,
    res_obj: zx.Http.Response,
    matched: ?*const Meta.Route,
    transport: Transport,
) !void {
    var shell_writer = std.Io.Writer.Allocating.init(ctx.arena);
    const async_components = Router.streamComponent(component, ctx.arena, &shell_writer.writer, o.base_path) catch |stream_err| {
        var page = component;
        switch (stream_err) {
            error.NotFound => {
                if (core_handler.prepareNotFound(http, pathname, req_obj, res_obj, ctx.arena, ctx.io, matched)) |c| {
                    page = c;
                    backend.setContentTypeStr("text/html");
                } else {
                    try transport.flush(transport.ptr, backend);
                    return;
                }
            },
            else => {},
        }
        try transport.html(transport.ptr, backend, &page);
        return;
    };

    try transport.ssr(transport.ptr, backend, shell_writer.written(), async_components);
}

fn handleDevtool(
    ctx: Ctx,
    backend: *Conn,
    http: zx.Http,
    method: std.http.Method,
    transport: Transport,
) !bool {
    const action = Devtool.early(http.reqHeaderGet(Devtool.header_mode), method == .OPTIONS);
    if (action == .none) return false;
    Devtool.applyCors(http);

    switch (action) {
        .none => unreachable,
        .empty => {
            try transport.flush(transport.ptr, backend);
            return true;
        },
        .meta, .info => {
            var aw: std.Io.Writer.Allocating = .init(ctx.arena);
            if (action == .meta)
                try Devtool.writeMeta(ctx.arena, ctx.meta, ctx.server_config, &aw.writer)
            else
                try Devtool.writeInfo(ctx.arena, ctx.meta, ctx.server_config, &aw.writer);
            backend.setContentTypeStr("application/json");
            try transport.write(transport.ptr, backend, aw.written());
            return true;
        },
        .continue_render => return false,
    }
}

fn respondDevtoolComponents(
    ctx: Ctx,
    backend: *Conn,
    http: zx.Http,
    component: *Component,
    transport: Transport,
) !void {
    Devtool.applyCors(http);
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    try Devtool.writeComponents(component.*, Devtool.componentOptions(http), &aw.writer);
    backend.setContentTypeStr("application/json");
    try transport.write(transport.ptr, backend, aw.written());
}

fn handleExportProbes(
    ctx: Ctx,
    backend: *Conn,
    http: zx.Http,
    pathname: []const u8,
    req_obj: zx.Http.Request,
    res_obj: zx.Http.Response,
    matched: ?*const Meta.Route,
    transport: Transport,
) !bool {
    if (http.reqHeaderHas("x-zx-export-notfound")) {
        if (core_handler.prepareNotFound(http, pathname, req_obj, res_obj, ctx.arena, ctx.io, matched)) |cmp| {
            var page = cmp;
            if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
            try transport.html(transport.ptr, backend, &page);
        } else {
            backend.status = 404;
            try transport.write(transport.ptr, backend, "404 Not Found");
        }
        return true;
    }

    if (matched) |route| {
        if (http.reqHeaderHas("x-zx-static-data")) {
            if (try route.resolveStaticParams(ctx.arena, ctx.io)) |params| {
                var aw: std.Io.Writer.Allocating = .init(ctx.arena);
                try std.zon.stringify.serialize(params, .{ .whitespace = true }, &aw.writer);
                try transport.write(transport.ptr, backend, aw.written());
            } else {
                try transport.write(transport.ptr, backend, "");
            }
            return true;
        }

        if (route.isDynamic()) {
            http.resHeaderSet("x-zx-dynamic", "true");
            var aw: std.Io.Writer.Allocating = .init(ctx.arena);
            try std.zon.stringify.serialize(.{ .dynamic = true }, .{ .whitespace = true }, &aw.writer);
            try transport.write(transport.ptr, backend, aw.written());
            return true;
        }
    }
    return false;
}

// --- Shared helpers --- //

pub const defaults = struct {
    pub const port = constants.default_port;
    pub const address = constants.default_address;
    pub const staticdir = constants.default_staticdir;
};

pub const colors = struct {
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const reset = "\x1b[0m";
    pub const move_up = "\x1b[1A";
    pub const strikethrough = "\x1b[9m";
};

/// Listen / bind / console helpers.
pub const net = struct {
    pub const Port = enum {
        inner,
        outer,

        fn key(self: Port) []const u8 {
            return switch (self) {
                .inner => "ZIEX_INNER_PORT",
                .outer => "ZIEX_OUTER_PORT",
            };
        }
    };

    pub fn address(host: []const u8, port_num: u16) std.Io.net.IpAddress {
        const ip = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        return std.Io.net.IpAddress.parse(ip, port_num) catch (std.Io.net.IpAddress.parse("0.0.0.0", port_num) catch unreachable);
    }

    pub fn port(alloc: std.mem.Allocator, inita: zx.Init, which: Port) ?u16 {
        const minimal: std.process.Init.Minimal = switch (@TypeOf(inita)) {
            std.process.Init.Minimal => inita,
            std.process.Init => inita.minimal,
            else => return null,
        };
        const value = minimal.environ.getAlloc(alloc, which.key()) catch return null;
        defer alloc.free(value);
        return std.fmt.parseInt(u16, value, 10) catch null;
    }

    pub fn busy(port_num: u16) void {
        std.debug.print("{s}Port {d} is already in use{s}\n", .{ colors.red, port_num, colors.reset });
        std.debug.print("\nTo kill the port, run:\n  {s}kill -9 $(lsof -t -i:{d}){s}\n\n", .{ colors.dim, port_num, colors.reset });
    }

    pub fn banner(port_num: u16, comptime suffix: []const u8) void {
        if (comptime suffix.len == 0) {
            std.debug.print("{s}ZX{s} {s}- v{s}{s} | http://localhost:{d}\n", .{
                colors.bold,
                colors.reset,
                colors.dim,
                zx.info.version,
                colors.reset,
                port_num,
            });
        } else {
            std.debug.print("{s}ZX{s} {s}- v{s}{s} | http://localhost:{d} ({s})\n", .{
                colors.bold,
                colors.reset,
                colors.dim,
                zx.info.version,
                colors.reset,
                port_num,
                suffix,
            });
        }
    }
};

/// Request / response / content helpers.
pub const web = struct {
    pub fn status(code: u16) std.http.Status {
        return @fromBackingInt(@intCast(code));
    }

    pub fn target(url: []const u8) struct { path: []const u8, search: []const u8 } {
        if (std.mem.indexOfScalar(u8, url, '?')) |p| {
            return .{ .path = url[0..p], .search = url[p..] };
        }
        return .{ .path = url, .search = "" };
    }

    pub fn headers(entries: []const HeaderEntry) struct { content_type: []const u8, cookie: []const u8 } {
        var content_type: []const u8 = "";
        var cookie: []const u8 = "";
        for (entries) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, "content-type")) content_type = e.value;
            if (std.ascii.eqlIgnoreCase(e.name, "cookie")) cookie = e.value;
        }
        return .{ .content_type = content_type, .cookie = cookie };
    }

    pub fn mime(path: []const u8) []const u8 {
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".html")) return "text/html";
        if (std.mem.eql(u8, ext, ".css")) return "text/css";
        if (std.mem.eql(u8, ext, ".js")) return "text/javascript";
        if (std.mem.eql(u8, ext, ".png")) return "image/png";
        if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
        if (std.mem.eql(u8, ext, ".json")) return "application/json";
        if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
        if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
        return "application/octet-stream";
    }

    pub fn staticFile(
        io: std.Io,
        arena: std.mem.Allocator,
        staticdir: []const u8,
        pathname: []const u8,
    ) !?[]const u8 {
        const rel = if (pathname.len > 0 and pathname[0] == '/') pathname[1..] else pathname;
        if (rel.len == 0) return null;
        const file_path = std.fs.path.join(arena, &.{ staticdir, rel }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .unlimited) catch null;
    }
};

pub fn proxyStatus(proxy: Router.ProxyResult) void {
    if (proxy.aborted) {
        AccessLog.ProxyStatus.markAborted();
    } else if (proxy.state_ptr != null) {
        AccessLog.ProxyStatus.markExecuted();
    }
}

pub fn socket(h: zx.Http, handlers: ?RouteHandlers) zx.Socket {
    if (handlers != null and handlers.?.socket != null) {
        return .{ ._internal = .{ .http = h, .attached = true } };
    }
    return .{};
}

/// Streaming bootstrap script for SSR shells.
pub const ssr_bootstrap = render.streaming_bootstrap_script;
pub const AsyncComponent = render.AsyncComponent;
