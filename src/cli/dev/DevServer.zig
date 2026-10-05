/// DevServer - a lightweight proxy that owns the user-facing port so it never, this is based on WebServer.zig reom Zig std
/// drops during app binary restarts, and provides a stable WebSocket endpoint
/// for hot-reload signals and error overlays.
///
/// Architecture:
///   Browser ──HTTP──► DevServer (outer_port, stays alive)
///                         ├─ /.well-known/_zx/devsocket|devscript|open-in-editor|app → served here
///                         ├─ /.well-known/_zx/devtool → rewrite + proxy with x-zx-devtool header
///                         └─ everything else    → proxy → app binary (inner_port)
///
/// WebSocket messages sent to browsers are JSON-serialized `Notification`
/// values. `dev.zig` decides which notification to send; DevServer just
/// serializes, queues, and broadcasts them.
const std = @import("std");
const builtin = @import("builtin");

const Manifest = @import("../../build/Manifest.zig");
const CliConstant = @import("../shared/constant.zig");
const con = @import("../../util/conn.zig");

const http = std.http;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.devserver);

/// Minimal HTML shell served when the inner app is not running (e.g. initial
/// build errors). It includes the devscript so the browser can connect to the
/// DevServer WebSocket and display the error overlay immediately.
const ERROR_SHELL_HTML = @embedFile("errorshell.html");
const DEVSCRIPT_JS = @embedFile("devscript.js");

const DevServer = @This();

pub const Notification = struct {
    type: Type,
    message: ?[]const u8 = null,
    diagnostics: ?[]const Diagnostic = null,
    files: ?[]const []const u8 = null,

    pub const Type = enum {
        connected,
        reload,
        @"error",
        clear,
        building,
        asset_update,
    };

    pub const Kind = enum {
        @"error",
        warning,
        note,
    };

    pub const Diagnostic = struct {
        file: []const u8,
        line: u32,
        col: u32,
        kind: Kind,
        message: []const u8,
        source: ?[]const u8 = null,
        source_html: ?[]const u8 = null,
    };

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, writer);
    }
};

const QueuedEvent = struct {
    json: []u8,
};

const EVENT_QUEUE_CAP = 16;

io: std.Io,
gpa: Allocator,
env_map: *const std.process.Environ.Map,
address: std.Io.net.IpAddress,
inner_port: u16,
install_prefix: []const u8,
transpile_dir: []const u8,
tcp_server: ?std.Io.net.Server,
serve_thread: ?std.Thread,

/// Incremented on each event. WebSocket threads block on this with Futex.
update_id: std.atomic.Value(u32),
shutting_down: std.atomic.Value(bool),
active_workers: std.atomic.Value(u32),
live_connections: con,

/// Bounded event queue so rapid transitions (building → reload) don't drop events.
event_mutex: std.Io.Mutex,
event_queue: [EVENT_QUEUE_CAP]QueuedEvent = undefined,
event_head: u32 = 0, // next write position
event_tail: u32 = 0, // next read position
sticky_state_json: ?[]u8 = null,

pub const Options = struct {
    io: std.Io,
    gpa: Allocator,
    env_map: *const std.process.Environ.Map,
    /// Address to bind the user-facing proxy to.
    address: std.Io.net.IpAddress,
    /// Port the app binary will listen on.
    inner_port: u16,
    install_prefix: []const u8 = "",
    transpile_dir: []const u8 = CliConstant.default_transpile_dir,
};

pub fn init(opts: Options) DevServer {
    log.debug("devserver init port: {d}", .{opts.address.getPort()});
    return .{
        .gpa = opts.gpa,
        .env_map = opts.env_map,
        .address = opts.address,
        .inner_port = opts.inner_port,
        .install_prefix = opts.install_prefix,
        .transpile_dir = opts.transpile_dir,
        .tcp_server = null,
        .serve_thread = null,
        .update_id = .init(0),
        .shutting_down = .init(false),
        .active_workers = .init(0),
        .live_connections = .{},
        .event_mutex = .init,
        .io = opts.io,
    };
}

pub fn deinit(ds: *DevServer) void {
    ds.shutting_down.store(true, .release);
    ds.update_id.store(std.math.maxInt(u32), .release);
    ds.io.futexWake(u32, &ds.update_id.raw, std.math.maxInt(u32));

    ds.live_connections.shutdownAll(ds.io);
    if (ds.serve_thread) |t| {
        if (ds.tcp_server) |*s| {
            const listener: std.Io.net.Stream = .{ .socket = s.socket };
            listener.shutdown(ds.io, .both) catch {
                wakeLocalhostPort(ds.io, s.socket.address.getPort());
            };
        }
        t.join();
    }
    if (ds.tcp_server) |*s| {
        s.deinit(ds.io);
        ds.tcp_server = null;
    }

    var spins: u32 = 0;
    while (ds.active_workers.load(.acquire) != 0 and spins < 2000) : (spins += 1) {
        std.Io.sleep(ds.io, .fromMilliseconds(1), .awake) catch {};
    }
    // Drain any remaining queued events
    while (ds.event_tail != ds.event_head) {
        const idx = ds.event_tail % EVENT_QUEUE_CAP;
        ds.gpa.free(ds.event_queue[idx].json);
        ds.event_tail +%= 1;
    }
    if (ds.sticky_state_json) |json| {
        ds.gpa.free(json);
    }
}

