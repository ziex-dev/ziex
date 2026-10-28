const std = @import("std");
const zx = @import("root.zig");
const app_opts = @import("app_opts");

const Allocator = std.mem.Allocator;
const Conn = zx.http.Conn;
const Router = zx.Router;

pub const Backend = enum {
    httpz,
    std,
    wasm,

    pub fn name(self: Backend) []const u8 {
        return @tagName(self);
    }

    pub fn isTcp(self: Backend) bool {
        return self != .wasm;
    }
};

var next_harness_port: std.atomic.Value(u16) = .init(19000);

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const FetchOptions = struct {
    method: zx.server.Request.Method = .GET,
    path: []const u8 = "/",
    headers: []const Header = &.{},
    body: []const u8 = "",
    stream: ?*std.Io.net.Stream = null,
};

pub const FetchResult = struct {
    status: u16,
    body: []const u8,
    raw: []const u8 = "",
    headers: []const Header = &.{},
    arena: Allocator,

    pub fn deinit(self: *FetchResult) void {
        _ = self;
    }

    pub fn header(self: FetchResult, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const Harness = struct {
    backend: Backend,
    io: std.Io,
    allocator: Allocator,
    tcp: ?Tcp = null,

    const Tcp = struct {
        kind: enum { httpz, std },
        httpz: ?*zx.App.Server.Httpz.Backend(void) = null,
        std: ?*zx.App.Server.Std.Backend(void) = null,
        transport: zx.App.Server,
        thread: std.Thread,
        port: u16,
    };

    pub const StartOptions = struct {
        workers: zx.AppConfig.ServerConfig.Worker = .{ .count = 1, .min_conn = 1, .max_conn = 8 },
        thread_pool: zx.AppConfig.ServerConfig.ThreadPool = .{ .count = 1 },
        timeout: zx.AppConfig.ServerConfig.Timeout = .{ .keepalive = 2 },
    };

    pub fn start(backend: Backend, io: std.Io, allocator: Allocator, opts: StartOptions) !Harness {
        var harness: Harness = .{
            .backend = backend,
            .io = io,
            .allocator = allocator,
        };
        if (!backend.isTcp()) return harness;

        if (backend == .httpz and !app_opts.enable_httpz) {
            return error.HttpzBackendDisabled;
        }

        const listen_port = next_harness_port.fetchAdd(1, .monotonic);
        const config: zx.AppConfig = .{
            .server = .{
                .port = listen_port,
                .address = "127.0.0.1",
                .workers = opts.workers,
                .thread_pool = opts.thread_pool,
                .timeout = opts.timeout,
            },
        };

        var tcp: Tcp = .{
            .kind = if (backend == .httpz) .httpz else .std,
            .transport = undefined,
            .thread = undefined,
            .port = listen_port,
        };

        const transport: zx.App.Server = switch (backend) {
            .httpz => blk: {
                const b = try zx.App.Server.Httpz.Backend(void).init(io, allocator, config, {}, {});
                tcp.httpz = b;
                break :blk b.server();
            },
            .std => blk: {
                const b = try zx.App.Server.Std.Backend(void).init(io, allocator, config, {}, {});
                tcp.std = b;
                break :blk b.server();
            },
            .wasm => unreachable,
        };
        tcp.transport = transport;

        tcp.thread = try std.Thread.spawn(.{}, struct {
            fn run(s: zx.App.Server) void {
                s.start() catch {};
            }
        }.run, .{transport});
        errdefer {
            transport.stop();
            tcp.thread.join();
            deinitTcp(&tcp, allocator);
        }

        try waitUntilListening(io, listen_port);
        harness.tcp = tcp;
        return harness;
    }

    pub fn stop(self: *Harness) void {
        if (self.tcp) |*tcp| {
            if (tcp.kind == .httpz) {
                self.io.sleep(.fromMilliseconds(50), .awake) catch {};
            }
            tcp.transport.stop();
            tcp.thread.join();
            deinitTcp(tcp, self.allocator);
            self.tcp = null;
        }
    }

    pub fn connect(self: *const Harness) !std.Io.net.Stream {
        const tcp = self.tcp orelse return error.NotATcpBackend;
        return connectPort(self.io, tcp.port);
    }

    pub fn fetch(self: *Harness, arena: Allocator, opts: FetchOptions) !FetchResult {
        return switch (self.backend) {
            .httpz, .std => self.fetchTcp(arena, opts),
            .wasm => fetchWasm(self.io, arena, opts),
        };
    }

    fn fetchTcp(self: *Harness, arena: Allocator, opts: FetchOptions) !FetchResult {
        const owned = opts.stream == null;
        var stream = if (opts.stream) |s| s.* else try self.connect();
        defer if (owned) stream.close(self.io);

        var req_buf: std.Io.Writer.Allocating = .init(arena);
        try writeRequest(&req_buf.writer, opts);
        var writer = stream.writer(self.io, &.{});
        try writer.interface.writeAll(req_buf.written());
        try writer.interface.flush();

        var raw_buf: std.Io.Writer.Allocating = .init(arena);
        var scratch: [4096]u8 = undefined;
        while (!httpResponseComplete(raw_buf.written())) {
            const n = try readChunk(stream, self.io, &scratch);
            if (n == 0) break;
            try raw_buf.writer.writeAll(scratch[0..n]);
        }

        return try parseHttpResponse(arena, raw_buf.written());
    }
};

fn deinitTcp(tcp: *Harness.Tcp, allocator: Allocator) void {
    if (tcp.httpz) |b| {
        b.deinit();
        tcp.httpz = null;
    }
    if (tcp.std) |b| {
        b.deinit();
        tcp.std = null;
    }
    _ = allocator;
}

fn writeRequest(w: *std.Io.Writer, opts: FetchOptions) !void {
    var connection: []const u8 = "close";
    var has_content_length = false;
    for (opts.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) connection = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) has_content_length = true;
    }
    try w.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: {s}\r\n", .{
        @tagName(opts.method),
        opts.path,
        connection,
    });
    for (opts.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (opts.body.len > 0 and !has_content_length) {
        try w.print("Content-Length: {d}\r\n", .{opts.body.len});
    }
    try w.writeAll("\r\n");
    if (opts.body.len > 0) try w.writeAll(opts.body);
}

