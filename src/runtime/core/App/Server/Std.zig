/// App.Server.Std - experimental server backend using std.http.Server.
const Std = @This();

const std = @import("std");
const builtin = @import("builtin");
const app_opts = @import("app_opts");

const zx = @import("../../../../root.zig");
const constants = @import("../../constants.zig");
const App = @import("../../App.zig");
const AppConfig = @import("../Config.zig");
const server_meta = @import("../../../server/Server.zig");
const core_handler = @import("../Router/Handler.zig");
const render = @import("../../../server/render.zig");
const AccessLog = @import("AccessLog.zig");
const Devtool = @import("Devtool.zig");
const PubSub = @import("PubSub.zig");
const con = @import("../../../../util/conn.zig");

const Router = zx.Router;
const Component = zx.Component;
const Conn = zx.Http.Conn;
const HeaderEntry = zx.Http.Conn.HeaderEntry;
const ServerApp = server_meta.ServerApp;
const server_app = server_meta.server_app;

const base_path = app_opts.app_base_path;
const is_dev = App.mode == .dev;
const is_export = App.mode == .@"export";

pub const server_token = "ziex/std";

pub fn Server(comptime H: type) type {
    const AppCtxType = switch (@typeInfo(H)) {
        .@"struct" => H,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Server app context must be a struct, pointer to struct, or void, got: " ++ @tagName(@typeInfo(H))),
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        config: AppConfig,
        app_ctx: H,
        app_ctx_ptr: *AppCtxType,
        meta: ServerApp,
        address: std.Io.net.IpAddress,
        tcp: ?std.Io.net.Server = null,
        shutting_down: std.atomic.Value(bool) = .init(false),
        port: u16,
        inner_port: ?u16 = null,
        outer_port: ?u16 = null,

        worker_count: u32 = 0,
        queue_cap: u32 = 0,
        queue_buf: []std.Io.net.Stream = &.{},
        queue_head: u32 = 0,
        queue_len: u32 = 0,
        queue_mu: std.Io.Mutex = .init,
        queue_not_empty: std.Io.Condition = .init,
        queue_not_full: std.Io.Condition = .init,
        workers: []std.Thread = &.{},

        live_connections: con = .{},

        pub fn init(io: std.Io, allocator: std.mem.Allocator, config: AppConfig, app_ctx: H, inita: zx.Init) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const port: u16 = (if (app_opts.server_port) |p| p else config.server.port) orelse constants.default_port;
            const address_str = app_opts.server_address orelse config.server.address orelse constants.default_address;

            const worker_count: u32 = @max(@as(u32, config.server.thread_pool.count orelse 1), 1);
            const queue_cap: u32 = @max(config.server.thread_pool.backlog, 1);

            self.* = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .app_ctx = app_ctx,
                .app_ctx_ptr = if (H == void) undefined else if (@typeInfo(H) == .pointer) app_ctx else &self.app_ctx,
                .meta = server_app,
                .address = resolveAddress(address_str, port),
                .port = port,
                .inner_port = parseEnvPort(allocator, inita, "ZIEX_INNER_PORT"),
                .outer_port = parseEnvPort(allocator, inita, "ZIEX_OUTER_PORT"),
                .worker_count = worker_count,
                .queue_cap = @max(queue_cap, 1),
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.allocator.destroy(self);
        }

        pub fn stop(self: *Self) void {
            if (self.shutting_down.swap(true, .acq_rel)) return;
            if (self.tcp) |*server| {
                const listener: std.Io.net.Stream = .{ .socket = server.socket };
                listener.shutdown(self.io, .both) catch {
                    wakeAccept(self.io, self.inner_port orelse self.port);
                };
            }
            self.live_connections.shutdownAll(self.io);
            self.wakeQueueWaiters();
        }

        pub fn start(self: *Self) !void {
            self.shutting_down.store(false, .release);
            var bind_address = self.address;
            if (self.inner_port) |inner_port| {
                bind_address = std.Io.net.IpAddress.parse("127.0.0.1", inner_port) catch bind_address;
            }

            self.tcp = bind_address.listen(self.io, .{
                .reuse_address = self.inner_port != null,
            }) catch |err| switch (err) {
                error.AddressInUse => {
                    std.debug.print("{s}Port {d} is already in use{s}\n", .{ colors.red, bind_address.getPort(), colors.reset_all });
                    std.debug.print("\nTo kill the port, run:\n  {s}kill -9 $(lsof -t -i:{d}){s}\n\n", .{ colors.dim, bind_address.getPort(), colors.reset_all });
                    return err;
                },
                else => return err,
            };
            defer {
                if (self.tcp) |*s| {
                    s.deinit(self.io);
                    self.tcp = null;
                }
            }

            try self.startWorkers();
            defer self.shutdownWorkers();

            const server = &self.tcp.?;
            while (true) {
                if (self.shutting_down.load(.acquire)) return;
                const stream = server.accept(self.io) catch {
                    if (self.shutting_down.load(.acquire)) return;
                    continue;
                };
                if (self.shutting_down.load(.acquire)) {
                    stream.close(self.io);
                    return;
                }
                self.enqueue(stream) catch {
                    stream.close(self.io);
                    return;
                };
            }
        }

        fn startWorkers(self: *Self) !void {
            self.queue_buf = try self.allocator.alloc(std.Io.net.Stream, self.queue_cap);
            errdefer self.allocator.free(self.queue_buf);
            self.queue_head = 0;
            self.queue_len = 0;

            self.workers = try self.allocator.alloc(std.Thread, self.worker_count);
            errdefer self.allocator.free(self.workers);

            var spawned: usize = 0;
            errdefer {
                self.shutting_down.store(true, .release);
                self.wakeQueueWaiters();
                var i: usize = 0;
                while (i < spawned) : (i += 1) self.workers[i].join();
            }

            while (spawned < self.worker_count) : (spawned += 1) {
                self.workers[spawned] = try std.Thread.spawn(.{}, workerMain, .{self});
            }
        }

        fn shutdownWorkers(self: *Self) void {
            self.shutting_down.store(true, .release);
            self.live_connections.shutdownAll(self.io);
            self.wakeQueueWaiters();
            for (self.workers) |*t| t.join();
            if (self.workers.len != 0) {
                self.allocator.free(self.workers);
                self.workers = &.{};
            }

            // Close any connections still sitting in the queue.
            self.queue_mu.lockUncancelable(self.io);
            var i: u32 = 0;
            while (i < self.queue_len) : (i += 1) {
                const idx = (self.queue_head + i) % self.queue_cap;
                self.queue_buf[idx].close(self.io);
            }
            self.queue_len = 0;
            self.queue_mu.unlock(self.io);

            if (self.queue_buf.len != 0) {
                self.allocator.free(self.queue_buf);
                self.queue_buf = &.{};
            }
        }

        fn wakeQueueWaiters(self: *Self) void {
            self.queue_mu.lockUncancelable(self.io);
            self.queue_not_empty.broadcast(self.io);
            self.queue_not_full.broadcast(self.io);
            self.queue_mu.unlock(self.io);
        }

        fn enqueue(self: *Self, stream: std.Io.net.Stream) error{ShuttingDown}!void {
            self.queue_mu.lockUncancelable(self.io);
            defer self.queue_mu.unlock(self.io);

            while (self.queue_len >= self.queue_cap) {
                if (self.shutting_down.load(.acquire)) return error.ShuttingDown;
                self.queue_not_full.waitTimeout(self.io, &self.queue_mu, .{
                    .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake },
                }) catch {};
            }
            if (self.shutting_down.load(.acquire)) return error.ShuttingDown;

            const idx = (self.queue_head + self.queue_len) % self.queue_cap;
            self.queue_buf[idx] = stream;
            self.queue_len += 1;
            self.queue_not_empty.signal(self.io);
        }

        fn dequeue(self: *Self) ?std.Io.net.Stream {
            self.queue_mu.lockUncancelable(self.io);
            defer self.queue_mu.unlock(self.io);

            while (self.queue_len == 0) {
                if (self.shutting_down.load(.acquire)) return null;
                self.queue_not_empty.waitTimeout(self.io, &self.queue_mu, .{
                    .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake },
                }) catch {};
            }

            const stream = self.queue_buf[self.queue_head];
            self.queue_head = (self.queue_head + 1) % self.queue_cap;
            self.queue_len -= 1;
            self.queue_not_full.signal(self.io);
            return stream;
        }

        fn workerMain(self: *Self) void {
            while (true) {
                const stream = self.dequeue() orelse return;
                self.handleConnection(stream);
            }
        }

        /// Print the server info to the console: ZX - v{version} | http://localhost:{port}
        pub fn info(self: *Self) void {
            const display_port = self.outer_port orelse self.port;
            std.debug.print("{s}ZX{s} {s}- v{s}{s} | http://localhost:{d}\n", .{ colors.bold, colors.reset_all, colors.dim, zx.info.version, colors.reset_all, display_port });
        }

        fn handleConnection(self: *Self, stream: std.Io.net.Stream) void {
            const live_token = self.live_connections.track(stream) orelse {
                stream.close(self.io);
                return;
            };
            defer {
                self.live_connections.untrack(live_token);
                stream.close(self.io);
            }

            var send_buffer: [8192]u8 = undefined;
            var recv_buffer: [8192]u8 = undefined;
            var connection_reader = stream.reader(self.io, &recv_buffer);
            var connection_writer = stream.writer(self.io, &send_buffer);
            var http_server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

            while (true) {
                if (self.shutting_down.load(.acquire)) return;
                var request = http_server.receiveHead() catch return;
                const persistent = request.head.keep_alive;
                const keep_going = self.serveRequest(&request) catch return;
                if (!keep_going or !persistent) return;
            }
        }

        /// Returns whether the connection may accept further requests
        /// (`false` once upgraded to a WebSocket).
        fn serveRequest(self: *Self, request: *std.http.Server.Request) !bool {
            var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_instance.deinit();
            const arena = arena_instance.allocator();

            const target_raw = request.head.target;
            const qpos = std.mem.indexOfScalar(u8, target_raw, '?');
            const target = try arena.dupe(u8, target_raw);
            const pathname = if (qpos) |p| target[0..p] else target;
            const search = if (qpos) |p| target[p..] else "";
            const method = request.head.method;
            const upgrade = request.upgradeRequested();
            const ws_key: ?[]const u8 = switch (upgrade) {
                .websocket => |k| if (k) |key| try arena.dupe(u8, key) else null,
                else => null,
            };

            const start_time = if (comptime is_dev) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;
            if (comptime is_dev) AccessLog.ProxyStatus.reset();

            var header_entries: std.ArrayList(HeaderEntry) = .empty;
            var header_iter = request.iterateHeaders();
            while (header_iter.next()) |h| {
                header_entries.append(arena, .{
                    .name = try arena.dupe(u8, h.name),
                    .value = try arena.dupe(u8, h.value),
                }) catch {};
            }

            var content_type: []const u8 = "";
            var cookie_header: []const u8 = "";
            for (header_entries.items) |e| {
                if (std.ascii.eqlIgnoreCase(e.name, "content-type")) content_type = e.value;
                if (std.ascii.eqlIgnoreCase(e.name, "cookie")) cookie_header = e.value;
            }

            var body_scratch: [8192]u8 = undefined;
            const body: []const u8 = if (ws_key != null)
                ""
            else if (request.readerExpectContinue(&body_scratch)) |body_reader|
                body_reader.allocRemaining(arena, .unlimited) catch ""
            else |_|
                "";

            var backend = Conn.init(arena);
            backend.headers = header_entries.items;
            backend.search = search;
            backend.body = body;
            backend.content_type = content_type;
            backend.cookie_header = cookie_header;
            backend.route_match = Router.matchRoute(pathname, .{ .match = .exact });

            const req_obj = backend.request(method, pathname, target);
            const res_obj = backend.response();
            const http = backend.http();
            http.resHeaderSet("Server", server_token);

            if (comptime is_dev) {
                if (try self.handleDevtool(request, arena, &backend, http, method)) return true;
            }

            const matched = if (backend.route_match) |m| m.route else null;
            const handlers = if (matched) |r| r.route else null;
            const socket: zx.Socket = if (handlers != null and handlers.?.socket != null)
                .{ ._internal = .{ .http = http, .attached = true } }
            else
                .{};

            // Export-only early outs (parity with Httpz backend)
            if (comptime is_export) {
                if (http.reqHeaderHas("x-zx-export-notfound")) {
                    if (core_handler.prepareNotFound(http, pathname, req_obj, res_obj, arena, self.io, matched)) |cmp| {
                        var page = cmp;
                        if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
                        try self.streamHtmlDocument(arena, request, &backend, &page);
                    } else {
                        backend.status = 404;
                        try self.respondBody(arena, request, &backend, "404 Not Found");
                    }
                    return true;
                }

                if (matched) |route| {
                    if (http.reqHeaderHas("x-zx-static-data")) {
                        if (try route.resolveStaticParams(arena, self.io)) |params| {
                            var aw: std.Io.Writer.Allocating = .init(arena);
                            try std.zon.stringify.serialize(params, .{ .whitespace = true }, &aw.writer);
                            try self.respondBody(arena, request, &backend, aw.written());
                        } else {
                            try self.respondBody(arena, request, &backend, "");
                        }
                        return true;
                    }

                    if (route.isDynamic()) {
                        http.resHeaderSet("x-zx-dynamic", "true");
                        var aw: std.Io.Writer.Allocating = .init(arena);
                        try std.zon.stringify.serialize(.{ .dynamic = true }, .{ .whitespace = true }, &aw.writer);
                        try self.respondBody(arena, request, &backend, aw.written());
                        return true;
                    }
                }
            }

            const result = try Router.handle(.{ .is_dev = is_dev }, .{
                .http = http,
                .request = req_obj,
                .response = res_obj,
                .pathname = pathname,
                .method = method,
                .allocator = self.allocator,
                .arena = arena,
                .io = self.io,
                .base_path = base_path,
                .app_ctx = @ptrCast(self.app_ctx_ptr),
                .socket = socket,
            });
            if (comptime is_dev) markProxyStatus(result.proxy);

            const keep_going = blk: {
                switch (result.outcome) {
                    .response_ready => try self.flushRespond(arena, request, &backend),

                    .component => |c| {
                        var component = c.component;
                        if (comptime is_dev) {
                            if (Devtool.isComponentsMode(http.reqHeaderGet(Devtool.header_mode))) {
                                try self.respondDevtoolComponents(arena, request, &backend, http, &component);
                                break :blk true;
                            }
                            core_handler.injectDevScript(arena, &component);
                        }
                        if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
                        if (c.streaming) {
                            try self.streamHtmlSsr(arena, request, &backend, component, http, pathname, req_obj, res_obj, matched);
                        } else {
                            try self.streamHtmlDocument(arena, request, &backend, &component);
                        }
                    },

                    .ws_upgraded => {
                        if (!backend.upgraded) {
                            try self.flushRespond(arena, request, &backend);
                            break :blk true;
                        }
                        try self.handleWsUpgrade(request, ws_key, handlers.?, backend.upgradeData(), arena);
                        break :blk false;
                    },

                    .not_found => |nf| {
                        if (try self.respondStatic(arena, request, pathname)) {
                            backend.status = 200;
                            break :blk true;
                        }
                        if (nf.component) |cmp| {
                            var page = cmp;
                            if (comptime is_dev) core_handler.injectDevScript(arena, &page);
                            if (http.resHeaderGet("Content-Type") == null) backend.setContentTypeStr("text/html");
                            try self.streamHtmlDocument(arena, request, &backend, &page);
                        } else {
                            try self.flushRespond(arena, request, &backend);
                        }
                    },
                }
                break :blk true;
            };

            if ((comptime is_dev) and !AccessLog.isNoisyPath(pathname)) {
                AccessLog.log(arena, self.io, .{
                    .method = @tagName(method),
                    .path = pathname,
                    .status = backend.status,
                    .start_time = start_time,
                    .cache_status = .disabled,
                });
            }

            return keep_going;
        }

        fn markProxyStatus(proxy: zx.Router.ProxyResult) void {
            if (proxy.aborted) {
                AccessLog.ProxyStatus.markAborted();
            } else if (proxy.state_ptr != null) {
                AccessLog.ProxyStatus.markExecuted();
            }
        }

        /// Devtool probe via `x-zx-devtool` (proxied from `/.well-known/_zx/devtool`).
        /// Returns true when the request is fully handled (OPTIONS / meta / info).
        fn handleDevtool(
            self: *Self,
            request: *std.http.Server.Request,
            arena: std.mem.Allocator,
            backend: *Conn,
            http: zx.Http,
            method: std.http.Method,
        ) !bool {
            const action = Devtool.early(http.reqHeaderGet(Devtool.header_mode), method == .OPTIONS);
            if (action == .none) return false;
            Devtool.applyCors(http);

            switch (action) {
                .none => unreachable,
                .empty => {
                    try self.flushRespond(arena, request, backend);
                    return true;
                },
                .meta, .info => {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    if (action == .meta)
                        try Devtool.writeMeta(arena, &self.meta, self.config.server, &aw.writer)
                    else
                        try Devtool.writeInfo(arena, &self.meta, self.config.server, &aw.writer);
                    backend.setContentTypeStr("application/json");
                    try self.respondBody(arena, request, backend, aw.written());
                    return true;
                },
                .continue_render => return false,
            }
        }

        fn respondDevtoolComponents(
            self: *Self,
            arena: std.mem.Allocator,
            request: *std.http.Server.Request,
            backend: *Conn,
            http: zx.Http,
            component: *Component,
        ) !void {
            Devtool.applyCors(http);
            var aw: std.Io.Writer.Allocating = .init(arena);
            try Devtool.writeComponents(component.*, Devtool.componentOptions(http), &aw.writer);
            backend.setContentTypeStr("application/json");
            try self.respondBody(arena, request, backend, aw.written());
        }

        fn respondBody(self: *Self, arena: std.mem.Allocator, request: *std.http.Server.Request, backend: *Conn, body: []const u8) !void {
            _ = self;
            const headers = try collectHeaders(arena, backend);
            try request.respond(body, .{
                .status = statusFrom(backend.status),
                .extra_headers = headers,
            });
        }

        /// Write-through HTML: `Component.render` → `BodyWriter` (chunked).
        fn streamHtmlDocument(
            self: *Self,
            arena: std.mem.Allocator,
            request: *std.http.Server.Request,
            backend: *Conn,
            component: *Component,
        ) !void {
            _ = self;
            var chunk_buf: [16 * 1024]u8 = undefined;
            const headers = try collectHeaders(arena, backend);
            var body = try request.respondStreaming(&chunk_buf, .{
                .respond_options = .{
                    .status = statusFrom(backend.status),
                    .extra_headers = headers,
                },
            });
            core_handler.renderHtmlDocument(&body.writer, component, base_path) catch {
                try body.end();
                return;
            };
            try body.end();
        }

        /// Shell-first SSR: stream DOCTYPE + shell, then async component scripts.
        fn streamHtmlSsr(
            self: *Self,
            arena: std.mem.Allocator,
            request: *std.http.Server.Request,
            backend: *Conn,
            component: Component,
            http: zx.Http,
            pathname: []const u8,
            req_obj: zx.Http.Request,
            res_obj: zx.Http.Response,
            matched: ?*const ServerApp.Route,
        ) !void {
            var shell_writer = std.Io.Writer.Allocating.init(arena);
            const async_components = Router.streamComponent(component, arena, &shell_writer.writer, base_path) catch |stream_err| {
                var page = component;
                switch (stream_err) {
                    error.NotFound => {
                        if (core_handler.prepareNotFound(http, pathname, req_obj, res_obj, arena, self.io, matched)) |c| {
                            page = c;
                            backend.setContentTypeStr("text/html");
                        } else {
                            try self.flushRespond(arena, request, backend);
                            return;
                        }
                    },
                    else => {},
                }
                try self.streamHtmlDocument(arena, request, backend, &page);
                return;
            };

            var chunk_buf: [16 * 1024]u8 = undefined;
            const headers = try collectHeaders(arena, backend);
            var body = try request.respondStreaming(&chunk_buf, .{
                .respond_options = .{
                    .status = statusFrom(backend.status),
                    .extra_headers = headers,
                },
            });
            try writeAndFlushChunk(&body, "<!DOCTYPE html>\n");
            try writeAndFlushChunk(&body, shell_writer.written());
            if (async_components.len > 0) {
                try writeAndFlushChunk(&body, render.streaming_bootstrap_script);
                try streamAsyncComponents(self.io, &body, async_components);
            }
            try body.end();
        }

        fn handleWsUpgrade(
            self: *Self,
            request: *std.http.Server.Request,
            ws_key: ?[]const u8,
            handlers: ServerApp.RouteHandlers,
            upgrade_data: ?[]const u8,
            arena: std.mem.Allocator,
        ) !void {
            const key = ws_key orelse {
                request.respond("Invalid WebSocket handshake", .{ .status = .bad_request }) catch {};
                return;
            };

            var ws = request.respondWebSocket(.{ .key = key }) catch return;
            try ws.flush();

            var conn: WsConn = .{
                .ws = &ws,
                .io = self.io,
                .subscriber = undefined,
            };
            conn.subscriber = PubSub.Subscriber.init(self.allocator, self.io, &conn, stdWsWrite);
            defer conn.subscriber.unsubscribeAll();

            const socket = conn.socket();

            if (handlers.socket_open) |open_fn| {
                open_fn(socket, upgrade_data, self.allocator, arena, self.io) catch {};
            }

            while (true) {
                const msg = ws.readSmallMessage() catch break;
                switch (msg.opcode) {
                    .ping => {
                        conn.writeRaw(msg.data, .pong) catch break;
                        continue;
                    },
                    else => {},
                }
                if (handlers.socket) |socket_fn| {
                    const msg_type: zx.SocketMessageType = if (msg.opcode == .binary) .binary else .text;
                    socket_fn(socket, msg.data, msg_type, upgrade_data, self.allocator, arena, self.io) catch {};
                }
            }

            if (handlers.socket_close) |close_fn| {
                close_fn(socket, upgrade_data, self.allocator, self.io);
            }
        }

        fn flushRespond(self: *Self, arena: std.mem.Allocator, request: *std.http.Server.Request, backend: *Conn) !void {
            try self.respondBody(arena, request, backend, backend.bodySlice());
        }

        /// Serve a static file from the staticdir.
        fn respondStatic(self: *Self, arena: std.mem.Allocator, request: *std.http.Server.Request, pathname: []const u8) !bool {
            const staticdir = self.config.staticdir orelse constants.default_staticdir;
            const rel = if (pathname.len > 0 and pathname[0] == '/') pathname[1..] else pathname;
            if (rel.len == 0) return false;

            const file_path = std.fs.path.join(arena, &.{ staticdir, rel }) catch return false;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, arena, .unlimited) catch return false;

            const headers = [_]std.http.Header{
                .{ .name = "Server", .value = server_token },
                .{ .name = "Content-Type", .value = mimeForPath(pathname) },
            };
            try request.respond(data, .{ .status = .ok, .extra_headers = &headers });
            return true;
        }
    };
}

