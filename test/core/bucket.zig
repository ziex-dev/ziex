const std = @import("std");
const zx = @import("zx");

const Bucket = zx.Bucket;
const S3 = Bucket.S3;
const sign = S3.sign;
const xml = S3.xml;
const Harness = zx.testing.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;

// --- Interface --- //

test "failing > every call is unavailable" {
    try std.testing.expectError(error.Unavailable, Bucket.failing.put("a", "b", .{}));
    try std.testing.expectError(error.Unavailable, Bucket.failing.get(gpa, "a", .{}));
    try std.testing.expectError(error.Unavailable, Bucket.failing.list(gpa, .{}));
}

test "zx.bucket > defaults to failing" {
    try std.testing.expectError(error.Unavailable, zx.bucket.head(gpa, "a"));
}

test "provider > type by tag" {
    try std.testing.expect(Bucket.Provider.fs.Type() == Bucket.Fs);
    try std.testing.expect(Bucket.Provider.wasm.Type() == Bucket.Wasm);
    try std.testing.expect(Bucket.Provider.s3.Type() == Bucket.S3);
}

test "validation > keys and options" {
    const b = Bucket.failing;
    try std.testing.expectError(error.InvalidKey, b.put("", "x", .{}));
    try std.testing.expectError(error.InvalidKey, b.put("a\x00b", "x", .{}));
    const long: [Bucket.max_key_len + 1]u8 = @splat('k');
    try std.testing.expectError(error.InvalidKey, b.get(gpa, &long, .{}));
    try std.testing.expectError(error.InvalidOptions, b.put("a", "x", .{ .content_type = "text/plain\r\nx-evil: 1" }));
    try std.testing.expectError(error.InvalidOptions, b.put("a", "x", .{ .metadata = &.{.{ .name = "bad name", .value = "v" }} }));
    try std.testing.expectError(error.InvalidOptions, b.put("a", "x", .{ .metadata = &.{.{ .name = "ok", .value = "a\nb" }} }));
    try std.testing.expectError(error.InvalidOptions, b.get(gpa, "a", .{ .range = .{ .length = 0 } }));
    try std.testing.expectError(error.InvalidOptions, b.list(gpa, .{ .limit = 0 }));
    try std.testing.expectError(error.InvalidOptions, b.presign(gpa, "a", .{ .expires = 8 * 24 * 3600 }));
}

// --- Signing: AWS's published SigV4 examples for S3 --- //

const example: sign.Credentials = .{
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    .region = "us-east-1",
    .endpoint = "examplebucket.s3.amazonaws.com",
    .bucket = "examplebucket",
    .virtual_hosted_style = true,
};
// 20130524T000000Z
const example_time = 1369353600;

fn header(signed: sign.Signed, name: []const u8) ?[]const u8 {
    for (signed.headers) |h| if (std.mem.eql(u8, h.name, name)) return h.value;
    return null;
}

fn expectSignature(signed: sign.Signed, signed_headers: []const u8, signature: []const u8) !void {
    var buf: [512]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders={s}, Signature={s}", .{ signed_headers, signature });
    try std.testing.expectEqualStrings(want, header(signed, "authorization").?);
}

test "sign > GET object with range" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const signed = try sign.sign(example, arena.allocator(), example_time, .{
        .method = "GET",
        .key = "test.txt",
        .headers = &.{.{ .name = "range", .value = "bytes=0-9" }},
        .payload_hash = sign.empty_payload_hash,
    });
    try std.testing.expectEqualStrings("https://examplebucket.s3.amazonaws.com/test.txt", signed.url);
    try std.testing.expectEqualStrings("20130524T000000Z", header(signed, "x-amz-date").?);
    try expectSignature(signed, "host;range;x-amz-content-sha256;x-amz-date", "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
}

test "sign > PUT object" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const body = "Welcome to Amazon S3.";
    const hash = sign.sha256Hex(body);
    try std.testing.expectEqualStrings("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", &hash);
    const signed = try sign.sign(example, arena.allocator(), example_time, .{
        .method = "PUT",
        .key = "test$file.text",
        .headers = &.{
            .{ .name = "date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
            .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
        },
        .payload_hash = &hash,
    });
    try std.testing.expectEqualStrings("https://examplebucket.s3.amazonaws.com/test%24file.text", signed.url);
    try expectSignature(signed, "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class", "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");
}

