const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const app_opts = @import("app_opts");

const zx = @import("../../root.zig");
const constants = @import("constants.zig");
const sig = @import("../../util/sig.zig");

const platform = zx.platform;

pub const mode = std.meta.stringToEnum(Mode, app_opts.cli_command) orelse .@"--";
pub const base_path = app_opts.app_base_path;

pub const Config = @import("App/Config.zig");
pub const Router = @import("App/Router.zig");
pub const Server = @import("App/Server.zig");
pub const Client = @import("App/Client.zig");
pub const Wasm = Server.Wasm;

server: Server = .failing,
alloc: std.mem.Allocator = undefined,
config: Config = .{},

default_create: ?*const fn (userdata: ?*anyopaque) anyerror!Server = null,
default_destroy: ?*const fn (userdata: ?*anyopaque, alloc: std.mem.Allocator) void = null,
default_userdata: ?*anyopaque = null,

pub fn init(inita: zx.Init, process_io: anytype, alloc: std.mem.Allocator, config: Config, app_ctx: anytype) !App {
    const H = @TypeOf(app_ctx);
    const cfg = try resolveOptions(alloc, inita, config);

    switch (platform.role) {
        .client => return .{
            .server = Client.server(),
            .alloc = alloc,
            .config = cfg,
        },
        .server => switch (platform.os) {
            .wasi => return .{
                .server = Wasm.server(inita),
                .alloc = alloc,
                .config = cfg,
            },
            else => {
                const io_value = if (@TypeOf(process_io) == std.Io) process_io else return error.InvalidIo;

                const State = struct {
                    io: std.Io,
                    config: Config,
                    app_ctx: H,
                    inita: zx.Init,
                    alloc: std.mem.Allocator,

                    fn create(userdata: ?*anyopaque) anyerror!Server {
                        const self: *@This() = @ptrCast(@alignCast(userdata.?));
                        const Transport = if (comptime app_opts.enable_httpz)
                            Server.Httpz
                        else
                            Server.Std;
                        const instance = try Transport.Backend(H).init(self.io, self.alloc, self.config, self.app_ctx, self.inita);
                        const transport = instance.server();
                        if (App.mode != .@"export") transport.info();
                        return transport;
                    }

                    fn destroy(userdata: ?*anyopaque, gpa: std.mem.Allocator) void {
                        const self: *@This() = @ptrCast(@alignCast(userdata.?));
                        gpa.destroy(self);
                    }
                };

                const state = try alloc.create(State);
                state.* = .{
                    .io = io_value,
                    .config = cfg,
                    .app_ctx = app_ctx,
                    .inita = inita,
                    .alloc = alloc,
                };

                return .{
                    .server = .failing,
                    .alloc = alloc,
                    .config = cfg,
                    .default_create = &State.create,
                    .default_destroy = &State.destroy,
                    .default_userdata = state,
                };
            },
        },
    }
}

pub fn start(self: *App) !void {
    try self.ensureServer();

    const arm_signals = comptime builtin.optimize == .debug and platform.os != .freestanding and platform.os != .wasi;
    if (arm_signals) {
        armSignal(self, struct {
            fn call(ctx: *anyopaque) void {
                const app: *App = @ptrCast(@alignCast(ctx));
                app.server.stop();
            }
        }.call);
        defer disarmSignal();
        try self.server.start();
        return;
    }

    try self.server.start();
}

pub fn stop(self: App) void {
    self.server.stop();
}

pub fn deinit(self: *App) void {
    self.clearDefaultFactory();
    self.server.deinit();
    release(self.alloc);
    assertNoLeaks();
}

pub fn info(self: App) void {
    self.server.info();
}

fn ensureServer(self: *App) !void {
    if (self.server.vtable != &Server.failing_vtable) {
        self.clearDefaultFactory();
        return;
    }
    const create = self.default_create orelse return error.AppUnavailable;
    const userdata = self.default_userdata;
    self.server = try create(userdata);
    self.clearDefaultFactory();
}