fn parseHttpResponse(arena: Allocator, raw: []const u8) !FetchResult {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.IncompleteResponse;
    const head = raw[0..header_end];
    const body = raw[header_end + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.IncompleteResponse;
    var status_parts = std.mem.tokenizeAny(u8, status_line, " ");
    _ = status_parts.next(); // HTTP/1.x
    const status_str = status_parts.next() orelse return error.InvalidStatus;
    const status = try std.fmt.parseInt(u16, status_str, 10);

    var headers: std.ArrayList(Header) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        try headers.append(arena, .{
            .name = line[0..sep],
            .value = std.mem.trim(u8, line[sep + 1 ..], " \t"),
        });
    }

    return .{
        .status = status,
        .body = body,
        .raw = raw,
        .headers = try headers.toOwnedSlice(arena),
        .arena = arena,
    };
}

fn fetchWasm(io: std.Io, arena: Allocator, opts: FetchOptions) !FetchResult {
    var conn = Conn.init(arena);
    defer conn.deinit();

    const path_only, const search = splitPath(opts.path);
    conn.search = search;
    conn.body = opts.body;

    var header_entries: std.ArrayList(Conn.HeaderEntry) = .empty;
    for (opts.headers) |h| {
        try header_entries.append(arena, .{ .name = h.name, .value = h.value });
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) conn.content_type = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) conn.cookie_header = h.value;
    }
    if (opts.body.len > 0 and conn.content_type.len == 0) {
        conn.content_type = "text/plain";
    }
    conn.headers = try header_entries.toOwnedSlice(arena);
    conn.route_match = Router.matchRoute(path_only, .{ .match = .exact });

    const request = conn.request(opts.method, path_only, opts.path);
    const response = conn.response();
    const http = conn.http();

    const result = try Router.handle(.{ .is_dev = false }, .{
        .http = http,
        .request = request,
        .response = response,
        .pathname = path_only,
        .method = opts.method,
        .allocator = arena,
        .arena = arena,
        .io = io,
        .base_path = app_opts.app_base_path,
        .app_ctx = null,
        .socket = .{},
    });

    switch (result.outcome) {
        .response_ready => {},
        .component => |c| {
            var page = c.component;
            var aw: std.Io.Writer.Allocating = .init(arena);
            zx.App.Server.Handler.renderHtmlDocument(&aw.writer, &page, app_opts.app_base_path) catch {};
            conn.deferred_body = aw.written();
        },
        .not_found => |nf| {
            conn.status = 404;
            if (nf.component) |cmp| {
                var page = cmp;
                var aw: std.Io.Writer.Allocating = .init(arena);
                zx.App.Server.Handler.renderHtmlDocument(&aw.writer, &page, app_opts.app_base_path) catch {};
                conn.deferred_body = aw.written();
            } else {
                conn.deferred_body = "404 Not Found";
            }
        },
        .ws_upgraded => return error.UnexpectedWebsocketUpgrade,
    }

    var out_headers: std.ArrayList(Header) = .empty;
    for (conn.resp_headers.items) |h| {
        try out_headers.append(arena, .{ .name = h.name, .value = h.value });
    }

    return .{
        .status = conn.status,
        .body = conn.bodySlice(),
        .headers = try out_headers.toOwnedSlice(arena),
        .arena = arena,
    };
}

fn splitPath(path: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, path, '?')) |q| {
        return .{ path[0..q], path[q..] };
    }
    return .{ path, "" };
}

pub fn connectPort(io: std.Io, port: u16) !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    return try address.connect(io, .{ .mode = .stream });
}

fn readChunk(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !usize {
    var data: [1][]u8 = .{buf};
    const result = stream.readWithControl(io, &data, &.{}) catch |err| switch (err) {
        error.ConnectionResetByPeer => return 0,
        else => return err,
    };
    return result.data_len;
}

fn httpResponseComplete(raw: []const u8) bool {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
    const head = raw[0..header_end];
    const body = raw[header_end + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "content-length:")) continue;
        const v = std.mem.trim(u8, line["content-length:".len..], " \t");
        const n = std.fmt.parseInt(usize, v, 10) catch return false;
        return body.len >= n;
    }
    return true;
}

fn waitUntilListening(io: std.Io, port: u16) !void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (connectPort(io, port)) |stream| {
            stream.close(io);
            return;
        } else |_| {
            try io.sleep(.fromMilliseconds(5), .awake);
        }
    }
    return error.ServerDidNotStart;
}
