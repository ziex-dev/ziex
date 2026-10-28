const std = @import("std");
const zx = @import("zx");

const allocator = std.testing.allocator;

var cache_fs = zx.Kv.Fs{
    .io = std.testing.io,
    .subdir = "zig-out" ++ std.fs.path.sep_str ++ "test-data" ++ std.fs.path.sep_str ++ "cache",
};
var cache: zx.Cache = .failing;

fn scopedCache(namespace: []const u8) zx.Cache {
    return .{
        .backend = cache.backend,
        .namespace = namespace,
        .allocator = cache.allocator,
        .io = cache.io,
        .memory = cache.memory,
    };
}

const Profile = struct {
    id: u32,
    name: []const u8,
    active: bool,
};

const ProfileAlias = struct {
    id: u32,
    label: []const u8,
    active: bool,
};

const WorkerContext = struct {
    ns: []const u8,
    worker_id: usize,
    err: ?anyerror = null,
};

const worker_iterations = 100;

fn ensureCache() !void {
    cache = try zx.Cache.init(allocator, std.testing.io, cache_fs.kv(), .{
        .max_size = 4096,
        .segment_count = 8,
    });
}

fn cleanupCache() void {
    cache.deinit();
}

fn uniqueLabel(comptime prefix: []const u8, buf: []u8) ![]const u8 {
    var source: std.Random.IoSource = .{ .io = std.testing.io };
    const value = source.interface().int(u64);
    return std.fmt.bufPrint(buf, "{s}-{x}", .{ prefix, value });
}

fn freeProfile(profile: Profile) void {
    allocator.free(profile.name);
}

test "put/get/delete roundtrip" {
    try ensureCache();
    defer cleanupCache();

    var key_buf: [96]u8 = undefined;
    const key = try uniqueLabel("cache-roundtrip", &key_buf);

    defer _ = cache.delete(key) catch false;

    try cache.put(key, "cached value", .{ .ttl = .fromSeconds(30) });

    const found = (try cache.get(allocator, key)).?;
    defer allocator.free(found);

    try std.testing.expectEqualStrings("cached value", found);

    _ = try cache.delete(key);
    try std.testing.expect((try cache.get(allocator, key)) == null);
}

test "del reports whether key existed" {
    try ensureCache();
    defer cleanupCache();

    var key_buf: [96]u8 = undefined;
    const key = try uniqueLabel("cache-del", &key_buf);

    try std.testing.expect(!try cache.delete(key));

    try cache.put(key, "delete me", .{ .ttl = .fromSeconds(30) });
    try std.testing.expect(try cache.delete(key));
    try std.testing.expect(!try cache.delete(key));
}

test "put without expiration does not overflow memory ttl" {
    try ensureCache();
    defer cleanupCache();

    var key_buf: [96]u8 = undefined;
    const key = try uniqueLabel("cache-no-expiration", &key_buf);

    defer _ = cache.delete(key) catch false;

    try cache.put(key, "no-expiration", .{});

    const found = (try cache.get(allocator, key)).?;
    defer allocator.free(found);

    try std.testing.expectEqualStrings("no-expiration", found);
}

test "stress many entries without expiration" {
    try ensureCache();
    defer cleanupCache();

    var prefix_buf: [96]u8 = undefined;
    const prefix = try uniqueLabel("cache-stress", &prefix_buf);
    const scoped = scopedCache(prefix);

    defer _ = scoped.deletePrefix("") catch 0;

    var key_buf: [128]u8 = undefined;
    var value_buf: [128]u8 = undefined;

    for (0..512) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "stress-key-{d}", .{i});
        const value = try std.fmt.bufPrint(&value_buf, "stress-value-{d}", .{i});
        try scoped.put(key, value, .{});

        const found = (try scoped.get(allocator, key)).?;
        defer allocator.free(found);
        try std.testing.expectEqualStrings(value, found);
    }

    const keys = try scoped.list(allocator, "");
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 512), keys.len);
}

