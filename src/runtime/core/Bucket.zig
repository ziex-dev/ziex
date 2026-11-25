// S3-compatible object storage behind one interface: a directory natively
// (`Fs`), the edge host's bucket binding (`Wasm`, Cloudflare R2 as is), or any
// S3 API from any target (`S3`).
const Bucket = @This();

const std = @import("std");
const http = @import("http.zig");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const Fs = @import("Bucket/Fs.zig");
pub const Wasm = @import("Bucket/Wasm.zig");
pub const S3 = @import("Bucket/S3.zig");

pub const Header = http.Header;

pub const Provider = enum {
    fs,
    wasm,
    s3,

    pub fn Type(comptime provider: Provider) type {
        return switch (provider) {
            .fs => Fs,
            .wasm => Wasm,
            .s3 => S3,
        };
    }
};

pub const Error = error{
    Unavailable,
    InvalidKey,
    InvalidOptions,
    MissingCredentials,
    AccessDenied,
    StorageFailed,
    ApiError,
} || http.Client.Error;

// S3's limit, applied everywhere so code behaves the same on every backend.
pub const max_key_len = 1024;

pub const VTable = struct {
    head: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8) Error!?Object,
    get: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: GetOptions) Error!?Object,
    put: *const fn (userdata: ?*anyopaque, key: []const u8, body: []const u8, opts: PutOptions) Error!void,
    delete: *const fn (userdata: ?*anyopaque, key: []const u8) Error!void,
    list: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, opts: ListOptions) Error!List,
    open: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: GetOptions) Error!?*Reader,
    upload: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: PutOptions) Error!*Upload,
    presign: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: PresignOptions) Error![]u8,
};