test "sign > GET bucket lifecycle" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const signed = try sign.sign(example, arena.allocator(), example_time, .{
        .method = "GET",
        .query = &.{.{ .name = "lifecycle" }},
        .payload_hash = sign.empty_payload_hash,
    });
    try std.testing.expectEqualStrings("https://examplebucket.s3.amazonaws.com/?lifecycle=", signed.url);
    try expectSignature(signed, "host;x-amz-content-sha256;x-amz-date", "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543");
}

test "sign > list objects sorts the query" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const signed = try sign.sign(example, arena.allocator(), example_time, .{
        .method = "GET",
        .query = &.{ .{ .name = "prefix", .value = "J" }, .{ .name = "max-keys", .value = "2" } },
        .payload_hash = sign.empty_payload_hash,
    });
    try std.testing.expectEqualStrings("https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J", signed.url);
    try expectSignature(signed, "host;x-amz-content-sha256;x-amz-date", "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7");
}

test "sign > presigned GET" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const url = try sign.presign(example, arena.allocator(), example_time, .{ .method = "GET", .key = "test.txt" }, 86400);
    try std.testing.expectEqualStrings(
        "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
        url,
    );
}

test "sign > path style, session token and missing credentials" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: sign.Credentials = .{
        .access_key_id = "id",
        .secret_access_key = "secret",
        .session_token = "tok",
        .endpoint = "http://localhost:9000/",
        .bucket = "my bucket",
    };
    const signed = try sign.sign(c, arena.allocator(), example_time, .{ .method = "GET", .key = "a b/c+d.txt" });
    try std.testing.expectEqualStrings("http://localhost:9000/my%20bucket/a%20b/c%2Bd.txt", signed.url);
    try std.testing.expectEqualStrings("tok", header(signed, "x-amz-security-token").?);
    try std.testing.expectEqualStrings("UNSIGNED-PAYLOAD", header(signed, "x-amz-content-sha256").?);
    try std.testing.expect(std.mem.indexOf(u8, header(signed, "authorization").?, "/auto/s3/aws4_request") != null);
    try std.testing.expectError(error.InvalidOptions, sign.sign(c, arena.allocator(), 0, .{ .method = "GET", .key = "a", .headers = &.{.{ .name = "x-a", .value = "1\r\n2" }} }));

    c.secret_access_key = "";
    try std.testing.expectError(error.MissingCredentials, sign.sign(c, arena.allocator(), 0, .{ .method = "GET", .key = "a" }));
}

test "sign > region and endpoint guesses" {
    try std.testing.expectEqualStrings("us-east-1", sign.guessRegion(""));
    try std.testing.expectEqualStrings("auto", sign.guessRegion("https://acc.r2.cloudflarestorage.com"));
    try std.testing.expectEqualStrings("eu-west-2", sign.guessRegion("https://s3.eu-west-2.amazonaws.com"));
    try std.testing.expectEqualStrings("auto", sign.guessRegion("http://localhost:9000"));

    const ep = sign.Endpoint.parse("https://host.dev:443/base/");
    try std.testing.expect(!ep.insecure);
    try std.testing.expectEqualStrings("host.dev", ep.host);
    try std.testing.expectEqualStrings("/base", ep.path);
    try std.testing.expectEqualStrings("127.0.0.1:9000", sign.Endpoint.parse("http://127.0.0.1:9000").host);
}

// --- XML --- //

test "xml > ListObjectsV2" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\  <Name>b</Name><Prefix></Prefix><KeyCount>2</KeyCount>
        \\  <Contents><Key>a&amp;b &lt;1&gt;.txt</Key><LastModified>2009-10-12T17:50:30.123Z</LastModified>
        \\    <ETag>&quot;abc&quot;</ETag><Size>42</Size><StorageClass>STANDARD</StorageClass></Contents>
        \\  <Contents><Key>z</Key><Size>0</Size></Contents>
        \\  <CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes>
        \\  <CommonPrefixes><Prefix>x&#38;y/</Prefix></CommonPrefixes>
        \\  <IsTruncated>true</IsTruncated><NextContinuationToken>tok/en=</NextContinuationToken>
        \\</ListBucketResult>
    ;
    const arena = try Bucket.createArena(gpa);
    const list = try S3.parseList(arena, body);
    defer list.deinit();

    try std.testing.expectEqual(2, list.objects.len);
    try std.testing.expectEqualStrings("a&b <1>.txt", list.objects[0].key);
    try std.testing.expectEqualStrings("abc", list.objects[0].etag);
    try std.testing.expectEqual(42, list.objects[0].size);
    try std.testing.expectEqual(1255369830123, list.objects[0].last_modified);
    try std.testing.expectEqualStrings("z", list.objects[1].key);
    try std.testing.expectEqual(2, list.prefixes.len);
    try std.testing.expectEqualStrings("dir/", list.prefixes[0]);
    try std.testing.expectEqualStrings("x&y/", list.prefixes[1]);
    try std.testing.expectEqualStrings("tok/en=", list.cursor.?);
}