fn clearDefaultFactory(self: *App) void {
    if (self.default_destroy) |destroy| {
        if (self.default_userdata) |userdata| {
            destroy(userdata, self.alloc);
        }
    }
    self.default_create = null;
    self.default_destroy = null;
    self.default_userdata = null;
}

pub fn armSignal(instance: *anyopaque, on_stop: *const fn (ctx: *anyopaque) void) void {
    stop_ctx = instance;
    stop_fn = on_stop;
    sig.install() catch {};
    sig.addListener(onSignal);
}

pub fn disarmSignal() void {
    sig.removeListener(onSignal);
    stop_ctx = null;
    stop_fn = null;
}

pub fn release(alloc: std.mem.Allocator) void {
    freeResolved(alloc);
    if (comptime Threaded != void) {
        if (threaded_initialized) {
            threaded_instance.deinit();
            threaded_initialized = false;
        }
    }
}

pub fn assertNoLeaks() void {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return;
    if (builtin.optimize == .debug)
        std.debug.assert(debug_allocator.deinit() == .ok);
}

var stop_ctx: ?*anyopaque = null;
var stop_fn: ?*const fn (ctx: *anyopaque) void = null;

fn onSignal() void {
    if (stop_fn) |f| if (stop_ctx) |ctx| {
        if (App.mode != .dev and App.mode != .@"export") std.debug.print("\nShutting down...\n", .{});
        f(ctx);
    };
}

var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 100 }) = .{};
pub const allocator = switch (builtin.os.tag) {
    .wasi, .freestanding => std.heap.wasm_allocator,
    else => switch (builtin.optimize) {
        .debug => debug_allocator.allocator(),
        .fast, .safe, .small => std.heap.smp_allocator,
    },
};

const Io = if (platform.os == .freestanding) void else std.Io;
const Threaded = if (platform.os == .freestanding) void else std.Io.Threaded;

var threaded_instance: Threaded = if (Threaded == void) {} else undefined;
var threaded_initialized = false;

pub fn io() Io {
    if (comptime platform.os == .freestanding) return {};

    if (!threaded_initialized) {
        threaded_instance = Threaded.init(allocator, .{});
        threaded_initialized = true;
    }
    return threaded_instance.io();
}

var kv: zx.Kv = undefined;
var cache: zx.Cache = undefined;
var db: zx.Db = undefined;

var kv_fs: zx.Kv.Fs = undefined;
var cache_fs: zx.Kv.Fs = undefined;

const Resolved = struct {
    datadir: ?[]const u8 = null,
    staticdir: ?[]const u8 = null,
    db_url: ?[]const u8 = null,
    kv_subdir: ?[]const u8 = null,
    cache_subdir: ?[]const u8 = null,
};

var resolved: Resolved = .{};

