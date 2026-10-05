const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const app_opts = @import("app_opts");

const zx = @import("../../../../root.zig");
const constants = @import("../../constants.zig");
const App = @import("../../App.zig");
const Server = @import("../Server.zig");
const AppConfig = @import("../Config.zig");
const server_meta = @import("../../../server/Server.zig");
const Http = @import("../../Http.zig");
const Request = @import("../../Http/Request.zig");
const Response = @import("../../Http/Response.zig");
const common = @import("../../Http/common.zig");
const MultiFormData = @import("../../Http/MultiFormData.zig");
const core_handler = @import("../Router/Handler.zig");
const routing = @import("../Router/routing.zig");
const rndr = @import("../../../server/render.zig");
const PageCache = @import("../../../server/PageCache.zig");
const AccessLog = @import("AccessLog.zig");
const Devtool = @import("Devtool.zig");
const PubSub = @import("PubSub.zig");
const Pipeline = @import("Pipeline.zig");

fn onPublish(ctx: *anyopaque, message: []const u8) anyerror!void {
    const conn: *httpz.websocket.Conn = @ptrCast(@alignCast(ctx));
    try conn.write(message);
}

pub const token = "ziex/httpz";

const Allocator = std.mem.Allocator;
const Component = zx.Component;
const Socket = routing.Socket;
const ServerApp = server_meta.ServerApp;
const server_app = server_meta.server_app;
const log = std.log.scoped(.app);

