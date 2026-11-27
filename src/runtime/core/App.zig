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
var flag_env: if (app_opts.feat_flag_server) std.heap.ArenaAllocator else void = undefined;

const EmailBackend = if (app_opts.feat_email_server) switch (std.meta.stringToEnum(zx.Email.Provider, app_opts.email_provider).?) {
    .resend => zx.Email.Resend,
    .smtp => if (platform.os == .wasi) zx.Email.Memory else zx.Email.Smtp,
    .wasm => if (platform.os == .wasi) zx.Email.Wasm else zx.Email.Memory,
    .memory => zx.Email.Memory,
} else void;
var email_backend: EmailBackend = undefined;
var email_env: if (app_opts.feat_email_server) std.heap.ArenaAllocator else void = undefined;

const BucketBackend = if (app_opts.feat_bucket_server) switch (@as(zx.Bucket.Provider, if (app_opts.bucket_provider) |p|
    std.meta.stringToEnum(zx.Bucket.Provider, p).?
else if (platform.os == .wasi) .wasm else .fs)) {
    .s3 => zx.Bucket.S3,
    .wasm, .fs => if (platform.os == .wasi) zx.Bucket.Wasm else zx.Bucket.Fs,
} else void;
var bucket_backend: BucketBackend = undefined;
var bucket_env: if (app_opts.feat_bucket_server) std.heap.ArenaAllocator else void = undefined;

const wasi = platform.os == .wasi;
var secrets_env: ?zx.Secrets.Env = null;
var secrets_wasm: if (wasi) zx.Secrets.Wasm else void = if (wasi) .{} else {};
var secrets_stores: if (wasi) [2]zx.Secrets else void = undefined;
var secrets_chain: if (wasi) zx.Secrets.Chain else void = undefined;