test "xml > error body, empty elements and dates" {
    const e = xml.errorBody("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code><Message>nope</Message></Error>").?;
    try std.testing.expectEqualStrings("NoSuchKey", e.code);
    try std.testing.expectEqualStrings("nope", e.message);
    try std.testing.expect(xml.errorBody("<ListBucketResult/>") == null);
    try std.testing.expectEqualStrings("", xml.text("<a><Prefix/><b>1</b></a>", "Prefix").?);
    try std.testing.expectEqualStrings("1", xml.text("<a><bb>2</bb><b>1</b></a>", "b").?);

    try std.testing.expectEqual(1255369800000, xml.parseHttpDate("Mon, 12 Oct 2009 17:50:00 GMT").?);
    try std.testing.expectEqual(0, xml.parseIsoDate("1970-01-01T00:00:00Z").?);
    try std.testing.expectEqual(951782400500, xml.parseIsoDate("2000-02-29T00:00:00.5Z").?);
    try std.testing.expect(xml.parseIsoDate("garbage") == null);
}

// --- Fs --- //

fn withFs(comptime name: []const u8, comptime case: fn (b: Bucket) anyerror!void) !void {
    const root = "zig-out/test-data/bucket-" ++ name;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var fs: Bucket.Fs = .{ .io = io, .root = root, .upload_buffer_len = 16 };
    try case(fs.bucket());
}

test "fs > put/get/head/delete roundtrip" {
    try withFs("roundtrip", struct {
        fn run(b: Bucket) !void {
            try b.put("docs/hello.txt", "hello world", .{
                .content_type = "text/plain",
                .cache_control = "max-age=60",
                .metadata = &.{.{ .name = "owner", .value = "ana" }},
            });

            const obj = (try b.get(gpa, "docs/hello.txt", .{})).?;
            defer obj.deinit();
            try std.testing.expectEqualStrings("hello world", obj.body);
            try std.testing.expectEqualStrings("docs/hello.txt", obj.meta.key);
            try std.testing.expectEqual(11, obj.meta.size);
            try std.testing.expectEqualStrings("5eb63bbbe01eeed093cb22bb8f5acdc3", obj.meta.etag);
            try std.testing.expectEqualStrings("text/plain", obj.meta.content_type.?);
            try std.testing.expectEqualStrings("max-age=60", obj.meta.cache_control.?);
            try std.testing.expectEqualStrings("ana", obj.meta.get("owner").?);
            try std.testing.expect(obj.meta.last_modified > 0);

            const meta = (try b.head(gpa, "docs/hello.txt")).?;
            defer meta.deinit();
            try std.testing.expectEqualStrings("", meta.body);
            try std.testing.expectEqual(11, meta.meta.size);

            const part = (try b.get(gpa, "docs/hello.txt", .{ .range = .{ .offset = 6, .length = 100 } })).?;
            defer part.deinit();
            try std.testing.expectEqualStrings("world", part.body);
            try std.testing.expectError(error.InvalidOptions, b.get(gpa, "docs/hello.txt", .{ .range = .{ .offset = 11 } }));

            try b.put("docs/hello.txt", "", .{});
            const empty = (try b.get(gpa, "docs/hello.txt", .{})).?;
            defer empty.deinit();
            try std.testing.expectEqualStrings("", empty.body);
            try std.testing.expect(empty.meta.content_type == null);

            try b.delete("docs/hello.txt");
            try b.delete("docs/hello.txt");
            try std.testing.expect(try b.get(gpa, "docs/hello.txt", .{}) == null);
            try std.testing.expect(!try b.exists(gpa, "docs/hello.txt"));
        }
    }.run);
}