const WsConn = struct {
    ws: *std.http.Server.WebSocket,
    io: std.Io,
    write_mu: std.Io.Mutex = .init,
    subscriber: PubSub.Subscriber,

    fn socket(self: *WsConn) zx.Socket {
        return .{ ._internal = .{ .http = .{ .userdata = @ptrCast(self), .vtable = &vtable }, .attached = true } };
    }

    fn writeRaw(self: *WsConn, data: []const u8, op: std.http.Server.WebSocket.Opcode) !void {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        try self.ws.writeMessage(data, op);
    }

    const vtable = blk: {
        var vt = zx.Http.failing_vtable;
        vt.wsWrite = &wsWrite;
        vt.wsClose = &wsClose;
        vt.wsSubscribe = &wsSubscribe;
        vt.wsUnsubscribe = &wsUnsubscribe;
        vt.wsPublish = &wsPublish;
        vt.wsIsSubscribed = &wsIsSubscribed;
        vt.wsSetPublishToSelf = &wsSetPublishToSelf;
        break :blk vt;
    };

    fn of(userdata: ?*anyopaque) *WsConn {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn wsWrite(userdata: ?*anyopaque, data: []const u8) anyerror!void {
        try of(userdata).writeRaw(data, .text);
    }

    fn wsClose(userdata: ?*anyopaque) void {
        of(userdata).writeRaw("", .connection_close) catch {};
    }

    fn wsSubscribe(userdata: ?*anyopaque, topic: []const u8) void {
        of(userdata).subscriber.subscribe(topic);
    }

    fn wsUnsubscribe(userdata: ?*anyopaque, topic: []const u8) void {
        of(userdata).subscriber.unsubscribe(topic);
    }

    fn wsPublish(userdata: ?*anyopaque, topic: []const u8, message: []const u8) usize {
        return PubSub.publish(&of(userdata).subscriber, topic, message);
    }

    fn wsIsSubscribed(userdata: ?*anyopaque, topic: []const u8) bool {
        return of(userdata).subscriber.isSubscribed(topic);
    }

    fn wsSetPublishToSelf(userdata: ?*anyopaque, value: bool) void {
        of(userdata).subscriber.publish_to_self = value;
    }
};

fn stdWsWrite(ctx: *anyopaque, message: []const u8) anyerror!void {
    const self: *WsConn = @ptrCast(@alignCast(ctx));
    try self.writeRaw(message, .text);
}

fn collectHeaders(arena: std.mem.Allocator, backend: *Conn) ![]const std.http.Header {
    const headers = try arena.alloc(std.http.Header, backend.resp_headers.items.len);
    for (backend.resp_headers.items, 0..) |h, i| headers[i] = .{ .name = h.name, .value = h.value };
    return headers;
}

fn writeAndFlushChunk(body: *std.http.BodyWriter, data: []const u8) !void {
    if (data.len == 0) return;
    try body.writer.writeAll(data);
    try body.writer.flush();
    try body.flush();
}

/// Render async stream components in parallel and flush each script as it finishes.
fn streamAsyncComponents(io: std.Io, body: *std.http.BodyWriter, async_components: []render.AsyncComponent) !void {
    const AsyncResult = struct {
        script: []const u8 = &.{},
        done: std.atomic.Value(bool) = .init(false),
    };

    const results = try std.heap.page_allocator.alloc(AsyncResult, async_components.len);
    defer std.heap.page_allocator.free(results);
    for (results) |*result_entry| result_entry.* = .{};

    var remaining = std.atomic.Value(usize).init(async_components.len);

    const TaskContext = struct {
        async_comp: render.AsyncComponent,
        result: *AsyncResult,
        remaining_ref: *std.atomic.Value(usize),

        fn work(ctx: *@This()) void {
            defer {
                _ = ctx.remaining_ref.fetchSub(1, .seq_cst);
                std.heap.page_allocator.destroy(ctx);
            }

            const script = ctx.async_comp.renderScript(std.heap.page_allocator) catch {
                ctx.result.done.store(true, .seq_cst);
                return;
            };
            ctx.result.script = script;
            ctx.result.done.store(true, .seq_cst);
        }
    };

    const threads = try std.heap.page_allocator.alloc(?std.Thread, async_components.len);
    defer std.heap.page_allocator.free(threads);

    for (async_components, 0..) |async_comp, i| {
        const ctx = std.heap.page_allocator.create(TaskContext) catch {
            threads[i] = null;
            continue;
        };
        ctx.* = .{
            .async_comp = async_comp,
            .result = &results[i],
            .remaining_ref = &remaining,
        };
        threads[i] = std.Thread.spawn(.{}, TaskContext.work, .{ctx}) catch blk: {
            std.heap.page_allocator.destroy(ctx);
            _ = remaining.fetchSub(1, .seq_cst);
            results[i].done.store(true, .seq_cst);
            break :blk null;
        };
    }

    const streamed = try std.heap.page_allocator.alloc(bool, async_components.len);
    defer std.heap.page_allocator.free(streamed);
    @memset(streamed, false);

    var completed: usize = 0;
    var connection_closed = false;
    while (completed < async_components.len and !connection_closed) {
        for (results, 0..) |*result_entry, i| {
            if (streamed[i]) continue;
            if (!result_entry.done.load(.seq_cst)) continue;

            if (result_entry.script.len > 0) {
                writeAndFlushChunk(body, result_entry.script) catch {
                    connection_closed = true;
                    break;
                };
            }
            streamed[i] = true;
            completed += 1;
        }
        if (completed < async_components.len and !connection_closed) {
            _ = try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake);
        }
    }

    for (threads) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }
}