/// Max times to try the next port when the preferred one is busy.
pub const max_port_retries: u8 = 50;
/// Give a previous dev process a moment to release the preferred port.
const preferred_port_grace_ms: u16 = 500;
const preferred_port_retry_ms: u16 = 10;

fn isPortAccepting(io: std.Io, port: u16) bool {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    if (addr.connect(io, .{ .mode = .stream })) |s| {
        s.close(io);
        return true;
    } else |_| return false;
}

fn wakeLocalhostPort(io: std.Io, port: u16) void {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    if (addr.connect(io, .{ .mode = .stream })) |s| {
        s.close(io);
    } else |_| {}
}

fn retryPreferredPort(io: std.Io, port: u16, preferred: u16, waited_ms: *u16) bool {
    if (port != preferred or waited_ms.* >= preferred_port_grace_ms) return false;
    std.Io.sleep(io, .fromMilliseconds(preferred_port_retry_ms), .awake) catch {};
    waited_ms.* += preferred_port_retry_ms;
    return true;
}

fn advancePort(port: u16, preferred: u16, attempts: *u8) error{AlreadyReported}!u16 {
    if (attempts.* >= max_port_retries) {
        log.err("failed to find an available port after {d} retries (started at {d})", .{ max_port_retries, preferred });
        std.debug.print("Port {d} is in use\n", .{preferred});
        if (comptime builtin.os.tag == .windows) {
            std.debug.print("To free it, run:\n  netstat -ano | findstr :{d}\n\n", .{preferred});
        } else {
            std.debug.print("To free it, run:\n  kill -9 $(lsof -t -i:{d})\n\n", .{preferred});
        }
        return error.AlreadyReported;
    }
    const next = port +% 1;
    if (next == 0) {
        log.err("port overflow while searching for a free port", .{});
        return error.AlreadyReported;
    }
    log.debug("port {d} in use, trying {d}", .{ port, next });
    attempts.* += 1;
    return next;
}

pub fn start(ds: *DevServer) error{AlreadyReported}!void {
    assert(ds.tcp_server == null);
    assert(ds.serve_thread == null);

    log.debug("devserver start", .{});

    const preferred = ds.address.getPort();
    var port = preferred;
    var attempts: u8 = 0;
    var preferred_waited_ms: u16 = 0;

    while (true) {
        ds.address.setPort(port);

        if (isPortAccepting(ds.io, port)) {
            if (retryPreferredPort(ds.io, port, preferred, &preferred_waited_ms)) continue;
            port = try advancePort(port, preferred, &attempts);
            continue;
        }

        ds.tcp_server = ds.address.listen(ds.io, .{ .reuse_address = true }) catch |err| {
            switch (err) {
                error.AddressInUse => {
                    if (retryPreferredPort(ds.io, port, preferred, &preferred_waited_ms)) continue;
                    port = try advancePort(port, preferred, &attempts);
                    continue;
                },
                else => {
                    log.err("failed to listen on {f}: {s}", .{ ds.address, @errorName(err) });
                    return error.AlreadyReported;
                },
            }
        };
        break;
    }

    if (port != preferred) {
        std.debug.print("Port {d} is in use, using {d}\n", .{ preferred, port });
    }

    ds.serve_thread = std.Thread.spawn(.{}, serve, .{ds}) catch |err| {
        log.err("unable to spawn dev server thread: {s}", .{@errorName(err)});
        ds.tcp_server.?.deinit(ds.io);
        ds.tcp_server = null;
        return error.AlreadyReported;
    };
}

/// Resolve the preferred user-facing port: CLI `--port`/`-p`, else `PORT` env, else `default`.
pub fn resolvePreferredPort(cli_port: u32, env_map: *const std.process.Environ.Map, default: u16) u16 {
    if (cli_port != 0) return @intCast(cli_port);
    if (env_map.get("PORT")) |s| {
        return std.fmt.parseInt(u16, s, 10) catch default;
    }
    return default;
}

