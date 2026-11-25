const std = @import("std");
const zx = @import("zx");

const sha256Hex = zx.Bucket.S3.sign.sha256Hex;

// In-memory S3 for `test/core/bucket.zig`, path style under `/s3/<bucket>/<key>`.
// Rejects requests not signed for `test-key`, and bodies whose
// `x-amz-content-sha256` doesn't match.

const gpa = std.heap.smp_allocator;

const Object = struct { body: []const u8, content_type: []const u8, owner: []const u8 };

var objects: std.StringArrayHashMapUnmanaged(Object) = .empty;
var uploads: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
var next_upload: u32 = 0;
var lock: std.atomic.Mutex = .unlocked;

pub fn Route(ctx: zx.RouteContext) !void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();

    const auth = ctx.request.headers.get("authorization") orelse "";
    if (!std.mem.startsWith(u8, auth, "AWS4-HMAC-SHA256 Credential=test-key/") or ctx.request.headers.get("x-amz-date") == null) {
        return fail(ctx, .forbidden, "AccessDenied", "Access Denied");
    }
    const body = ctx.request.text() orelse "";
    const hash = ctx.request.headers.get("x-amz-content-sha256") orelse "";
    if (!std.mem.eql(u8, hash, "UNSIGNED-PAYLOAD") and !std.mem.eql(u8, hash, &sha256Hex(body))) {
        return fail(ctx, .bad_request, "XAmzContentSHA256Mismatch", "hash mismatch");
    }

    // `/s3/<bucket>[/<key>]`
    const rest = ctx.request.pathname["/s3/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const raw_key = if (slash < rest.len) rest[slash + 1 ..] else "";
    const key = try percentDecode(ctx.arena, raw_key);
    const id = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rest[0..slash], key });

    const q = &ctx.request.query;
    switch (ctx.request.method) {
        .GET => {
            if (key.len == 0) return list(ctx, rest[0..slash]);
            const obj = objects.get(id) orelse return fail(ctx, .not_found, "NoSuchKey", "The specified key does not exist.");
            setHeaders(ctx, obj);
            if (ctx.request.headers.get("range")) |range| {
                const spec = range["bytes=".len..];
                const dash = std.mem.indexOfScalar(u8, spec, '-').?;
                const start = try std.fmt.parseInt(usize, spec[0..dash], 10);
                if (start >= obj.body.len) return fail(ctx, .range_not_satisfiable, "InvalidRange", "bad range");
                const end = if (dash + 1 < spec.len) @min(obj.body.len - 1, try std.fmt.parseInt(usize, spec[dash + 1 ..], 10)) else obj.body.len - 1;
                ctx.response.setStatus(.partial_content);
                ctx.response.headers.set("content-range", try std.fmt.allocPrint(ctx.arena, "bytes {d}-{d}/{d}", .{ start, end, obj.body.len }));
                return ctx.response.text(obj.body[start .. end + 1]);
            }
            ctx.response.text(obj.body);
        },
        .HEAD => {
            const obj = objects.get(id) orelse {
                ctx.response.setStatus(.not_found);
                return ctx.response.text("");
            };
            setHeaders(ctx, obj);
            ctx.response.text("");
        },
        .PUT => {
            if (q.get("uploadId")) |upload_id| {
                const parts = uploads.getPtr(upload_id) orelse return fail(ctx, .not_found, "NoSuchUpload", "no upload");
                const n = try std.fmt.parseInt(usize, q.get("partNumber").?, 10);
                if (n != parts.items.len + 1) return fail(ctx, .bad_request, "InvalidPartOrder", "out of order");
                try parts.append(gpa, try gpa.dupe(u8, body));
                ctx.response.headers.set("etag", try std.fmt.allocPrint(ctx.arena, "\"part-{d}\"", .{n}));
                return ctx.response.text("");
            }
            try store(id, try gpa.dupe(u8, body), ctx);
            ctx.response.headers.set("etag", "\"stored\"");
            ctx.response.text("");
        },
        .POST => {
            if (q.has("uploads")) {
                next_upload += 1;
                const upload_id = try std.fmt.allocPrint(gpa, "up+{d}/x", .{next_upload});
                try uploads.put(gpa, upload_id, .empty);
                // Kept for the complete call: it carries no content-type of its own.
                try store(try std.fmt.allocPrint(gpa, "pending:{s}", .{upload_id}), "", ctx);
                return ctx.response.text(try std.fmt.allocPrint(ctx.arena, "<?xml version=\"1.0\"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>{s}</Key><UploadId>{s}</UploadId></InitiateMultipartUploadResult>", .{ key, upload_id }));
            }
            const upload_id = q.get("uploadId") orelse return fail(ctx, .bad_request, "InvalidRequest", "no upload");
            const parts = uploads.get(upload_id) orelse return fail(ctx, .not_found, "NoSuchUpload", "no upload");
            if (std.mem.count(u8, body, "<Part>") != parts.items.len) return fail(ctx, .bad_request, "InvalidPart", "part count");
            const joined = try std.mem.concat(gpa, u8, parts.items);
            const pending = objects.get(try std.fmt.allocPrint(gpa, "pending:{s}", .{upload_id})).?;
            try objects.put(gpa, id, .{ .body = joined, .content_type = pending.content_type, .owner = pending.owner });
            _ = uploads.remove(upload_id);
            ctx.response.text("<?xml version=\"1.0\"?><CompleteMultipartUploadResult><ETag>\"done\"</ETag></CompleteMultipartUploadResult>");
        },
        .DELETE => {
            if (q.get("uploadId")) |upload_id| {
                _ = uploads.remove(upload_id);
            } else {
                _ = objects.orderedRemove(id);
            }
            ctx.response.setStatus(.no_content);
            ctx.response.text("");
        },
        else => fail(ctx, .method_not_allowed, "MethodNotAllowed", "nope"),
    }
}

