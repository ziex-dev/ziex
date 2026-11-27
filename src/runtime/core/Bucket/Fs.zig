// Objects as files under `root`. Each key segment is a directory, percent-encoded
// so any key is safe: `.` is always encoded, so names never collide with the
// `.o` (object) and `.m` (metadata, JSON) suffixes, and `..` can't escape.
const Fs = @This();

const std = @import("std");
const Bucket = @import("../Bucket.zig");

const Md5 = std.crypto.hash.Md5;

io: std.Io,
root: []const u8,
// Write buffer for uploads; also the most a single write reaches the disk at.
upload_buffer_len: usize = 64 * 1024,

pub fn bucket(fs: *Fs) Bucket {
    return .{ .userdata = fs, .vtable = &.{
        .head = &head,
        .get = &get,
        .put = &put,
        .delete = &delete,
        .list = &list,
        .open = &open,
        .upload = &upload,
        .presign = &Bucket.unavailablePresign,
    } };
}

fn from(userdata: ?*anyopaque) *Fs {
    return @ptrCast(@alignCast(userdata));
}

const object_ext = ".o";
const meta_ext = ".m";
// Encoded segments stay under common 255-byte name limits with a suffix.
const max_segment_len = 250;

const Sidecar = struct {
    etag: []const u8 = "",
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    metadata: []const Bucket.Header = &.{},
};

// --- Paths --- //

fn encodeSegment(w: *std.Io.Writer, segment: []const u8) std.Io.Writer.Error!void {
    if (segment.len == 0) return w.writeByte('%');
    for (segment) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn decodeSegment(w: *std.Io.Writer, name: []const u8) !void {
    if (std.mem.eql(u8, name, "%")) return;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] == '%') {
            if (i + 3 > name.len) return error.InvalidName;
            try w.writeByte(std.fmt.parseInt(u8, name[i + 1 .. i + 3], 16) catch return error.InvalidName);
            i += 3;
        } else {
            try w.writeByte(name[i]);
            i += 1;
        }
    }
}

// `<root>/<seg>/…/<last><ext>`.
fn path(fs: *const Fs, arena: std.mem.Allocator, key: []const u8, ext: []const u8) Bucket.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(fs.root) catch return error.OutOfMemory;
    var it = std.mem.splitScalar(u8, key, '/');
    while (it.next()) |segment| {
        w.writeByte(std.Io.Dir.path.sep) catch return error.OutOfMemory;
        const start = w.end;
        encodeSegment(w, segment) catch return error.OutOfMemory;
        if (w.end - start > max_segment_len) return error.InvalidKey;
    }
    w.writeAll(ext) catch return error.OutOfMemory;
    return out.written();
}

// The directory holding every key that starts with `prefix`, and that prefix as a key.
fn prefixDir(fs: *const Fs, arena: std.mem.Allocator, prefix: []const u8) Bucket.Error!struct { dir: []const u8, key: []const u8 } {
    const slash = std.mem.findScalarLast(u8, prefix, '/') orelse return .{ .dir = fs.root, .key = "" };
    const key = prefix[0 .. slash + 1];
    const dir = try fs.path(arena, key[0..slash], "");
    return .{ .dir = dir, .key = key };
}

// --- Metadata --- //