test "fs > any key is a safe, distinct path" {
    try withFs("keys", struct {
        fn run(b: Bucket) !void {
            const keys = [_][]const u8{ "a", "a/b", "a/", "../escape", "a/../b", ".", "x.o", "x.m", "dir//double", "ünï cødé", "%2F" };
            for (keys) |k| try b.put(k, k, .{});
            for (keys) |k| {
                const obj = (try b.get(gpa, k, .{})).?;
                defer obj.deinit();
                try std.testing.expectEqualStrings(k, obj.body);
            }
            std.Io.Dir.cwd().access(io, "zig-out/test-data/escape.o", .{}) catch return;
            return error.Escaped;
        }
    }.run);
}

test "fs > list pages with prefix and delimiter" {
    try withFs("list", struct {
        fn run(b: Bucket) !void {
            for ([_][]const u8{ "photos/2024/a.jpg", "photos/2024/b.jpg", "photos/2025/c.jpg", "photos/top.jpg", "readme.md", "photosx" }) |k| try b.put(k, "x", .{});

            const all = try b.list(gpa, .{});
            defer all.deinit();
            try std.testing.expectEqual(6, all.objects.len);
            try std.testing.expectEqualStrings("photos/2024/a.jpg", all.objects[0].key);
            try std.testing.expect(all.cursor == null);

            const level = try b.list(gpa, .{ .prefix = "photos/", .delimiter = "/" });
            defer level.deinit();
            try std.testing.expectEqual(1, level.objects.len);
            try std.testing.expectEqualStrings("photos/top.jpg", level.objects[0].key);
            try std.testing.expectEqual(2, level.prefixes.len);
            try std.testing.expectEqualStrings("photos/2024/", level.prefixes[0]);
            try std.testing.expectEqualStrings("photos/2025/", level.prefixes[1]);

            const first = try b.list(gpa, .{ .prefix = "photos", .limit = 2 });
            defer first.deinit();
            try std.testing.expectEqual(2, first.objects.len);
            const second = try b.list(gpa, .{ .prefix = "photos", .limit = 2, .cursor = first.cursor.? });
            defer second.deinit();
            try std.testing.expectEqualStrings("photos/2025/c.jpg", second.objects[0].key);
            try std.testing.expectEqualStrings("photos/top.jpg", second.objects[1].key);
            const third = try b.list(gpa, .{ .prefix = "photos", .limit = 2, .cursor = second.cursor.? });
            defer third.deinit();
            try std.testing.expectEqual(1, third.objects.len);
            try std.testing.expectEqualStrings("photosx", third.objects[0].key);
            try std.testing.expect(third.cursor == null);

            const none = try b.list(gpa, .{ .prefix = "nothing/here/" });
            defer none.deinit();
            try std.testing.expectEqual(0, none.objects.len);
        }
    }.run);
}

test "fs > delete removes emptied directories" {
    try withFs("prune", struct {
        fn run(b: Bucket) !void {
            try b.put("a/b/c/d.txt", "x", .{});
            try b.put("a/keep.txt", "x", .{});
            try b.delete("a/b/c/d.txt");
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "zig-out/test-data/bucket-prune/a/b", .{}));
            try std.Io.Dir.cwd().access(io, "zig-out/test-data/bucket-prune/a/keep%2Etxt.o", .{});
        }
    }.run);
}

test "fs > streamed upload and read" {
    try withFs("stream", struct {
        fn run(b: Bucket) !void {
            const up = try b.upload(gpa, "big.bin", .{ .content_type = "application/octet-stream" });
            for (0..100) |i| try up.writer.print("line {d}\n", .{i});
            try up.finish();

            const r = (try b.open(gpa, "big.bin", .{ .range = .{ .offset = 7 } })).?;
            defer r.close();
            try std.testing.expectEqualStrings("application/octet-stream", r.meta.content_type.?);
            try std.testing.expectEqualStrings("line 1", (try r.interface.takeDelimiter('\n')).?);
            const rest = try r.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(rest);
            try std.testing.expect(std.mem.endsWith(u8, rest, "line 99\n"));

            const whole = (try b.get(gpa, "big.bin", .{})).?;
            defer whole.deinit();
            var md5: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(whole.body, &md5, .{});
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(md5, .lower), whole.meta.etag);

            const aborted = try b.upload(gpa, "never.bin", .{});
            try aborted.writer.splatByteAll('x', 40);
            aborted.abort();
            try std.testing.expect(try b.open(gpa, "never.bin", .{}) == null);
        }
    }.run);
}

