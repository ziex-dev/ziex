const Wasm = @This();

const std = @import("std");
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

const base_path = app_opts.app_base_path;
const feat_cache = app_opts.feat_cache_server;
const is_dev = App.mode == .dev;

var g_inita: zx.Init = undefined;

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
    return run(g_inita);
}

pub fn run(process_init: std.process.Init) !void {
    const allocator = std.heap.wasm_allocator;

    var args = try process_init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    var pathname: []const u8 = "/";
    var search: []const u8 = "";
    var url: []const u8 = "";
    var method: zx.server.Request.Method = .GET;
    var header_entries = std.ArrayList(HeaderEntry).empty;
    defer header_entries.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pathname")) {
            pathname = args.next() orelse return error.MissingPathname;
        } else if (std.mem.eql(u8, arg, "--search")) {
            search = args.next() orelse return error.MissingSearch;
        } else if (std.mem.eql(u8, arg, "--method")) {
            const method_str = args.next() orelse return error.MissingMethod;
            method = std.meta.stringToEnum(zx.server.Request.Method, method_str) orelse return error.InvalidMethod;
        } else if (std.mem.eql(u8, arg, "--header")) {
            const header_str = args.next() orelse return error.MissingHeader;
            if (std.mem.indexOfScalar(u8, header_str, ':')) |sep| {
                try header_entries.append(allocator, .{
                    .name = header_str[0..sep],
                    .value = std.mem.trimStart(u8, header_str[sep + 1 ..], " "),
                });
            }
        } else if (std.mem.eql(u8, arg, "--url")) {
            url = args.next() orelse return error.MissingUrl;
        }
    }

    var stdin_body_buf: std.Io.Writer.Allocating = .init(allocator);
    defer stdin_body_buf.deinit();
    var stdin_read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(process_init.io, &stdin_read_buf);
    _ = stdin_reader.interface.streamRemaining(&stdin_body_buf.writer) catch {};

    var content_type: []const u8 = "";
    var cookie_header: []const u8 = "";
    for (header_entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "content-type")) content_type = entry.value;
        if (std.ascii.eqlIgnoreCase(entry.name, "cookie")) cookie_header = entry.value;
    }

    var conn = Conn.init(allocator);
    defer conn.deinit();
    conn.headers = header_entries.items;
    conn.search = search;
    conn.body = stdin_body_buf.written();
    conn.content_type = content_type;
    conn.cookie_header = cookie_header;
    conn.route_match = Router.matchRoute(pathname, .{ .match = .exact });
    conn.http().resHeaderSet("Server", "ziex/wasm");

    const request = conn.request(method, pathname, url);
    const response = conn.response();
    const http = conn.http();

    var host: Host = .{};
    host.init();
    const host_out = &host.writer;

    var page_cache: if (feat_cache) PageCache else void = if (feat_cache)
        try PageCache.initKv(process_init.io, allocator, zx.kv.scoped(.@"page-cache"), AppConfig.CacheConfig{})
    else {};
    defer if (feat_cache) page_cache.deinit();

    const cache_status = if (feat_cache) page_cache.tryServe(request, response) else PageCache.Status.disabled;
    if (cache_status == .hit) {
        try sendDeferred(allocator, &conn, host_out);
        return;
    }

    const matched = if (conn.route_match) |m| m.route else null;
    const handlers = if (matched) |r| r.route else null;
    const socket: zx.Socket = if (handlers != null and handlers.?.socket != null)
        .{ ._internal = .{ .http = http, .attached = true } }
    else
        .{};

    const result = try Router.handle(.{ .is_dev = is_dev }, .{
        .http = http,
        .request = request,
        .response = response,
        .pathname = pathname,
        .method = method,
        .allocator = allocator,
        .arena = allocator,
        .io = process_init.io,
        .base_path = base_path,
        .app_ctx = null,
        .socket = socket,
    });

    switch (result.outcome) {
        .response_ready => {
            // Capture only when this route opted into `options.caching` (`.miss`).
            if (shouldCapture(cache_status)) {
                storePageCache(&page_cache, request, response, &conn, conn.bodySlice());
            }
            try sendDeferred(allocator, &conn, host_out);
        },

        .component => |c| {
            var component = c.component;
            if (!headerHas(conn.resp_headers.items, "Content-Type")) {
                conn.setContentTypeStr("text/html");
            }
            if (c.streaming) {
                try conn.resp_headers.append(allocator, .{ .name = "content-encoding", .value = "identify" });
                try streamComponent(
                    allocator,
                    host_out,
                    &conn,
                    &page_cache,
                    cache_status,
                    request,
                    response,
                    http,
                    pathname,
                    process_init.io,
                    matched,
                    component,
                );
            } else {
                try emitComponent(
                    allocator,
                    host_out,
                    &conn,
                    &page_cache,
                    cache_status,
                    request,
                    response,
                    http,
                    pathname,
                    process_init.io,
                    matched,
                    &component,
                );
            }
        },

        .ws_upgraded => {
            ext.ws_upgrade();
            const upgrade_data = conn.upgradeData();
            if (handlers.?.socket_open) |open_fn| {
                open_fn(socket, upgrade_data, allocator, allocator, process_init.io) catch {};
            }

            const recv_buf = allocator.alloc(u8, 65536) catch return;
            defer allocator.free(recv_buf);

            while (true) {
                const n = ext.ws_recv(recv_buf.ptr, recv_buf.len);
                if (n < 0) break;
                if (handlers.?.socket) |socket_fn| {
                    socket_fn(socket, recv_buf[0..@intCast(n)], .text, upgrade_data, allocator, allocator, process_init.io) catch {};
                }
            }

            if (handlers.?.socket_close) |close_fn| {
                close_fn(socket, upgrade_data, allocator, process_init.io);
            }
        },

        .not_found => |nf| {
            try emitHtmlOrPlain(allocator, host_out, &conn, nf.component);
        },
    }
}