fn readSidecar(fs: *Fs, arena: std.mem.Allocator, key: []const u8) Bucket.Error!Sidecar {
    const p = try fs.path(arena, key, meta_ext);
    const raw = std.Io.Dir.cwd().readFileAlloc(fs.io, p, arena, .limited(1024 * 1024)) catch return .{};
    return std.json.parseFromSliceLeaky(Sidecar, arena, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn writeSidecar(fs: *Fs, arena: std.mem.Allocator, key: []const u8, etag: []const u8, opts: Bucket.PutOptions) Bucket.Error!void {
    const json = try std.json.Stringify.valueAlloc(arena, Sidecar{
        .etag = etag,
        .content_type = opts.content_type,
        .content_disposition = opts.content_disposition,
        .content_encoding = opts.content_encoding,
        .cache_control = opts.cache_control,
        .metadata = opts.metadata,
    }, .{ .emit_null_optional_fields = false });
    try fs.writeAtomic(try fs.path(arena, key, meta_ext), json);
}

fn writeAtomic(fs: *Fs, p: []const u8, bytes: []const u8) Bucket.Error!void {
    var file = std.Io.Dir.cwd().createFileAtomic(fs.io, p, .{ .make_path = true, .replace = true }) catch return error.StorageFailed;
    defer file.deinit(fs.io);
    file.file.writeStreamingAll(fs.io, bytes) catch return error.StorageFailed;
    file.replace(fs.io) catch return error.StorageFailed;
}

// Meta for an existing object, or null.
fn stat(fs: *Fs, arena: std.mem.Allocator, key: []const u8) Bucket.Error!?Bucket.Meta {
    const p = try fs.path(arena, key, object_ext);
    const st = std.Io.Dir.cwd().statFile(fs.io, p, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => error.StorageFailed,
    };
    if (st.kind != .file) return null;
    const side = try fs.readSidecar(arena, key);
    return .{
        .key = try arena.dupe(u8, key),
        .size = st.size,
        .etag = side.etag,
        .last_modified = @intCast(@divFloor(st.mtime.toNanoseconds(), std.time.ns_per_ms)),
        .content_type = side.content_type,
        .content_disposition = side.content_disposition,
        .content_encoding = side.content_encoding,
        .cache_control = side.cache_control,
        .metadata = side.metadata,
    };
}

fn md5Hex(bytes: []const u8) [32]u8 {
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// Byte span of `range` in an object of `size`; S3 rejects a start at or past the end.
fn span(size: u64, range: ?Bucket.Range) Bucket.Error!struct { offset: u64, len: u64 } {
    const r = range orelse return .{ .offset = 0, .len = size };
    if (r.offset >= size) return error.InvalidOptions;
    const rest = size - r.offset;
    return .{ .offset = r.offset, .len = if (r.length) |l| @min(l, rest) else rest };
}

// --- Bucket --- //

fn head(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8) Bucket.Error!?Bucket.Object {
    const fs = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const meta = try fs.stat(arena.allocator(), key) orelse {
        Bucket.destroyArena(arena);
        return null;
    };
    return .{ .meta = meta, .arena = arena };
}

fn get(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?Bucket.Object {
    const fs = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const meta = try fs.stat(a, key) orelse {
        Bucket.destroyArena(arena);
        return null;
    };
    var file = std.Io.Dir.cwd().openFile(fs.io, try fs.path(a, key, object_ext), .{}) catch return error.StorageFailed;
    defer file.close(fs.io);

    const s = try span(meta.size, opts.range);
    const body = try a.alloc(u8, @intCast(s.len));
    const n = file.readPositionalAll(fs.io, body, s.offset) catch return error.StorageFailed;
    return .{ .meta = meta, .body = body[0..n], .arena = arena };
}

fn put(userdata: ?*anyopaque, key: []const u8, body: []const u8, opts: Bucket.PutOptions) Bucket.Error!void {
    const fs = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try fs.writeAtomic(try fs.path(arena, key, object_ext), body);
    try fs.writeSidecar(arena, key, &md5Hex(body), opts);
}

fn delete(userdata: ?*anyopaque, key: []const u8) Bucket.Error!void {
    const fs = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    const object = try fs.path(arena, key, object_ext);
    cwd.deleteFile(fs.io, object) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return error.StorageFailed,
    };
    cwd.deleteFile(fs.io, try fs.path(arena, key, meta_ext)) catch {};

    // Drops directories the key leaves empty, up to `root`.
    var dir = std.Io.Dir.path.dirname(object) orelse return;
    while (dir.len > fs.root.len) : (dir = std.Io.Dir.path.dirname(dir) orelse return) {
        cwd.deleteDir(fs.io, dir) catch return;
    }
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// Walks the prefix's directory, sorts, then pages like S3: the cursor is the last
// key returned, and a rolled-up prefix consumes every key under it.
fn list(userdata: ?*anyopaque, gpa: std.mem.Allocator, opts: Bucket.ListOptions) Bucket.Error!Bucket.List {
    const fs = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var keys: std.ArrayList([]const u8) = .empty;
    const base = try fs.prefixDir(a, opts.prefix);
    walk: {
        var dir = std.Io.Dir.cwd().openDir(fs.io, base.dir, .{ .iterate = true }) catch break :walk;
        defer dir.close(fs.io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(fs.io) catch return error.StorageFailed) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, object_ext)) continue;
            const key = decodeKey(a, base.key, entry.path[0 .. entry.path.len - object_ext.len]) catch continue;
            if (std.mem.startsWith(u8, key, opts.prefix)) try keys.append(a, key);
        }
    }
    std.mem.sort([]const u8, keys.items, {}, lessString);

    var objects: std.ArrayList(Bucket.Meta) = .empty;
    var prefixes: std.ArrayList([]const u8) = .empty;
    var last: ?[]const u8 = null;
    var i: usize = 0;
    while (i < keys.items.len) {
        const key = keys.items[i];
        if (opts.cursor) |c| if (!std.mem.lessThan(u8, c, key)) {
            i += 1;
            continue;
        };
        if (objects.items.len + prefixes.items.len >= opts.limit) break;

        if (opts.delimiter) |d| if (std.mem.find(u8, key[opts.prefix.len..], d)) |at| {
            const rolled = key[0 .. opts.prefix.len + at + d.len];
            try prefixes.append(a, rolled);
            while (i < keys.items.len and std.mem.startsWith(u8, keys.items[i], rolled)) : (i += 1) last = keys.items[i];
            continue;
        };
        if (try fs.stat(a, key)) |meta| try objects.append(a, meta);
        last = key;
        i += 1;
    }

    return .{
        .objects = objects.items,
        .prefixes = prefixes.items,
        .cursor = if (i < keys.items.len) last else null,
        .arena = arena,
    };
}

// `base` plus the walked relative path, decoded segment by segment.
fn decodeKey(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(base);
    var it = std.mem.splitScalar(u8, rel, std.Io.Dir.path.sep);
    var first = true;
    while (it.next()) |segment| {
        if (!first) try out.writer.writeByte('/');
        first = false;
        try decodeSegment(&out.writer, segment);
    }
    return out.written();
}

// --- Streaming --- //

const Stream = struct {
    reader: Bucket.Reader,
    file: std.Io.File,
    io: std.Io,
    file_reader: std.Io.File.Reader,
    limited: std.Io.Reader.Limited,

    fn close(r: *Bucket.Reader) void {
        const st: *Stream = @fieldParentPtr("reader", r);
        st.file.close(st.io);
    }
};

fn open(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?*Bucket.Reader {
    const fs = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const meta = try fs.stat(a, key) orelse {
        Bucket.destroyArena(arena);
        return null;
    };
    const s = try span(meta.size, opts.range);

    const st = try a.create(Stream);
    st.io = fs.io;
    st.file = std.Io.Dir.cwd().openFile(fs.io, try fs.path(a, key, object_ext), .{}) catch return error.StorageFailed;
    errdefer st.file.close(fs.io);
    st.file_reader = st.file.reader(fs.io, &.{});
    st.file_reader.seekTo(s.offset) catch return error.StorageFailed;
    st.limited = .init(&st.file_reader.interface, .limited64(s.len), try a.alloc(u8, 64 * 1024));
    st.reader = .{ .meta = meta, .interface = &st.limited.interface, .arena = arena, .close_fn = Stream.close };
    return &st.reader;
}

// Streams into a temporary file that replaces the object on `finish`.
const Upload = struct {
    upload: Bucket.Upload,
    fs: *Fs,
    key: []const u8,
    opts: Bucket.PutOptions,
    file: std.Io.File.Atomic,
    // Set once `file` is released.
    closed: bool = false,
    md5: Md5,

    const vtable: Bucket.Upload.UploadVTable = .{ .part = part, .finish = finish, .abort = abort };

    fn part(u: *Bucket.Upload, bytes: []const u8) Bucket.Error!void {
        const up: *Upload = @fieldParentPtr("upload", u);
        up.file.file.writeStreamingAll(up.fs.io, bytes) catch return error.StorageFailed;
        up.md5.update(bytes);
    }

    fn finish(u: *Bucket.Upload, rest: []const u8) Bucket.Error!void {
        const up: *Upload = @fieldParentPtr("upload", u);
        try part(u, rest);
        var digest: [Md5.digest_length]u8 = undefined;
        up.md5.final(&digest);
        up.file.replace(up.fs.io) catch return error.StorageFailed;
        up.file.deinit(up.fs.io);
        up.closed = true;
        try up.fs.writeSidecar(u.arena.allocator(), up.key, &std.fmt.bytesToHex(digest, .lower), up.opts);
    }

    fn abort(u: *Bucket.Upload) void {
        const up: *Upload = @fieldParentPtr("upload", u);
        if (!up.closed) up.file.deinit(up.fs.io);
    }
};

fn upload(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.PutOptions) Bucket.Error!*Bucket.Upload {
    const fs = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const up = try a.create(Upload);
    up.* = .{
        .upload = .init(try a.alloc(u8, fs.upload_buffer_len), &Upload.vtable, arena),
        .fs = fs,
        .key = try a.dupe(u8, key),
        .opts = try opts.dupe(a),
        .file = std.Io.Dir.cwd().createFileAtomic(fs.io, try fs.path(a, key, object_ext), .{ .make_path = true, .replace = true }) catch return error.StorageFailed,
        .md5 = .init(.{}),
    };
    return &up.upload;
}
