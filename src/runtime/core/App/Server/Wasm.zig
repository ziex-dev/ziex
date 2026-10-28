const Wasm = @This();

const std = @import("std");
const builtin = @import("builtin");
const app_opts = @import("app_opts");

const zx = @import("../../../../root.zig");
const App = @import("../../App.zig");
const Server = @import("../Server.zig");
const AppConfig = @import("../Config.zig");
const ext = @import("../../../server/wasm/extern.zig");
const core_handler = @import("../Router/Handler.zig");
const render = @import("../../../server/render.zig");
const PageCache = @import("../../../server/PageCache.zig");

const Router = zx.Router;
const Conn = zx.Http.Conn;
const Capture = zx.Http.Capture;
const Host = zx.Http.Host;
const HeaderEntry = zx.Http.Conn.HeaderEntry;
const Method = zx.server.Request.Method;

const base_path = app_opts.app_base_path;
const feat_cache = app_opts.feat_cache_server;
const is_dev = App.mode == .dev;

const MaybePageCache = if (feat_cache) PageCache else void;

var g_inita: zx.Init = undefined;
var g_request_arena: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);

pub fn server(inita: zx.Init) Server {
    g_inita = inita;
    return .{ .userdata = null, .vtable = &vtable };
}

const vtable = Server.VTable{
    .start = &start,
    .stop = Server.failing_vtable.stop,
    .deinit = Server.failing_vtable.deinit,
    .info = Server.failing_vtable.info,
};

fn start(_: ?*anyopaque) anyerror!void {
    if (reuseRequested()) {
        // The host serves each request through `__zx_serve` on this initialized instance.
        ext.sys.park();
        return;
    }
    return run(g_inita);
}

comptime {
    if (builtin.os.tag == .wasi) @export(&serveCurrent, .{ .name = "__zx_serve" });
}

fn serveCurrent() callconv(.c) void {
    defer _ = g_request_arena.reset(.retain_capacity);
    serve(g_inita, g_request_arena.allocator()) catch |err| {
        std.log.err("request failed: {s}", .{@errorName(err)});
    };
}

pub fn run(process_init: std.process.Init) !void {
    return serve(process_init, std.heap.wasm_allocator);
}

fn reuseRequested() bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
    defer arena.deinit();
    const args = readArgs(arena.allocator()) catch return false;
    for (args) |arg| if (std.mem.eql(u8, arg, "--zx-reuse")) return true;
    return false;
}

// Read argv from WASI directly: libc's `std.process.Args` keeps the startup argv,
// which is stale on reused instances.
fn readArgs(allocator: std.mem.Allocator) ![]const [:0]const u8 {
    var count: usize = 0;
    var buf_size: usize = 0;
    if (std.os.wasi.args_sizes_get(&count, &buf_size) != .SUCCESS) return error.ArgsUnavailable;
    const argv = try allocator.alloc([*:0]u8, count);
    defer allocator.free(argv);
    const buf = try allocator.alloc(u8, buf_size);
    if (std.os.wasi.args_get(argv.ptr, buf.ptr) != .SUCCESS) return error.ArgsUnavailable;
    const args = try allocator.alloc([:0]const u8, count);
    for (argv, args) |arg, *out| out.* = std.mem.span(arg);
    return args;
}

const RequestArgs = struct {
    pathname: []const u8 = "/",
    search: []const u8 = "",
    url: []const u8 = "",
    method: Method = .GET,
    headers: std.ArrayList(HeaderEntry) = .empty,

    fn parse(allocator: std.mem.Allocator, argv: []const [:0]const u8) !RequestArgs {
        var self: RequestArgs = .{};
        errdefer self.headers.deinit(allocator);

        var args = argv[@min(1, argv.len)..];
        while (nextArg(&args)) |flag| {
            if (std.mem.eql(u8, flag, "--pathname")) {
                self.pathname = nextArg(&args) orelse return error.MissingPathname;
            } else if (std.mem.eql(u8, flag, "--search")) {
                self.search = nextArg(&args) orelse return error.MissingSearch;
            } else if (std.mem.eql(u8, flag, "--url")) {
                self.url = nextArg(&args) orelse return error.MissingUrl;
            } else if (std.mem.eql(u8, flag, "--method")) {
                const name = nextArg(&args) orelse return error.MissingMethod;
                self.method = std.meta.stringToEnum(Method, name) orelse return error.InvalidMethod;
            } else if (std.mem.eql(u8, flag, "--header")) {
                const header = nextArg(&args) orelse return error.MissingHeader;
                const sep = std.mem.indexOfScalar(u8, header, ':') orelse continue;
                try self.headers.append(allocator, .{
                    .name = header[0..sep],
                    .value = std.mem.trimStart(u8, header[sep + 1 ..], " "),
                });
            }
        }
        return self;
    }

    fn nextArg(args: *[]const [:0]const u8) ?[]const u8 {
        if (args.len == 0) return null;
        defer args.* = args.*[1..];
        return args.*[0];
    }

    fn deinit(self: *RequestArgs, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
    }
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: *Conn,
    http: zx.Http,
    request: zx.server.Request,
    response: zx.server.Response,
    pathname: []const u8,
    matched_route: ?*const core_handler.Route,
    out: *std.Io.Writer,
    page_cache: *MaybePageCache,
    cache_status: PageCache.Status,

    fn shouldCapture(self: *const Ctx) bool {
        return feat_cache and self.cache_status == .miss;
    }

    fn storePageCache(self: *const Ctx, body: []const u8) void {
        if (comptime !feat_cache) return;
        self.page_cache.store(self.request, self.response, .{
            .status = self.conn.status,
            .body = body,
            .content_type = headerGet(self.conn.resp_headers.items, "Content-Type") orelse "text/html",
        });
    }
};

