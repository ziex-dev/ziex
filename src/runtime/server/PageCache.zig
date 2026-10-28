const PageCache = @This();

const std = @import("std");
const zx = @import("../../root.zig");
const AppConfig = @import("../core/App/Config.zig");
const Request = @import("../core/Http/Request.zig");
const Response = @import("../core/Http/Response.zig");

const Allocator = std.mem.Allocator;
const cachez = zx.Cache.cachez;
const ServerApp = zx.server.App;
const log = std.log.scoped(.page_cache);

userdata: ?*anyopaque = null,
vtable: *const VTable,
config: AppConfig.CacheConfig,
allocator: Allocator,

pub const Status = enum {
    hit,
    miss,
    skip,
    disabled,
};

pub const CacheValue = struct {
    body: []const u8,
    etag: []const u8,
    content_type: ?[]const u8 = null,

    pub fn deinit(self: CacheValue, allocator: Allocator) void {
        allocator.free(self.body);
        allocator.free(self.etag);
        if (self.content_type) |ct| allocator.free(ct);
    }

    pub fn removedFromCache(self: CacheValue, allocator: Allocator) void {
        self.deinit(allocator);
    }
};

pub const VTable = struct {
    get: *const fn (userdata: ?*anyopaque, allocator: Allocator, key: []const u8) anyerror!?CacheValue,
    put: *const fn (userdata: ?*anyopaque, key: []const u8, value: CacheValue, ttl: u32) anyerror!void,
    del: *const fn (userdata: ?*anyopaque, key: []const u8) bool,
    delPrefix: *const fn (userdata: ?*anyopaque, prefix: []const u8) usize,
    deinit: *const fn (userdata: ?*anyopaque) void,
};

pub const StoreInfo = struct {
    status: u16,
    body: []const u8,
    content_type: ?[]const u8 = null,
};

/// In-memory page cache backed by `cachez` (native server).
pub fn initCachez(io: std.Io, allocator: Allocator, config: AppConfig.CacheConfig) !PageCache {
    const state = try allocator.create(CachezState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .cache = try cachez.Cache(CacheValue).init(io, allocator, .{
            .max_size = config.max_size,
        }),
    };
    return .{
        .userdata = state,
        .vtable = &cachez_vtable,
        .config = config,
        .allocator = allocator,
    };
}

/// Persistent/edge page cache backed by `zx.Kv` (WASM / Workers KV, etc.).
pub fn initKv(io: std.Io, allocator: Allocator, kv: zx.Kv, config: AppConfig.CacheConfig) !PageCache {
    const state = try allocator.create(KvState);
    errdefer allocator.destroy(state);
    state.* = .{
        .io = io,
        .allocator = allocator,
        .kv = kv,
    };
    return .{
        .userdata = state,
        .vtable = &kv_vtable,
        .config = config,
        .allocator = allocator,
    };
}

pub fn deinit(self: *PageCache) void {
    self.vtable.deinit(self.userdata);
    self.userdata = null;
}

/// Try to serve from cache. Returns cache status.
pub fn tryServe(self: *PageCache, req: Request, res: Response) Status {
    const ttl = checkCacheable(self.config, req, null) catch |err| return statusFromError(err);

    const path = req.pathname;

    if (req.headers.get("if-none-match")) |client_etag| {
        if (self.vtable.get(self.userdata, req.arena, path) catch null) |entry| {
            // Arena-owned; no explicit free.
            if (std.mem.eql(u8, client_etag, entry.etag)) {
                res.setStatus(.not_modified);
                setCacheHeaders(res, entry.etag, req.arena, ttl, .hit);
                return .hit;
            }
        }
    }

    if (self.vtable.get(self.userdata, req.arena, path) catch null) |entry| {
        if (entry.content_type) |ct| res.headers.set("Content-Type", ct);
        setCacheHeaders(res, entry.etag, req.arena, ttl, .hit);
        res.text(entry.body);
        return .hit;
    }

    return .miss;
}

