// Any S3-compatible API (AWS, R2, MinIO, Tigris, B2, …) over `zx.http.Client`, so
// it runs natively and on edge runtimes alike. Ported from Bun's Zig S3 client
// (bun-v1.3.14, `src/runtime/webcore/s3/`). Uploads send one part at a time.
//
// ```zig
// var s3: zx.Bucket.S3 = .{ .io = io, .access_key_id = id, .secret_access_key = secret, .bucket_name = "media" };
// const bucket = s3.bucket();
// try bucket.put("hello.txt", "hi", .{ .content_type = "text/plain" });
// ```
const S3 = @This();

const std = @import("std");
const Bucket = @import("../Bucket.zig");
const http = @import("../http.zig");
pub const sign = @import("S3/sign.zig");
pub const xml = @import("S3/xml.zig");
const acl_mod = @import("S3/acl.zig");

pub const Acl = acl_mod.Acl;
pub const StorageClass = acl_mod.StorageClass;

const Header = http.Header;
const log = std.log.scoped(.zx_bucket);

io: std.Io,
// For calls that don't take one, like `put` and `delete`.
allocator: std.mem.Allocator = if (@import("builtin").cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator,
access_key_id: []const u8 = "",
secret_access_key: []const u8 = "",
session_token: []const u8 = "",
// Guessed from `endpoint` when empty ("auto" for R2, us-east-1 for AWS).
region: []const u8 = "",
// e.g. `https://<account>.r2.cloudflarestorage.com` or `http://localhost:9000`; AWS when empty.
endpoint: []const u8 = "",
bucket_name: []const u8 = "",
// `bucket.host/key` instead of `host/bucket/key`.
virtual_hosted_style: bool = false,
acl: ?Acl = null,
storage_class: ?StorageClass = null,
// For requester-pays buckets.
request_payer: bool = false,
// S3 needs at least 5 MiB for every part but the last.
part_size: usize = min_part_size,
// Extra attempts for each upload part, commit and abort, as in Bun.
retry: u8 = 3,
// Signs the SHA-256 of each body; Bun sends `UNSIGNED-PAYLOAD`, which some
// S3-compatible services reject over plain HTTP.
sign_payload: bool = true,

pub const min_part_size = 5 * 1024 * 1024;
pub const max_parts = 10_000;

// Read in order by the app; the `AWS_*` names are fallbacks, as in Bun.
pub const env = struct {
    pub const access_key_id = [_][]const u8{ "S3_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID" };
    pub const secret_access_key = [_][]const u8{ "S3_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY" };
    pub const session_token = [_][]const u8{ "S3_SESSION_TOKEN", "AWS_SESSION_TOKEN" };
    pub const region = [_][]const u8{ "S3_REGION", "AWS_REGION" };
    pub const endpoint = [_][]const u8{ "S3_ENDPOINT", "AWS_ENDPOINT" };
    pub const bucket_name = [_][]const u8{ "S3_BUCKET", "AWS_BUCKET" };
};

pub fn bucket(s: *S3) Bucket {
    return .{ .userdata = s, .vtable = &.{
        .head = &head,
        .get = &get,
        .put = &put,
        .delete = &delete,
        .list = &list,
        .open = &open,
        .upload = &upload,
        .presign = &presign,
    } };
}

pub fn credentials(s: *const S3) sign.Credentials {
    return .{
        .access_key_id = s.access_key_id,
        .secret_access_key = s.secret_access_key,
        .session_token = s.session_token,
        .region = s.region,
        .endpoint = s.endpoint,
        .bucket = s.bucket_name,
        .virtual_hosted_style = s.virtual_hosted_style,
    };
}

fn from(userdata: ?*anyopaque) *S3 {
    return @ptrCast(@alignCast(userdata));
}

fn now(s: *const S3) i64 {
    return std.Io.Timestamp.now(s.io, .real).toSeconds();
}

// --- Requests --- //

const Call = struct {
    method: http.Method,
    key: []const u8 = "",
    query: []const sign.Param = &.{},
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
};

fn signCall(s: *S3, arena: std.mem.Allocator, call: Call) Bucket.Error!sign.Signed {
    const hash: ?[]const u8 = if (!s.sign_payload)
        null
    else if (call.body) |b|
        try arena.dupe(u8, &sign.sha256Hex(b))
    else
        sign.empty_payload_hash;

    var headers: std.ArrayList(Header) = .empty;
    try headers.appendSlice(arena, call.headers);
    if (s.request_payer) try headers.append(arena, .{ .name = "x-amz-request-payer", .value = "requester" });

    return sign.sign(s.credentials(), arena, s.now(), .{
        .method = @tagName(call.method),
        .key = call.key,
        .query = call.query,
        .headers = headers.items,
        .payload_hash = hash,
    }) catch |err| switch (err) {
        error.MissingCredentials => error.MissingCredentials,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidKey => error.InvalidKey,
        error.InvalidOptions => error.InvalidOptions,
    };
}

fn send(s: *S3, client: *http.Client, arena: std.mem.Allocator, call: Call) Bucket.Error!http.Client.Result {
    const signed = try s.signCall(arena, call);
    return client.fetch(.{ .url = signed.url, .method = call.method, .headers = signed.headers, .payload = call.body });
}

// Logs S3's `<Error>` and maps it, as Bun's `errorWithBody` does.
fn failure(status: http.Status, body: []const u8) Bucket.Error {
    const e = xml.errorBody(body) orelse xml.ErrorBody{ .code = @tagName(status), .message = "" };
    log.warn("s3 {d}: {s} {s}", .{ @backingInt(status), e.code, e.message });
    if (status == .forbidden or status == .unauthorized) return error.AccessDenied;
    for ([_][]const u8{ "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken" }) |code| {
        if (std.mem.eql(u8, e.code, code)) return error.AccessDenied;
    }
    if (status == .range_not_satisfiable) return error.InvalidOptions;
    return error.ApiError;
}

fn ok(status: http.Status) bool {
    return status.class() == .success;
}

fn putHeaders(s: *const S3, arena: std.mem.Allocator, opts: Bucket.PutOptions) Bucket.Error![]const Header {
    var headers: std.ArrayList(Header) = .empty;
    if (opts.content_type) |v| try headers.append(arena, .{ .name = "content-type", .value = v });
    if (opts.content_disposition) |v| try headers.append(arena, .{ .name = "content-disposition", .value = v });
    if (opts.content_encoding) |v| try headers.append(arena, .{ .name = "content-encoding", .value = v });
    if (opts.cache_control) |v| try headers.append(arena, .{ .name = "cache-control", .value = v });
    for (opts.metadata) |m| {
        const name = try arena.print("x-amz-meta-{s}", .{m.name});
        _ = std.ascii.lowerString(name, name);
        try headers.append(arena, .{ .name = name, .value = m.value });
    }
    if (s.acl) |a| try headers.append(arena, .{ .name = "x-amz-acl", .value = a.toString() });
    if (s.storage_class) |c| try headers.append(arena, .{ .name = "x-amz-storage-class", .value = c.toString() });
    return headers.items;
}

fn rangeHeader(arena: std.mem.Allocator, range: ?Bucket.Range) Bucket.Error![]const Header {
    const r = range orelse return &.{};
    const value = if (r.length) |len|
        try arena.print("bytes={d}-{d}", .{ r.offset, r.offset + len - 1 })
    else
        try arena.print("bytes={d}-", .{r.offset});
    return arena.dupe(Header, &.{.{ .name = "range", .value = value }});
}

fn unquote(etag: []const u8) []const u8 {
    return std.mem.trim(u8, etag, "\"");
}

fn metaFromHeaders(arena: std.mem.Allocator, key: []const u8, headers: []const Header) Bucket.Error!Bucket.Meta {
    var meta: Bucket.Meta = .{ .key = try arena.dupe(u8, key) };
    var custom: std.ArrayList(Header) = .empty;
    for (headers) |h| {
        const value = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
            meta.size = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
            // `bytes 0-9/100`: the object's full size.
            if (std.mem.findScalarLast(u8, value, '/')) |i| meta.size = std.fmt.parseInt(u64, value[i + 1 ..], 10) catch meta.size;
        } else if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
            meta.etag = unquote(value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "last-modified")) {
            meta.last_modified = xml.parseHttpDate(value) orelse 0;
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            meta.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-disposition")) {
            meta.content_disposition = value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-encoding")) {
            meta.content_encoding = value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "cache-control")) {
            meta.cache_control = value;
        } else if (std.ascii.startsWithIgnoreCase(h.name, "x-amz-meta-")) {
            const name = try arena.dupe(u8, h.name["x-amz-meta-".len..]);
            try custom.append(arena, .{ .name = std.ascii.lowerString(name, name), .value = value });
        }
    }
    meta.metadata = custom.items;
    return meta;
}