test "list and del prefix work for live entries" {
    try ensureCache();
    defer cleanupCache();

    var prefix_buf: [96]u8 = undefined;
    const prefix = try uniqueLabel("cache-prefix", &prefix_buf);

    var key1_buf: [128]u8 = undefined;
    var key2_buf: [128]u8 = undefined;
    var other_key_buf: [128]u8 = undefined;

    const key1 = try std.fmt.bufPrint(&key1_buf, "{s}-a", .{prefix});
    const key2 = try std.fmt.bufPrint(&key2_buf, "{s}-b", .{prefix});
    const other_key = try uniqueLabel("cache-other", &other_key_buf);

    defer _ = cache.deletePrefix(prefix) catch 0;
    defer _ = cache.delete(other_key) catch false;

    try cache.put(key1, "value-a", .{ .ttl = .fromSeconds(30) });
    try cache.put(key2, "value-b", .{ .ttl = .fromSeconds(30) });
    try cache.put(other_key, "value-c", .{ .ttl = .fromSeconds(30) });

    const keys = try cache.list(allocator, prefix);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    var saw_key1 = false;
    var saw_key2 = false;
    for (keys) |key| {
        try std.testing.expect(std.mem.startsWith(u8, key, prefix));
        if (std.mem.eql(u8, key, key1)) saw_key1 = true;
        if (std.mem.eql(u8, key, key2)) saw_key2 = true;
        try std.testing.expect(!std.mem.eql(u8, key, other_key));
    }

    try std.testing.expect(saw_key1);
    try std.testing.expect(saw_key2);
    try std.testing.expectEqual(@as(usize, 2), try scopedCache("default").deletePrefix(prefix));
    try std.testing.expect((try cache.get(allocator, key1)) == null);
    try std.testing.expect((try cache.get(allocator, key2)) == null);
}

test "scoped namespaces are isolated" {
    try ensureCache();
    defer cleanupCache();

    var ns_buf: [96]u8 = undefined;
    const namespace = try uniqueLabel("cache-scope", &ns_buf);
    const scoped = scopedCache(namespace);
    const key = "shared-key";

    defer _ = scoped.delete(key) catch false;
    defer _ = cache.delete(key) catch false;

    try scoped.put(key, "scoped-value", .{ .ttl = .fromSeconds(30) });
    try cache.put(key, "default-value", .{ .ttl = .fromSeconds(30) });

    const scoped_value = (try scoped.get(allocator, key)).?;
    defer allocator.free(scoped_value);

    const default_value = (try cache.get(allocator, key)).?;
    defer allocator.free(default_value);

    try std.testing.expectEqualStrings("scoped-value", scoped_value);
    try std.testing.expectEqualStrings("default-value", default_value);
}

test "typed roundtrip" {
    try ensureCache();
    defer cleanupCache();

    var key_buf: [96]u8 = undefined;
    const key = try uniqueLabel("cache-typed", &key_buf);

    defer _ = cache.delete(key) catch false;

    try cache.putAs(key, Profile{
        .id = 42,
        .name = "nurul",
        .active = true,
    }, .{ .ttl = .fromSeconds(30) });

    const profile = (try cache.as(allocator, key, Profile)).?;
    defer freeProfile(profile);

    try std.testing.expectEqual(@as(u32, 42), profile.id);
    try std.testing.expectEqualStrings("nurul", profile.name);
    try std.testing.expect(profile.active);
}

test "as returns invalid type on schema mismatch" {
    try ensureCache();
    defer cleanupCache();

    var key_buf: [96]u8 = undefined;
    const key = try uniqueLabel("cache-typed-mismatch", &key_buf);

    defer _ = cache.delete(key) catch false;

    try cache.putAs(key, Profile{
        .id = 7,
        .name = "mismatch",
        .active = false,
    }, .{ .ttl = .fromSeconds(30) });

    try std.testing.expectError(error.InvalidType, cache.as(allocator, key, ProfileAlias));
}

