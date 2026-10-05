const Dusty = @This();

const std = @import("std");
const dusty = @import("dusty");
const zx = @import("zx");

const Server = zx.App.Server;
const Pipeline = Server.Pipeline;

pub const token = "ziex/dusty";

pub fn Backend(comptime H: type) type {
    const Ctx = switch (@typeInfo(H)) {
        .@"struct" => H,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Server app context must be a struct, pointer to struct, or void, got: " ++ @tagName(@typeInfo(H))),
    };

    return struct {
        const Self = @This();
        const Inner = dusty.Server(Self);

        allocator: std.mem.Allocator,
        io: std.Io,
        config: Pipeline.Config,
        app_ctx: H,
        app_ctx_ptr: *Ctx,
        address: std.Io.net.IpAddress,
        port: u16,
        inner_port: ?u16 = null,
        outer_port: ?u16 = null,
        inner: Inner = undefined,
        listen_cfg: [1]dusty.Listener = undefined,
        stop_event: std.Io.Event = .unset,
        serve_err: ?anyerror = null,

        pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Pipeline.Config, app_ctx: H, inita: zx.Init) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const port_num: u16 = config.server.port orelse Pipeline.defaults.port;
            const host = config.server.address orelse Pipeline.defaults.address;

            self.* = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .app_ctx = app_ctx,
                .app_ctx_ptr = if (H == void) undefined else if (@typeInfo(H) == .pointer) app_ctx else &self.app_ctx,
                .address = Pipeline.net.address(host, port_num),
                .port = port_num,
                .inner_port = Pipeline.net.port(allocator, inita, .inner),
                .outer_port = Pipeline.net.port(allocator, inita, .outer),
            };

            self.inner = Inner.init(allocator, io, .{}, self);
            self.inner.router.any("/", handle);
            self.inner.router.any("/*path", handle);

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.inner.deinit();
            self.allocator.destroy(self);
        }

        pub fn stop(self: *Self) void {
            self.stop_event.set(self.io);
        }

        pub fn start(self: *Self) !void {
            self.stop_event.reset();
            self.serve_err = null;

            var bind_address = self.address;
            if (self.inner_port) |inner_port| {
                bind_address = std.Io.net.IpAddress.parse("127.0.0.1", inner_port) catch bind_address;
            }

            self.listen_cfg[0] = .{
                .address = .{ .ip = bind_address },
                .reuse_address = self.inner_port != null,
            };
            self.inner.config.listen = &self.listen_cfg;

            var group: std.Io.Group = .init;
            defer group.cancel(self.io);

            try group.concurrent(self.io, serveLoop, .{self});

            // Wait until ready, stop, or serve failed (serveLoop always sets stop_event on exit).
            while (!self.inner.ready.isSet() and !self.stop_event.isSet()) {
                self.stop_event.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Canceled => break,
                };
                break;
            }

            if (!self.inner.ready.isSet()) {
                return self.serve_err orelse error.Canceled;
            }

            if (!self.stop_event.isSet()) {
                self.stop_event.wait(self.io) catch {};
            }
        }

        fn serveLoop(self: *Self) !void {
            defer self.stop_event.set(self.io);
            self.inner.run() catch |err| switch (err) {
                error.Canceled => {},
                error.AddressInUse => {
                    Pipeline.net.busy(self.inner_port orelse self.port);
                    self.serve_err = err;
                },
                else => self.serve_err = err,
            };
        }

        pub fn info(self: *Self) void {
            Pipeline.net.banner(self.outer_port orelse self.port, "dusty");
        }

        pub fn server(self: *Self) Server {
            return .{ .userdata = self, .vtable = &vtable };
        }

        const vtable = Server.bind(Self);

        fn handle(self: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            const arena = req.arena;
            const url = try arena.dupe(u8, req.url);
            const method = http.method(req.method);

            var headers: std.ArrayList(Pipeline.HeaderEntry) = .empty;
            var header_iter = req.headers.iterator();
            while (header_iter.next()) |h| {
                try headers.append(arena, .{
                    .name = try arena.dupe(u8, h.key),
                    .value = try arena.dupe(u8, h.value),
                });
            }

            const body: []const u8 = blk: {
                const maybe_body = req.body() catch break :blk "";
                break :blk try arena.dupe(u8, maybe_body orelse "");
            };

            var request: Request = .{
                .server = self,
                .req = req,
                .res = res,
                .arena = arena,
            };

            _ = try Pipeline.serve(
                Pipeline.opts,
                Pipeline.context(Pipeline.opts, arena, self.allocator, self.io, self.config.server, @ptrCast(self.app_ctx_ptr)),
                method,
                url,
                headers.items,
                body,
                request.transport(),
                token,
            );
        }

        const Request = struct {
            server: *Self,
            req: *dusty.Request,
            res: *dusty.Response,
            arena: std.mem.Allocator,

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
                try http.apply(of(ptr).res, backend, backend.bodySlice());
            }

            fn write(ptr: *anyopaque, backend: *Pipeline.Conn, body: []const u8) anyerror!void {
                try http.apply(of(ptr).res, backend, body);
            }

            fn html(ptr: *anyopaque, backend: *Pipeline.Conn, component: *Pipeline.Component) anyerror!void {
                const ctx = of(ptr);
                try http.copyHeaders(ctx.res, backend);
                ctx.res.status = http.status(backend.status);

                var chunk_buf: [16 * 1024]u8 = undefined;
                var body = try ctx.res.stream(&chunk_buf);
                Pipeline.renderHtml(&body.interface, component, Pipeline.opts.base_path) catch {
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
                try http.copyHeaders(ctx.res, backend);
                ctx.res.status = http.status(backend.status);

                var chunk_buf: [16 * 1024]u8 = undefined;
                var body = try ctx.res.stream(&chunk_buf);
                try body.interface.writeAll("<!DOCTYPE html>\n");
                try body.interface.writeAll(shell);
                try body.interface.flush();
                if (async_components.len > 0) {
                    try body.interface.writeAll(Pipeline.ssr_bootstrap);
                    try body.interface.flush();
                    for (async_components) |async_comp| {
                        const script = async_comp.renderScript(ctx.arena) catch continue;
                        try body.interface.writeAll(script);
                        try body.interface.flush();
                    }
                }
                try body.end();
            }

            fn static(ptr: *anyopaque, pathname: []const u8) anyerror!bool {
                const ctx = of(ptr);
                const staticdir = ctx.server.config.staticdir orelse Pipeline.defaults.staticdir;
                const data = try Pipeline.web.staticFile(ctx.server.io, ctx.arena, staticdir, pathname) orelse return false;

                try ctx.res.header("Server", token);
                try ctx.res.header("Content-Type", Pipeline.web.mime(pathname));
                ctx.res.status = .ok;
                ctx.res.body = data;
                return true;
            }

            fn upgrade(ptr: *anyopaque, handlers: Pipeline.RouteHandlers, upgrade_data: ?[]const u8) anyerror!void {
                const ctx = of(ptr);
                var ws = try ctx.res.upgradeWebSocket(ctx.req) orelse {
                    ctx.res.status = .bad_request;
                    ctx.res.body = "Invalid WebSocket handshake";
                    return;
                };
                defer ws.deinit();

                var conn: Ws = .{
                    .ws = &ws,
                    .io = ctx.server.io,
                    .subscriber = undefined,
                };
                conn.subscriber = Pipeline.PubSub.Subscriber.init(ctx.server.allocator, ctx.server.io, &conn, Ws.onPublish);
                defer conn.subscriber.unsubscribeAll();

                const sock = conn.socket();

                if (handlers.socket_open) |open_fn| {
                    var open_arena: std.heap.ArenaAllocator = .init(ctx.server.allocator);
                    defer open_arena.deinit();
                    open_fn(sock, upgrade_data, ctx.server.allocator, open_arena.allocator(), ctx.server.io) catch {};
                }

                while (true) {
                    const msg = ws.receive() catch break;
                    switch (msg.type) {
                        .close => break,
                        .text, .binary => {
                            if (handlers.socket) |socket_fn| {
                                var msg_arena: std.heap.ArenaAllocator = .init(ctx.server.allocator);
                                defer msg_arena.deinit();
                                const msg_type: Pipeline.SocketMessageType = if (msg.type == .binary) .binary else .text;
                                socket_fn(sock, msg.data, msg_type, upgrade_data, ctx.server.allocator, msg_arena.allocator(), ctx.server.io) catch {};
                            }
                        },
                        else => {},
                    }
                }

                if (handlers.socket_close) |close_fn| {
                    close_fn(sock, upgrade_data, ctx.server.allocator, ctx.server.io);
                }
            }
        };
    };
}

