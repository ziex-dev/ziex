/// App.Server.Std - experimental server backend using std.http.Server.
const Std = @This();

const std = @import("std");
const builtin = @import("builtin");
const app_opts = @import("app_opts");

const zx = @import("../../../../root.zig");
const Server = @import("../Server.zig");
const Pipeline = @import("Pipeline.zig");
const con = @import("../../../../util/conn.zig");

pub const token = "ziex/std";

pub fn Backend(comptime H: type) type {
    const Ctx = switch (@typeInfo(H)) {
        .@"struct" => H,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Server app context must be a struct, pointer to struct, or void, got: " ++ @tagName(@typeInfo(H))),
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        config: Pipeline.Config,
        app_ctx: H,
        app_ctx_ptr: *Ctx,
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

        pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Pipeline.Config, app_ctx: H, inita: zx.Init) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const port: u16 = (if (app_opts.server_port) |p| p else config.server.port) orelse Pipeline.defaults.port;
            const address_str = app_opts.server_address orelse config.server.address orelse Pipeline.defaults.address;

            const worker_count: u32 = @max(@as(u32, config.server.thread_pool.count orelse 1), 1);
            const queue_cap: u32 = @max(config.server.thread_pool.backlog, 1);

            self.* = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .app_ctx = app_ctx,
                .app_ctx_ptr = if (H == void) undefined else if (@typeInfo(H) == .pointer) app_ctx else &self.app_ctx,
                .address = Pipeline.net.address(address_str, port),
                .port = port,
                .inner_port = Pipeline.net.port(allocator, inita, .inner),
                .outer_port = Pipeline.net.port(allocator, inita, .outer),
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
            if (self.tcp) |*tcp| {
                const listener: std.Io.net.Stream = .{ .socket = tcp.socket };
                listener.shutdown(self.io, .both) catch {
                    http.wake(self.io, self.inner_port orelse self.port);
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
                    Pipeline.net.busy(bind_address.getPort());
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

            const tcp = &self.tcp.?;
            while (true) {
                if (self.shutting_down.load(.acquire)) return;
                const stream = tcp.accept(self.io) catch {
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
            Pipeline.net.banner(display_port, "");
        }

        pub fn server(self: *Self) Server {
            return .{ .userdata = self, .vtable = &vtable };
        }

        const vtable = Server.bind(Self);

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

            const target = try arena.dupe(u8, request.head.target);
            const method = request.head.method;
            const upgrade = request.upgradeRequested();
            const ws_key: ?[]const u8 = switch (upgrade) {
                .websocket => |k| if (k) |key| try arena.dupe(u8, key) else null,
                else => null,
            };

            var header_entries: std.ArrayList(Pipeline.HeaderEntry) = .empty;
            var header_iter = request.iterateHeaders();
            while (header_iter.next()) |h| {
                header_entries.append(arena, .{
                    .name = try arena.dupe(u8, h.name),
                    .value = try arena.dupe(u8, h.value),
                }) catch {};
            }

            var body_scratch: [8192]u8 = undefined;
            const body: []const u8 = if (ws_key != null)
                ""
            else if (request.readerExpectContinue(&body_scratch)) |body_reader|
                body_reader.allocRemaining(arena, .unlimited) catch ""
            else |_|
                "";

            var ctx: Request = .{
                .server = self,
                .request = request,
                .arena = arena,
                .ws_key = ws_key,
            };

            const result = try Pipeline.serve(
                Pipeline.opts,
                Pipeline.context(Pipeline.opts, arena, self.allocator, self.io, self.config.server, @ptrCast(self.app_ctx_ptr)),
                method,
                target,
                header_entries.items,
                body,
                ctx.transport(),
                token,
            );

            return result.keep_http;
        }

        const Request = struct {
            server: *Self,
            request: *std.http.Server.Request,
            arena: std.mem.Allocator,
            ws_key: ?[]const u8,

            fn transport(self: *Request) Pipeline.Transport {
                return .{
                    .ptr = self,
                    .flush = &flush,
                    .write = &write,
                    .html = &html,
                    .ssr = &ssr,
                    .static = &static,
                    .upgrade = &upgrade,
                };
            }

            fn of(ptr: *anyopaque) *Request {
                return @ptrCast(@alignCast(ptr));
            }

            fn flush(ptr: *anyopaque, backend: *Pipeline.Conn) anyerror!void {
                const ctx = of(ptr);
                try respondBody(ctx.arena, ctx.request, backend, backend.bodySlice());
            }

            fn write(ptr: *anyopaque, backend: *Pipeline.Conn, body: []const u8) anyerror!void {
                const ctx = of(ptr);
                try respondBody(ctx.arena, ctx.request, backend, body);
            }

            fn html(ptr: *anyopaque, backend: *Pipeline.Conn, component: *Pipeline.Component) anyerror!void {
                const ctx = of(ptr);
                var chunk_buf: [16 * 1024]u8 = undefined;
                const headers = try http.headers(ctx.arena, backend);
                var body = try ctx.request.respondStreaming(&chunk_buf, .{
                    .respond_options = .{
                        .status = http.status(backend.status),
                        .extra_headers = headers,
                    },
                });
                Pipeline.renderHtml(&body.writer, component, Pipeline.opts.base_path) catch {
                    try body.end();
                    return;
                };
                try body.end();
            }

            fn ssr(
                ptr: *anyopaque,
                backend: *Pipeline.Conn,
                shell: []const u8,
                async_components: []Pipeline.AsyncComponent,
            ) anyerror!void {
                const ctx = of(ptr);
                var chunk_buf: [16 * 1024]u8 = undefined;
                const headers = try http.headers(ctx.arena, backend);
                var body = try ctx.request.respondStreaming(&chunk_buf, .{
                    .respond_options = .{
                        .status = http.status(backend.status),
                        .extra_headers = headers,
                    },
                });
                try http.chunk(&body, "<!DOCTYPE html>\n");
                try http.chunk(&body, shell);
                if (async_components.len > 0) {
                    try http.chunk(&body, Pipeline.ssr_bootstrap);
                    try http.streamAsync(ctx.server.io, &body, async_components);
                }
                try body.end();
            }

            fn static(ptr: *anyopaque, pathname: []const u8) anyerror!bool {
                const ctx = of(ptr);
                const staticdir = ctx.server.config.staticdir orelse Pipeline.defaults.staticdir;
                const data = try Pipeline.web.staticFile(ctx.server.io, ctx.arena, staticdir, pathname) orelse return false;
                const headers = [_]std.http.Header{
                    .{ .name = "Server", .value = token },
                    .{ .name = "Content-Type", .value = Pipeline.web.mime(pathname) },
                };
                try ctx.request.respond(data, .{ .status = .ok, .extra_headers = &headers });
                return true;
            }

            fn upgrade(ptr: *anyopaque, handlers: Pipeline.RouteHandlers, upgrade_data: ?[]const u8) anyerror!void {
                const ctx = of(ptr);
                const key = ctx.ws_key orelse {
                    ctx.request.respond("Invalid WebSocket handshake", .{ .status = .bad_request }) catch {};
                    return;
                };

                var ws = ctx.request.respondWebSocket(.{ .key = key }) catch return;
                try ws.flush();

                var conn: Ws = .{
                    .ws = &ws,
                    .io = ctx.server.io,
                    .subscriber = undefined,
                };
                conn.subscriber = Pipeline.PubSub.Subscriber.init(ctx.server.allocator, ctx.server.io, &conn, Ws.onPublish);
                defer conn.subscriber.unsubscribeAll();

                const sock = conn.socket();

                if (handlers.socket_open) |open_fn| {
                    open_fn(sock, upgrade_data, ctx.server.allocator, ctx.arena, ctx.server.io) catch {};
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
                        const msg_type: Pipeline.SocketMessageType = if (msg.opcode == .binary) .binary else .text;
                        socket_fn(sock, msg.data, msg_type, upgrade_data, ctx.server.allocator, ctx.arena, ctx.server.io) catch {};
                    }
                }

                if (handlers.socket_close) |close_fn| {
                    close_fn(sock, upgrade_data, ctx.server.allocator, ctx.server.io);
                }
            }
        };

        fn respondBody(arena: std.mem.Allocator, request: *std.http.Server.Request, backend: *Pipeline.Conn, body: []const u8) !void {
            const headers = try http.headers(arena, backend);
            try request.respond(body, .{
                .status = http.status(backend.status),
                .extra_headers = headers,
            });
        }
    };
}