/// Push a serialized notification onto the queue and wake WS threads.
/// Takes its own owned copy of `json`; the caller keeps ownership of the
/// passed-in slice. Thread-safe.
fn pushEvent(ds: *DevServer, json: []const u8) void {
    const owned = ds.gpa.dupe(u8, json) catch return;
    const io = ds.io;
    ds.event_mutex.lockUncancelable(io);
    const idx = ds.event_head % EVENT_QUEUE_CAP;
    // If queue is full, drop oldest event
    if (ds.event_head -% ds.event_tail >= EVENT_QUEUE_CAP) {
        const old_idx = ds.event_tail % EVENT_QUEUE_CAP;
        ds.gpa.free(ds.event_queue[old_idx].json);
        ds.event_tail +%= 1;
    }
    ds.event_queue[idx] = .{ .json = owned };
    ds.event_head +%= 1;
    ds.event_mutex.unlock(io);
    _ = ds.update_id.rmw(.Add, 1, .release);
    io.futexWake(u32, &ds.update_id.raw, std.math.maxInt(u32));
}

pub fn notify(ds: *DevServer, notification: Notification) void {
    const json = std.fmt.allocPrint(ds.gpa, "{f}", .{notification}) catch return;
    defer ds.gpa.free(json);

    ds.updateStickyState(notification, json);
    ds.pushEvent(json);
}

fn updateStickyState(ds: *DevServer, notification: Notification, json: []const u8) void {
    const io = ds.io;
    ds.event_mutex.lockUncancelable(io);
    defer ds.event_mutex.unlock(io);

    switch (notification.type) {
        .building, .@"error" => {
            const duplicated = ds.gpa.dupe(u8, json) catch return;
            if (ds.sticky_state_json) |prev| ds.gpa.free(prev);
            ds.sticky_state_json = duplicated;
        },
        .clear, .reload, .connected, .asset_update => {
            if (ds.sticky_state_json) |prev| {
                ds.gpa.free(prev);
                ds.sticky_state_json = null;
            }
        },
    }
}