fn resolveOptions(alloc: std.mem.Allocator, inita: zx.Init, config: Config) !Config {
    var cfg = config;

    if (app_opts.server_port) |p| cfg.server.port = p;
    if (app_opts.server_address) |a| cfg.server.address = a;

    const rootdir_env = envVar(alloc, inita, "ZIEX_ROOT_DIR");
    const datadir_env = envVar(alloc, inita, "ZIEX_DATA_DIR");
    const staticdir_env = envVar(alloc, inita, "ZIEX_STATIC_DIR");
    const port_env = envVar(alloc, inita, "PORT");

    defer if (rootdir_env) |s| alloc.free(s);
    defer if (datadir_env) |s| alloc.free(s);
    defer if (staticdir_env) |s| alloc.free(s);
    defer if (port_env) |s| alloc.free(s);

    const rootdir = rootdir_env orelse constants.default_rootdir;
    const datadir = try std.fs.path.join(alloc, &.{ rootdir, datadir_env orelse constants.default_datadir });
    const staticdir = try std.fs.path.join(alloc, &.{ rootdir, staticdir_env orelse constants.default_staticdir });
    const port = if (port_env) |pe| std.fmt.parseInt(u16, pe, 10) catch return error.InvalidPort else cfg.server.port;

    cfg.datadir = datadir;
    cfg.staticdir = staticdir;
    cfg.server.port = port;

    switch (platform.os) {
        .freestanding, .wasi => |os| {
            // freestanding => client (browser wasm); wasi => server (server wasm).
            const wasm_kv_enabled = switch (os) {
                .wasi => app_opts.feat_kv_server,
                else => app_opts.feat_kv_client,
            };

            // Feature ==> zx.db (wasm backend, server-side only)
            if (comptime app_opts.feat_sqlite_server) {
                if (os == .wasi) zx.db = try zx.Db.Wasm.open(null, null, "default", .{});
            }

            // Feature ==> zx.kv (wasm backend)
            if (comptime wasm_kv_enabled) {
                var kv_wasm = zx.Kv.Wasm{};
                zx.kv = kv_wasm.kv();
            }

            return cfg;
        },
        else => {},
    }

    // Native target is always server-side from here on.

    // Feature ==> zx.kv (filesystem backend)
    if (comptime app_opts.feat_kv_server) {
        const kv_subdir = try std.fs.path.join(alloc, &.{ datadir, "kv" });
        kv_fs = .{ .io = inita.io, .subdir = kv_subdir };
        kv = kv_fs.kv();
        zx.kv = kv;
        resolved.kv_subdir = kv_subdir;
    }

    // Feature ==> zx.cache (filesystem backend)
    if (comptime app_opts.feat_cache_server) {
        const cache_subdir = try std.fs.path.join(alloc, &.{ datadir, "cache" });
        cache_fs = .{ .io = inita.io, .subdir = cache_subdir };
        const cache_kv: zx.Kv = cache_fs.kv();
        cache = try zx.Cache.init(inita.io, alloc, cache_kv, .{
            .max_size = cfg.cache.max_size,
        });
        zx.cache = cache;
        resolved.cache_subdir = cache_subdir;
    }

    // Feature ==> zx.db (sqlite backend)
    if (comptime app_opts.feat_sqlite_server) {
        const db_dir = try std.fs.path.join(alloc, &.{ datadir, "db", "default.db" });
        defer alloc.free(db_dir);
        const db_url = try std.fmt.allocPrint(alloc, "file:{s}", .{db_dir});
        zx.db = try zx.Db.Sqlite.open(alloc, inita.io, db_url, .{});
        resolved.db_url = db_url;
    }

    resolved.datadir = datadir;
    resolved.staticdir = staticdir;

    if (cfg.server.thread_pool.count == null) {
        const cpus = std.Thread.getCpuCount() catch 1;
        cfg.server.thread_pool.count = @intCast(@max(cpus, 1));
    }

    return cfg;
}

fn freeResolved(alloc: std.mem.Allocator) void {
    if (resolved.datadir == null) return;

    // Feature ==> zx.db (sqlite backend)
    if (comptime app_opts.feat_sqlite_server) {
        if (resolved.db_url) |s| {
            zx.db.deinit();
            alloc.free(s);
        }
    }

    // Feature ==> zx.cache
    if (comptime app_opts.feat_cache_server) {
        if (resolved.cache_subdir) |s| {
            zx.cache.deinit();
            alloc.free(s);
        }
    }

    // Feature ==> zx.kv
    if (comptime app_opts.feat_kv_server) {
        if (resolved.kv_subdir) |s| alloc.free(s);
    }

    if (resolved.staticdir) |s| alloc.free(s);
    if (resolved.datadir) |s| alloc.free(s);
    resolved = .{};
}

fn envVar(alloc: std.mem.Allocator, inita: zx.Init, name: []const u8) ?[]const u8 {
    if (platform.os == .freestanding or platform.os == .wasi) return null;
    const minimal: std.process.Init.Minimal = switch (@TypeOf(inita)) {
        std.process.Init.Minimal => inita,
        std.process.Init => inita.minimal,
        else => return null,
    };
    return minimal.environ.getAlloc(alloc, name) catch null;
}

pub const Route = struct {
    path: []const u8,
    page: ?type = null,
    layout: ?type = null,
    notfound: ?type = null,
    @"error": ?type = null,
    route: ?type = null,
    proxy: ?type = null,
};

pub const Mode = enum { dev, serve, @"export", @"--" };
