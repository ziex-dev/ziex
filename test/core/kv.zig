const std = @import("std");
const zx = @import("zx");

const allocator = std.testing.allocator;

var kv_fs = zx.Kv.Fs{
    .io = std.testing.io,
    .subdir = "zig-out" ++ std.Io.Dir.path.sep_str ++ "test-data" ++ std.Io.Dir.path.sep_str ++ "kv",
};

const kv = kv_fs.kv();

const User = struct {
    id: u32,
    name: []const u8,
    active: bool,
};

const UserAlias = struct {
    id: u32,
    label: []const u8,
    active: bool,
};

fn uniqueLabel(comptime prefix: []const u8, buf: []u8) ![]const u8 {
    var source: std.Random.IoSource = .{ .io = std.testing.io };
    const value = source.interface().int(u64);
    return std.mem.print(buf, "{s}-{x}", .{ prefix, value });
}

fn freeUser(user: User) void {
    allocator.free(user.name);
}

test "put/get/delete roundtrip" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-default-key", &key_buf);
    const value = "hello from kv";

    defer kv.delete(key) catch {};

    try kv.put(key, value, .{});

    const found = (try kv.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(found);

    try std.testing.expectEqualStrings(value, found);

    try kv.delete(key);
    try std.testing.expect((try kv.get(std.testing.allocator, key)) == null);
}

test "list returns prefixed keys" {
    var prefix_buf: [64]u8 = undefined;
    const prefix = try uniqueLabel("kv-list-prefix", &prefix_buf);

    var key1_buf: [96]u8 = undefined;
    var key2_buf: [96]u8 = undefined;
    var other_key_buf: [96]u8 = undefined;

    const key1 = try std.mem.print(&key1_buf, "{s}-a", .{prefix});
    const key2 = try std.mem.print(&key2_buf, "{s}-b", .{prefix});
    const other_key = try uniqueLabel("kv-list-other", &other_key_buf);

    defer kv.delete(key1) catch {};
    defer kv.delete(key2) catch {};
    defer kv.delete(other_key) catch {};

    try kv.put(key1, "value-a", .{});
    try kv.put(key2, "value-b", .{});
    try kv.put(other_key, "value-c", .{});

    const keys = try kv.list(std.testing.allocator, prefix);
    defer {
        for (keys) |key| std.testing.allocator.free(key);
        std.testing.allocator.free(keys);
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
}

test "scoped namespaces are isolated" {
    var ns_buf: [64]u8 = undefined;
    const namespace = try uniqueLabel("kv-scope", &ns_buf);

    // Runtime namespace: set the field directly (scoped() takes a comptime literal).
    const scoped = zx.Kv{ .vtable = kv.vtable, .userdata = kv.userdata, .namespace = namespace };
    const key = "shared-key";

    defer scoped.delete(key) catch {};
    defer kv.delete(key) catch {};

    try scoped.put(key, "scoped-value", .{});
    try kv.put(key, "default-value", .{});

    const scoped_value = (try scoped.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(scoped_value);

    const default_value = (try kv.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(default_value);

    try std.testing.expectEqualStrings("scoped-value", scoped_value);
    try std.testing.expectEqualStrings("default-value", default_value);
}

test "scoped() enum literal routes to a distinct namespace" {
    const users = kv.scoped(.users);
    const key = "u-1";

    defer users.delete(key) catch {};
    defer kv.delete(key) catch {};

    try users.put(key, "in-users", .{});
    try kv.put(key, "in-default", .{});

    const from_users = (try users.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(from_users);
    const from_default = (try kv.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(from_default);

    try std.testing.expectEqualStrings("in-users", from_users);
    try std.testing.expectEqualStrings("in-default", from_default);
}

test "typed roundtrip" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-typed-key", &key_buf);

    defer kv.delete(key) catch {};

    try kv.putAs(key, User{
        .id = 42,
        .name = "nurul",
        .active = true,
    }, .{});

    const user = (try kv.as(allocator, key, User)).?;
    defer freeUser(user);

    try std.testing.expectEqual(@as(u32, 42), user.id);
    try std.testing.expectEqualStrings("nurul", user.name);
    try std.testing.expect(user.active);
}

test "as returns invalid type on schema mismatch" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-typed-mismatch", &key_buf);

    defer kv.delete(key) catch {};

    try kv.putAs(key, User{
        .id = 7,
        .name = "mismatch",
        .active = false,
    }, .{});

    try std.testing.expectError(error.InvalidType, kv.as(allocator, key, UserAlias));
}

test "scoped typed roundtrip" {
    var ns_buf: [64]u8 = undefined;
    var key_buf: [64]u8 = undefined;

    const namespace = try uniqueLabel("kv-typed-scope", &ns_buf);
    const key = try uniqueLabel("profile", &key_buf);
    const scoped = zx.Kv{ .vtable = kv.vtable, .userdata = kv.userdata, .namespace = namespace };

    defer scoped.delete(key) catch {};

    try scoped.putAs(key, User{
        .id = 99,
        .name = "scoped-user",
        .active = true,
    }, .{});

    const user = (try scoped.as(allocator, key, User)).?;
    defer freeUser(user);

    try std.testing.expectEqual(@as(u32, 99), user.id);
    try std.testing.expectEqualStrings("scoped-user", user.name);
    try std.testing.expect(user.active);
}

test "ttl entry is readable before it expires" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-ttl-live", &key_buf);
    defer kv.delete(key) catch {};

    try kv.put(key, "still here", .{ .ttl = .fromSeconds(60) });

    const found = (try kv.get(allocator, key)).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings("still here", found);
}

test "expired entry reads as missing and is left out of list" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-ttl-expired", &key_buf);
    defer kv.delete(key) catch {};

    try kv.put(key, "gone", .{ .ttl = .fromSeconds(0) });

    const keys = try kv.list(allocator, key);
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }
    try std.testing.expectEqual(@as(usize, 0), keys.len);
    try std.testing.expect((try kv.get(allocator, key)) == null);
}

