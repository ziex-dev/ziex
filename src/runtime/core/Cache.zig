const Cache = @This();

const std = @import("std");
const builtin = @import("builtin");

const Kv = @import("Kv.zig");

const Allocator = std.mem.Allocator;

pub const cachez = @import("Cache/Mem/cache.zig");

backend: Kv = Kv.failing,
namespace: []const u8 = "default",
allocator: std.mem.Allocator,
io: std.Io,
memory: ?*cachez.Cache(CacheEntry) = null,

pub const PutOptions = Kv.PutOptions;

pub const Error = error{
    Unavailable,
};

pub const Config = struct {
    max_size: u32 = 8000,
    segment_count: u16 = 8,
    gets_per_promote: u8 = 5,
    shrink_ratio: f32 = 0.2,
};

const CacheEntry = struct {
    bytes: []u8,

    pub fn removedFromCache(self: CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const StoredEntry = struct {
    expires_at: ?u64,
    payload: []const u8,
};

pub fn init(allocator: Allocator, io: std.Io, kv: Kv, config: Config) !Cache {
    const cachez_config = cachez.Config{
        .max_size = config.max_size,
        .segment_count = config.segment_count,
        .gets_per_promote = config.gets_per_promote,
        .shrink_ratio = config.shrink_ratio,
    };

    const memory = try allocator.create(cachez.Cache(CacheEntry));
    errdefer allocator.destroy(memory);
    memory.* = try cachez.Cache(CacheEntry).init(io, allocator, cachez_config);

    return .{
        .backend = kv,
        .namespace = "default",
        .allocator = allocator,
        .io = io,
        .memory = memory,
    };
}

pub fn deinit(self: *Cache) void {
    if (self.memory) |mem| {
        const allocator = mem.allocator;
        mem.deinit();
        allocator.destroy(mem);
        self.memory = null;
    }
}

pub fn scoped(self: Cache, comptime ns: @EnumLiteral()) Cache {
    return .{
        .backend = self.backend,
        .namespace = @tagName(ns),
        .allocator = self.allocator,
        .io = self.io,
        .memory = self.memory,
    };
}

fn boundBackend(self: Cache) Kv {
    return .{
        .vtable = self.backend.vtable,
        .userdata = self.backend.userdata,
        .namespace = if (self.namespace.len == 0) "default" else self.namespace,
    };
}

pub fn get(self: Cache, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const io = self.io;
    const memory = self.memory orelse return error.Unavailable;

    const scoped_key = try scopedKey(allocator, self.namespace, key);
    defer allocator.free(scoped_key);

    if (memory.get(scoped_key)) |entry| {
        defer entry.release();
        return @as(?[]u8, try allocator.dupe(u8, entry.value.bytes));
    }

    const backend = self.boundBackend();
    const encoded = (try backend.get(allocator, key)) orelse return null;
    defer allocator.free(encoded);

    const decoded = decodeStoredEntry(encoded) orelse {
        try backend.delete(key);
        _ = memory.del(scoped_key);
        return null;
    };
    if (isExpired(io, decoded.expires_at)) {
        try backend.delete(key);
        _ = memory.del(scoped_key);
        return null;
    }

    try putMemoryEntryLocked(self, scoped_key, decoded.payload, ttlFromExpiration(io, decoded.expires_at));
    return @as(?[]u8, try allocator.dupe(u8, decoded.payload));
}

pub fn as(self: Cache, allocator: std.mem.Allocator, key: []const u8, comptime T: type) !?T {
    const raw = (try self.get(allocator, key)) orelse return null;
    defer allocator.free(raw);
    return try Kv.decodeTyped(T, allocator, raw);
}

pub fn put(self: Cache, key: []const u8, value: []const u8, opts: PutOptions) !void {
    _ = self.memory orelse return error.Unavailable;

    const io = self.io;
    const allocator = self.allocator;
    const encoded = try encodeStoredEntry(io, allocator, value, opts);
    defer allocator.free(encoded);

    try self.boundBackend().put(key, encoded, .{});

    const scoped_key = try scopedKey(allocator, self.namespace, key);
    defer allocator.free(scoped_key);
    try putMemoryEntryLocked(self, scoped_key, value, ttlFromOptions(io, opts));
}

pub fn putAs(self: Cache, key: []const u8, value: anytype, opts: PutOptions) !void {
    _ = self.memory orelse return error.Unavailable;

    var writer = std.Io.Writer.Allocating.init(self.allocator);
    defer writer.deinit();
    try Kv.encodeTyped(&writer.writer, value);
    try self.put(key, writer.written(), opts);
}

/// Returns whether the key existed.
pub fn delete(self: Cache, key: []const u8) !bool {
    const memory = self.memory orelse return error.Unavailable;
    const allocator = self.allocator;
    const backend = self.boundBackend();

    const scoped_key = try scopedKey(allocator, self.namespace, key);
    defer allocator.free(scoped_key);
    const memory_deleted = memory.del(scoped_key);

    const existing = try backend.get(allocator, key);
    defer if (existing) |bytes| allocator.free(bytes);
    try backend.delete(key);
    return memory_deleted or existing != null;
}

pub fn list(self: Cache, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
    const io = self.io;
    const memory = self.memory orelse return error.Unavailable;
    const backend = self.boundBackend();
    const keys = try backend.list(allocator, prefix);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    var live_keys: std.ArrayList([]u8) = .empty;
    defer live_keys.deinit(allocator);

    for (keys) |key| {
        const encoded = (try backend.get(allocator, key)) orelse continue;
        defer allocator.free(encoded);

        const decoded = decodeStoredEntry(encoded) orelse {
            try backend.delete(key);
            continue;
        };
        if (isExpired(io, decoded.expires_at)) {
            try backend.delete(key);

            const scoped_key = try scopedKey(allocator, self.namespace, key);
            defer allocator.free(scoped_key);
            _ = memory.del(scoped_key);
            continue;
        }

        try live_keys.append(allocator, try allocator.dupe(u8, key));
    }

    return live_keys.toOwnedSlice(allocator);
}

pub fn deletePrefix(self: Cache, prefix: []const u8) !usize {
    const memory = self.memory orelse return error.Unavailable;
    const allocator = self.allocator;
    const backend = self.boundBackend();
    const keys = try backend.list(allocator, prefix);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    var deleted: usize = 0;
    for (keys) |key| {
        try backend.delete(key);

        const scoped_key = try scopedKey(allocator, self.namespace, key);
        defer allocator.free(scoped_key);
        _ = memory.del(scoped_key);
        deleted += 1;
    }

    return deleted;
}

fn scopedKey(allocator: Allocator, ns: []const u8, key: []const u8) ![]u8 {
    return allocator.print("{s}\x1f{s}", .{ ns, key });
}

/// A `Kv.Meta.Expiry` line followed by the payload.
fn encodeStoredEntry(io: std.Io, allocator: Allocator, payload: []const u8, opts: PutOptions) ![]u8 {
    const expires_at = try expirationFromOptions(io, opts);
    var line_buf: [Kv.Meta.max_len]u8 = undefined;
    const line = Kv.Meta.line(&line_buf, Kv.Meta.Expiry{ .expires_at = expires_at orelse 0 });
    const encoded = try allocator.alloc(u8, line.len + payload.len);
    @memcpy(encoded[0..line.len], line);
    @memcpy(encoded[line.len..], payload);
    return encoded;
}

/// Null for entries without a valid expiry line (e.g. written by an older format).
fn decodeStoredEntry(encoded: []const u8) ?StoredEntry {
    const entry = Kv.Meta.split(Kv.Meta.Expiry, encoded) orelse return null;
    const expires_at = entry.meta.expires_at;
    return .{
        .expires_at = if (expires_at == 0) null else expires_at,
        .payload = entry.rest,
    };
}

fn now(io: std.Io) u64 {
    if (comptime builtin.os.tag == .freestanding or builtin.os.tag == .wasi) return 0;
    const ts = std.Io.Timestamp.now(io, .real);
    return @as(u64, @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000)));
}