/// Cache a successful response.
pub fn store(self: *PageCache, req: Request, res: Response, info: StoreInfo) void {
    const ttl = checkCacheable(self.config, req, .{
        .status = info.status,
        .body_len = info.body.len,
    }) catch return;

    const etag = std.fmt.allocPrint(self.allocator, "\"{x}\"", .{std.hash.Wyhash.hash(0, info.body)}) catch return;

    const cached_body = self.allocator.dupe(u8, info.body) catch {
        self.allocator.free(etag);
        return;
    };

    const cached_ct: ?[]const u8 = if (info.content_type) |ct|
        self.allocator.dupe(u8, ct) catch {
            self.allocator.free(cached_body);
            self.allocator.free(etag);
            return;
        }
    else
        null;

    const header_etag = req.arena.dupe(u8, etag) catch etag;

    // `put` takes ownership of the CacheValue (frees on failure).
    self.vtable.put(self.userdata, req.pathname, .{
        .body = cached_body,
        .etag = etag,
        .content_type = cached_ct,
    }, ttl) catch |err| {
        log.warn("Failed to cache page {s}: {}", .{ req.pathname, err });
        return;
    };

    setCacheHeaders(res, header_etag, req.arena, ttl, .miss);
}

fn setCacheHeaders(res: Response, etag: []const u8, arena: Allocator, ttl: u32, result: enum { hit, miss }) void {
    res.headers.set("ETag", etag);
    res.headers.set("Cache-Control", std.fmt.allocPrint(arena, "public, max-age={d}", .{ttl}) catch "public, max-age=300");
    res.headers.set("X-Cache", if (result == .hit) "HIT" else "MISS");
}

pub const CacheError = error{
    Disabled,
    MissingRouteData,
    NotConfigured,
    UnsupportedMethod,
    UnsupportedPath,
    ZeroTtl,
    UnsupportedHttpStatus,
    EmptyBody,
};

const ResponseCheck = struct {
    status: ?u16 = null,
    body_len: ?usize = null,
};

/// Adjust cache status for display when the response is not cacheable.
pub fn effectiveStatus(cache_status: Status, http_status: u16) Status {
    _ = checkCacheable(null, null, .{ .status = http_status }) catch return .skip;
    return cache_status;
}

fn statusFromError(err: CacheError) Status {
    return switch (err) {
        error.Disabled => .disabled,
        error.MissingRouteData => .skip,
        error.NotConfigured => .skip,
        error.UnsupportedMethod => .skip,
        error.UnsupportedPath => .skip,
        error.ZeroTtl => .skip,
        error.UnsupportedHttpStatus => .skip,
        error.EmptyBody => .skip,
    };
}

/// Validate whether a request/response may be cached. Returns the route TTL when a request is provided.
fn checkCacheable(
    config: ?AppConfig.CacheConfig,
    req: ?Request,
    response: ?ResponseCheck,
) CacheError!u32 {
    if (config) |cfg| {
        if (cfg.max_size == 0) return error.Disabled;
    }

    if (req) |r| {
        if (r.method != .GET) return error.UnsupportedMethod;
        if (std.mem.startsWith(u8, r.pathname, "/.well-known/_zx/")) return error.UnsupportedPath;
    }

    const ttl = ttl_blk: {
        if (req) |r| {
            const match = zx.Router.matchRoute(r.pathname, .{ .match = .exact }) orelse return error.MissingRouteData;
            const route: *const ServerApp.Route = match.route;

            const caching: ?zx.BuiltinAttribute.Caching = cache_blk: {
                if (route.page_opts) |o| if (o.caching) |c| break :cache_blk c else break :cache_blk null;
                if (route.layout_opts) |o| if (o.caching) |c| break :cache_blk c else break :cache_blk null;
                if (route.notfound_opts) |o| if (o.caching) |c| break :cache_blk c else break :cache_blk null;
                if (route.route_opts) |o| if (o.caching) |c| break :cache_blk c else break :cache_blk null;
                break :cache_blk null;
            };

            const c = caching orelse return error.NotConfigured;
            if (c.ttl.nanoseconds == 0) return error.ZeroTtl;
            const ttl_s: u32 = @intCast(c.ttl.toSeconds());
            break :ttl_blk ttl_s;
        } else break :ttl_blk 0;
    };

    if (response) |r| {
        if (r.status) |status| {
            if (status != 200) return error.UnsupportedHttpStatus;
        }
        if (r.body_len) |len| {
            if (len == 0) return error.EmptyBody;
        }
    }

    return ttl;
}

pub fn del(self: *PageCache, path: []const u8) bool {
    return self.vtable.del(self.userdata, path);
}

pub fn delPath(self: *PageCache, path_prefix: []const u8) usize {
    return self.vtable.delPrefix(self.userdata, path_prefix);
}

// --- cachez backend --- //