/// httpz ↔ std.http conversions.
const conv = struct {
    fn method(m: httpz.Method) std.http.Method {
        return switch (m) {
            .GET => .GET,
            .HEAD => .HEAD,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .CONNECT => .CONNECT,
            .OPTIONS => .OPTIONS,
            .PATCH => .PATCH,
            .OTHER => .CONNECT,
        };
    }

    fn protocol(p: httpz.Protocol) std.http.Version {
        return switch (p) {
            .HTTP10 => .@"HTTP/1.0",
            .HTTP11 => .@"HTTP/1.1",
        };
    }

    fn mime(ct: ?httpz.ContentType) ?[]const u8 {
        return if (ct) |c| switch (c) {
            .BINARY => "application/octet-stream",
            .CSS => "text/css",
            .CSV => "text/csv",
            .EOT => "application/vnd.ms-fontobject",
            .EVENTS => "text/event-stream",
            .GIF => "image/gif",
            .GZ => "application/gzip",
            .HTML => "text/html",
            .ICO => "image/vnd.microsoft.icon",
            .JPG => "image/jpeg",
            .JS => "text/javascript",
            .JSON => "application/json",
            .OTF => "font/otf",
            .PDF => "application/pdf",
            .PNG => "image/png",
            .SVG => "image/svg+xml",
            .TAR => "application/x-tar",
            .TEXT => "text/plain",
            .TTF => "font/ttf",
            .WASM => "application/wasm",
            .WEBP => "image/webp",
            .WOFF => "font/woff",
            .WOFF2 => "font/woff2",
            .XML => "text/xml",
            .UNKNOWN => null,
        } else null;
    }
};
// --- Backend context --- //
pub const HttpzCtx = struct {
    req: *httpz.Request,
    res: *httpz.Response,

    pub fn http(self: *HttpzCtx) Http {
        return .{ .userdata = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = Http.VTable{
        .reqText = &reqText,
        .reqHeaderGet = &reqHeaderGet,
        .reqHeaderHas = &reqHeaderHas,
        .reqParam = &reqParam,
        .reqQueryGet = &reqQueryGet,
        .reqQueryHas = &reqQueryHas,
        .reqFormGet = &reqFormGet,
        .reqFormHas = &reqFormHas,
        .reqMultiGet = &reqMultiGet,
        .reqMultiHas = &reqMultiHas,
        .reqMultiGetAll = &reqMultiGetAll,
        .resSetStatus = &resSetStatus,
        .resSetBody = &resSetBody,
        .resHeaderGet = &resHeaderGet,
        .resHeaderSet = &resHeaderSet,
        .resHeaderAdd = &resHeaderAdd,
        .resWriter = &resWriter,
        .resWriteChunk = &resWriteChunk,
        .resClearWriter = &resClearWriter,
        .resSetCookie = &resSetCookie,
        // WebSocket ops are not available on the plain request/response backend.
        .wsUpgrade = Http.failing_vtable.wsUpgrade,
        .wsWrite = Http.failing_vtable.wsWrite,
        .wsRead = Http.failing_vtable.wsRead,
        .wsClose = Http.failing_vtable.wsClose,
        .wsSubscribe = Http.failing_vtable.wsSubscribe,
        .wsUnsubscribe = Http.failing_vtable.wsUnsubscribe,
        .wsPublish = Http.failing_vtable.wsPublish,
        .wsIsSubscribed = Http.failing_vtable.wsIsSubscribed,
        .wsSetPublishToSelf = Http.failing_vtable.wsSetPublishToSelf,
    };

    fn ctx(userdata: ?*anyopaque) *HttpzCtx {
        return @ptrCast(@alignCast(userdata.?));
    }

    // --- request --- //

    fn reqText(userdata: ?*anyopaque) ?[]const u8 {
        return ctx(userdata).req.body();
    }

    fn reqHeaderGet(userdata: ?*anyopaque, name: []const u8) ?[]const u8 {
        return ctx(userdata).req.headers.get(name);
    }

    fn reqHeaderHas(userdata: ?*anyopaque, name: []const u8) bool {
        return ctx(userdata).req.headers.has(name);
    }

    fn reqParam(userdata: ?*anyopaque, name: []const u8) ?[]const u8 {
        return ctx(userdata).req.param(name);
    }

    fn reqQueryGet(userdata: ?*anyopaque, name: []const u8) ?[]const u8 {
        const query = ctx(userdata).req.query() catch return null;
        return query.get(name);
    }

    fn reqQueryHas(userdata: ?*anyopaque, name: []const u8) bool {
        const query = ctx(userdata).req.query() catch return false;
        return query.has(name);
    }

    fn reqFormGet(userdata: ?*anyopaque, name: []const u8) ?[]const u8 {
        if (ctx(userdata).req.formData()) |fd| {
            return fd.get(name);
        } else |_| {}
        return null;
    }

    fn reqFormHas(userdata: ?*anyopaque, name: []const u8) bool {
        if (ctx(userdata).req.formData()) |fd| {
            return fd.has(name);
        } else |_| {}
        return false;
    }

    fn reqMultiGet(userdata: ?*anyopaque, name: []const u8) ?MultiFormData.Value {
        if (ctx(userdata).req.multiFormData()) |mfd| {
            if (mfd.get(name)) |entry| {
                return .{ .data = entry.value, .filename = entry.filename };
            }
        } else |_| {}
        return null;
    }

    fn reqMultiHas(userdata: ?*anyopaque, name: []const u8) bool {
        if (ctx(userdata).req.multiFormData()) |mfd| {
            return mfd.has(name);
        } else |_| {}
        return false;
    }

    fn reqMultiGetAll(userdata: ?*anyopaque, name: []const u8, allocator: std.mem.Allocator) ?[]const MultiFormData.Value {
        const mfd = ctx(userdata).req.multiFormData() catch return null;
        if (mfd.get(name)) |entry| {
            const result = allocator.alloc(MultiFormData.Value, 1) catch return null;
            result[0] = .{ .data = entry.value, .filename = entry.filename };
            return result;
        }
        return null;
    }

    // --- response --- //

    fn resSetStatus(userdata: ?*anyopaque, code: u16) void {
        ctx(userdata).res.status = code;
    }

    fn resSetBody(userdata: ?*anyopaque, content: []const u8) void {
        ctx(userdata).res.body = content;
    }

    fn resHeaderGet(userdata: ?*anyopaque, name: []const u8) ?[]const u8 {
        return ctx(userdata).res.headers.get(name);
    }

    fn resHeaderSet(userdata: ?*anyopaque, name: []const u8, value: []const u8) void {
        ctx(userdata).res.header(name, value);
    }

    fn resHeaderAdd(userdata: ?*anyopaque, name: []const u8, value: []const u8) void {
        ctx(userdata).res.headers.add(name, value);
    }

    fn resWriter(userdata: ?*anyopaque) ?*std.Io.Writer {
        return ctx(userdata).res.writer();
    }

    fn resWriteChunk(userdata: ?*anyopaque, data: []const u8) anyerror!void {
        try ctx(userdata).res.chunk(data);
    }

    fn resClearWriter(userdata: ?*anyopaque) void {
        ctx(userdata).res.clearWriter();
    }

    fn resSetCookie(userdata: ?*anyopaque, name: []const u8, value: []const u8, opts: common.CookieOptions) anyerror!void {
        const res = ctx(userdata).res;
        const httpz_opts: httpz.response.CookieOpts = .{
            .path = opts.path,
            .domain = opts.domain,
            .max_age = opts.max_age,
            .secure = opts.secure,
            .http_only = opts.http_only,
            .partitioned = opts.partitioned,
            .same_site = if (opts.same_site) |ss| switch (ss) {
                .lax => .lax,
                .strict => .strict,
                .none => .none,
            } else null,
        };
        try res.setCookie(name, value, httpz_opts);
    }
};

// --- Facade construction --- //

/// Build an abstract `Request` backed by the given httpz request/response pair.
pub fn createRequest(ctx: *HttpzCtx) Request {
    const inner = ctx.req;
    return .init(.{
        .url = inner.url.raw,
        .method = conv.method(inner.method),
        .method_str = inner.method_string,
        .pathname = inner.url.path,
        .referrer = inner.headers.get("referer") orelse "",
        .search = inner.url.query,
        .protocol = conv.protocol(inner.protocol),
        .arena = inner.arena,
        .cookie_header = inner.headers.get("cookie") orelse "",
        .http = ctx.http(),
    });
}

/// Build an abstract `Response` backed by the given httpz request/response pair.
pub fn createResponse(ctx: *HttpzCtx, arena: std.mem.Allocator) Response {
    if (!ctx.res.headers.has("Server")) {
        ctx.res.header("Server", token);
    }
    return .init(.{
        .status = ctx.res.status,
        .arena = arena,
        .http = ctx.http(),
    });
}

// --- WebSocket: pre-upgrade --- //

pub const UpgradeBackend = struct {
    req: *httpz.Request,
    res: *httpz.Response,
    allocator: std.mem.Allocator,
    upgraded: bool = false,
    upgrade_data: ?[]const u8 = null,

    pub fn socket(self: *UpgradeBackend) Socket {
        return .{ ._internal = .{ .http = .{ .userdata = @ptrCast(self), .vtable = &vtable }, .attached = true } };
    }

    const vtable = blk: {
        var vt = Http.failing_vtable;
        vt.wsUpgrade = &wsUpgrade;
        break :blk vt;
    };

    fn ctx(userdata: ?*anyopaque) *UpgradeBackend {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn wsUpgrade(userdata: ?*anyopaque, data: ?[]const u8) anyerror!void {
        const self = ctx(userdata);
        self.upgraded = true;
        if (data) |bytes| {
            // The HTTP request arena is freed after the handler returns, but
            // upgrade_data must persist for the WebSocket lifetime.
            const copied = std.heap.page_allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
            @memcpy(copied, bytes);
            self.upgrade_data = copied;
        }
    }
};

// --- Native httpz server --- //

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
        meta: ServerApp,
        handler: HandlerType,
        inner: httpz.Server(*HandlerType),
        config: AppConfig,
        app_ctx: H,
        io: std.Io,
        /// Dev proxy bind port (`ZIEX_INNER_PORT`), parsed from process Init.
        inner_port: ?u16 = null,
        /// User-facing port (`ZIEX_OUTER_PORT`), parsed from process Init.
        outer_port: ?u16 = null,

        _is_listening: bool = false,

        const HandlerType = Handler(Ctx);

        pub fn init(io: std.Io, allocator: std.mem.Allocator, config: AppConfig, app_ctx: H, inita: zx.Init) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.allocator = allocator;
            self.meta = server_app;
            self.app_ctx = app_ctx;
            self.io = io;
            self._is_listening = false;
            self.inner_port = Pipeline.net.port(allocator, inita, .inner);
            self.outer_port = Pipeline.net.port(allocator, inita, .outer);

            // Get pointer to app context for handler initialization
            // When H is void, pass undefined; when H is pointer, use directly; when H is value, get pointer from self
            const app_ctx_ptr: *Ctx = if (H == void)
                undefined
            else if (@typeInfo(H) == .pointer)
                app_ctx
            else
                &self.app_ctx;

            self.config = config;
            self.handler = try HandlerType.init(self.io, allocator, &self.meta, config, app_ctx_ptr);
            errdefer self.handler.deinit();
            self.inner = try httpz.Server(*HandlerType).init(self.io, allocator, mapStruct(httpz.Config, config.server), &self.handler);

            // -- Routing -- //
            var router = try self.inner.router(.{});

            // Static assets
            router.get("/assets/*", HandlerType.static, .{});
            router.get("/*", HandlerType.static, .{});

            // Routes
            inline for (server_app.routes) |*route| {
                // Check if this is an API-only route (no page)
                const is_api_only = route.page == null;

                if (!is_api_only) {
                    // Page routes
                    var method_found = false;
                    var get_method_found = false;
                    if (route.page_opts) |pg_opts| {
                        inline for (pg_opts.methods) |method| {
                            method_found = true;
                            switch (method) {
                                .GET => {
                                    get_method_found = true;
                                    router.get(route.path, HandlerType.page, .{ .data = route });
                                },
                                .POST => router.post(route.path, HandlerType.page, .{ .data = route }),
                                .PUT => router.put(route.path, HandlerType.page, .{ .data = route }),
                                .DELETE => router.delete(route.path, HandlerType.page, .{ .data = route }),
                                .PATCH => router.patch(route.path, HandlerType.page, .{ .data = route }),
                                .OPTIONS => router.options(route.path, HandlerType.page, .{ .data = route }),
                                .HEAD => router.head(route.path, HandlerType.page, .{ .data = route }),
                                .CONNECT => router.connect(route.path, HandlerType.page, .{ .data = route }),
                                .TRACE => router.trace(route.path, HandlerType.page, .{ .data = route }),
                                .ALL => router.all(route.path, HandlerType.page, .{ .data = route }),
                            }
                        }
                    }

                    if (!method_found or !get_method_found) {
                        router.get(route.path, HandlerType.page, .{ .data = route });
                    }
                }

                // API routes
                if (route.route) |handlers| {
                    if (handlers.get) |_| router.get(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.post) |_| router.post(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.put) |_| router.put(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.delete) |_| router.delete(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.patch) |_| router.patch(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.head) |_| router.head(route.path, HandlerType.page, .{ .data = route });
                    if (handlers.options) |_| router.options(route.path, HandlerType.page, .{ .data = route });

                    if (handlers.handler) |_| {
                        if (handlers.get == null and is_api_only) router.get(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.post == null) router.post(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.put == null) router.put(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.delete == null) router.delete(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.patch == null) router.patch(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.head == null) router.head(route.path, HandlerType.page, .{ .data = route });
                        if (handlers.options == null) router.options(route.path, HandlerType.page, .{ .data = route });
                    }

                    if (handlers.custom_methods) |custom_methods| {
                        inline for (custom_methods) |custom| {
                            router.method(custom.method, route.path, HandlerType.page, .{ .data = route });
                        }
                    }
                }
            }

            self.applyServerDefaults();

            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;

            if (self._is_listening) {
                self.inner.stop();
                self._is_listening = false;
            }
            self.inner.deinit();
            self.handler.deinit();
            allocator.destroy(self);
        }

        pub fn stop(self: *Self) void {
            if (self._is_listening) {
                self.inner.stop();
                self._is_listening = false;
            }
        }

        pub fn start(self: *Self) !void {
            if (self._is_listening) return;
            self._is_listening = true;

            // When running under the dev proxy, bind to the inner port on
            // loopback only - the proxy owns the user-facing port.
            if (self.inner_port) |inner_port| {
                setServerAddress(&self.inner.config, "127.0.0.1", inner_port);
            }

            self.inner.listen() catch |err| {
                self._is_listening = false;

                switch (err) {
                    error.AddressInUse => {
                        // Dev port fallback lives in DevServer (outer proxy).
                        // The app binary must stay on ZIEX_INNER_PORT when proxied.
                        const port = serverPort(&self.inner.config).?;
                        self.infoWithCrossedOutPort(port);
                        Pipeline.net.busy(port);
                        return err;
                    },
                    else => return err,
                }
            };
        }

        /// Print the server info to the console
        /// ZX - v{version} | http://localhost:{port}
        pub fn info(self: *Self) void {
            const display_port: u16 = self.outer_port orelse serverPort(&self.inner.config).?;
            Pipeline.net.banner(display_port, "");
        }

        pub fn server(self: *Self) Server {
            return .{ .userdata = self, .vtable = &vtable };
        }

        const vtable = Server.bind(Self);

        /// Print the info line with the address/port part crossed out
        fn infoWithCrossedOutPort(_: *Self, port: u16) void {
            const c = Pipeline.colors;
            std.debug.print(
                "{s}\r{s}ZX{s} {s}- v{s}{s} {s} | {s}http://localhost:{d}{s}\n",
                .{
                    c.move_up,
                    c.bold,
                    c.reset,
                    c.dim,
                    zx.info.version,
                    c.reset,
                    c.dim,
                    c.strikethrough,
                    port,
                    c.reset,
                },
            );
        }

        fn applyServerDefaults(self: *Self) void {
            const port = (if (app_opts.server_port != null) app_opts.server_port else serverPort(&self.inner.config)) orelse Pipeline.defaults.port;
            const address = app_opts.server_address orelse self.config.server.address orelse Pipeline.defaults.address;

            setServerAddress(&self.inner.config, address, port);
            // Config already carries ziex form defaults; keep httpz in sync if
            // an older mapped null somehow remains.
            if (self.inner.config.request.max_form_count == null) {
                self.inner.config.request.max_form_count = constants.default_max_form_count;
            }
            if (self.inner.config.request.max_multiform_count == null) {
                self.inner.config.request.max_multiform_count = constants.default_max_multiform_count;
            }
        }
    };
}

