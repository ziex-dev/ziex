const Fs = @This();

const std = @import("std");
const Kv = @import("../Kv.zig");

io: std.Io,
subdir: []const u8,

/// Each file is a `Kv.Meta.Expiry` line followed by the raw value.
fn get(userdata: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const f: *Fs = @ptrCast(@alignCast(userdata));
    var buf: [1024]u8 = undefined;
    const path = keyPath(f.subdir, ns, key, &buf) orelse return null;

    var file = std.Io.Dir.cwd().openFile(f.io, path, .{}) catch return null;
    defer file.close(f.io);

    // One read covers the metadata line and, for small values, the value itself.
    var head: [512]u8 = undefined;
    const head_len = file.readPositionalAll(f.io, &head, 0) catch return null;
    const entry = f.liveEntry(path, head[0..head_len]) orelse return null;
    const offset = head_len - entry.rest.len;

    const total = file.length(f.io) catch return null;
    if (total > max_value_len) return null;
    const value = try allocator.alloc(u8, @intCast(total - offset));
    errdefer allocator.free(value);
    if (total <= head_len) {
        @memcpy(value, entry.rest);
    } else {
        const n = file.readPositionalAll(f.io, value, offset) catch return null;
        if (n != value.len) return error.GetFailed;
    }
    return value;
}

fn put(userdata: ?*anyopaque, ns: []const u8, key: []const u8, value: []const u8, opts: Kv.PutOptions) !void {
    const f: *Fs = @ptrCast(@alignCast(userdata));
    var buf: [1024]u8 = undefined;
    const path = keyPath(f.subdir, ns, key, &buf) orelse return error.KeyTooLong;

    const expires_at: u64 = if (opts.ttl) |ttl| @intCast(@max(0, f.nowSeconds() + ttl.toSeconds())) else 0;
    var line_buf: [Kv.Meta.max_len]u8 = undefined;
    const line = Kv.Meta.line(&line_buf, Kv.Meta.Expiry{ .expires_at = expires_at });

    var file = try std.Io.Dir.cwd().createFileAtomic(f.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer file.deinit(f.io);
    try file.file.writeStreamingAll(f.io, line);
    try file.file.writeStreamingAll(f.io, value);
    try file.replace(f.io);
}

fn delete(userdata: ?*anyopaque, ns: []const u8, key: []const u8) !void {
    const f: *Fs = @ptrCast(@alignCast(userdata));
    var buf: [1024]u8 = undefined;
    const path = keyPath(f.subdir, ns, key, &buf) orelse return;
    std.Io.Dir.cwd().deleteFile(f.io, path) catch {};
}

const max_value_len = 10 * 1024 * 1024;

/// Parses the expiry line from the start of a file. Expired or unreadable
/// entries (including files from before this format) are deleted.
fn liveEntry(f: *Fs, path: []const u8, head: []const u8) ?Kv.Meta.Split(Kv.Meta.Expiry) {
    const entry = Kv.Meta.split(Kv.Meta.Expiry, head) orelse {
        std.Io.Dir.cwd().deleteFile(f.io, path) catch {};
        return null;
    };
    const expires_at = entry.meta.expires_at;
    if (expires_at != 0 and f.nowSeconds() >= @as(i64, @intCast(expires_at))) {
        std.Io.Dir.cwd().deleteFile(f.io, path) catch {};
        return null;
    }
    return entry;
}

fn isLive(f: *Fs, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(f.io, path, .{}) catch return false;
    defer file.close(f.io);
    var head: [Kv.Meta.max_len]u8 = undefined;
    const n = file.readPositionalAll(f.io, &head, 0) catch return false;
    return f.liveEntry(path, head[0..n]) != null;
}

fn nowSeconds(f: *Fs) i64 {
    return std.Io.Timestamp.now(f.io, .real).toSeconds();
}

fn list(userdata: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
    const f: *Fs = @ptrCast(@alignCast(userdata));
    var dir_buf: [256]u8 = undefined;
    const dir_path = nsDir(f.subdir, ns, &dir_buf) orelse return &[_][]u8{};
    var dir = std.Io.Dir.cwd().openDir(f.io, dir_path, .{ .iterate = true }) catch return &[_][]u8{};
    defer dir.close(f.io);
    var keys = std.ArrayList([]u8).empty;
    var iter = dir.iterate();
    while (try iter.next(f.io)) |entry| {
        if (entry.kind != .file) continue;
        const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(entry.name) catch continue;
        const key = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(key);
        std.base64.url_safe_no_pad.Decoder.decode(key, entry.name) catch {
            allocator.free(key);
            continue;
        };
        var path_buf: [1024]u8 = undefined;
        const matches = prefix.len == 0 or std.mem.startsWith(u8, key, prefix);
        const path = keyPath(f.subdir, ns, key, &path_buf);
        if (matches and path != null and f.isLive(path.?)) {
            try keys.append(allocator, key);
        } else {
            allocator.free(key);
        }
    }
    return keys.toOwnedSlice(allocator);
}

fn keyPath(base: []const u8, ns: []const u8, key: []const u8, buf: *[1024]u8) ?[]u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(key.len);
    // "<base>/<ns>/<encoded_key>"
    const needed = base.len + 1 + ns.len + 1 + encoded_len;
    if (needed > buf.len) return null;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..base.len], base);
    pos += base.len;
    buf[pos] = std.fs.path.sep;
    pos += 1;
    @memcpy(buf[pos..][0..ns.len], ns);
    pos += ns.len;
    buf[pos] = std.fs.path.sep;
    pos += 1;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(buf[pos..], key);
    return buf[0 .. pos + encoded.len];
}

fn nsDir(base: []const u8, ns: []const u8, buf: *[256]u8) ?[]u8 {
    const needed = base.len + 1 + ns.len;
    if (needed > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = std.fs.path.sep;
    @memcpy(buf[base.len + 1 ..][0..ns.len], ns);
    return buf[0..needed];
}

pub fn kv(fs: *Fs) Kv {
    return Kv{
        .userdata = fs,
        .vtable = &.{
            .get = &get,
            .put = &put,
            .delete = &delete,
            .list = &list,
        },
    };
}