test "scoped typed roundtrip" {
    try ensureCache();
    defer cleanupCache();

    var ns_buf: [96]u8 = undefined;
    var key_buf: [96]u8 = undefined;

    const namespace = try uniqueLabel("cache-typed-scope", &ns_buf);
    const key = try uniqueLabel("profile", &key_buf);
    const scoped = scopedCache(namespace);

    defer _ = scoped.delete(key) catch false;

    try scoped.putAs(key, Profile{
        .id = 99,
        .name = "scoped-user",
        .active = true,
    }, .{ .ttl = .fromSeconds(30) });

    const profile = (try scoped.as(allocator, key, Profile)).?;
    defer freeProfile(profile);

    try std.testing.expectEqual(@as(u32, 99), profile.id);
    try std.testing.expectEqualStrings("scoped-user", profile.name);
    try std.testing.expect(profile.active);
}

test "expired entries are filtered from get and list" {
    try ensureCache();
    defer cleanupCache();

    var prefix_buf: [96]u8 = undefined;
    const prefix = try uniqueLabel("cache-expired", &prefix_buf);

    var expired_key_buf: [128]u8 = undefined;
    var live_key_buf: [128]u8 = undefined;

    const expired_key = try std.fmt.bufPrint(&expired_key_buf, "{s}-expired", .{prefix});
    const live_key = try std.fmt.bufPrint(&live_key_buf, "{s}-live", .{prefix});

    defer _ = cache.deletePrefix(prefix) catch 0;

    try cache.put(expired_key, "stale", .{ .ttl = .fromSeconds(0) });
    try cache.put(live_key, "fresh", .{ .ttl = .fromSeconds(30) });

    try std.testing.expect((try cache.get(allocator, expired_key)) == null);

    const keys = try cache.list(allocator, prefix);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings(live_key, keys[0]);
}

fn runConcurrentWorker(ctx: *WorkerContext) void {
    const scoped = scopedCache(ctx.ns);

    var key_buf: [96]u8 = undefined;
    var value_buf: [96]u8 = undefined;

    for (0..worker_iterations) |i| {
        const key = std.fmt.bufPrint(&key_buf, "worker-{d}-key-{d}", .{ ctx.worker_id, i }) catch {
            ctx.err = error.Unexpected;
            return;
        };
        const value = std.fmt.bufPrint(&value_buf, "value-{d}-{d}", .{ ctx.worker_id, i }) catch {
            ctx.err = error.Unexpected;
            return;
        };

        scoped.put(key, value, .{ .ttl = .fromSeconds(60) }) catch |err| {
            ctx.err = err;
            return;
        };

        const found = scoped.get(std.heap.page_allocator, key) catch |err| {
            ctx.err = err;
            return;
        };
        if (found) |bytes| {
            defer std.heap.page_allocator.free(bytes);
            if (!std.mem.eql(u8, bytes, value)) {
                ctx.err = error.Unexpected;
                return;
            }
        } else {
            ctx.err = error.Unexpected;
            return;
        }
    }
}

test "concurrent reads and writes are threadsafe" {
    try ensureCache();
    defer cleanupCache();

    var ns_buf: [96]u8 = undefined;
    const namespace = try uniqueLabel("cache-threadsafe", &ns_buf);
    const scoped = scopedCache(namespace);

    defer {
        _ = scoped.deletePrefix("") catch 0;
    }

    var workers = [_]WorkerContext{
        .{ .ns = namespace, .worker_id = 0 },
        .{ .ns = namespace, .worker_id = 1 },
        .{ .ns = namespace, .worker_id = 2 },
        .{ .ns = namespace, .worker_id = 3 },
        .{ .ns = namespace, .worker_id = 4 },
        .{ .ns = namespace, .worker_id = 5 },
        .{ .ns = namespace, .worker_id = 6 },
        .{ .ns = namespace, .worker_id = 7 },
    };
    var threads: [workers.len]std.Thread = undefined;

    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, runConcurrentWorker, .{worker});
    }

    for (threads, &workers) |thread, *worker| {
        thread.join();
        if (worker.err) |err| return err;
    }

    const keys = try scoped.list(allocator, "");
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, workers.len * worker_iterations), keys.len);
}