/// Find a free OS-assigned port by briefly binding to port 0.
pub fn findFreePort(io: std.Io) !u16 {
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

pub fn waitUntilInnerReady(ds: *DevServer, timeout_ms: u64) bool {
    const inner_addr = std.Io.net.IpAddress.parse("127.0.0.1", ds.inner_port) catch return false;
    const begin = std.Io.Timestamp.now(ds.io, .awake);
    while (true) {
        if (inner_addr.connect(ds.io, .{ .mode = .stream })) |s| {
            s.close(ds.io);
            return true;
        } else |_| {}
        const elapsed: u64 = @intCast(begin.durationTo(std.Io.Timestamp.now(ds.io, .awake)).toMilliseconds());
        if (elapsed >= timeout_ms) return false;
        std.Io.sleep(ds.io, .fromMilliseconds(5), .awake) catch {};
    }
}

fn serve(ds: *DevServer) void {
    var retry_count: u8 = 0;

    while (true) {
        if (ds.shutting_down.load(.acquire)) return;
        const server = if (ds.tcp_server) |*s| s else return;
        const connection = server.accept(ds.io) catch |err| {
            if (ds.shutting_down.load(.acquire)) return;
            switch (err) {
                error.Canceled, error.Unexpected => {
                    retry_count += 1;
                    if (retry_count > 5) {
                        log.err("accept() failed {d} times, giving up: {s}", .{ retry_count - 1, @errorName(err) });
                        return;
                    }
                    log.warn("accept() failed (transient): {s}", .{@errorName(err)});
                    std.Io.sleep(ds.io, .fromMilliseconds(50), .awake) catch {};
                    continue;
                },
                else => {
                    log.err("failed to accept connection: {s}", .{@errorName(err)});
                    return;
                },
            }
        };
        retry_count = 0;
        if (ds.shutting_down.load(.acquire)) {
            connection.close(ds.io);
            return;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ ds, connection }) catch |err| {
            log.err("unable to spawn connection thread: {s}", .{@errorName(err)});
            connection.close(ds.io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(ds: *DevServer, stream: std.Io.net.Stream) void {
    _ = ds.active_workers.rmw(.Add, 1, .acq_rel);
    defer _ = ds.active_workers.rmw(.Sub, 1, .acq_rel);
    const live_token = ds.live_connections.track(stream) orelse {
        stream.close(ds.io);
        return;
    };
    defer {
        ds.live_connections.untrack(live_token);
        stream.close(ds.io);
    }
    if (ds.shutting_down.load(.acquire)) return;

    // Connection accepted
    log.debug("connection accepted", .{});

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(ds.io, &recv_buffer);
    var connection_writer = stream.writer(ds.io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return log.debug("failed to receive http request: {s}", .{@errorName(err)}),
        };

        switch (request.upgradeRequested()) {
            .websocket => |opt_key| {
                var ws_target_split = std.mem.splitScalar(u8, request.head.target, '?');
                const ws_target_path = ws_target_split.first();
                if (!std.mem.eql(u8, ws_target_path, "/.well-known/_zx/devsocket")) {
                    log.debug("proxying websocket upgrade to inner: {s}", .{request.head.target});
                    const buffered_extra = request.server.reader.in.buffer[request.server.reader.in.seek..request.server.reader.in.end];
                    proxyWebSocket(ds, stream, request.head_buffer, buffered_extra) catch |err| {
                        log.debug("websocket proxy failed: {s}", .{@errorName(err)});
                    };
                    return;
                }

                const key = opt_key orelse return log.err("missing websocket key", .{});
                var web_socket = request.respondWebSocket(.{ .key = key }) catch {
                    return log.err("failed to respond web socket", .{});
                };
                serveWebSocket(ds, &web_socket, stream) catch |err| {
                    log.debug("failed to serve websocket: {s}", .{@errorName(err)});
                    return;
                };
                return;
            },
            .other => |name| return log.err("unknown upgrade request: {s}", .{name}),
            .none => {
                ds.serveRequest(&request, stream) catch |err| switch (err) {
                    error.AlreadyReported => return,
                    else => {
                        log.err("failed to serve '{s}': {s}", .{ request.head.target, @errorName(err) });
                        return;
                    },
                };
            },
        }
    }
}

const cors_headers = [_]http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, x-zx-devtool, x-zx-devtool-include-native, x-zx-devtool-include-props, x-zx-devtool-include-attributes" },
    .{ .name = "Access-Control-Allow-Private-Network", .value = "true" },
};

fn serveRequest(ds: *DevServer, req: *http.Server.Request, client_stream: std.Io.net.Stream) !void {
    const target = req.head.target;
    var target_split = std.mem.splitScalar(u8, target, '?');
    const target_path = target_split.first();
    const target_query = target_split.rest();

    // 1. Intercept system requests (dev server only)
    if (std.mem.startsWith(u8, target_path, "/.well-known/_zx/")) {
        if (std.mem.eql(u8, target_path, "/.well-known/_zx/devscript.js")) {
            log.debug("devscript matched: {s}", .{target});
            try req.respond(DEVSCRIPT_JS, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/javascript" },
                    .{ .name = "Cache-Control", .value = "no-cache" },
                    .{ .name = "Connection", .value = "close" },
                },
            });
            return;
        }

        if (std.mem.eql(u8, target_path, "/.well-known/_zx/open-in-editor")) {
            log.debug("open-in-editor matched: {s}", .{target});
            if (req.head.method == .OPTIONS) {
                try req.respond("", .{
                    .status = .ok,
                    .extra_headers = &(cors_headers ++ [_]http.Header{
                        .{ .name = "Connection", .value = "close" },
                    }),
                });
                return;
            }
            handleOpenInEditor(ds, target) catch |err| {
                log.debug("handleOpenInEditor failed: {s}", .{@errorName(err)});
            };
            try req.respond("", .{
                .extra_headers = &(cors_headers ++ [_]http.Header{
                    .{ .name = "Connection", .value = "close" },
                }),
            });
            return;
        }

        if (std.mem.eql(u8, target_path, "/.well-known/_zx/app")) {
            if (req.head.method == .OPTIONS) {
                try req.respond("", .{
                    .status = .ok,
                    .extra_headers = &(cors_headers ++ [_]http.Header{
                        .{ .name = "Connection", .value = "close" },
                    }),
                });
                return;
            }
            const body = try buildAppInfoJson(ds);
            defer ds.gpa.free(body);
            try req.respond(body, .{
                .extra_headers = &(cors_headers ++ [_]http.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Cache-Control", .value = "no-cache, no-store" },
                    .{ .name = "Connection", .value = "close" },
                }),
            });
            return;
        }

        // Devtool: rewrite to the inspected app path and ask the app for JSON via header.
        if (std.mem.eql(u8, target_path, "/.well-known/_zx/devtool")) {
            if (req.head.method == .OPTIONS) {
                try req.respond("", .{
                    .status = .ok,
                    .extra_headers = &(cors_headers ++ [_]http.Header{
                        .{ .name = "Connection", .value = "close" },
                    }),
                });
                return;
            }

            const buffered_extra = req.server.reader.in.buffer[req.server.reader.in.seek..req.server.reader.in.end];
            const rewrite = try buildDevtoolProxyRewrite(ds.gpa, target_query);
            defer ds.gpa.free(rewrite.rewrite_target);
            defer ds.gpa.free(rewrite.extra_headers);

            log.debug("devtool proxy → {s} ({s})", .{ rewrite.rewrite_target, rewrite.mode });
            proxyToInner(ds, client_stream, req.head_buffer, buffered_extra, .{
                .rewrite_target = rewrite.rewrite_target,
                .extra_headers = rewrite.extra_headers,
            }) catch |err| {
                log.debug("devtool proxy failed ({s})", .{@errorName(err)});
                try req.respond("{\"error\":\"app unavailable\"}", .{
                    .status = .bad_gateway,
                    .extra_headers = &(cors_headers ++ [_]http.Header{
                        .{ .name = "Content-Type", .value = "application/json" },
                        .{ .name = "Connection", .value = "close" },
                    }),
                });
                return error.AlreadyReported;
            };
            return error.AlreadyReported;
        }
    }

    // 2. Everything else goes to the inner app
    log.debug("proxyToInner: {s}", .{target});
    const buffered_extra = req.server.reader.in.buffer[req.server.reader.in.seek..req.server.reader.in.end];

    // For app proxying, we currently only proxy ONE request per connection.
    // This is because proxyToInner pipes raw streams.
    proxyToInner(ds, client_stream, req.head_buffer, buffered_extra, .{}) catch |err| {
        // If the inner app isn't running (build errors, first startup, etc.),
        // serve a minimal HTML shell with the devscript embedded so the
        // browser can connect to the WebSocket and display error overlays.
        log.debug("proxyToInner failed ({s}), serving error shell", .{@errorName(err)});
        try req.respond(ERROR_SHELL_HTML, .{
            .status = .service_unavailable,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Cache-Control", .value = "no-cache, no-store" },
                .{ .name = "Connection", .value = "close" },
            },
        });
        return error.AlreadyReported;
    };

    // After proxyToInner returns, the connection is typically exhausted.
    return error.AlreadyReported;
}

