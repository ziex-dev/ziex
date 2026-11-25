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
// The `Io` passed to `init`, on native servers.
io: ?std.Io = null,

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
                        if (App.mode != .static) transport.info();
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
                    .io = io_value,
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
        }.call, self.io);
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

pub fn armSignal(instance: *anyopaque, on_stop: *const fn (ctx: *anyopaque) void, io: ?std.Io) void {
    stop_ctx = instance;
    stop_fn = on_stop;
    stopping.store(false, .release);
    sig.install(onSignal) catch {};
    if (stop_on_eof) if (io) |i| {
        eof_watch = .{ .io = i, .future = i.concurrent(stopOnStdinEof, .{i}) catch return };
    };
}

/// `zx dev` closes our stdin to stop us: unlike signals, that works on Windows.
fn stopOnStdinEof(io: std.Io) void {
    var buf: [256]u8 = undefined;
    while (true) _ = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch |err| {
        if (err == error.Canceled) return;
        break;
    };
    onSignal(.TERM);
}

pub fn disarmSignal() void {
    // Cancel before `release` tears the `Io` down.
    if (eof_watch) |*w| {
        w.future.cancel(w.io);
        eof_watch = null;
    }
    sig.uninstall();
    stop_ctx = null;
    stop_fn = null;
}

pub fn release(alloc: std.mem.Allocator) void {
    freeResolved(alloc);
    @import("Io.zig").deinitDefault();
}

pub fn assertNoLeaks() void {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return;
    if (builtin.optimize != .debug) return;
    const leaked = debug_allocator.deinit() == .leak;
    // `zx dev` shows the leak report; a panic trace would bury it.
    if (mode != .dev) std.debug.assert(!leaked);
}

var stop_on_eof = false;
var eof_watch: ?struct { io: std.Io, future: std.Io.Future(void) } = null;
var stopping: std.atomic.Value(bool) = .init(false);
var stop_ctx: ?*anyopaque = null;
var stop_fn: ?*const fn (ctx: *anyopaque) void = null;