const Ws = struct {
    ws: *dusty.WebSocket,
    io: std.Io,
    subscriber: Pipeline.PubSub.Subscriber,

    fn socket(self: *Ws) Pipeline.Socket {
        return .{ ._internal = .{ .http = .{ .userdata = @ptrCast(self), .vtable = &vtable }, .attached = true } };
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
        try of(userdata).ws.send(.text, data);
    }

    fn close(userdata: ?*anyopaque) void {
        of(userdata).ws.close(.normal, "closed") catch {};
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
        try of(ctx).ws.send(.text, message);
    }
};

/// Dusty request/response bridging.
const http = struct {
    fn apply(res: *dusty.Response, backend: *Pipeline.Conn, body: []const u8) !void {
        try copyHeaders(res, backend);
        res.status = status(backend.status);
        res.body = body;
    }

    fn copyHeaders(res: *dusty.Response, backend: *Pipeline.Conn) !void {
        for (backend.resp_headers.items) |entry| {
            res.header(entry.name, entry.value) catch {};
        }
    }

    fn method(m: dusty.Method) std.http.Method {
        return switch (m) {
            .get => .GET,
            .head => .HEAD,
            .post => .POST,
            .put => .PUT,
            .delete => .DELETE,
            .options => .OPTIONS,
            .trace => .TRACE,
            .connect => .CONNECT,
            .patch => .PATCH,
            else => .GET,
        };
    }

    fn status(code: u16) dusty.Status {
        return @fromBackingInt(@intCast(code));
    }
};