const DevtoolProxyRewrite = struct {
    mode: []const u8,
    rewrite_target: []u8,
    extra_headers: []http.Header,
};

fn buildDevtoolProxyRewrite(allocator: Allocator, query: []const u8) !DevtoolProxyRewrite {
    if (queryParam(query, "info") != null) {
        const headers = try allocator.dupe(http.Header, &.{
            .{ .name = "x-zx-devtool", .value = "info" },
        });
        return .{
            .mode = "info",
            .rewrite_target = try allocator.dupe(u8, "/"),
            .extra_headers = headers,
        };
    }

    const is_meta = queryParam(query, "meta") != null;
    if (is_meta) {
        const headers = try allocator.dupe(http.Header, &.{
            .{ .name = "x-zx-devtool", .value = "meta" },
        });
        return .{
            .mode = "meta",
            .rewrite_target = try allocator.dupe(u8, "/"),
            .extra_headers = headers,
        };
    }

    const path = queryParam(query, "path") orelse "/";
    const include_native = queryParam(query, "include_native") orelse "1";
    const include_props = queryParam(query, "include_props") orelse "1";
    const include_attributes = queryParam(query, "include_attributes") orelse "1";
    const headers = try allocator.alloc(http.Header, 4);
    headers[0] = .{ .name = "x-zx-devtool", .value = "components" };
    headers[1] = .{ .name = "x-zx-devtool-include-native", .value = include_native };
    headers[2] = .{ .name = "x-zx-devtool-include-props", .value = include_props };
    headers[3] = .{ .name = "x-zx-devtool-include-attributes", .value = include_attributes };
    return .{
        .mode = "components",
        .rewrite_target = try allocator.dupe(u8, path),
        .extra_headers = headers,
    };
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const k = kv.first();
        if (std.mem.eql(u8, k, key)) {
            const v = kv.rest();
            return if (v.len == 0) "" else v;
        }
    }
    return null;
}

fn buildAppInfoJson(ds: *DevServer) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(ds.gpa);
    errdefer aw.deinit();

    var exe_path_owned: ?[]const u8 = null;
    defer if (exe_path_owned) |p| ds.gpa.free(p);
    var route_count: usize = 0;
    var injection_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (injection_ids.items) |id| ds.gpa.free(id);
        injection_ids.deinit(ds.gpa);
    }

    if (ds.install_prefix.len > 0) {
        const manifest_path = try std.fs.path.join(ds.gpa, &.{ ds.install_prefix, "manifest", "app.zon" });
        defer ds.gpa.free(manifest_path);
        if (std.Io.Dir.cwd().readFileAlloc(ds.io, manifest_path, ds.gpa, .unlimited)) |source| {
            defer ds.gpa.free(source);
            if (source.len > 0) {
                const source_z = try ds.gpa.dupeSentinel(u8, source, 0);
                defer ds.gpa.free(source_z);
                var arena = std.heap.ArenaAllocator.init(ds.gpa);
                defer arena.deinit();
                var diagnostics: std.zon.parse.Diagnostics = undefined;
                if (std.zon.parse.fromSlice(Manifest.App, .{
                    .gpa = ds.gpa,
                    .arena = arena.allocator(),
                    .source = source_z,
                    .diagnostics = &diagnostics,
                    .ignore_unknown_fields = true,
                })) |manifest| {
                    if (manifest.exe_path) |p| {
                        exe_path_owned = try ds.gpa.dupe(u8, p);
                    }
                    route_count = manifest.routes.len;
                    for (manifest.injections) |inj| {
                        if (inj.id) |id| try injection_ids.append(ds.gpa, try ds.gpa.dupe(u8, id));
                    }
                } else |_| {}
            }
        } else |_| {}
    }

    const Payload = struct {
        outer_port: u16,
        inner_port: u16,
        install_prefix: []const u8,
        exe_path: ?[]const u8,
        route_count: usize,
        injection_count: usize,
        injections: []const []const u8,
    };

    try std.json.Stringify.value(Payload{
        .outer_port = ds.address.getPort(),
        .inner_port = ds.inner_port,
        .install_prefix = ds.install_prefix,
        .exe_path = exe_path_owned,
        .route_count = route_count,
        .injection_count = injection_ids.items.len,
        .injections = injection_ids.items,
    }, .{ .emit_null_optional_fields = true }, &aw.writer);

    return try aw.toOwnedSlice();
}