const CachezState = struct {
    allocator: Allocator,
    cache: cachez.Cache(CacheValue),
};

const cachez_vtable = VTable{
    .get = &cachezGet,
    .put = &cachezPut,
    .del = &cachezDel,
    .delPrefix = &cachezDelPrefix,
    .deinit = &cachezDeinit,
};

fn cachezState(userdata: ?*anyopaque) *CachezState {
    return @ptrCast(@alignCast(userdata.?));
}

fn cachezGet(userdata: ?*anyopaque, allocator: Allocator, key: []const u8) anyerror!?CacheValue {
    const state = cachezState(userdata);
    const entry = state.cache.get(key) orelse return null;
    defer entry.release();
    return .{
        .body = try allocator.dupe(u8, entry.value.body),
        .etag = try allocator.dupe(u8, entry.value.etag),
        .content_type = if (entry.value.content_type) |ct| try allocator.dupe(u8, ct) else null,
    };
}

fn cachezPut(userdata: ?*anyopaque, key: []const u8, value: CacheValue, ttl: u32) anyerror!void {
    const state = cachezState(userdata);
    errdefer value.deinit(state.allocator);
    try state.cache.put(key, value, .{ .ttl = ttl });
}

fn cachezDel(userdata: ?*anyopaque, key: []const u8) bool {
    return cachezState(userdata).cache.del(key);
}

fn cachezDelPrefix(userdata: ?*anyopaque, prefix: []const u8) usize {
    return cachezState(userdata).cache.delPrefix(prefix) catch 0;
}

fn cachezDeinit(userdata: ?*anyopaque) void {
    const state = cachezState(userdata);
    const allocator = state.allocator;
    state.cache.deinit();
    allocator.destroy(state);
}

// --- zx.Kv backend --- //

const KvStored = struct {
    body: []const u8,
    etag: []const u8,
    content_type: ?[]const u8 = null,
    /// Unix seconds; 0 means no expiry.
    expires_at: u64 = 0,
};

const KvState = struct {
    io: std.Io,
    allocator: Allocator,
    kv: zx.Kv,
};

const kv_vtable = VTable{
    .get = &kvGet,
    .put = &kvPut,
    .del = &kvDel,
    .delPrefix = &kvDelPrefix,
    .deinit = &kvDeinit,
};

fn kvState(userdata: ?*anyopaque) *KvState {
    return @ptrCast(@alignCast(userdata.?));
}

fn unixNow(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn kvGet(userdata: ?*anyopaque, allocator: Allocator, key: []const u8) anyerror!?CacheValue {
    const state = kvState(userdata);
    const stored = (try state.kv.as(allocator, key, KvStored)) orelse return null;
    if (stored.expires_at != 0 and stored.expires_at <= unixNow(state.io)) {
        allocator.free(stored.body);
        allocator.free(stored.etag);
        if (stored.content_type) |ct| allocator.free(ct);
        state.kv.delete(key) catch {};
        return null;
    }
    return .{
        .body = stored.body,
        .etag = stored.etag,
        .content_type = stored.content_type,
    };
}

fn kvPut(userdata: ?*anyopaque, key: []const u8, value: CacheValue, ttl: u32) anyerror!void {
    const state = kvState(userdata);
    defer value.deinit(state.allocator);
    const expires_at: u64 = if (ttl == 0) 0 else unixNow(state.io) + ttl;
    try state.kv.putAs(key, KvStored{
        .body = value.body,
        .etag = value.etag,
        .content_type = value.content_type,
        .expires_at = expires_at,
    }, .{
        .ttl = if (ttl == 0) null else .fromSeconds(ttl),
    });
}

fn kvDel(userdata: ?*anyopaque, key: []const u8) bool {
    const state = kvState(userdata);
    state.kv.delete(key) catch return false;
    return true;
}

fn kvDelPrefix(userdata: ?*anyopaque, prefix: []const u8) usize {
    const state = kvState(userdata);
    const keys = state.kv.list(state.allocator, prefix) catch return 0;
    defer {
        for (keys) |k| state.allocator.free(k);
        state.allocator.free(keys);
    }
    var count: usize = 0;
    for (keys) |k| {
        state.kv.delete(k) catch continue;
        count += 1;
    }
    return count;
}

fn kvDeinit(userdata: ?*anyopaque) void {
    const state = kvState(userdata);
    state.allocator.destroy(state);
}