/// Comptime-map any struct into a target struct type by matching field names.
/// Used to convert our AppConfig.ServerConfig into httpz.Config without manually
/// listing each field. Only fields present in both are copied; nested structs
/// recurse. This keeps AppConfig decoupled from httpz (so wasm/wasi builds work).
pub fn mapStruct(comptime T: type, src: anytype) T {
    var out: T = .{};
    const S = @TypeOf(src);
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
        if (comptime T == httpz.Config and std.mem.eql(u8, field_name, "address")) {
            // handled after the loop because our app config stores host/port
            // separately while httpz expects a tagged union
        } else if (@hasField(S, field_name)) {
            const sv = @field(src, field_name);
            switch (@typeInfo(field_type)) {
                .@"struct" => @field(out, field_name) = mapStruct(field_type, sv),
                else => @field(out, field_name) = sv,
            }
        }
    }
    if (comptime T == httpz.Config) out.address = mapServerAddress(src);
    return out;
}

fn mapServerAddress(src: AppConfig.ServerConfig) httpz.Config.Address {
    if (src.unix_path) |unix_path| return .{ .unix = unix_path };
    const port = src.port orelse Pipeline.defaults.port;
    const address = src.address orelse Pipeline.defaults.address;

    if (std.mem.eql(u8, address, "localhost")) return httpz.Config.Address.localhost(port);
    if (std.mem.eql(u8, address, "0.0.0.0")) return httpz.Config.Address.all(port);

    return .{ .ip = std.Io.net.IpAddress.parse(address, port) catch .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } } };
}