const ProxyOptions = struct {
    rewrite_target: ?[]const u8 = null,
    extra_headers: []const http.Header = &.{},
};

fn serveWebSocket(ds: *DevServer, sock: *http.Server.WebSocket, stream: std.Io.net.Stream) !noreturn {
    // Send initial connected message (also flushes the 101 handshake response).
    log.debug("ws: sending connected message", .{});
    const connected = try std.fmt.allocPrint(ds.gpa, "{f}", .{Notification{ .type = .connected }});
    defer ds.gpa.free(connected);

    sock.writeMessage(connected, .text) catch |err| {
        log.err("ws: failed to send connected message: {s}", .{@errorName(err)});
        return err;
    };
    log.debug("ws: connected message sent", .{});

    // Drain incoming frames on a dedicated thread - mirrors WebServer.zig's
    // recvWebSocketMessages pattern. Without this, the connection stalls because
    // unread frames (pings, close frames, etc.) block the underlying TCP stream.
    const recv_thread = std.Thread.spawn(.{}, recvWebSocketFrames, .{sock}) catch |err| {
        log.err("ws: failed to spawn recv thread: {s}", .{@errorName(err)});
        return err;
    };
    defer recv_thread.join();
    defer stream.shutdown(ds.io, .recv) catch {};
    log.debug("ws: recv thread spawned, entering event loop", .{});

    const io = ds.io;
    var sticky_snapshot: ?[]u8 = null;
    var last_id: u32 = 0;
    ds.event_mutex.lockUncancelable(io);
    last_id = ds.event_head;
    if (ds.sticky_state_json) |json| {
        sticky_snapshot = ds.gpa.dupe(u8, json) catch null;
    }
    ds.event_mutex.unlock(io);

    if (sticky_snapshot) |json| {
        defer ds.gpa.free(json);
        try sock.writeMessage(json, .text);
    }

    while (true) {
        if (ds.shutting_down.load(.acquire)) return error.ShuttingDown;
        const cur = ds.update_id.load(.acquire);
        if (cur == last_id) {
            // No pending event - wait up to 30 s then ping to keep the connection alive.
            io.futexWaitTimeout(u32, &ds.update_id.raw, last_id, .{ .duration = .{ .raw = .{ .nanoseconds = 30 * std.time.ns_per_s }, .clock = .awake } }) catch {
                try sock.writeMessage("", .ping);
                continue;
            };
            continue;
        }

        // Read the current event under the lock, then release before I/O.
        ds.event_mutex.lockUncancelable(io);
        const head = ds.event_head;
        if (head == last_id) {
            ds.event_mutex.unlock(io);
            continue;
        }
        if (head -% last_id > EVENT_QUEUE_CAP) {
            last_id = head - EVENT_QUEUE_CAP;
        }
        const event_index = last_id % EVENT_QUEUE_CAP;
        const json_copy = ds.gpa.dupe(u8, ds.event_queue[event_index].json) catch {
            ds.event_mutex.unlock(io);
            last_id +%= 1;
            continue;
        };
        ds.event_mutex.unlock(io);

        last_id +%= 1;

        defer ds.gpa.free(json_copy);
        try sock.writeMessage(json_copy, .text);
    }
}

/// Continuously reads and discards incoming WebSocket frames so the TCP receive
/// buffer never fills up and control frames (pings, close) are consumed.
fn recvWebSocketFrames(sock: *http.Server.WebSocket) void {
    log.debug("ws: recv thread started", .{});
    while (true) {
        const msg = sock.readSmallMessage() catch |err| {
            log.debug("ws: recv thread exiting: {s}", .{@errorName(err)});
            return;
        };
        log.debug("ws: received frame opcode={s} len={d}", .{ @tagName(msg.opcode), msg.data.len });
    }
}