const Ws = struct {
    ws: *std.http.Server.WebSocket,
    io: std.Io,
    write_mu: std.Io.Mutex = .init,
    subscriber: Pipeline.PubSub.Subscriber,

    fn socket(self: *Ws) Pipeline.Socket {
        return .{ ._internal = .{ .http = .{ .userdata = @ptrCast(self), .vtable = &vtable }, .attached = true } };
    }

    fn writeRaw(self: *Ws, data: []const u8, op: std.http.Server.WebSocket.Opcode) !void {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        try self.ws.writeMessage(data, op);
    }

    const vtable = blk: {
        var vt = zx.Http.failing_vtable;
        vt.wsWrite = &write;
        vt.wsClose = &close;
        vt.wsSubscribe = &subscribe;
        vt.wsUnsubscribe = &unsubscribe;
        vt.wsPublish = &publish;
        vt.wsIsSubscribed = &isSubscribed;
        vt.wsSetPublishToSelf = &setPublishToSelf;
        break :blk vt;
    };

    fn of(userdata: ?*anyopaque) *Ws {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn write(userdata: ?*anyopaque, data: []const u8) anyerror!void {
        try of(userdata).writeRaw(data, .text);
    }

    fn close(userdata: ?*anyopaque) void {
        of(userdata).writeRaw("", .connection_close) catch {};
    }

    fn subscribe(userdata: ?*anyopaque, topic: []const u8) void {
        of(userdata).subscriber.subscribe(topic);
    }

    fn unsubscribe(userdata: ?*anyopaque, topic: []const u8) void {
        of(userdata).subscriber.unsubscribe(topic);
    }

    fn publish(userdata: ?*anyopaque, topic: []const u8, message: []const u8) usize {
        return Pipeline.PubSub.publish(&of(userdata).subscriber, topic, message);
    }

    fn isSubscribed(userdata: ?*anyopaque, topic: []const u8) bool {
        return of(userdata).subscriber.isSubscribed(topic);
    }

    fn setPublishToSelf(userdata: ?*anyopaque, value: bool) void {
        of(userdata).subscriber.publish_to_self = value;
    }

    fn onPublish(ctx: *anyopaque, message: []const u8) anyerror!void {
        try of(ctx).writeRaw(message, .text);
    }
};

/// std.http response bridging.
const http = struct {
    fn headers(arena: std.mem.Allocator, backend: *Pipeline.Conn) ![]const std.http.Header {
        const out = try arena.alloc(std.http.Header, backend.resp_headers.items.len);
        for (backend.resp_headers.items, 0..) |h, i| out[i] = .{ .name = h.name, .value = h.value };
        return out;
    }

    fn chunk(body: *std.http.BodyWriter, data: []const u8) !void {
        if (data.len == 0) return;
        try body.writer.writeAll(data);
        try body.writer.flush();
        try body.flush();
    }

    fn status(code: u16) std.http.Status {
        return @fromBackingInt(@intCast(@as(u10, @intCast(code))));
    }

    fn wake(io: std.Io, port: u16) void {
        if (comptime builtin.os.tag == .wasi) return;
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
        if (addr.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
        } else |_| {}
    }

    /// Render async stream components in parallel and flush each script as it finishes.
    fn streamAsync(io: std.Io, body: *std.http.BodyWriter, async_components: []Pipeline.AsyncComponent) !void {
        const AsyncResult = struct {
            script: []const u8 = &.{},
            done: std.atomic.Value(bool) = .init(false),
        };

        const results = try std.heap.page_allocator.alloc(AsyncResult, async_components.len);
        defer std.heap.page_allocator.free(results);
        for (results) |*result_entry| result_entry.* = .{};

        var remaining = std.atomic.Value(usize).init(async_components.len);

        const TaskContext = struct {
            async_comp: Pipeline.AsyncComponent,
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
                    chunk(body, result_entry.script) catch {
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
};