fn serverPort(config: *const httpz.Config) ?u16 {
    return switch (config.address) {
        .ip => |ip| ip.getPort(),
        .unix => null,
    };
}

fn setServerAddress(config: *httpz.Config, address: []const u8, port: u16) void {
    config.address = if (std.mem.eql(u8, address, "localhost"))
        httpz.Config.Address.localhost(port)
    else if (std.mem.eql(u8, address, "0.0.0.0"))
        httpz.Config.Address.all(port)
    else
        .{ .ip = std.Io.net.IpAddress.parse(address, port) catch .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } } };
}

// --- Client WebSocket (outbound `ws://`/`wss://` connections) --- //

pub const websocket = struct {
    const WebSocket = @import("../../WebSocket.zig");
    const ws = httpz.websocket;

    const CloseOptions = WebSocket.CloseOptions;
    const WebSocketError = WebSocket.WebSocketError;

    /// Backend context stored in WebSocket.backend_ctx
    const BackendContext = struct {
        client: ws.Client,
        read_thread: ?std.Thread,
        ws_ptr: *WebSocket,

        fn init(allocator: Allocator, host: []const u8, port: u16, tls: bool) !*BackendContext {
            const ctx = try allocator.create(BackendContext);
            errdefer allocator.destroy(ctx);

            ctx.* = .{
                .client = try ws.Client.init(allocator, .{
                    .host = host,
                    .port = port,
                    .tls = tls,
                }),
                .read_thread = null,
                .ws_ptr = undefined,
            };

            return ctx;
        }

        fn deinit(self: *BackendContext, allocator: Allocator) void {
            // Wait for read thread to finish
            if (self.read_thread) |thread| {
                thread.join();
            }
            self.client.deinit();
            allocator.destroy(self);
        }
    };

    /// Handler for the websocket read loop
    const ReadHandler = struct {
        ws: *WebSocket,

        pub fn serverMessage(self: *ReadHandler, data: []const u8, msg_type: ws.MessageType) !void {
            const w = self.ws;
            if (w.onmessage) |handler| {
                if (msg_type == .binary) {
                    handler(w, .{ .data = .{ .binary = data } });
                } else {
                    handler(w, .{ .data = .{ .text = data } });
                }
            }
        }

        pub fn serverClose(self: *ReadHandler, data: []const u8) !void {
            const w = self.ws;
            w.ready_state = .closed;

            // Parse close code from data if available
            const code: u16 = if (data.len >= 2)
                std.mem.readInt(u16, data[0..2], .big)
            else
                1000;

            const reason = if (data.len > 2) data[2..] else "";

            if (w.onclose) |handler| {
                handler(w, .{
                    .code = code,
                    .reason = reason,
                    .was_clean = true,
                });
            }
        }

        pub fn close(self: *ReadHandler) void {
            const w = self.ws;
            if (w.ready_state != .closed) {
                w.ready_state = .closed;
            }
        }
    };

    /// Parse a WebSocket URL into components
    fn parseWsUrl(url: []const u8) !struct { host: []const u8, port: u16, path: []const u8, tls: bool } {
        var tls = false;
        var rest: []const u8 = url;

        if (std.mem.startsWith(u8, url, "wss://")) {
            tls = true;
            rest = url[6..];
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            rest = url[5..];
        } else {
            return error.InvalidUrl;
        }

        // Find path separator
        const path_start = std.mem.indexOf(u8, rest, "/") orelse rest.len;
        const host_port = rest[0..path_start];
        const path = if (path_start < rest.len) rest[path_start..] else "/";

        // Parse host:port
        if (std.mem.indexOf(u8, host_port, ":")) |colon| {
            const host = host_port[0..colon];
            const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidUrl;
            return .{ .host = host, .port = port, .path = path, .tls = tls };
        } else {
            const default_port: u16 = if (tls) 443 else 80;
            return .{ .host = host_port, .port = default_port, .path = path, .tls = tls };
        }
    }

    /// Establish a WebSocket connection
    pub fn connect(w: *WebSocket) WebSocketError!void {
        const allocator = w._allocator;

        // Parse URL
        const url_parts = parseWsUrl(w.url) catch return error.InvalidUrl;

        // Create backend context
        const ctx = BackendContext.init(allocator, url_parts.host, url_parts.port, url_parts.tls) catch
            return error.ConnectionFailed;
        errdefer ctx.deinit(allocator);

        ctx.ws_ptr = w;
        w._backend_ctx = ctx;

        // Perform handshake
        ctx.client.handshake(url_parts.path, .{}) catch {
            return error.ConnectionFailed;
        };

        w.ready_state = .open;

        // Notify open handler
        w._handleOpen();

        // Start read loop in background thread
        ctx.read_thread = std.Thread.spawn(.{}, struct {
            fn run(context: *BackendContext) void {
                var handler = ReadHandler{ .ws = context.ws_ptr };
                context.client.readLoop(&handler) catch |err| {
                    const inner = context.ws_ptr;
                    if (inner.onerror) |error_handler| {
                        error_handler(inner, .{ .message = @errorName(err) });
                    }
                };
            }
        }.run, .{ctx}) catch {
            return error.ConnectionFailed;
        };
    }

    /// Send text data
    pub fn send(w: *WebSocket, data: []const u8) WebSocketError!void {
        const ctx: *BackendContext = @ptrCast(@alignCast(w._backend_ctx orelse return error.NotConnected));

        // writeText takes a mutable slice, so we need to copy
        const buf = w._allocator.alloc(u8, data.len) catch return error.SendFailed;
        defer w._allocator.free(buf);
        @memcpy(buf, data);

        ctx.client.writeText(buf) catch return error.SendFailed;
    }

    /// Send binary data
    pub fn sendBinary(w: *WebSocket, data: []const u8) WebSocketError!void {
        const ctx: *BackendContext = @ptrCast(@alignCast(w._backend_ctx orelse return error.NotConnected));

        // writeBin takes a mutable slice, so we need to copy
        const buf = w._allocator.alloc(u8, data.len) catch return error.SendFailed;
        defer w._allocator.free(buf);
        @memcpy(buf, data);

        ctx.client.writeBin(buf) catch return error.SendFailed;
    }

    /// Close the connection
    pub fn close(w: *WebSocket, options: CloseOptions) void {
        const ctx: *BackendContext = @ptrCast(@alignCast(w._backend_ctx orelse return));

        w.ready_state = .closing;
        const code = options.code orelse 1000;
        const reason = options.reason orelse "";

        ctx.client.close(.{ .code = code }) catch {};
        w.ready_state = .closed;

        if (w.onclose) |handler| {
            handler(w, .{
                .code = code,
                .reason = reason,
                .was_clean = true,
            });
        }
    }

    /// Clean up resources
    pub fn deinit(w: *WebSocket) void {
        if (w._backend_ctx) |ptr| {
            const ctx: *BackendContext = @ptrCast(@alignCast(ptr));
            ctx.deinit(w._allocator);
            w._backend_ctx = null;
        }
    }
};