/// Proxy a request to the inner app binary.
/// `head_buffer`     - raw HTTP request head (including terminating \r\n\r\n).
/// `buffered_extra`  - body bytes already consumed by the http.Server reader.
fn proxyToInner(
    ds: *DevServer,
    client: std.Io.net.Stream,
    head_buffer: []const u8,
    buffered_extra: []const u8,
    opts: ProxyOptions,
) !void {
    const inner_addr = try std.Io.net.IpAddress.parse("127.0.0.1", ds.inner_port);

    // Retry while the inner server is (re)starting - up to 2 s.
    const inner: std.Io.net.Stream = for (0..200) |_| {
        if (inner_addr.connect(ds.io, .{ .mode = .stream })) |s| break s else |_| std.Io.sleep(ds.io, .fromMicroseconds(10), .real) catch {};
    } else return error.ConnectionRefused;
    defer inner.close(ds.io);
    // We MUST force the inner server to close the connection, otherwise the browser
    // will try to reuse this connection (which we are currently piping raw)
    // for subsequent requests that might need to be intercepted by the DevServer.

    // Find the end of headers
    const end_idx = std.mem.indexOf(u8, head_buffer, "\r\n\r\n") orelse head_buffer.len;
    var header_part = head_buffer[0..end_idx];

    var rewritten_owned: ?[]u8 = null;
    defer if (rewritten_owned) |buf| ds.gpa.free(buf);
    if (opts.rewrite_target) |new_target| {
        rewritten_owned = try rewriteRequestTarget(ds.gpa, header_part, new_target);
        header_part = rewritten_owned.?;
    }

    var transformed = std.ArrayList(u8).empty;
    defer transformed.deinit(ds.gpa);

    const keep_alive = "keep-alive";
    const close = "close";

    if (std.mem.indexOf(u8, header_part, keep_alive) != null) {
        const count = std.mem.count(u8, header_part, keep_alive);
        const new_len = header_part.len - (count * (keep_alive.len - close.len));
        try transformed.resize(ds.gpa, new_len);
        _ = std.mem.replace(u8, header_part, keep_alive, close, transformed.items);
    } else if (std.mem.indexOf(u8, header_part, "Connection:") == null) {
        try transformed.appendSlice(ds.gpa, header_part);
        try transformed.appendSlice(ds.gpa, "\r\nConnection: close");
    } else {
        try transformed.appendSlice(ds.gpa, header_part);
    }

    for (opts.extra_headers) |h| {
        const line = try std.fmt.allocPrint(ds.gpa, "\r\n{s}: {s}", .{ h.name, h.value });
        defer ds.gpa.free(line);
        try transformed.appendSlice(ds.gpa, line);
    }
    try transformed.appendSlice(ds.gpa, "\r\n\r\n");

    var inner_writer_buf: [4096]u8 = undefined;
    var inner_writer = inner.writer(ds.io, &inner_writer_buf);
    try inner_writer.interface.writeAll(transformed.items);

    // Forward any body bytes already buffered by the http.Server reader.
    if (buffered_extra.len > 0) try inner_writer.interface.writeAll(buffered_extra);
    try inner_writer.interface.flush();

    // Windows can report ERROR_INVALID_PARAMETER from ReadFile when combining
    // this shutdown-based bidirectional copy pattern with sockets. Use a
    // simpler one-way response copy there.
    if (builtin.os.tag == .windows) {
        copyStream(ds.io, inner, client);
        return;
    }

    // Bidirectional pipe: remaining request body client→inner, response inner→client.
    // The inner→client thread shuts down the client write side when inner closes,
    // which unblocks the client→inner copy loop below.
    const fwd = std.Thread.spawn(.{}, copyStreamThenShutdown, .{ ds.io, inner, client }) catch return;
    defer fwd.join();

    copyStream(ds.io, client, inner);

    // Unblock the inner→client thread if client closed first.
    inner.shutdown(ds.io, .recv) catch {};
}

fn rewriteRequestTarget(allocator: Allocator, header_part: []const u8, new_target: []const u8) ![]u8 {
    const line_end = std.mem.indexOf(u8, header_part, "\r\n") orelse return error.InvalidRequest;
    const first_line = header_part[0..line_end];
    const rest = header_part[line_end..];

    const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return error.InvalidRequest;
    const after_method = first_line[method_end + 1 ..];
    const target_end = std.mem.indexOfScalar(u8, after_method, ' ') orelse return error.InvalidRequest;
    const version = after_method[target_end + 1 ..];

    return std.fmt.allocPrint(allocator, "{s} {s} {s}{s}", .{
        first_line[0..method_end],
        new_target,
        version,
        rest,
    });
}