test "values with newlines and metadata-like bytes roundtrip" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-raw-bytes", &key_buf);
    defer kv.delete(key) catch {};

    const value = "[1,99]\n[1,0]\nnot metadata\n\x00tail";
    try kv.put(key, value, .{ .ttl = .fromSeconds(60) });

    const found = (try kv.get(allocator, key)).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(value, found);
}

test "large values roundtrip" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-large", &key_buf);
    defer kv.delete(key) catch {};

    var value: [4096]u8 = undefined;
    for (&value, 0..) |*b, i| b.* = @truncate(i * 31);
    try kv.put(key, &value, .{});

    const found = (try kv.get(allocator, key)).?;
    defer allocator.free(found);
    try std.testing.expectEqualSlices(u8, &value, found);
}

test "file without a metadata line reads as missing" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-old-format", &key_buf);
    defer kv.delete(key) catch {};

    var name_buf: [128]u8 = undefined;
    const name = std.base64.url_safe_no_pad.Encoder.encode(&name_buf, key);
    var path_buf: [256]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}{s}default{s}{s}", .{ kv_fs.subdir, std.Io.Dir.path.sep_str, std.Io.Dir.path.sep_str, name });
    try kv.put(key, "placeholder", .{});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "plain value from an older format" });

    try std.testing.expect((try kv.get(allocator, key)) == null);
}

test "typed value from an older format is an invalid type" {
    var key_buf: [64]u8 = undefined;
    const key = try uniqueLabel("kv-old-typed", &key_buf);
    defer kv.delete(key) catch {};

    try kv.put(key, "[123,[1,\"name\",true]]", .{});
    try std.testing.expectError(error.InvalidType, kv.as(allocator, key, User));
}

test "meta line roundtrips and rejects bad input" {
    const Meta = zx.Kv.Meta;
    var buf: [Meta.max_len]u8 = undefined;
    const line = Meta.line(&buf, Meta.Expiry{ .expires_at = 1730000000 });
    try std.testing.expectEqualStrings("[1,1730000000]\n", line);

    const raw = "[1,42]\nvalue\nwith lines";
    const parsed = Meta.split(Meta.Typed, raw).?;
    try std.testing.expectEqual(@as(u64, 42), parsed.meta.hash);
    try std.testing.expectEqualStrings("value\nwith lines", parsed.rest);

    try std.testing.expect(Meta.split(Meta.Typed, "no newline") == null);
    try std.testing.expect(Meta.split(Meta.Typed, "[2,42]\nfuture version") == null);
    try std.testing.expect(Meta.split(Meta.Typed, "not zxon\nvalue") == null);
}

test "wasm ttl rounds sub-second up so it still expires" {
    const ttlSeconds = zx.Kv.Wasm.ttlSeconds;
    try std.testing.expectEqual(@as(u32, 1), ttlSeconds(.fromMilliseconds(500)));
    try std.testing.expectEqual(@as(u32, 1), ttlSeconds(.fromSeconds(1)));
    try std.testing.expectEqual(@as(u32, 2), ttlSeconds(.fromMilliseconds(1001)));
    try std.testing.expectEqual(@as(u32, 0), ttlSeconds(.fromSeconds(0)));
    try std.testing.expectEqual(@as(u32, 0), ttlSeconds(.fromSeconds(-5)));
}