test "fs > presign is unavailable" {
    try withFs("presign", struct {
        fn run(b: Bucket) !void {
            try std.testing.expectError(error.Unavailable, b.presign(gpa, "a", .{}));
        }
    }.run);
}

// --- S3, against the fake in `test/server/routes/bucket/s3.zig` --- //

fn withS3(comptime bucket_name: []const u8, comptime case: fn (s3: *S3) anyerror!void) !void {
    var harness = try Harness.start(.std, io, gpa, .{ .request = .{ .max_body_size = 8 * 1024 * 1024 } });
    defer harness.stop();

    var buf: [64]u8 = undefined;
    var s3: S3 = .{
        .io = io,
        .allocator = gpa,
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .endpoint = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/s3", .{harness.tcp.?.port}),
        .bucket_name = bucket_name,
    };
    try case(&s3);
}

test "s3 > put/get/head/delete roundtrip" {
    try withS3("roundtrip", struct {
        fn run(s3: *S3) !void {
            const b = s3.bucket();
            try b.put("dir/hello world.txt", "hello world", .{ .content_type = "text/plain", .metadata = &.{.{ .name = "Owner", .value = "ana" }} });

            const obj = (try b.get(gpa, "dir/hello world.txt", .{})).?;
            defer obj.deinit();
            try std.testing.expectEqualStrings("hello world", obj.body);
            try std.testing.expectEqualStrings("stored", obj.meta.etag);
            try std.testing.expectEqualStrings("text/plain", obj.meta.content_type.?);
            try std.testing.expectEqualStrings("ana", obj.meta.get("owner").?);
            try std.testing.expectEqual(11, obj.meta.size);
            try std.testing.expectEqual(1255369800000, obj.meta.last_modified);

            const part = (try b.get(gpa, "dir/hello world.txt", .{ .range = .{ .offset = 6, .length = 3 } })).?;
            defer part.deinit();
            try std.testing.expectEqualStrings("wor", part.body);
            try std.testing.expectEqual(11, part.meta.size);

            const meta = (try b.head(gpa, "dir/hello world.txt")).?;
            defer meta.deinit();
            try std.testing.expectEqualStrings("stored", meta.meta.etag);

            try b.delete("dir/hello world.txt");
            try std.testing.expect(try b.get(gpa, "dir/hello world.txt", .{}) == null);
            try std.testing.expect(try b.head(gpa, "dir/hello world.txt") == null);
            try b.delete("dir/hello world.txt");
        }
    }.run);
}

test "s3 > list pages with prefix and delimiter" {
    try withS3("listing", struct {
        fn run(s3: *S3) !void {
            const b = s3.bucket();
            for ([_][]const u8{ "p/a&b.txt", "p/q/1", "p/q/2", "p/z", "other" }) |k| try b.put(k, "xy", .{});

            const level = try b.list(gpa, .{ .prefix = "p/", .delimiter = "/" });
            defer level.deinit();
            try std.testing.expectEqual(2, level.objects.len);
            try std.testing.expectEqualStrings("p/a&b.txt", level.objects[0].key);
            try std.testing.expectEqual(2, level.objects[0].size);
            try std.testing.expectEqualStrings("p/z", level.objects[1].key);
            try std.testing.expectEqual(1, level.prefixes.len);
            try std.testing.expectEqualStrings("p/q/", level.prefixes[0]);

            const first = try b.list(gpa, .{ .prefix = "p/", .limit = 3 });
            defer first.deinit();
            try std.testing.expectEqual(3, first.objects.len);
            const second = try b.list(gpa, .{ .prefix = "p/", .limit = 3, .cursor = first.cursor.? });
            defer second.deinit();
            try std.testing.expectEqual(1, second.objects.len);
            try std.testing.expectEqualStrings("p/z", second.objects[0].key);
            try std.testing.expect(second.cursor == null);
        }
    }.run);
}

test "s3 > credentials are checked" {
    try withS3("auth", struct {
        fn run(s3: *S3) !void {
            s3.access_key_id = "wrong-key";
            try std.testing.expectError(error.AccessDenied, s3.bucket().put("a", "b", .{}));
            s3.access_key_id = "";
            try std.testing.expectError(error.MissingCredentials, s3.bucket().put("a", "b", .{}));
        }
    }.run);
}