fn statusFrom(code: u16) std.http.Status {
    return @fromBackingInt(@intCast(@as(u10, @intCast(code))));
}

fn mimeForPath(path: []const u8) []const u8 {
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

fn resolveAddress(address_str: []const u8, port: u16) std.Io.net.IpAddress {
    const addr = if (std.mem.eql(u8, address_str, "localhost")) "127.0.0.1" else address_str;
    return std.Io.net.IpAddress.parse(addr, port) catch (std.Io.net.IpAddress.parse("0.0.0.0", port) catch unreachable);
}

fn wakeAccept(io: std.Io, port: u16) void {
    if (comptime builtin.os.tag == .wasi) return;
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    if (addr.connect(io, .{ .mode = .stream })) |s| {
        s.close(io);
    } else |_| {}
}

fn parseEnvPort(alloc: std.mem.Allocator, inita: zx.Init, name: []const u8) ?u16 {
    const minimal: std.process.Init.Minimal = switch (@TypeOf(inita)) {
        std.process.Init.Minimal => inita,
        std.process.Init => inita.minimal,
        else => return null,
    };
    const value = minimal.environ.getAlloc(alloc, name) catch return null;
    defer alloc.free(value);
    return std.fmt.parseInt(u16, value, 10) catch null;
}

const colors = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const reset_all = "\x1b[0m";
    const red = "\x1b[31m";
};