pub const Meta = struct {
    key: []const u8,
    size: u64 = 0,
    // Without quotes.
    etag: []const u8 = "",
    // Unix milliseconds; 0 when unknown.
    last_modified: i64 = 0,
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    // Custom metadata, `x-amz-meta-*` on S3.
    metadata: []const Header = &.{},

    pub fn get(meta: Meta, name: []const u8) ?[]const u8 {
        for (meta.metadata) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

pub const Object = struct {
    meta: Meta,
    // Empty for `head`; only the requested bytes for a range.
    body: []const u8 = "",
    arena: *std.heap.ArenaAllocator,
    // A body the backend handed over instead of copying into `arena`.
    owned: []const u8 = &.{},

    pub fn deinit(o: Object) void {
        if (o.owned.len > 0) o.arena.child_allocator.free(o.owned);
        destroyArena(o.arena);
    }
};

pub const List = struct {
    objects: []const Meta,
    // Keys rolled up by `ListOptions.delimiter`, each ending with it.
    prefixes: []const []const u8,
    // Pass as `ListOptions.cursor` for the next page; null on the last one.
    cursor: ?[]const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(l: List) void {
        destroyArena(l.arena);
    }
};

pub const Range = struct {
    offset: u64 = 0,
    // To the end when null.
    length: ?u64 = null,
};

pub const GetOptions = struct {
    range: ?Range = null,

    pub fn validate(opts: GetOptions) Error!void {
        const r = opts.range orelse return;
        if (r.length) |l| if (l == 0 or r.offset > std.math.maxInt(u64) - l) return error.InvalidOptions;
    }
};

pub const PutOptions = struct {
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    metadata: []const Header = &.{},

    // A copy in `arena`, for backends that keep options past the call.
    pub fn dupe(opts: PutOptions, arena: std.mem.Allocator) error{OutOfMemory}!PutOptions {
        var owned = opts;
        inline for (.{ "content_type", "content_disposition", "content_encoding", "cache_control" }) |f| {
            if (@field(opts, f)) |v| @field(owned, f) = try arena.dupe(u8, v);
        }
        const metadata = try arena.alloc(Header, opts.metadata.len);
        for (metadata, opts.metadata) |*d, m| d.* = .{ .name = try arena.dupe(u8, m.name), .value = try arena.dupe(u8, m.value) };
        owned.metadata = metadata;
        return owned;
    }

    // Values become HTTP headers on S3, so CR/LF would inject new ones.
    pub fn validate(opts: PutOptions) Error!void {
        inline for (.{ "content_type", "content_disposition", "content_encoding", "cache_control" }) |f| {
            if (@field(opts, f)) |v| if (!validValue(v)) return error.InvalidOptions;
        }
        for (opts.metadata) |h| {
            if (h.name.len == 0 or !validValue(h.value)) return error.InvalidOptions;
            for (h.name) |c| if (!isTokenChar(c)) return error.InvalidOptions;
        }
    }
};

pub const ListOptions = struct {
    prefix: []const u8 = "",
    // Usually "/", to list one level like a directory.
    delimiter: ?[]const u8 = null,
    // From the previous page's `List.cursor`.
    cursor: ?[]const u8 = null,
    limit: u16 = 1000,
};

pub const PresignOptions = struct {
    method: http.Method = .GET,
    // Seconds, at most 7 days.
    expires: u32 = 3600,
    // GET only: overrides the response's headers.
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
};

// A streamed object body; `close` releases it.
pub const Reader = struct {
    meta: Meta,
    interface: *std.Io.Reader,
    arena: *std.heap.ArenaAllocator,
    close_fn: *const fn (r: *Reader) void,

    pub fn close(r: *Reader) void {
        const arena = r.arena;
        r.close_fn(r);
        destroyArena(arena);
    }
};

// A streamed upload. Write to `writer`; bytes go out in parts as its buffer
// fills, then `finish` commits the object or `abort` discards it. Either one
// frees the upload. `writer.flush` is a no-op.
pub const Upload = struct {
    writer: std.Io.Writer,
    vtable: *const UploadVTable,
    arena: *std.heap.ArenaAllocator,
    // The first failure while writing; `finish` returns it.
    err: ?Error = null,

    pub const UploadVTable = struct {
        // A full buffer; the slice is reused after this returns.
        part: *const fn (u: *Upload, bytes: []const u8) Error!void,
        // Whatever is left buffered, possibly empty.
        finish: *const fn (u: *Upload, rest: []const u8) Error!void,
        abort: *const fn (u: *Upload) void,
    };

    pub fn init(buffer: []u8, vtable: *const UploadVTable, arena: *std.heap.ArenaAllocator) Upload {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain, .flush = noFlush }, .buffer = buffer },
            .vtable = vtable,
            .arena = arena,
        };
    }

    pub fn finish(u: *Upload) Error!void {
        const arena = u.arena;
        defer destroyArena(arena);
        if (u.err) |err| {
            u.vtable.abort(u);
            return err;
        }
        u.vtable.finish(u, u.writer.buffered()) catch |err| {
            u.vtable.abort(u);
            return err;
        };
    }

    pub fn abort(u: *Upload) void {
        const arena = u.arena;
        u.vtable.abort(u);
        destroyArena(arena);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const u: *Upload = @alignCast(@fieldParentPtr("writer", w));
        if (u.err != null) return error.WriteFailed;
        if (w.end == w.buffer.len) {
            u.vtable.part(u, w.buffer) catch |err| {
                u.err = err;
                return error.WriteFailed;
            };
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const k = fill(w, bytes);
            n += k;
            if (k < bytes.len) return n;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            const k = fill(w, last);
            n += k;
            if (k < last.len) return n;
        }
        return n;
    }

    fn fill(w: *std.Io.Writer, bytes: []const u8) usize {
        const k = @min(bytes.len, w.buffer.len - w.end);
        @memcpy(w.buffer[w.end..][0..k], bytes[0..k]);
        w.end += k;
        return k;
    }

    fn noFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};

pub fn head(b: Bucket, gpa: std.mem.Allocator, key: []const u8) Error!?Object {
    try validateKey(key);
    return b.vtable.head(b.userdata, gpa, key);
}