// --- Bucket --- //

fn head(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8) Bucket.Error!?Bucket.Object {
    const s = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);

    var client: http.Client = .{ .io = s.io, .allocator = gpa };
    defer client.deinit();
    const res = try s.send(&client, arena.allocator(), .{ .method = .HEAD, .key = key });
    defer res.deinit(gpa);

    if (res.status == .not_found) {
        Bucket.destroyArena(arena);
        return null;
    }
    if (!ok(res.status)) return failure(res.status, res.body);
    return .{ .meta = try metaFromHeaders(arena.allocator(), key, res.headers), .arena = arena };
}

fn get(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?Bucket.Object {
    const s = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var client: http.Client = .{ .io = s.io, .allocator = gpa };
    defer client.deinit();
    const res = try s.send(&client, a, .{ .method = .GET, .key = key, .headers = try rangeHeader(a, opts.range) });

    if (res.status == .not_found) {
        res.deinit(gpa);
        Bucket.destroyArena(arena);
        return null;
    }
    if (!ok(res.status)) {
        defer res.deinit(gpa);
        return failure(res.status, res.body);
    }
    const meta = metaFromHeaders(a, key, res.headers) catch |err| {
        res.deinit(gpa);
        return err;
    };
    // The body stays in the response's buffer, handed to the object.
    gpa.free(res.headers);
    return .{ .meta = meta, .body = res.body, .arena = arena, .owned = res._bytes };
}

fn put(userdata: ?*anyopaque, key: []const u8, body: []const u8, opts: Bucket.PutOptions) Bucket.Error!void {
    const s = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(s.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: http.Client = .{ .io = s.io, .allocator = s.allocator };
    defer client.deinit();
    const res = try s.send(&client, arena, .{ .method = .PUT, .key = key, .headers = try s.putHeaders(arena, opts), .body = body });
    defer res.deinit(s.allocator);
    if (!ok(res.status)) return failure(res.status, res.body);
}

fn delete(userdata: ?*anyopaque, key: []const u8) Bucket.Error!void {
    const s = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(s.allocator);
    defer arena_state.deinit();

    var client: http.Client = .{ .io = s.io, .allocator = s.allocator };
    defer client.deinit();
    const res = try s.send(&client, arena_state.allocator(), .{ .method = .DELETE, .key = key });
    defer res.deinit(s.allocator);
    if (!ok(res.status) and res.status != .not_found) return failure(res.status, res.body);
}

// ListObjectsV2, as Bun's `listObjects` builds it.
fn list(userdata: ?*anyopaque, gpa: std.mem.Allocator, opts: Bucket.ListOptions) Bucket.Error!Bucket.List {
    const s = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    var query: std.ArrayList(sign.Param) = .empty;
    try query.append(a, .{ .name = "list-type", .value = "2" });
    try query.append(a, .{ .name = "max-keys", .value = try a.print("{d}", .{opts.limit}) });
    if (opts.prefix.len > 0) try query.append(a, .{ .name = "prefix", .value = opts.prefix });
    if (opts.delimiter) |d| try query.append(a, .{ .name = "delimiter", .value = d });
    if (opts.cursor) |c| try query.append(a, .{ .name = "continuation-token", .value = c });

    var client: http.Client = .{ .io = s.io, .allocator = gpa };
    defer client.deinit();
    const res = try s.send(&client, a, .{ .method = .GET, .query = query.items });
    defer res.deinit(gpa);
    if (!ok(res.status)) return failure(res.status, res.body);
    return parseList(arena, res.body);
}

pub fn parseList(arena: *std.heap.ArenaAllocator, body: []const u8) Bucket.Error!Bucket.List {
    const a = arena.allocator();
    const result = xml.text(body, "ListBucketResult") orelse return error.InvalidResponse;

    var objects: std.ArrayList(Bucket.Meta) = .empty;
    var contents: xml.Iterator = .{ .xml = result, .name = "Contents" };
    while (contents.next()) |c| {
        const key = try xml.decodedText(a, c, "Key") orelse continue;
        try objects.append(a, .{
            .key = key,
            .size = std.fmt.parseInt(u64, xml.text(c, "Size") orelse "0", 10) catch 0,
            .etag = unquote(try xml.decodedText(a, c, "ETag") orelse ""),
            .last_modified = xml.parseIsoDate(xml.text(c, "LastModified") orelse "") orelse 0,
        });
    }

    var prefixes: std.ArrayList([]const u8) = .empty;
    var common: xml.Iterator = .{ .xml = result, .name = "CommonPrefixes" };
    while (common.next()) |c| {
        var it: xml.Iterator = .{ .xml = c, .name = "Prefix" };
        while (it.next()) |p| try prefixes.append(a, try xml.decode(a, p));
    }

    const truncated = std.mem.eql(u8, xml.text(result, "IsTruncated") orelse "false", "true");
    return .{
        .objects = objects.items,
        .prefixes = prefixes.items,
        .cursor = if (truncated) try xml.decodedText(a, result, "NextContinuationToken") else null,
        .arena = arena,
    };
}

fn presign(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.PresignOptions) Bucket.Error![]u8 {
    const s = from(userdata);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var query: std.ArrayList(sign.Param) = .empty;
    if (opts.content_disposition) |v| try query.append(arena, .{ .name = "response-content-disposition", .value = v });
    if (opts.content_type) |v| try query.append(arena, .{ .name = "response-content-type", .value = v });
    if (s.request_payer) try query.append(arena, .{ .name = "x-amz-request-payer", .value = "requester" });
    if (opts.method == .PUT) {
        if (s.acl) |acl| try query.append(arena, .{ .name = "X-Amz-Acl", .value = acl.toString() });
        if (s.storage_class) |c| try query.append(arena, .{ .name = "x-amz-storage-class", .value = c.toString() });
    }

    const url = sign.presign(s.credentials(), arena, s.now(), .{
        .method = @tagName(opts.method),
        .key = key,
        .query = query.items,
    }, opts.expires) catch |err| return switch (err) {
        error.MissingCredentials => error.MissingCredentials,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidKey => error.InvalidKey,
        error.InvalidOptions => error.InvalidOptions,
    };
    return gpa.dupe(u8, url);
}

// --- Streaming read --- //

const Stream = struct {
    reader: Bucket.Reader,
    client: http.Client,
    body: *http.Client.Body,

    fn close(r: *Bucket.Reader) void {
        const st: *Stream = @fieldParentPtr("reader", r);
        st.body.close();
        st.client.deinit();
    }
};

fn open(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.GetOptions) Bucket.Error!?*Bucket.Reader {
    const s = from(userdata);
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const st = try a.create(Stream);
    st.client = .{ .io = s.io, .allocator = gpa };
    errdefer st.client.deinit();

    const signed = try s.signCall(a, .{ .method = .GET, .key = key, .headers = try rangeHeader(a, opts.range) });
    st.body = try st.client.open(.{ .url = signed.url, .headers = signed.headers });
    errdefer st.body.close();

    if (st.body.status == .not_found) {
        st.body.close();
        st.client.deinit();
        Bucket.destroyArena(arena);
        return null;
    }
    if (!ok(st.body.status)) {
        const text: []const u8 = st.body.reader.allocRemaining(a, .limited(64 * 1024)) catch "";
        return failure(st.body.status, text);
    }

    st.reader = .{
        .meta = try metaFromHeaders(a, key, st.body.headers),
        .interface = st.body.reader,
        .arena = arena,
        .close_fn = Stream.close,
    };
    return &st.reader;
}

// --- Multipart upload --- //

// Bun's `MultiPartUpload` flow: the first full buffer starts a multipart upload,
// each buffer is one part, and `finish` commits; an object smaller than one part
// is a single PUT. Failed requests retry up to `retry` times.
const Upload = struct {
    upload: Bucket.Upload,
    s3: *S3,
    client: http.Client,
    key: []const u8,
    headers: []const Header,
    upload_id: ?[]const u8 = null,
    etags: std.ArrayList([]const u8) = .empty,

    const vtable: Bucket.Upload.UploadVTable = .{ .part = part, .finish = finish, .abort = abort };

    fn from(u: *Bucket.Upload) *Upload {
        return @fieldParentPtr("upload", u);
    }

    fn arena(up: *Upload) std.mem.Allocator {
        return up.upload.arena.allocator();
    }

    // Runs `call`, retrying failures; the caller frees the result with `client.allocator`.
    fn request(up: *Upload, call: Call) Bucket.Error!http.Client.Result {
        var attempts: u16 = 0;
        while (true) : (attempts += 1) {
            var scratch: std.heap.ArenaAllocator = .init(up.client.allocator);
            defer scratch.deinit();
            const res = up.s3.send(&up.client, scratch.allocator(), call) catch |err| {
                if (attempts < up.s3.retry and err != error.MissingCredentials and err != error.OutOfMemory) continue;
                return err;
            };
            // A commit can fail with 200 and an `<Error>` body.
            if (ok(res.status) and xml.errorBody(res.body) == null) return res;
            defer res.deinit(up.client.allocator);
            if (attempts < up.s3.retry and res.status != .forbidden) continue;
            return failure(res.status, res.body);
        }
    }

    fn part(u: *Bucket.Upload, bytes: []const u8) Bucket.Error!void {
        const up = Upload.from(u);
        if (up.etags.items.len >= max_parts) return error.InvalidOptions;
        if (up.upload_id == null) {
            const res = try up.request(.{ .method = .POST, .key = up.key, .query = &.{.{ .name = "uploads" }}, .headers = up.headers, .body = "" });
            defer res.deinit(up.client.allocator);
            const id = try xml.decodedText(up.arena(), res.body, "UploadId") orelse return error.InvalidResponse;
            if (id.len == 0) return error.InvalidResponse;
            up.upload_id = try up.arena().dupe(u8, id);
        }
        var number_buf: [8]u8 = undefined;
        const number = std.mem.print(&number_buf, "{d}", .{up.etags.items.len + 1}) catch unreachable;
        const res = try up.request(.{
            .method = .PUT,
            .key = up.key,
            .query = &.{ .{ .name = "partNumber", .value = number }, .{ .name = "uploadId", .value = up.upload_id.? } },
            .body = bytes,
        });
        defer res.deinit(up.client.allocator);
        const etag = res.header("etag") orelse return error.InvalidResponse;
        try up.etags.append(up.arena(), try up.arena().dupe(u8, etag));
    }

    fn finish(u: *Bucket.Upload, rest: []const u8) Bucket.Error!void {
        const up = Upload.from(u);
        if (up.upload_id == null) {
            const res = try up.request(.{ .method = .PUT, .key = up.key, .headers = up.headers, .body = rest });
            res.deinit(up.client.allocator);
            up.client.deinit();
            return;
        }
        if (rest.len > 0) try part(u, rest);

        var body: std.Io.Writer.Allocating = .init(up.arena());
        const w = &body.writer;
        w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">") catch return error.OutOfMemory;
        for (up.etags.items, 1..) |etag, n| {
            w.print("<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>", .{ n, etag }) catch return error.OutOfMemory;
        }
        w.writeAll("</CompleteMultipartUpload>") catch return error.OutOfMemory;

        const res = try up.request(.{
            .method = .POST,
            .key = up.key,
            .query = &.{.{ .name = "uploadId", .value = up.upload_id.? }},
            .headers = &.{.{ .name = "content-type", .value = "application/xml" }},
            .body = body.written(),
        });
        res.deinit(up.client.allocator);
        up.upload_id = null;
        up.client.deinit();
    }

    // Best effort, as Bun's rollback: deletes the parts already uploaded.
    fn abort(u: *Bucket.Upload) void {
        const up = Upload.from(u);
        if (up.upload_id) |id| {
            if (up.request(.{ .method = .DELETE, .key = up.key, .query = &.{.{ .name = "uploadId", .value = id }} })) |res| {
                res.deinit(up.client.allocator);
            } else |err| log.warn("s3 abort of {s} failed: {t}", .{ up.key, err });
        }
        up.client.deinit();
    }
};

fn upload(userdata: ?*anyopaque, gpa: std.mem.Allocator, key: []const u8, opts: Bucket.PutOptions) Bucket.Error!*Bucket.Upload {
    const s = from(userdata);
    if (s.part_size < min_part_size) return error.InvalidOptions;
    const arena = try Bucket.createArena(gpa);
    errdefer Bucket.destroyArena(arena);
    const a = arena.allocator();

    const up = try a.create(Upload);
    up.* = .{
        .upload = .init(try a.alloc(u8, s.part_size), &Upload.vtable, arena),
        .s3 = s,
        .client = .{ .io = s.io, .allocator = gpa },
        .key = try a.dupe(u8, key),
        .headers = try s.putHeaders(a, try opts.dupe(a)),
    };
    return &up.upload;
}