// --- Shared native server request handler --- //

/// Converts transport-specific (httpz) types to abstract Request/Response,
/// then runs cache / Router / render / static / WebSocket orchestration.
fn Handler(comptime Ctx: type) type {
    const is_dev = App.mode == .dev;
    const is_export = App.mode == .@"export";
    const feat_cache = app_opts.feat_cache_server;

    return struct {
        const Self = @This();

        meta: *ServerApp,
        config: AppConfig,
        page_cache: if (feat_cache) PageCache else void,
        allocator: std.mem.Allocator,
        app_ctx: *Ctx,
        io: std.Io,

        pub fn init(io: std.Io, allocator: std.mem.Allocator, meta: *ServerApp, config: AppConfig, app_ctx: *Ctx) !Self {
            const cache_config = config.cache;

            return Self{
                .meta = meta,
                .config = config,
                .allocator = allocator,
                .page_cache = if (feat_cache) try PageCache.initCachez(io, allocator, cache_config) else {},
                .app_ctx = app_ctx,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            if (feat_cache) self.page_cache.deinit();
        }

        pub fn dispatch(self: *Self, action: httpz.Action(*Self), req: *httpz.Request, res: *httpz.Response) !void {
            const start_time = if (comptime is_dev) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;

            // Reset proxy status for this request (dev mode tracking)
            if (comptime is_dev) AccessLog.ProxyStatus.reset();

            // Try cache first, execute action on miss
            // Note: Middlewares are handled by httpz before this dispatch is called
            var hctx = HttpzCtx{ .req = req, .res = res };
            const abstract_req = createRequest(&hctx);
            const abstract_res = createResponse(&hctx, req.arena);

            const is_devtool_req = (comptime is_dev) and req.header("x-zx-devtool") != null;
            const cache_status = if (feat_cache and !is_devtool_req) self.page_cache.tryServe(abstract_req, abstract_res) else PageCache.Status.disabled;
            if (cache_status != .hit) {
                try action(self, req, res);
                if (cache_status == .miss) {
                    const buffered = res.buffer.writer.buffered();
                    const body = if (buffered.len > 0) buffered else res.body;
                    self.page_cache.store(abstract_req, abstract_res, .{
                        .status = res.status,
                        .body = body,
                        .content_type = conv.mime(res.content_type),
                    });
                }
            }

            // Dev mode logging (skip noisy paths)
            if ((comptime is_dev) and !AccessLog.isNoisyPath(req.url.path)) {
                AccessLog.log(req.arena, self.io, .{
                    .method = @tagName(req.method),
                    .path = req.url.path,
                    .status = res.status,
                    .start_time = start_time,
                    .cache_status = cache_status,
                });
            }
        }

        pub fn notFound(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
            var hctx = HttpzCtx{ .req = req, .res = res };
            const abstract_req = createRequest(&hctx);
            const abstract_res = createResponse(&hctx, req.arena);
            const http = hctx.http();
            const path = req.url.path;

            const matched_route: ?*const ServerApp.Route = if (req.route_data) |rd|
                @ptrCast(@alignCast(rd))
            else
                zx.Router.findRoute(path, .{ .match = .exact });

            const proxy_result = core_handler.executeNotFoundProxy(path, abstract_req, abstract_res, req.arena, self.io);
            if (proxy_result.aborted) {
                AccessLog.ProxyStatus.markAborted();
                return;
            }
            if (proxy_result.state_ptr != null) AccessLog.ProxyStatus.markExecuted();

            const component = core_handler.prepareNotFound(http, path, abstract_req, abstract_res, req.arena, self.io, matched_route);
            try self.emitHtmlOrPlain(req, res, component);
        }

        pub fn uncaughtError(self: *Self, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
            var hctx = HttpzCtx{ .req = req, .res = res };
            const abstract_req = createRequest(&hctx);
            const abstract_res = createResponse(&hctx, req.arena);
            const http = hctx.http();

            const component = core_handler.prepareError(http, req.url.path, abstract_req, abstract_res, req.arena, self.io, err);
            self.emitHtmlOrPlain(req, res, component) catch {
                res.body = "500 Internal Server Error";
            };
        }

        fn emitHtmlOrPlain(self: *Self, req: *httpz.Request, res: *httpz.Response, component: ?Component) !void {
            _ = self;
            if (component) |cmp| {
                var page_component = cmp;
                if (comptime is_dev) core_handler.injectDevScript(req.arena, &page_component);

                res.clearWriter();
                const writer = res.writer();
                core_handler.renderHtmlDocument(writer, &page_component, app_opts.app_base_path) catch {
                    if (res.body.len == 0) {
                        res.body = if (res.status == 404) "404 Not Found" else "500 Internal Server Error";
                    }
                };
                res.content_type = .HTML;
            } else {
                res.content_type = .HTML;
                // prepare* already set res.body via Http.resSetBody
            }
        }

        pub fn page(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
            const allocator = self.allocator;

            if (comptime is_dev) {
                if (try self.devtool(req, res)) return;
            }

            // Export-only early outs
            if (comptime is_export) {
                if (req.header("x-zx-export-notfound")) |_| {
                    return self.notFound(req, res);
                }
                if (req.route_data) |rd| {
                    const route: *const ServerApp.Route = @ptrCast(@alignCast(rd));
                    if (req.header("x-zx-static-data")) |_| {
                        if (try route.resolveStaticParams(req.arena, self.io)) |params| {
                            try std.zon.stringify.serialize(params, .{ .whitespace = true }, res.writer());
                        }
                        return;
                    }

                    if (route.isDynamic()) {
                        res.header("x-zx-dynamic", "true");
                        try std.zon.stringify.serialize(.{ .dynamic = true }, .{ .whitespace = true }, res.writer());
                        return;
                    }
                }
            }

            var hctx = HttpzCtx{ .req = req, .res = res };
            const abstract_req = createRequest(&hctx);
            const abstract_res = createResponse(&hctx, req.arena);
            const http = hctx.http();

            const route: ?*const ServerApp.Route = if (req.route_data) |rd|
                @ptrCast(@alignCast(rd))
            else
                null;

            var upgrade_ctx = UpgradeBackend{
                .allocator = allocator,
                .req = req,
                .res = res,
            };
            var use_socket = false;
            const socket: zx.Socket = blk: {
                if (route) |r| {
                    if (r.route) |handlers| {
                        if (handlers.socket != null) {
                            use_socket = true;
                            break :blk upgrade_ctx.socket();
                        }
                    }
                }
                break :blk .{};
            };

            const result = try zx.Router.handle(.{ .is_dev = is_dev }, .{
                .http = http,
                .request = abstract_req,
                .response = abstract_res,
                .pathname = req.url.path,
                .method = abstract_req.method,
                .allocator = allocator,
                .arena = req.arena,
                .io = self.io,
                .base_path = app_opts.app_base_path,
                .app_ctx = @ptrCast(self.app_ctx),
                .socket = socket,
            });
            Pipeline.proxyStatus(result.proxy);

            switch (result.outcome) {
                .response_ready => {},
                .component => |c| {
                    var page_component = c.component;

                    if (comptime is_dev) {
                        if (Devtool.isComponentsMode(req.header(Devtool.header_mode))) {
                            res.content_type = .JSON;
                            try Devtool.writeComponents(page_component, Devtool.componentOptions(http), res.writer());
                            return;
                        }
                        core_handler.injectDevScript(req.arena, &page_component);
                    }

                    if (c.streaming) {
                        try self.renderStreaming(res, &page_component, req.arena);
                    } else {
                        const writer = &res.buffer.writer;
                        core_handler.renderHtmlDocument(writer, &page_component, app_opts.app_base_path) catch |err| switch (err) {
                            error.NotFound => return self.notFound(req, res),
                            else => {
                                log.err("rendering page: {}", .{err});
                                return self.uncaughtError(req, res, err);
                            },
                        };
                    }
                    res.content_type = .HTML;
                },
                .ws_upgraded => {
                    if (use_socket and upgrade_ctx.upgraded) {
                        if (route) |r| {
                            if (r.route) |handlers| {
                                const ws_ctx = WebsocketContext{
                                    .socket_handler = handlers.socket,
                                    .socket_open_handler = handlers.socket_open,
                                    .socket_close_handler = handlers.socket_close,
                                    .allocator = allocator,
                                    .io = self.io,
                                    .upgrade_data = upgrade_ctx.upgrade_data,
                                };
                                if (try httpz.upgradeWebsocket(WebsocketHandler, req, res, ws_ctx) == false) {
                                    res.status = 400;
                                    res.body = "Invalid WebSocket handshake";
                                }
                            }
                        }
                    }
                },
                .not_found => |nf| {
                    try self.emitHtmlOrPlain(req, res, nf.component);
                },
            }
        }

        /// Returns true when the request was fully handled.
        fn devtool(self: *Self, req: *httpz.Request, res: *httpz.Response) !bool {
            const action = Devtool.early(req.header(Devtool.header_mode), req.method == .OPTIONS);
            if (action == .none) return false;
            inline for (Devtool.cors) |pair| {
                res.header(pair[0], pair[1]);
            }

            switch (action) {
                .none => unreachable,
                .empty => {
                    res.status = 200;
                    return true;
                },
                .meta => {
                    res.content_type = .JSON;
                    try Devtool.writeMeta(req.arena, self.meta, self.config.server, res.writer());
                    return true;
                },
                .info => {
                    res.content_type = .JSON;
                    try Devtool.writeInfo(req.arena, self.meta, self.config.server, res.writer());
                    return true;
                },
                .continue_render => return false,
            }
        }

        /// Render a page with streaming SSR support
        /// Sends the initial shell immediately, then streams async components as they complete
        fn renderStreaming(self: *Self, res: *httpz.Response, page_component: *Component, arena: std.mem.Allocator) !void {
            var shell_writer = std.Io.Writer.Allocating.init(arena);
            const async_components = rndr.stream(page_component.*, arena, &shell_writer.writer, .{ .base_path = app_opts.app_base_path }) catch |err| {
                log.err("streaming page: {}", .{err});
                return err;
            };

            res.chunk("<!DOCTYPE html>\n") catch |err| {
                log.err("sending DOCTYPE: {}", .{err});
                return err;
            };
            res.chunk(shell_writer.written()) catch |err| {
                log.err("sending shell: {}", .{err});
                return err;
            };

            if (async_components.len > 0) {
                res.chunk(Pipeline.ssr_bootstrap) catch |err| {
                    log.err("sending bootstrap script: {}", .{err});
                    return err;
                };
                const AsyncResult = struct {
                    script: []const u8 = &.{},
                    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                };

                const results = std.heap.page_allocator.alloc(AsyncResult, async_components.len) catch |err| {
                    log.err("allocating results: {}", .{err});
                    return err;
                };
                defer std.heap.page_allocator.free(results);

                for (results) |*result_entry| {
                    result_entry.* = .{};
                }

                var remaining = std.atomic.Value(usize).init(async_components.len);

                const TaskContext = struct {
                    async_comp: rndr.AsyncComponent,
                    result: *AsyncResult,
                    remaining_ref: *std.atomic.Value(usize),

                    fn work(ctx: *@This()) void {
                        defer {
                            _ = ctx.remaining_ref.fetchSub(1, .seq_cst);
                            std.heap.page_allocator.destroy(ctx);
                        }

                        const script = ctx.async_comp.renderScript(std.heap.page_allocator) catch |work_err| {
                            log.err("rendering async component {d}: {}", .{ ctx.async_comp.id, work_err });
                            ctx.result.done.store(true, .seq_cst);
                            return;
                        };

                        ctx.result.script = script;
                        ctx.result.done.store(true, .seq_cst);
                    }
                };

                var threads = std.heap.page_allocator.alloc(?std.Thread, async_components.len) catch |err| {
                    log.err("allocating threads: {}", .{err});
                    return err;
                };
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

                var streamed = std.heap.page_allocator.alloc(bool, async_components.len) catch |err| {
                    log.err("allocating streamed flags: {}", .{err});
                    return err;
                };
                defer std.heap.page_allocator.free(streamed);
                @memset(streamed, false);

                var completed: usize = 0;
                var connection_closed = false;
                while (completed < async_components.len and !connection_closed) {
                    for (results, 0..) |*result_entry, i| {
                        if (streamed[i]) continue;

                        if (result_entry.done.load(.seq_cst)) {
                            if (result_entry.script.len > 0) {
                                res.chunk(result_entry.script) catch |chunk_err| {
                                    log.err("streaming async component: {}", .{chunk_err});
                                    connection_closed = true;
                                    break;
                                };
                            }
                            streamed[i] = true;
                            completed += 1;
                        }
                    }
                    if (completed < async_components.len and !connection_closed) {
                        _ = try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(5), .awake);
                    }
                }

                for (threads) |maybe_thread| {
                    if (maybe_thread) |thread| {
                        thread.join();
                    }
                }
            }
        }

        pub fn static(self: *Self, req: *httpz.Request, res: *httpz.Response) !void {
            const staticdir = self.config.staticdir orelse Pipeline.defaults.staticdir;
            const assets_path = try std.fs.path.join(res.arena, &.{ staticdir, req.url.path });

            const body = std.Io.Dir.cwd().readFileAlloc(self.io, assets_path, res.arena, .unlimited) catch |err| {
                switch (err) {
                    error.FileNotFound => return self.notFound(req, res),
                    else => return self.uncaughtError(req, res, err),
                }
            };

            res.body = body;
            res.content_type = httpz.ContentType.forFile(req.url.path);
        }

        /// Context passed when upgrading to WebSocket
        /// Contains the socket handler functions and allocator
        pub const WebsocketContext = struct {
            socket_handler: ?ServerApp.SocketHandler = null,
            socket_open_handler: ?ServerApp.SocketOpenHandler = null,
            socket_close_handler: ?ServerApp.SocketCloseHandler = null,
            allocator: std.mem.Allocator = std.heap.page_allocator,
            io: std.Io = .failing,
            /// Copied user data bytes passed during upgrade
            upgrade_data: ?[]const u8 = null,
        };

        pub const WebsocketHandler = struct {
            conn: *httpz.websocket.Conn,
            socket_handler: ?ServerApp.SocketHandler,
            socket_open_handler: ?ServerApp.SocketOpenHandler,
            socket_close_handler: ?ServerApp.SocketCloseHandler,
            ws_allocator: std.mem.Allocator,
            io: std.Io,
            upgrade_data: ?[]const u8,
            /// Subscriber data for pub/sub (stored directly on connection)
            subscriber: PubSub.Subscriber,

            pub fn init(conn: *httpz.websocket.Conn, ctx: WebsocketContext) !WebsocketHandler {
                return .{
                    .conn = conn,
                    .socket_handler = ctx.socket_handler,
                    .socket_open_handler = ctx.socket_open_handler,
                    .socket_close_handler = ctx.socket_close_handler,
                    .ws_allocator = ctx.allocator,
                    .io = ctx.io,
                    .upgrade_data = ctx.upgrade_data,
                    .subscriber = PubSub.Subscriber.init(ctx.allocator, ctx.io, conn, onPublish),
                };
            }

            /// Called after the WebSocket connection is established
            pub fn afterInit(self: *WebsocketHandler) !void {
                if (self.socket_open_handler) |handler| {
                    var arena_instance = std.heap.ArenaAllocator.init(self.ws_allocator);
                    defer arena_instance.deinit();
                    const socket = self.createSocket();
                    handler(socket, self.upgrade_data, self.ws_allocator, arena_instance.allocator(), self.io) catch |err| {
                        log.err("SocketOpen handler error: {}", .{err});
                    };
                }
            }

            /// Called when a text or binary message is received from the client
            pub fn clientMessage(self: *WebsocketHandler, _: Allocator, data: []const u8, message_type: httpz.websocket.MessageTextType) !void {
                const msg_type: zx.SocketMessageType = switch (message_type) {
                    .text => .text,
                    .binary => .binary,
                };

                if (self.socket_handler) |handler| {
                    var arena_instance = std.heap.ArenaAllocator.init(self.ws_allocator);
                    defer arena_instance.deinit();
                    const socket = self.createSocket();
                    handler(socket, data, msg_type, self.upgrade_data, self.ws_allocator, arena_instance.allocator(), self.io) catch |err| {
                        log.err("Socket handler error: {}", .{err});
                    };
                } else {
                    // Default echo behavior when no handler defined
                    try self.conn.write(data);
                }
            }

            /// Called when the connection is being closed (for any reason)
            pub fn close(self: *WebsocketHandler) void {
                // Unsubscribe from all topics (pub/sub cleanup)
                self.subscriber.unsubscribeAll();

                if (self.socket_close_handler) |handler| {
                    const socket = self.createSocket();
                    handler(socket, self.upgrade_data, self.ws_allocator, self.io);
                }

                // Free the upgrade_data that was allocated with page_allocator during upgrade
                if (self.upgrade_data) |data| {
                    std.heap.page_allocator.free(data);
                }
            }

            /// Create a Socket interface for the current connection, backed by
            /// this handler via the unified `Http` vtable (only `ws*` slots).
            fn createSocket(self: *WebsocketHandler) zx.Socket {
                return .{ ._internal = .{
                    .http = .{ .userdata = @ptrCast(self), .vtable = &socket_vtable },
                    .attached = true,
                } };
            }

            const socket_vtable = blk: {
                var vt = zx.Http.failing_vtable;
                vt.wsWrite = &socketWrite;
                vt.wsClose = &socketClose;
                vt.wsSubscribe = &socketSubscribe;
                vt.wsUnsubscribe = &socketUnsubscribe;
                vt.wsPublish = &socketPublish;
                vt.wsIsSubscribed = &socketIsSubscribed;
                vt.wsSetPublishToSelf = &socketSetPublishToSelf;
                break :blk vt;
            };

            fn handlerOf(userdata: ?*anyopaque) *WebsocketHandler {
                return @ptrCast(@alignCast(userdata.?));
            }

            fn socketWrite(userdata: ?*anyopaque, data: []const u8) anyerror!void {
                try handlerOf(userdata).conn.write(data);
            }

            fn socketClose(userdata: ?*anyopaque) void {
                handlerOf(userdata).conn.close(.{ .code = 1000, .reason = "closed" }) catch {};
            }

            // Pub/Sub vtable implementations - use subscriber data stored on connection
            fn socketSubscribe(userdata: ?*anyopaque, topic: []const u8) void {
                handlerOf(userdata).subscriber.subscribe(topic);
            }

            fn socketUnsubscribe(userdata: ?*anyopaque, topic: []const u8) void {
                handlerOf(userdata).subscriber.unsubscribe(topic);
            }

            fn socketPublish(userdata: ?*anyopaque, topic: []const u8, message: []const u8) usize {
                const handler = handlerOf(userdata);
                return PubSub.publish(&handler.subscriber, topic, message);
            }

            fn socketIsSubscribed(userdata: ?*anyopaque, topic: []const u8) bool {
                return handlerOf(userdata).subscriber.isSubscribed(topic);
            }

            fn socketSetPublishToSelf(userdata: ?*anyopaque, value: bool) void {
                handlerOf(userdata).subscriber.publish_to_self = value;
            }
        };
    };
}