fn serve(process_init: std.process.Init, allocator: std.mem.Allocator) !void {
    var args = try RequestArgs.parse(allocator, try readArgs(allocator));
    defer args.deinit(allocator);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var stdin_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(process_init.io, &stdin_buf);
    _ = stdin.interface.streamRemaining(&body.writer) catch {};

    var conn = Conn.init(allocator);
    defer conn.deinit();
    conn.headers = args.headers.items;
    conn.search = args.search;
    conn.body = body.written();
    conn.content_type = headerGet(args.headers.items, "content-type") orelse "";
    conn.cookie_header = headerGet(args.headers.items, "cookie") orelse "";
    conn.route_match = Router.matchRoute(args.pathname, .{ .match = .exact });
    conn.http().resHeaderSet("Server", "ziex/wasm");

    var host: Host = .{};
    host.init();

    var page_cache: MaybePageCache = if (feat_cache)
        try PageCache.initKv(process_init.io, allocator, zx.kv.scoped(.@"page-cache"), AppConfig.CacheConfig{})
    else {};
    defer if (feat_cache) page_cache.deinit();

    const matched = if (conn.route_match) |m| m.route else null;
    var ctx: Ctx = .{
        .allocator = allocator,
        .io = process_init.io,
        .conn = &conn,
        .http = conn.http(),
        .request = conn.request(args.method, args.pathname, args.url),
        .response = conn.response(),
        .pathname = args.pathname,
        .matched_route = matched,
        .out = &host.writer,
        .page_cache = &page_cache,
        .cache_status = .disabled,
    };

    if (feat_cache) {
        ctx.cache_status = page_cache.tryServe(ctx.request, ctx.response);
        if (ctx.cache_status == .hit) return sendBody(&ctx);
    }

    const handlers = if (matched) |r| r.route else null;
    const socket: zx.Socket = if (handlers != null and handlers.?.socket != null)
        .{ ._internal = .{ .http = ctx.http, .attached = true } }
    else
        .{};

    const result = try Router.handle(.{ .is_dev = is_dev }, .{
        .http = ctx.http,
        .request = ctx.request,
        .response = ctx.response,
        .pathname = args.pathname,
        .method = args.method,
        .allocator = allocator,
        .arena = allocator,
        .io = ctx.io,
        .base_path = base_path,
        .app_ctx = null,
        .socket = socket,
    });

    switch (result.outcome) {
        .response_ready => {
            if (ctx.shouldCapture()) ctx.storePageCache(conn.bodySlice());
            try sendBody(&ctx);
        },
        .component => |c| {
            if (headerGet(conn.resp_headers.items, "Content-Type") == null) {
                conn.setContentTypeStr("text/html");
            }
            if (c.streaming) {
                try conn.resp_headers.append(allocator, .{ .name = "content-encoding", .value = "identify" });
                try streamComponent(&ctx, c.component);
            } else {
                var component = c.component;
                try emitComponent(&ctx, &component);
            }
        },
        .ws_upgraded => runWebSocket(&ctx, handlers.?, socket),
        .not_found => |nf| try sendComponentOrBody(&ctx, nf.component),
    }
}

