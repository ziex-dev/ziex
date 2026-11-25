// Objects through the edge host's bucket binding, e.g. `new Ziex({ bucket: "BUCKET" })`.
// The binding has Cloudflare R2's shape, so an R2 binding works as is and any
// other runtime can provide an object with the same methods.
const Wasm = @This();

const std = @import("std");
const Bucket = @import("../Bucket.zig");
const host = @import("../../wasm/imports.zig");

// No host natively, so every call fails there without touching wasm-only code.
const is_wasm = @import("builtin").cpu.arch.isWasm();

binding: []const u8 = "default",
// R2, like S3, needs at least 5 MiB for every upload part but the last.
part_size: usize = 5 * 1024 * 1024,

pub fn bucket(w: *Wasm) Bucket {
    return .{ .userdata = w, .vtable = &.{
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

fn from(userdata: ?*anyopaque) *Wasm {
    return @ptrCast(@alignCast(userdata));
}

// Host results below zero; the host logs the cause of `failed`.
const not_found: i32 = -1;
const failed: i32 = -3;

fn check(n: i32) Bucket.Error!void {
    if (n >= 0) return;
    if (n == host.missing or n == host.unsupported) return error.Unavailable;
    return error.StorageFailed;
}

// --- Wire --- //

// Objects as the host reports them; mirrored in `pkg/ziex/src/runtime/bucket.ts`.
pub const WireMeta = struct {
    key: []const u8,
    size: u64 = 0,
    etag: []const u8 = "",
    lastModified: i64 = 0,
    contentType: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    metadata: []const [2][]const u8 = &.{},

    fn meta(m: WireMeta, arena: std.mem.Allocator) error{OutOfMemory}!Bucket.Meta {
        const custom = try arena.alloc(Bucket.Header, m.metadata.len);
        for (custom, m.metadata) |*d, kv| d.* = .{ .name = kv[0], .value = kv[1] };
        return .{
            .key = m.key,
            .size = m.size,
            .etag = m.etag,
            .last_modified = m.lastModified,
            .content_type = m.contentType,
            .content_disposition = m.contentDisposition,
            .content_encoding = m.contentEncoding,
            .cache_control = m.cacheControl,
            .metadata = custom,
        };
    }
};

const WireList = struct {
    objects: []const WireMeta = &.{},
    prefixes: []const []const u8 = &.{},
    cursor: ?[]const u8 = null,
};

const PutRequest = struct {
    key: []const u8,
    contentType: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    metadata: []const [2][]const u8 = &.{},

    fn init(arena: std.mem.Allocator, key: []const u8, opts: Bucket.PutOptions) error{OutOfMemory}!PutRequest {
        const metadata = try arena.alloc([2][]const u8, opts.metadata.len);
        for (metadata, opts.metadata) |*d, h| d.* = .{ h.name, h.value };
        return .{
            .key = key,
            .contentType = opts.content_type,
            .contentDisposition = opts.content_disposition,
            .contentEncoding = opts.content_encoding,
            .cacheControl = opts.cache_control,
            .metadata = metadata,
        };
    }
};

const GetRequest = struct {
    key: []const u8,
    range: ?struct { offset: u64, length: ?u64 = null } = null,

    fn init(key: []const u8, opts: Bucket.GetOptions) GetRequest {
        const r = opts.range orelse return .{ .key = key };
        return .{ .key = key, .range = .{ .offset = r.offset, .length = r.length } };
    }
};

fn encode(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

fn parse(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) Bucket.Error!T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        error.InvalidResponse;
}

// --- Bucket --- //

fn head(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8) Bucket.Error!?Bucket.Object {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    var out: [*]u8 = undefined;
    const n = host.wait(.bucket_head, .{ w.binding, key, &out });
    if (n == not_found) return null;
    try check(n);
    const raw = host.owned(out, n);
    defer host.free(raw);

    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const m = try parse(WireMeta, arena.allocator(), raw);
    return .{ .meta = try m.meta(arena.allocator()), .arena = arena };
}

// The host answers with `[u32 meta length][meta JSON][body]`.
fn get(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?Bucket.Object {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var out: [*]u8 = undefined;
    const n = host.wait(.bucket_get, .{ w.binding, try encode(a, GetRequest.init(key, opts)), &out });
    if (n == not_found) {
        Bucket.destroyArena(arena);
        return null;
    }
    try check(n);
    if (n < 4) return error.InvalidResponse;
    const raw = host.owned(out, n);
    defer host.free(raw);

    const meta_len = std.mem.readInt(u32, raw[0..4], .little);
    if (4 + @as(usize, meta_len) > raw.len) return error.InvalidResponse;
    const m = try parse(WireMeta, a, raw[4..][0..meta_len]);
    return .{ .meta = try m.meta(a), .body = try a.dupe(u8, raw[4 + meta_len ..]), .arena = arena };
}

fn put(userdata: ?*anyopaque, key: []const u8, body: []const u8, opts: Bucket.PutOptions) Bucket.Error!void {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(host.wait(.bucket_put, .{ w.binding, try encode(arena, try PutRequest.init(arena, key, opts)), body }));
}

fn delete(userdata: ?*anyopaque, key: []const u8) Bucket.Error!void {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    try check(host.wait(.bucket_delete, .{ w.binding, key }));
}

fn list(userdata: ?*anyopaque, gpa: std.mem.Allocator, opts: Bucket.ListOptions) Bucket.Error!Bucket.List {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const req = try encode(a, .{ .prefix = opts.prefix, .delimiter = opts.delimiter, .cursor = opts.cursor, .limit = opts.limit });
    var out: [*]u8 = undefined;
    const n = host.wait(.bucket_list, .{ w.binding, req, &out });
    try check(n);
    if (n == 0) return error.InvalidResponse;
    const raw = host.owned(out, n);
    defer host.free(raw);

    const wire = try parse(WireList, a, raw);
    const objects = try a.alloc(Bucket.Meta, wire.objects.len);
    for (objects, wire.objects) |*d, m| d.* = try m.meta(a);
    return .{ .objects = objects, .prefixes = wire.prefixes, .cursor = wire.cursor, .arena = arena };
}

// --- Streaming --- //

const Stream = struct {
    reader: Bucket.Reader,
    handle: u32,
    interface: std.Io.Reader,
    buffer: [4096]u8,

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const st: *Stream = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = host.wait(.bucket_read, .{ st.handle, dest });
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(@intCast(n));
        return @intCast(n);
    }

    fn close(r: *Bucket.Reader) void {
        const st: *Stream = @fieldParentPtr("reader", r);
        _ = host.call(.bucket_close, .{st.handle});
    }
};

fn open(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?*Bucket.Reader {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var out: [*]u8 = undefined;
    var handle: u32 = 0;
    const n = host.wait(.bucket_open, .{ w.binding, try encode(a, GetRequest.init(key, opts)), &out, &handle });
    if (n == not_found) {
        Bucket.destroyArena(arena);
        return null;
    }
    try check(n);
    errdefer _ = host.call(.bucket_close, .{handle});
    if (n == 0) return error.InvalidResponse;
    const raw = host.owned(out, n);
    defer host.free(raw);

    const st = try a.create(Stream);
    st.handle = handle;
    st.interface = .{ .vtable = &.{ .stream = Stream.stream }, .buffer = &st.buffer, .seek = 0, .end = 0 };
    const m = try parse(WireMeta, a, raw);
    st.reader = .{ .meta = try m.meta(a), .interface = &st.interface, .arena = arena, .close_fn = Stream.close };
    return &st.reader;
}

// The host starts a multipart upload with the first part and keeps its parts,
// or sends one put when `finish` comes first.
const Upload = struct {
    upload: Bucket.Upload,
    handle: u32,

    const vtable: Bucket.Upload.UploadVTable = .{ .part = part, .finish = finish, .abort = abort };

    fn part(u: *Bucket.Upload, bytes: []const u8) Bucket.Error!void {
        const up: *Upload = @fieldParentPtr("upload", u);
        try check(host.wait(.bucket_upload_part, .{ up.handle, bytes }));
    }

    fn finish(u: *Bucket.Upload, rest: []const u8) Bucket.Error!void {
        const up: *Upload = @fieldParentPtr("upload", u);
        try check(host.wait(.bucket_upload_finish, .{ up.handle, rest }));
    }

    // The host forgets the handle after `finish` either way, so this is harmless then.
    fn abort(u: *Bucket.Upload) void {
        const up: *Upload = @fieldParentPtr("upload", u);
        _ = host.wait(.bucket_upload_abort, .{up.handle});
    }
};

fn upload(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.PutOptions) Bucket.Error!*Bucket.Upload {
    if (comptime !is_wasm) return error.Unavailable;
    const w = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var handle: u32 = 0;
    try check(host.wait(.bucket_upload, .{ w.binding, try encode(a, try PutRequest.init(a, key, opts)), &handle }));

    const up = try a.create(Upload);
    up.* = .{ .upload = .init(try a.alloc(u8, w.part_size), &Upload.vtable, arena), .handle = handle };
    return &up.upload;
}