fn onSignal(_: std.posix.SIG) void {
    if (stopping.swap(true, .acq_rel)) return;
    if (stop_fn) |f| if (stop_ctx) |ctx| {
        if (App.mode != .dev and App.mode != .static) std.debug.print("\nShutting down...\n", .{});
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

var kv: zx.Kv = undefined;
var cache: zx.Cache = undefined;
var db: zx.Db = undefined;

var kv_fs: zx.Kv.Fs = undefined;
var cache_fs: zx.Kv.Fs = undefined;

const AiProvider = if (app_opts.feat_ai_server) std.meta.stringToEnum(zx.Ai.Provider, app_opts.ai_provider).?.Type() else void;
var ai_provider: AiProvider = undefined;

const FlagProvider = if (app_opts.feat_flag_server) std.meta.stringToEnum(zx.Flag.Provider, app_opts.flag_provider).?.Type() else void;
var flag_provider: FlagProvider = undefined;
var flag_env: std.heap.ArenaAllocator = undefined;

var email_resend: zx.Email.Resend = undefined;
var email_wasm: zx.Email.Wasm = undefined;
var email_memory: ?zx.Email.Memory = null;
var email_env: std.heap.ArenaAllocator = undefined;

var bucket_fs: zx.Bucket.Fs = undefined;
var bucket_wasm: zx.Bucket.Wasm = undefined;
var bucket_s3: zx.Bucket.S3 = undefined;
var bucket_env: std.heap.ArenaAllocator = undefined;

var secrets_env: ?zx.Secrets.Env = null;
var secrets_wasm: zx.Secrets.Wasm = .{};
var secrets_stores: [2]zx.Secrets = undefined;
var secrets_chain: zx.Secrets.Chain = .{ .stores = &secrets_stores };

const Resolved = struct {
    datadir: ?[]const u8 = null,
    staticdir: ?[]const u8 = null,
    db_url: ?[]const u8 = null,
    kv_subdir: ?[]const u8 = null,
    cache_subdir: ?[]const u8 = null,
    host: ?[]const u8 = null,
    ai_api_key: ?[]const u8 = null,
    ai_base_url: ?[]const u8 = null,
};

var resolved: Resolved = .{};

fn resolveOptions(alloc: std.mem.Allocator, inita: zx.Init, config: Config) !Config {
    var cfg = config;

    // Feature ==> zx.secrets; first, so `.env` files feed every `envVar` below.
    if (comptime platform.role == .server) try initSecrets(alloc, inita);

    if (app_opts.server_port) |p| cfg.server.port = p;
    if (app_opts.server_address) |a| cfg.server.address = a;

    const rootdir_env = envVar(alloc, "ZIEX_ROOT_DIR");
    const datadir_env = envVar(alloc, "ZIEX_DATA_DIR");
    const staticdir_env = envVar(alloc, "ZIEX_STATIC_DIR");
    const port_env = envVar(alloc, "PORT");
    const host_env = envVar(alloc, "HOST");
    if (envVar(alloc, "ZIEX_STOP_ON_EOF")) |s| {
        alloc.free(s);
        stop_on_eof = true;
    }

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
    if (host_env) |h| {
        cfg.server.address = h;
        resolved.host = h;
    }

    switch (platform.os) {
        .freestanding, .wasi => |os| {
            // freestanding => client (browser wasm); wasi => server (server wasm).
            const wasm_kv_enabled = switch (os) {
                .wasi => app_opts.feat_kv_server,
                else => app_opts.feat_kv_client,
            };

            // Feature ==> zx.db (wasm backend, server-side only)
            if (comptime app_opts.feat_sqlite_server) {
                if (os == .wasi) zx.db = try zx.Db.Wasm.open(alloc, inita.io, "default", .{});
            }

            // Feature ==> zx.kv (wasm backend)
            if (comptime wasm_kv_enabled) {
                var kv_wasm = zx.Kv.Wasm{};
                zx.kv = kv_wasm.kv();
            }

            // Feature ==> zx.ai
            if (comptime app_opts.feat_ai_server) {
                if (os == .wasi) initAi(alloc, inita);
            }

            // Feature ==> zx.flag
            if (comptime app_opts.feat_flag_server) {
                if (os == .wasi) initFlag(alloc, inita);
            }

            // Feature ==> zx.email
            if (comptime app_opts.feat_email_server) {
                if (os == .wasi) initEmail(alloc, inita);
            }

            // Feature ==> zx.bucket
            if (comptime app_opts.feat_bucket_server) {
                if (os == .wasi) try initBucket(alloc, inita, datadir);
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
        cache = try zx.Cache.init(alloc, inita.io, cache_kv, .{
            .max_size = cfg.cache.max_size,
        });
        zx.cache = cache;
        resolved.cache_subdir = cache_subdir;
    }

    // Feature ==> zx.db (sqlite backend)
    if (comptime app_opts.feat_sqlite_server) {
        const db_dir = try std.fs.path.join(alloc, &.{ datadir, "db", "default.db" });
        defer alloc.free(db_dir);
        const db_url = try alloc.print("file:{s}", .{db_dir});
        zx.db = try zx.Db.Sqlite.open(alloc, inita.io, db_url, .{});
        resolved.db_url = db_url;
    }

    // Feature ==> zx.db (postgres backend)
    if (comptime app_opts.feat_pg_server) {
        if (comptime app_opts.feat_sqlite_server) @compileError("zx.db: enable either the sqlite or the postgres feature, not both");
        const db_url = envVar(alloc, "DATABASE_URL") orelse {
            std.log.err("postgres is enabled but DATABASE_URL is not set", .{});
            return error.MissingDatabaseUrl;
        };
        errdefer alloc.free(db_url);
        zx.db = try zx.Db.Postgres.open(alloc, inita.io, db_url, .{});
        resolved.db_url = db_url;
    }

    // Feature ==> zx.ai
    if (comptime app_opts.feat_ai_server) initAi(alloc, inita);

    // Feature ==> zx.flag
    if (comptime app_opts.feat_flag_server) initFlag(alloc, inita);

    // Feature ==> zx.email
    if (comptime app_opts.feat_email_server) initEmail(alloc, inita);

    // Feature ==> zx.bucket
    if (comptime app_opts.feat_bucket_server) try initBucket(alloc, inita, datadir);

    resolved.datadir = datadir;
    resolved.staticdir = staticdir;

    if (cfg.server.thread_pool.count == null) {
        const cpus = std.Thread.getCpuCount() catch 1;
        cfg.server.thread_pool.count = @intCast(@max(cpus, 1));
    }

    return cfg;
}

fn initSecrets(alloc: std.mem.Allocator, inita: zx.Init) !void {
    secrets_env = try .fromEnviron(alloc, inita.minimal.environ);
    const env = &secrets_env.?;

    if (platform.os == .wasi) {
        secrets_stores = .{ env.secrets(), secrets_wasm.secrets() };
        zx.secrets = secrets_chain.secrets();
        return;
    }

    // `.env` files live in the project (cwd), not `ZIEX_ROOT_DIR`, which the CLI points at `zig-out`.
    const env_mode = env.map.get("ZIEX_ENV") orelse if (App.mode == .dev) "development" else "production";
    try env.load(inita.io, .{ .mode = env_mode });
    zx.secrets = env.secrets();
}

fn initAi(alloc: std.mem.Allocator, inita: zx.Init) void {
    resolved.ai_api_key = envVar(alloc, AiProvider.env_api_key);
    resolved.ai_base_url = envVar(alloc, AiProvider.env_base_url);
    ai_provider = .{
        .io = inita.io,
        .api_key = resolved.ai_api_key,
        .base_url = resolved.ai_base_url orelse app_opts.ai_base_url orelse AiProvider.default_base_url,
        .model = app_opts.ai_model,
    };
    if (@hasField(AiProvider, "image_model")) ai_provider.image_model = app_opts.ai_image_model;
    zx.ai = ai_provider.ai();
}

fn initFlag(alloc: std.mem.Allocator, inita: zx.Init) void {
    flag_env = .init(alloc);
    const env = flag_env.allocator();
    flag_provider = switch (FlagProvider) {
        zx.Flag.Ofrep => .{
            .io = inita.io,
            .base_url = envVar(env, zx.Flag.Ofrep.env_url) orelse app_opts.flag_base_url orelse "",
            .api_key = envVar(env, zx.Flag.Ofrep.env_api_key),
        },
        zx.Flag.Flagship => .{
            .io = inita.io,
            .binding = app_opts.flag_binding orelse zx.Flag.Flagship.default_binding,
            .base_url = app_opts.flag_base_url orelse zx.Flag.Flagship.default_base_url,
            .account_id = envVar(env, zx.Flag.Flagship.env_account_id),
            .app_id = envVar(env, zx.Flag.Flagship.env_app_id) orelse app_opts.flag_app_id,
            .api_token = envVar(env, zx.Flag.Flagship.env_api_token),
        },
        zx.Flag.Kv => if (app_opts.feat_kv_server) .{ .store = zx.kv } else @compileError("the .kv flag provider needs the .kv server feature"),
        else => unreachable,
    };
    zx.flag = flag_provider.flag();
}

fn initEmail(alloc: std.mem.Allocator, inita: zx.Init) void {
    email_env = .init(alloc);
    const env = email_env.allocator();
    const provider = comptime std.meta.stringToEnum(zx.Email.Provider, app_opts.email_provider).?;
    zx.email = switch (provider) {
        .resend => blk: {
            email_resend = .{
                .io = inita.io,
                .api_key = envVar(env, zx.Email.Resend.env_api_key),
                .base_url = envVar(env, zx.Email.Resend.env_base_url) orelse app_opts.email_base_url orelse zx.Email.Resend.default_base_url,
            };
            break :blk email_resend.email();
        },
        // No host binding natively, so messages are kept and logged instead.
        .wasm => if (platform.os == .wasi) blk: {
            email_wasm = .{ .binding = app_opts.email_binding orelse "default" };
            break :blk email_wasm.email();
        } else initEmailMemory(alloc, inita),
        .memory => initEmailMemory(alloc, inita),
    };

    const from = envVar(env, "EMAIL_FROM") orelse app_opts.email_from orelse return;
    zx.email.from = zx.Email.Address.parse(from) catch {
        std.log.scoped(.zx_email).warn("invalid sender address: {s}", .{from});
        return;
    };
}

fn initBucket(alloc: std.mem.Allocator, inita: zx.Init, datadir: []const u8) !void {
    bucket_env = .init(alloc);
    const env = bucket_env.allocator();
    const provider: zx.Bucket.Provider = comptime if (app_opts.bucket_provider) |p|
        std.meta.stringToEnum(zx.Bucket.Provider, p).?
    else if (platform.os == .wasi) .wasm else .fs;

    zx.bucket = switch (provider) {
        .s3 => blk: {
            bucket_s3 = .{
                .io = inita.io,
                .allocator = alloc,
                .access_key_id = firstEnvVar(env, &zx.Bucket.S3.env.access_key_id) orelse "",
                .secret_access_key = firstEnvVar(env, &zx.Bucket.S3.env.secret_access_key) orelse "",
                .session_token = firstEnvVar(env, &zx.Bucket.S3.env.session_token) orelse "",
                .region = firstEnvVar(env, &zx.Bucket.S3.env.region) orelse app_opts.bucket_region orelse "",
                .endpoint = firstEnvVar(env, &zx.Bucket.S3.env.endpoint) orelse app_opts.bucket_endpoint orelse "",
                .bucket_name = firstEnvVar(env, &zx.Bucket.S3.env.bucket_name) orelse app_opts.bucket_name orelse "",
            };
            break :blk bucket_s3.bucket();
        },
        // A directory can't be reached from wasm, and a host binding not from native.
        .wasm, .fs => if (platform.os == .wasi) blk: {
            bucket_wasm = .{ .binding = app_opts.bucket_binding orelse "default" };
            break :blk bucket_wasm.bucket();
        } else blk: {
            bucket_fs = .{ .io = inita.io, .root = try std.fs.path.join(env, &.{ datadir, "bucket" }) };
            break :blk bucket_fs.bucket();
        },
    };
}

fn firstEnvVar(alloc: std.mem.Allocator, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (envVar(alloc, name)) |v| return v;
    return null;
}

fn initEmailMemory(alloc: std.mem.Allocator, inita: zx.Init) zx.Email {
    email_memory = .init(alloc, inita.io);
    email_memory.?.log = true;
    return email_memory.?.email();
}

fn freeResolved(alloc: std.mem.Allocator) void {
    if (resolved.host) |s| alloc.free(s);
    resolved.host = null;

    // Feature ==> zx.secrets
    if (secrets_env) |*env| {
        zx.secrets = .failing;
        env.deinit();
        secrets_env = null;
    }

    if (resolved.datadir == null) return;

    // Feature ==> zx.db (sqlite or postgres backend)
    if (comptime app_opts.feat_sqlite_server or app_opts.feat_pg_server) {
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

    // Feature ==> zx.ai
    if (comptime app_opts.feat_ai_server) {
        zx.ai = .failing;
        if (resolved.ai_api_key) |s| alloc.free(s);
        if (resolved.ai_base_url) |s| alloc.free(s);
    }

    // Feature ==> zx.flag
    if (comptime app_opts.feat_flag_server) {
        zx.flag = .failing;
        flag_env.deinit();
    }

    // Feature ==> zx.email
    if (comptime app_opts.feat_email_server) {
        zx.email = .failing;
        if (email_memory) |*m| m.deinit();
        email_memory = null;
        email_env.deinit();
    }

    // Feature ==> zx.bucket
    if (comptime app_opts.feat_bucket_server) {
        zx.bucket = .failing;
        bucket_env.deinit();
    }

    if (resolved.staticdir) |s| alloc.free(s);
    if (resolved.datadir) |s| alloc.free(s);
    resolved = .{};
}

fn envVar(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return zx.secrets.get(alloc, name) catch null;
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

pub const Mode = enum { dev, serve, static, @"--" };