fn runWebSocket(ctx: *const Ctx, handlers: core_handler.ServerApp.RouteHandlers, socket: zx.Socket) void {
    ext.ws.upgrade();
    const upgrade_data = ctx.conn.upgradeData();
    const allocator = ctx.allocator;

    if (handlers.socket_open) |open_fn| {
        open_fn(socket, upgrade_data, allocator, allocator, ctx.io) catch {};
    }

    const recv_buf = allocator.alloc(u8, 64 * 1024) catch return;
    defer allocator.free(recv_buf);

    while (ext.ws.recv(recv_buf)) |n| {
        if (handlers.socket) |socket_fn| {
            socket_fn(socket, .{ .text = recv_buf[0..n] }, upgrade_data, allocator, allocator, ctx.io) catch {};
        }
    }

    if (handlers.socket_close) |close_fn| {
        close_fn(socket, upgrade_data, allocator, ctx.io);
    }
}

fn emitComponent(ctx: *const Ctx, component: *zx.Component) !void {
    try Host.commit(ctx.allocator, ctx.conn, false);
    defer Host.end();

    var capture: ?Capture = if (ctx.shouldCapture()) Capture.init(ctx.allocator, ctx.out) else null;
    defer if (capture) |*cap| cap.deinit();
    const out = if (capture) |*cap| &cap.writer else ctx.out;

    ctx.conn.out = out;
    defer ctx.conn.out = null;

    core_handler.renderHtmlDocument(out, component, base_path) catch |err| {
        // Already committed: only the body can change.
        return writeErrorBody(ctx, if (err == error.NotFound) null else err);
    };
    try out.flush();
    if (capture) |*cap| ctx.storePageCache(cap.captured());
}

fn streamComponent(ctx: *const Ctx, component: zx.Component) !void {
    var shell: std.Io.Writer.Allocating = .init(ctx.allocator);
    const async_components = Router.streamComponent(component, ctx.allocator, &shell.writer, base_path) catch |err| switch (err) {
        error.NotFound => {
            const not_found = core_handler.prepareNotFound(ctx.http, ctx.pathname, ctx.request, ctx.response, ctx.allocator, ctx.io, ctx.matched_route);
            return sendComponentOrBody(ctx, not_found);
        },
        // Not committed yet: fall back to a buffered render.
        else => {
            var page = component;
            return emitComponent(ctx, &page);
        },
    };

    try Host.commit(ctx.allocator, ctx.conn, true);
    defer Host.end();

    var capture: ?Capture = if (ctx.shouldCapture()) Capture.init(ctx.allocator, ctx.out) else null;
    defer if (capture) |*cap| cap.deinit();
    const out = if (capture) |*cap| &cap.writer else ctx.out;

    ctx.conn.out = out;
    defer ctx.conn.out = null;

    try writeStreamingBody(ctx.allocator, out, shell.written(), async_components);
    try out.flush();
    if (capture) |*cap| ctx.storePageCache(cap.captured());
}

fn writeStreamingBody(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    shell: []const u8,
    async_components: []render.AsyncComponent,
) !void {
    try out.writeAll("<!DOCTYPE html>\n");
    try out.writeAll(shell);
    try out.flush();
    if (async_components.len == 0) return;

    try out.writeAll(render.streaming_bootstrap_script);
    try out.flush();

    for (async_components) |async_comp| {
        const script = async_comp.renderScript(allocator) catch continue;
        try out.writeAll(script);
        try out.flush();
    }
}

// null err: 404, otherwise 500.
fn writeErrorBody(ctx: *const Ctx, err: ?anyerror) !void {
    const component = if (err) |e|
        core_handler.prepareError(ctx.http, ctx.pathname, ctx.request, ctx.response, ctx.allocator, ctx.io, e)
    else
        core_handler.prepareNotFound(ctx.http, ctx.pathname, ctx.request, ctx.response, ctx.allocator, ctx.io, null);
    try writeComponentOrBody(ctx, component);
}

fn sendComponentOrBody(ctx: *const Ctx, component: ?zx.Component) !void {
    try Host.commit(ctx.allocator, ctx.conn, false);
    defer Host.end();
    try writeComponentOrBody(ctx, component);
}

fn sendBody(ctx: *const Ctx) !void {
    return sendComponentOrBody(ctx, null);
}

fn writeComponentOrBody(ctx: *const Ctx, component: ?zx.Component) !void {
    if (component) |cmp| {
        var page = cmp;
        core_handler.renderHtmlDocument(ctx.out, &page, base_path) catch {};
    } else {
        try ctx.out.writeAll(ctx.conn.bodySlice());
    }
    try ctx.out.flush();
}

fn headerGet(headers: []const HeaderEntry, name: []const u8) ?[]const u8 {
    for (headers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const msg = std.fmt.allocPrint(std.heap.wasm_allocator, prefix ++ format, args) catch return;
    defer std.heap.wasm_allocator.free(msg);
    ext.log(level, msg);
}