const Resolved = struct {
    datadir: ?[]const u8 = null,
    staticdir: ?[]const u8 = null,
    db_url: ?[]const u8 = null,
    kv_subdir: ?[]const u8 = null,
    cache_subdir: ?[]const u8 = null,
    host: ?[]const u8 = null,
    ai_api_key: ?[]const u8 = null,
    ai_base_url: ?[]const u8 = null,
    ai_model: ?[]const u8 = null,
    ai_image_model: ?[]const u8 = null,
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

    // Feature ==> zx.db (mysql backend)
    if (comptime app_opts.feat_mysql_server) {
        if (comptime app_opts.feat_sqlite_server) @compileError("zx.db: enable either the sqlite or the mysql feature, not both");
        if (comptime app_opts.feat_pg_server) @compileError("zx.db: enable either the postgres or the mysql feature, not both");
        const db_url = envVar(alloc, "DATABASE_URL") orelse {
            std.log.err("mysql is enabled but DATABASE_URL is not set", .{});
            return error.MissingDatabaseUrl;
        };
        errdefer alloc.free(db_url);
        zx.db = try zx.Db.Mysql.open(alloc, inita.io, db_url, .{});
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

    if (comptime wasi) {
        secrets_stores = .{ env.secrets(), secrets_wasm.secrets() };
        secrets_chain = .{ .stores = &secrets_stores };
        zx.secrets = secrets_chain.secrets();
        return;
    }

    // `.env` files live in the project (cwd), not `ZIEX_ROOT_DIR`, which the CLI points at `zig-out`.
    const env_mode = env.map.get("ZIEX_ENV") orelse if (App.mode == .dev) "development" else "production";
    try env.load(inita.io, .{ .mode = env_mode });
    zx.secrets = env.secrets();
}

fn initAi(alloc: std.mem.Allocator, inita: zx.Init) void {
    resolved.ai_api_key = envVar(alloc, AiProvider.env.api_key.key());
    resolved.ai_base_url = envVar(alloc, AiProvider.env.base_url.key());
    resolved.ai_model = envVar(alloc, AiProvider.env.model.key());
    if (comptime @hasDecl(AiProvider.env, "image_model")) {
        resolved.ai_image_model = envVar(alloc, AiProvider.env.image_model.key());
    }
    ai_provider = .{
        .io = inita.io,
        .api_key = resolved.ai_api_key,
        .base_url = resolved.ai_base_url orelse AiProvider.default_base_url,
        .model = resolved.ai_model,
    };
    if (comptime @hasField(AiProvider, "image_model")) ai_provider.image_model = resolved.ai_image_model;
    zx.ai = ai_provider.ai();
}

fn initFlag(alloc: std.mem.Allocator, inita: zx.Init) void {
    flag_env = .init(alloc);
    const env = flag_env.allocator();
    flag_provider = switch (FlagProvider) {
        zx.Flag.Ofrep => .{
            .io = inita.io,
            .base_url = envVar(env, zx.Flag.Ofrep.env.url.key()) orelse "",
            .api_key = envVar(env, zx.Flag.Ofrep.env.api_key.key()),
        },
        zx.Flag.Flagship => .{
            .io = inita.io,
            .binding = envVar(env, zx.Flag.Flagship.env.binding.key()) orelse zx.Flag.Flagship.default_binding,
            .base_url = envVar(env, zx.Flag.Flagship.env.base_url.key()) orelse zx.Flag.Flagship.default_base_url,
            .account_id = envVar(env, zx.Flag.Flagship.env.account_id.key()),
            .app_id = envVar(env, zx.Flag.Flagship.env.app_id.key()),
            .api_token = envVar(env, zx.Flag.Flagship.env.api_token.key()),
        },
        zx.Flag.Kv => if (app_opts.feat_kv_server) .{ .store = zx.kv } else @compileError("the .kv flag provider needs the .kv server feature"),
        else => unreachable,
    };
    zx.flag = flag_provider.flag();
}

fn initEmail(alloc: std.mem.Allocator, inita: zx.Init) void {
    email_env = .init(alloc);
    const env = email_env.allocator();

    if (comptime EmailBackend == zx.Email.Resend) {
        email_backend = .{
            .io = inita.io,
            .api_key = envVar(env, zx.Email.Resend.env.api_key.key()),
            .base_url = envVar(env, zx.Email.Resend.env.base_url.key()) orelse zx.Email.Resend.default_base_url,
        };
    } else if (comptime EmailBackend == zx.Email.Smtp) {
        const tls_name = envVar(env, zx.Email.Smtp.env.tls.key());
        email_backend = .{
            .io = inita.io,
            .host = envVar(env, zx.Email.Smtp.env.host.key()) orelse "",
            .port = parsePort(envVar(env, zx.Email.Smtp.env.port.key())) orelse zx.Email.Smtp.default_port,
            .username = envVar(env, zx.Email.Smtp.env.username.key()),
            .password = envVar(env, zx.Email.Smtp.env.password.key()),
            .tls_mode = if (tls_name) |n| zx.Email.Smtp.parseTls(n) orelse .starttls else .starttls,
        };
    } else if (comptime EmailBackend == zx.Email.Wasm) {
        email_backend = .{ .binding = envVar(env, zx.Email.Wasm.env.binding.key()) orelse "default" };
    } else if (comptime EmailBackend == zx.Email.Memory) {
        email_backend = .init(alloc, inita.io);
        email_backend.log = true;
    } else unreachable;

    zx.email = email_backend.email();

    const from = envVar(env, zx.Email.Env.EMAIL_FROM.key()) orelse return;
    zx.email.from = zx.Email.Address.parse(from) catch {
        std.log.scoped(.zx_email).warn("invalid sender address: {s}", .{from});
        return;
    };
}

fn initBucket(alloc: std.mem.Allocator, inita: zx.Init, datadir: []const u8) !void {
    bucket_env = .init(alloc);
    const env = bucket_env.allocator();

    if (comptime BucketBackend == zx.Bucket.S3) {
        bucket_backend = .{
            .io = inita.io,
            .allocator = alloc,
            .access_key_id = firstEnvVar(env, &zx.Bucket.S3.env.access_key_id) orelse "",
            .secret_access_key = firstEnvVar(env, &zx.Bucket.S3.env.secret_access_key) orelse "",
            .session_token = firstEnvVar(env, &zx.Bucket.S3.env.session_token) orelse "",
            .region = firstEnvVar(env, &zx.Bucket.S3.env.region) orelse "",
            .endpoint = firstEnvVar(env, &zx.Bucket.S3.env.endpoint) orelse "",
            .bucket_name = firstEnvVar(env, &zx.Bucket.S3.env.bucket_name) orelse "",
        };
    } else if (comptime BucketBackend == zx.Bucket.Wasm) {
        bucket_backend = .{ .binding = envVar(env, zx.Bucket.Wasm.env.binding.key()) orelse "default" };
    } else if (comptime BucketBackend == zx.Bucket.Fs) {
        bucket_backend = .{ .io = inita.io, .root = try std.fs.path.join(env, &.{ datadir, "bucket" }) };
    } else unreachable;

    zx.bucket = bucket_backend.bucket();
}

fn firstEnvVar(alloc: std.mem.Allocator, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (envVar(alloc, name)) |v| return v;
    return null;
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

    // Feature ==> zx.db (sqlite, postgres or mysql backend)
    if (comptime app_opts.feat_sqlite_server or app_opts.feat_pg_server or app_opts.feat_mysql_server) {
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
        if (resolved.ai_model) |s| alloc.free(s);
        if (resolved.ai_image_model) |s| alloc.free(s);
    }

    // Feature ==> zx.flag
    if (comptime app_opts.feat_flag_server) {
        zx.flag = .failing;
        flag_env.deinit();
    }

    // Feature ==> zx.email
    if (comptime app_opts.feat_email_server) {
        zx.email = .failing;
        if (comptime EmailBackend == zx.Email.Memory) email_backend.deinit();
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

fn parsePort(text: ?[]const u8) ?u16 {
    return std.fmt.parseInt(u16, text orelse return null, 10) catch null;
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