fn proxyWebSocket(
    ds: *DevServer,
    client: std.Io.net.Stream,
    head_buffer: []const u8,
    buffered_extra: []const u8,
) !void {
    const inner_addr = try std.Io.net.IpAddress.parse("127.0.0.1", ds.inner_port);

    // Retry while the inner server is (re)starting - up to 2 s.
    const inner: std.Io.net.Stream = for (0..200) |_| {
        if (inner_addr.connect(ds.io, .{ .mode = .stream })) |s| break s else |_| std.Io.sleep(ds.io, .fromMicroseconds(10), .real) catch {};
    } else return error.ConnectionRefused;
    defer inner.close(ds.io);

    var inner_writer_buf: [4096]u8 = undefined;
    var inner_writer = inner.writer(ds.io, &inner_writer_buf);
    try inner_writer.interface.writeAll(head_buffer);
    if (buffered_extra.len > 0) try inner_writer.interface.writeAll(buffered_extra);
    try inner_writer.interface.flush();

    const fwd = std.Thread.spawn(.{}, copyStreamThenShutdown, .{ ds.io, inner, client }) catch return;
    defer fwd.join();

    copyStream(ds.io, client, inner);
    inner.shutdown(ds.io, .recv) catch {};
}

/// Copy src→dst, then shut down the dst send side so the peer's read unblocks.
fn copyStreamThenShutdown(io: std.Io, src: std.Io.net.Stream, dst: std.Io.net.Stream) void {
    copyStream(io, src, dst);
    dst.shutdown(io, .send) catch {};
}

fn copyStream(io: std.Io, src: std.Io.net.Stream, dst: std.Io.net.Stream) void {
    var read_buf: [65536]u8 = undefined;
    var reader_state: [1024]u8 = undefined;
    var writer_state: [1024]u8 = undefined;
    var reader = src.reader(io, &reader_state);
    var writer = dst.writer(io, &writer_state);

    while (true) {
        var data: [1][]u8 = .{&read_buf};
        const n = reader.interface.readVec(&data) catch return;
        if (n == 0) return;
        writer.interface.writeAll(read_buf[0..n]) catch return;
        writer.interface.flush() catch return;
    }
}

// Diagnostics integration
fn handleOpenInEditor(ds: *DevServer, target: []const u8) !void {
    const query_pos = std.mem.indexOf(u8, target, "?") orelse return;
    const query = target[query_pos + 1 ..];

    var it = std.mem.splitScalar(u8, query, '&');
    var file: ?[]const u8 = null;
    var line: ?[]const u8 = null;
    var col: ?[]const u8 = null;

    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "file=")) {
            file = pair[5..];
        } else if (std.mem.startsWith(u8, pair, "line=")) {
            line = pair[5..];
        } else if (std.mem.startsWith(u8, pair, "col=")) {
            col = pair[4..];
        }
    }

    if (file) |f_enc| {
        const decoded_file = try urlDecode(ds.gpa, f_enc);
        defer ds.gpa.free(decoded_file);

        const l_str = line orelse "1";
        const c_str = col orelse "1";
        const l_num = std.fmt.parseInt(u32, l_str, 10) catch 1;
        const c_num = std.fmt.parseInt(u32, c_str, 10) catch 1;

        // Remap generated .zig (+ line/col) back to original .zx when possible.
        var open_file: []const u8 = decoded_file;
        var open_line_buf: [16]u8 = undefined;
        var open_col_buf: [16]u8 = undefined;
        var open_line: []const u8 = l_str;
        var open_col: []const u8 = c_str;
        var remapped_owned: ?[]u8 = null;
        defer if (remapped_owned) |p| ds.gpa.free(p);

        if (Diagnostics.remapLocation(ds.gpa, decoded_file, l_num, c_num, .{
            .require_mapping = false,
            .transpile_dir = ds.transpile_dir,
        })) |maybe| {
            if (maybe) |remapped| {
                remapped_owned = remapped.file;
                open_file = remapped.file;
                open_line = std.fmt.bufPrint(&open_line_buf, "{d}", .{remapped.line}) catch l_str;
                open_col = std.fmt.bufPrint(&open_col_buf, "{d}", .{remapped.col}) catch c_str;
                log.debug("open-in-editor remapped {s}:{d} → {s}:{d}", .{ decoded_file, l_num, open_file, remapped.line });
            }
        } else |_| {}

        const args = try IdeScheme.detect(ds.gpa, ds.env_map, open_file, open_line, open_col);
        defer {
            for (args) |arg| ds.gpa.free(arg);
            ds.gpa.free(args);
        }

        if (args.len == 0) return;
        log.debug("opening in editor: {s}", .{args[0]});

        var child_proc = std.process.spawn(ds.io, .{
            .argv = args,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            log.debug("editor failed to spawn: {s}", .{@errorName(err)});
            return;
        };
        _ = child_proc.wait(ds.io) catch {};
    }
}

fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const buf = try allocator.dupe(u8, encoded);
    errdefer allocator.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.ptr != buf.ptr) {
        std.mem.copyForwards(u8, buf[0..decoded.len], decoded);
    }
    return try allocator.realloc(buf, decoded.len);
}

const IdeScheme = @import("IdeScheme.zig");
const Diagnostics = @import("Diagnostics.zig");