fn store(id: []const u8, body: []const u8, ctx: zx.RouteContext) !void {
    try objects.put(gpa, id, .{
        .body = body,
        .content_type = try gpa.dupe(u8, ctx.request.headers.get("content-type") orelse "binary/octet-stream"),
        .owner = try gpa.dupe(u8, ctx.request.headers.get("x-amz-meta-owner") orelse ""),
    });
}

fn setHeaders(ctx: zx.RouteContext, obj: Object) void {
    ctx.response.headers.set("etag", "\"stored\"");
    ctx.response.headers.set("content-type", obj.content_type);
    ctx.response.headers.set("last-modified", "Wed, 12 Oct 2009 17:50:00 GMT");
    if (obj.owner.len > 0) ctx.response.headers.set("x-amz-meta-owner", obj.owner);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn list(ctx: zx.RouteContext, bucket: []const u8) !void {
    const q = &ctx.request.query;
    if (!std.mem.eql(u8, q.get("list-type") orelse "", "2")) return fail(ctx, .bad_request, "InvalidArgument", "list-type");
    const prefix = q.get("prefix") orelse "";
    const delimiter = q.get("delimiter");
    const after = q.get("continuation-token");
    const max = try std.fmt.parseInt(usize, q.get("max-keys") orelse "1000", 10);

    var keys: std.ArrayList([]const u8) = .empty;
    for (objects.keys()) |id| {
        if (!std.mem.startsWith(u8, id, bucket) or id.len <= bucket.len or id[bucket.len] != '/') continue;
        const key = id[bucket.len + 1 ..];
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (after) |a| if (!std.mem.lessThan(u8, a, key)) continue;
        try keys.append(ctx.arena, key);
    }
    std.mem.sort([]const u8, keys.items, {}, lessString);

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>b</Name><Prefix></Prefix>");
    var count: usize = 0;
    var i: usize = 0;
    var last: []const u8 = "";
    while (i < keys.items.len and count < max) : (count += 1) {
        const key = keys.items[i];
        if (delimiter) |d| if (std.mem.indexOf(u8, key[prefix.len..], d)) |at| {
            const rolled = key[0 .. prefix.len + at + d.len];
            try w.writeAll("<CommonPrefixes><Prefix>");
            try escape(w, rolled);
            try w.writeAll("</Prefix></CommonPrefixes>");
            while (i < keys.items.len and std.mem.startsWith(u8, keys.items[i], rolled)) : (i += 1) last = keys.items[i];
            continue;
        };
        const obj = objects.get(try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ bucket, key })).?;
        try w.writeAll("<Contents><Key>");
        try escape(w, key);
        try w.print("</Key><LastModified>2009-10-12T17:50:30.123Z</LastModified><ETag>&quot;e{d}&quot;</ETag><Size>{d}</Size><StorageClass>STANDARD</StorageClass></Contents>", .{ count, obj.body.len });
        last = key;
        i += 1;
    }
    if (i < keys.items.len) {
        try w.writeAll("<IsTruncated>true</IsTruncated><NextContinuationToken>");
        try escape(w, last);
        try w.writeAll("</NextContinuationToken>");
    } else try w.writeAll("<IsTruncated>false</IsTruncated>");
    try w.writeAll("</ListBucketResult>");
    ctx.response.text(out.written());
}

fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn fail(ctx: zx.RouteContext, status: std.http.Status, code: []const u8, message: []const u8) void {
    ctx.response.setStatus(status);
    ctx.response.text(std.fmt.allocPrint(ctx.arena, "<?xml version=\"1.0\"?><Error><Code>{s}</Code><Message>{s}</Message></Error>", .{ code, message }) catch "");
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 3 <= s.len) {
            try out.append(arena, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
            i += 3;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}