/// True when server cache is on and this route has `options.caching` (PageCache `.miss`).
fn shouldCapture(cache_status: PageCache.Status) bool {
    return feat_cache and cache_status == .miss;
}

fn emitComponent(
    allocator: std.mem.Allocator,
    host_out: *std.Io.Writer,
    conn: *Conn,
    page_cache: anytype,
    cache_status: PageCache.Status,
    request: zx.server.Request,
    response: zx.server.Response,
    http: zx.Http,
    pathname: []const u8,
    io: std.Io,
    matched_route: ?*const core_handler.Route,
    component: *zx.Component,
) !void {
    try Host.commit(allocator, conn, false);
    defer Host.end();

    if (shouldCapture(cache_status)) {
        var cap = Capture.init(allocator, host_out);
        defer cap.deinit();
        conn.out = &cap.writer;
        defer conn.out = null;
        core_handler.renderHtmlDocument(&cap.writer, component, base_path) catch |err| switch (err) {
            error.NotFound => {
                try emitErrorBody(allocator, host_out, conn, http, pathname, request, response, io, matched_route, null);
                return;
            },
            else => {
                try emitErrorBody(allocator, host_out, conn, http, pathname, request, response, io, matched_route, err);
                return;
            },
        };
        try cap.writer.flush();
        storePageCache(page_cache, request, response, conn, cap.captured());
        return;
    }

    conn.out = host_out;
    defer conn.out = null;
    core_handler.renderHtmlDocument(host_out, component, base_path) catch |err| switch (err) {
        error.NotFound => {
            try emitErrorBody(allocator, host_out, conn, http, pathname, request, response, io, matched_route, null);
            return;
        },
        else => {
            try emitErrorBody(allocator, host_out, conn, http, pathname, request, response, io, matched_route, err);
            return;
        },
    };
    try host_out.flush();
}