test "s3 > unsigned payloads" {
    try withS3("unsigned", struct {
        fn run(s3: *S3) !void {
            s3.sign_payload = false;
            try s3.bucket().put("a", "b", .{});
            try std.testing.expect(try s3.bucket().exists(gpa, "a"));
        }
    }.run);
}

test "s3 > streamed read" {
    try withS3("stream", struct {
        fn run(s3: *S3) !void {
            const b = s3.bucket();
            try std.testing.expect(try b.open(gpa, "missing", .{}) == null);
            try b.put("lines", "one\ntwo\nthree\n", .{ .content_type = "text/plain" });
            const r = (try b.open(gpa, "lines", .{ .range = .{ .offset = 4 } })).?;
            defer r.close();
            try std.testing.expectEqualStrings("text/plain", r.meta.content_type.?);
            try std.testing.expectEqualStrings("two", (try r.interface.takeDelimiter('\n')).?);
            try std.testing.expectEqualStrings("three", (try r.interface.takeDelimiter('\n')).?);
        }
    }.run);
}

test "s3 > small upload is a single put" {
    try withS3("small", struct {
        fn run(s3: *S3) !void {
            const b = s3.bucket();
            const up = try b.upload(gpa, "small.txt", .{ .content_type = "text/plain" });
            try up.writer.writeAll("tiny");
            try up.finish();
            const obj = (try b.get(gpa, "small.txt", .{})).?;
            defer obj.deinit();
            try std.testing.expectEqualStrings("tiny", obj.body);
            try std.testing.expectEqualStrings("text/plain", obj.meta.content_type.?);
        }
    }.run);
}

test "s3 > large upload goes in parts" {
    try withS3("multipart", struct {
        fn run(s3: *S3) !void {
            const b = s3.bucket();
            const chunk = try gpa.alloc(u8, 1024 * 1024);
            defer gpa.free(chunk);

            const up = try b.upload(gpa, "big.bin", .{ .content_type = "video/mp4", .metadata = &.{.{ .name = "owner", .value = "ana" }} });
            for (0..11) |i| {
                @memset(chunk, @intCast('a' + i));
                try up.writer.writeAll(chunk);
            }
            try up.finish();

            const obj = (try b.get(gpa, "big.bin", .{})).?;
            defer obj.deinit();
            try std.testing.expectEqual(11 * 1024 * 1024, obj.body.len);
            try std.testing.expectEqual('a', obj.body[0]);
            try std.testing.expectEqual('k', obj.body[obj.body.len - 1]);
            try std.testing.expectEqualStrings("video/mp4", obj.meta.content_type.?);
            try std.testing.expectEqualStrings("ana", obj.meta.get("owner").?);
        }
    }.run);
}

test "s3 > presigned URLs" {
    try withS3("presign", struct {
        fn run(s3: *S3) !void {
            const url = try s3.bucket().presign(gpa, "a b.txt", .{ .method = .PUT, .expires = 60 });
            defer gpa.free(url);
            try std.testing.expect(std.mem.startsWith(u8, url, "http://127.0.0.1:"));
            try std.testing.expect(std.mem.indexOf(u8, url, "/s3/presign/a%20b.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=test-key%2F") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "&X-Amz-Expires=60&") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "&X-Amz-Signature=") != null);
        }
    }.run);
}

test "s3 > upload rejects parts under 5 MiB" {
    var s3: S3 = .{ .io = io, .bucket_name = "b", .part_size = 1024 };
    try std.testing.expectError(error.InvalidOptions, s3.bucket().upload(gpa, "a", .{}));
}

// --- Wasm --- //

test "wasm > unavailable natively" {
    var w: Bucket.Wasm = .{};
    const b = w.bucket();
    try std.testing.expectError(error.Unavailable, b.put("a", "b", .{}));
    try std.testing.expectError(error.Unavailable, b.get(gpa, "a", .{}));
    try std.testing.expectError(error.Unavailable, b.list(gpa, .{}));
    try std.testing.expectError(error.Unavailable, b.upload(gpa, "a", .{}));
    try std.testing.expectError(error.Unavailable, b.presign(gpa, "a", .{}));
}