pub fn exists(b: Bucket, gpa: std.mem.Allocator, key: []const u8) Error!bool {
    const obj = try b.head(gpa, key) orelse return false;
    obj.deinit();
    return true;
}

pub fn get(b: Bucket, gpa: std.mem.Allocator, key: []const u8, opts: GetOptions) Error!?Object {
    try validateKey(key);
    try opts.validate();
    return b.vtable.get(b.userdata, gpa, key, opts);
}

pub fn put(b: Bucket, key: []const u8, body: []const u8, opts: PutOptions) Error!void {
    try validateKey(key);
    try opts.validate();
    return b.vtable.put(b.userdata, key, body, opts);
}

// Succeeds when the key doesn't exist.
pub fn delete(b: Bucket, key: []const u8) Error!void {
    try validateKey(key);
    return b.vtable.delete(b.userdata, key);
}

// Keys in ascending order, one page at a time.
pub fn list(b: Bucket, gpa: std.mem.Allocator, opts: ListOptions) Error!List {
    if (opts.limit == 0 or opts.limit > 1000) return error.InvalidOptions;
    if (opts.delimiter) |d| if (d.len == 0) return error.InvalidOptions;
    return b.vtable.list(b.userdata, gpa, opts);
}

pub fn open(b: Bucket, gpa: std.mem.Allocator, key: []const u8, opts: GetOptions) Error!?*Reader {
    try validateKey(key);
    try opts.validate();
    return b.vtable.open(b.userdata, gpa, key, opts);
}

pub fn upload(b: Bucket, gpa: std.mem.Allocator, key: []const u8, opts: PutOptions) Error!*Upload {
    try validateKey(key);
    try opts.validate();
    return b.vtable.upload(b.userdata, gpa, key, opts);
}

// A URL that grants `opts.method` on `key` without credentials; S3 only.
pub fn presign(b: Bucket, gpa: std.mem.Allocator, key: []const u8, opts: PresignOptions) Error![]u8 {
    try validateKey(key);
    if (opts.expires == 0 or opts.expires > 7 * 24 * 3600) return error.InvalidOptions;
    inline for (.{ "content_type", "content_disposition" }) |f| {
        if (@field(opts, f)) |v| if (!validValue(v)) return error.InvalidOptions;
    }
    return b.vtable.presign(b.userdata, gpa, key, opts);
}

pub fn validateKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > max_key_len) return error.InvalidKey;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
}

fn validValue(v: []const u8) bool {
    return std.mem.indexOfAny(u8, v, "\r\n\x00") == null;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn createArena(gpa: std.mem.Allocator) Error!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return arena;
}

pub fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const gpa = arena.child_allocator;
    arena.deinit();
    gpa.destroy(arena);
}

fn failingHead(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) Error!?Object {
    return error.Unavailable;
}
fn failingGet(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: GetOptions) Error!?Object {
    return error.Unavailable;
}
fn failingPut(_: ?*anyopaque, _: []const u8, _: []const u8, _: PutOptions) Error!void {
    return error.Unavailable;
}
fn failingDelete(_: ?*anyopaque, _: []const u8) Error!void {
    return error.Unavailable;
}
fn failingList(_: ?*anyopaque, _: std.mem.Allocator, _: ListOptions) Error!List {
    return error.Unavailable;
}
fn failingOpen(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: GetOptions) Error!?*Reader {
    return error.Unavailable;
}
fn failingUpload(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: PutOptions) Error!*Upload {
    return error.Unavailable;
}
pub fn unavailablePresign(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: PresignOptions) Error![]u8 {
    return error.Unavailable;
}

pub const failing_vtable = VTable{
    .head = &failingHead,
    .get = &failingGet,
    .put = &failingPut,
    .delete = &failingDelete,
    .list = &failingList,
    .open = &failingOpen,
    .upload = &failingUpload,
    .presign = &unavailablePresign,
};

pub const failing = Bucket{ .vtable = &failing_vtable };