fn streamComponent(
    allocator: std.mem.Allocator,
    host_out: *std.Io.Writer,
    conn: *Conn,
    page_cache: anytype,
    cache_status: PageCache.Status,
    request: zx.server.Request,
    response: zx.server.Response,
    http: zx.Http,
    pathname: []const u8,
    io: std.Io,
    matched_route: ?*const core_handler.Route,
    component: zx.Component,
) !void {
    var shell_writer = std.Io.Writer.Allocating.init(allocator);
    const async_components = Router.streamComponent(component, allocator, &shell_writer.writer, base_path) catch |stream_err| switch (stream_err) {
        error.NotFound => {
            try emitNotFoundBeforeCommit(allocator, host_out, conn, http, pathname, request, response, io, matched_route);
            return;
        },
        else => {
            var page = component;
            try emitComponent(allocator, host_out, conn, page_cache, cache_status, request, response, http, pathname, io, matched_route, &page);
            return;
        },
    };

    try Host.commit(allocator, conn, true);
    defer Host.end();

    if (shouldCapture(cache_status)) {
        var cap = Capture.init(allocator, host_out);
        defer cap.deinit();
        conn.out = &cap.writer;
        defer conn.out = null;
        try writeStreamingBody(&cap.writer, shell_writer.written(), async_components, allocator);
        try cap.writer.flush();
        storePageCache(page_cache, request, response, conn, cap.captured());
    } else {
        conn.out = host_out;
        defer conn.out = null;
        try writeStreamingBody(host_out, shell_writer.written(), async_components, allocator);
        try host_out.flush();
    }
}

fn writeStreamingBody(
    out: *std.Io.Writer,
    shell: []const u8,
    async_components: []render.AsyncComponent,
    allocator: std.mem.Allocator,
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

fn emitNotFoundBeforeCommit(
    allocator: std.mem.Allocator,
    host_out: *std.Io.Writer,
    conn: *Conn,
    http: zx.Http,
    pathname: []const u8,
    request: zx.server.Request,
    response: zx.server.Response,
    io: std.Io,
    matched_route: ?*const core_handler.Route,
) !void {
    const component = core_handler.prepareNotFound(http, pathname, request, response, allocator, io, matched_route);
    try emitHtmlOrPlain(allocator, host_out, conn, component);
}

fn emitErrorBody(
    allocator: std.mem.Allocator,
    host_out: *std.Io.Writer,
    conn: *Conn,
    http: zx.Http,
    pathname: []const u8,
    request: zx.server.Request,
    response: zx.server.Response,
    io: std.Io,
    matched_route: ?*const core_handler.Route,
    err: ?anyerror,
) !void {
    _ = matched_route;
    const component = if (err) |e|
        core_handler.prepareError(http, pathname, request, response, allocator, io, e)
    else
        core_handler.prepareNotFound(http, pathname, request, response, allocator, io, null);
    if (component) |cmp| {
        var page = cmp;
        core_handler.renderHtmlDocument(host_out, &page, base_path) catch {};
    } else {
        const body = conn.bodySlice();
        if (body.len > 0) try host_out.writeAll(body);
    }
    try host_out.flush();
}

fn emitHtmlOrPlain(
    allocator: std.mem.Allocator,
    host_out: *std.Io.Writer,
    conn: *Conn,
    component: ?zx.Component,
) !void {
    try Host.commit(allocator, conn, false);
    defer Host.end();
    if (component) |cmp| {
        var page = cmp;
        core_handler.renderHtmlDocument(host_out, &page, base_path) catch {};
    } else {
        const body = conn.bodySlice();
        if (body.len > 0) try host_out.writeAll(body);
    }
    try host_out.flush();
}

fn storePageCache(
    page_cache: anytype,
    request: zx.server.Request,
    response: zx.server.Response,
    conn: *const Conn,
    body: []const u8,
) void {
    if (comptime !feat_cache) return;
    page_cache.store(request, response, .{
        .status = conn.status,
        .body = body,
        .content_type = headerGet(conn.resp_headers.items, "Content-Type") orelse "text/html",
    });
}

fn headerGet(headers: []const HeaderEntry, name: []const u8) ?[]const u8 {
    for (headers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

fn headerHas(headers: []const HeaderEntry, name: []const u8) bool {
    return headerGet(headers, name) != null;
}

fn sendDeferred(allocator: std.mem.Allocator, conn: *Conn, host_out: *std.Io.Writer) !void {
    try Host.commit(allocator, conn, false);
    defer Host.end();
    const body = conn.bodySlice();
    if (body.len > 0) try host_out.writeAll(body);
    try host_out.flush();
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    log_args: anytype,
) void {
    const level: u8 = switch (message_level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const msg = std.fmt.allocPrint(std.heap.wasm_allocator, prefix ++ format, log_args) catch return;
    defer std.heap.wasm_allocator.free(msg);
    ext._log(level, msg.ptr, msg.len);
}