fn expirationFromOptions(io: std.Io, opts: PutOptions) !?u64 {
    const ttl = opts.ttl orelse return null;
    const secs = ttl.toSeconds();
    if (secs <= 0) return now(io);
    return now(io) + @as(u64, @intCast(secs));
}

fn ttlFromOptions(_: std.Io, opts: PutOptions) ?u32 {
    const ttl = opts.ttl orelse return null;
    const secs = ttl.toSeconds();
    if (secs <= 0) return 0;
    return clampTtl(@as(u64, @intCast(secs)));
}

fn ttlFromExpiration(io: std.Io, expires_at: ?u64) ?u32 {
    const expiration = expires_at orelse return null;
    const current_now = now(io);
    if (expiration <= current_now) return 0;
    return clampTtl(expiration - current_now);
}

fn clampTtl(ttl: u64) u32 {
    return std.math.cast(u32, ttl) orelse std.math.maxInt(u32);
}

fn isExpired(io: std.Io, expires_at: ?u64) bool {
    const expiration = expires_at orelse return false;
    return expiration <= now(io);
}

fn putMemoryEntryLocked(self: Cache, scoped_key: []const u8, value: []const u8, ttl_seconds: ?u32) !void {
    const io = self.io;
    const memory = self.memory orelse return error.Unavailable;
    const value_copy = try memory.allocator.dupe(u8, value);
    errdefer memory.allocator.free(value_copy);

    try memory.put(scoped_key, .{ .bytes = value_copy }, .{
        .ttl = cachezSafeTtl(io, ttl_seconds),
    });
}

fn cachezSafeTtl(io: std.Io, ttl_seconds: ?u32) u32 {
    const current_now = now(io);
    const max_u32 = std.math.maxInt(u32);
    if (current_now >= max_u32) return 0;

    const max_ttl = max_u32 - @as(u32, @intCast(current_now));
    return @min(ttl_seconds orelse max_ttl, max_ttl);
}

pub const failing: Cache = .{
    .allocator = .failing,
    .io = .failing,
    .backend = .failing,
};
