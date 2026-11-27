// AWS Signature Version 4 for S3, ported from Bun's `src/s3_signing/credentials.zig`
// (bun-v1.3.14). Unlike Bun's fixed header set, every header passed in is signed,
// so `x-amz-meta-*` and friends work; S3 rejects unsigned `x-amz-*` headers.
const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Header = std.http.Header;

pub const Error = error{ MissingCredentials, InvalidKey, InvalidOptions, OutOfMemory };

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: []const u8 = "",
    // Guessed from `endpoint` when empty.
    region: []const u8 = "",
    // `host[:port][/path]`, optionally with a scheme; AWS when empty.
    endpoint: []const u8 = "",
    bucket: []const u8,
    // `bucket.host/key` instead of `host/bucket/key`.
    virtual_hosted_style: bool = false,

    pub fn regionOrGuess(c: Credentials) []const u8 {
        return if (c.region.len > 0) c.region else guessRegion(c.endpoint);
    }
};

pub const Param = struct { name: []const u8, value: []const u8 = "" };

pub const Request = struct {
    method: []const u8,
    // Empty for bucket-level requests like ListObjectsV2.
    key: []const u8 = "",
    // Raw; encoded and sorted while signing.
    query: []const Param = &.{},
    // Sent and signed; names must be lowercase.
    headers: []const Header = &.{},
    // Hex SHA-256 of the body, or null to send `UNSIGNED-PAYLOAD`.
    payload_hash: ?[]const u8 = null,
};

pub const Signed = struct {
    url: []const u8,
    // Everything to send besides `host`, which the client derives from `url`.
    headers: []const Header,
};

pub const unsigned_payload = "UNSIGNED-PAYLOAD";
pub const empty_payload_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const service = "s3";

// Same rules as Bun: R2 and unknown endpoints get "auto", AWS ones their region.
pub fn guessRegion(endpoint: []const u8) []const u8 {
    if (endpoint.len == 0) return "us-east-1";
    const host = Endpoint.parse(endpoint).host;
    if (std.mem.endsWith(u8, host, ".r2.cloudflarestorage.com")) return "auto";
    if (std.mem.find(u8, host, ".amazonaws.com")) |end| {
        if (std.mem.find(u8, host, "s3.")) |start| {
            if (start + 3 < end) return host[start + 3 .. end];
        }
    }
    return "auto";
}

pub const Endpoint = struct {
    insecure: bool,
    // With the port, minus a default one.
    host: []const u8,
    // Leading path without the trailing slash, e.g. "/s3".
    path: []const u8,

    pub fn parse(endpoint: []const u8) Endpoint {
        var rest = endpoint;
        var insecure = false;
        if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
            rest = rest["https://".len..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
            rest = rest["http://".len..];
            insecure = true;
        }
        rest = std.mem.trimEnd(u8, rest, "/");
        const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
        var host = rest[0..slash];
        // Hosts drop the default port from `Host`, which must match the signed one.
        const default_port = if (insecure) ":80" else ":443";
        if (std.mem.endsWith(u8, host, default_port)) host = host[0 .. host.len - default_port.len];
        return .{ .insecure = insecure, .host = host, .path = rest[slash..] };
    }
};

// RFC 3986 unreserved characters pass through, all else is %XX (uppercase).
pub fn encodeUri(w: *std.Io.Writer, input: []const u8, comptime keep_slash: bool) std.Io.Writer.Error!void {
    for (input) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
        '/' => if (keep_slash) try w.writeByte('/') else try w.writeAll("%2F"),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn encodeAlloc(arena: std.mem.Allocator, input: []const u8, comptime keep_slash: bool) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    encodeUri(&out.writer, input, keep_slash) catch return error.OutOfMemory;
    return out.written();
}

pub const Date = struct {
    // `YYYYMMDDTHHMMSSZ`.
    buf: [16]u8,

    pub fn init(unix_seconds: i64) Date {
        const secs: u64 = @intCast(@max(0, unix_seconds));
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch_secs.getDaySeconds();
        var d: Date = undefined;
        _ = std.mem.print(&d.buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        }) catch unreachable;
        return d;
    }

    pub fn full(d: *const Date) []const u8 {
        return &d.buf;
    }

    pub fn day(d: *const Date) []const u8 {
        return d.buf[0..8];
    }
};

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn checkCredentials(c: Credentials) Error!void {
    if (c.access_key_id.len == 0 or c.secret_access_key.len == 0) return error.MissingCredentials;
    if (c.secret_access_key.len > max_secret_len) return error.InvalidOptions;
}

const max_secret_len = 252;

fn hmac(key: []const u8, msg: []const u8) [Hmac.mac_length]u8 {
    var out: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&out, msg, key);
    return out;
}

fn signingKey(secret: []const u8, day: []const u8, region: []const u8) [Hmac.mac_length]u8 {
    var key_buf: [4 + max_secret_len]u8 = undefined;
    const k_secret = std.mem.print(&key_buf, "AWS4{s}", .{secret}) catch unreachable;
    const k_date = hmac(k_secret, day);
    const k_region = hmac(&k_date, region);
    const k_service = hmac(&k_region, service);
    return hmac(&k_service, "aws4_request");
}

const Target = struct {
    endpoint: Endpoint,
    host: []const u8,
    // Canonical, already encoded.
    path: []const u8,
};

fn target(c: Credentials, arena: std.mem.Allocator, key: []const u8) Error!Target {
    if (c.bucket.len == 0) return error.InvalidOptions;
    const region = c.regionOrGuess();
    const ep: Endpoint = if (c.endpoint.len > 0) Endpoint.parse(c.endpoint) else .{ .insecure = false, .host = "", .path = "" };
    const host = if (ep.host.len > 0)
        ep.host
    else if (c.virtual_hosted_style)
        try arena.print("{s}.s3.{s}.amazonaws.com", .{ c.bucket, region })
    else
        try arena.print("s3.{s}.amazonaws.com", .{region});

    var path: std.Io.Writer.Allocating = .init(arena);
    const w = &path.writer;
    w.writeAll(ep.path) catch return error.OutOfMemory;
    if (!c.virtual_hosted_style) {
        w.writeByte('/') catch return error.OutOfMemory;
        encodeUri(w, c.bucket, false) catch return error.OutOfMemory;
    }
    w.writeByte('/') catch return error.OutOfMemory;
    encodeUri(w, key, true) catch return error.OutOfMemory;
    return .{ .endpoint = ep, .host = host, .path = path.written() };
}

const EncodedParam = struct { name: []const u8, value: []const u8 };

fn lessParam(_: void, a: EncodedParam, b: EncodedParam) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.value, b.value),
    };
}

fn canonicalQuery(arena: std.mem.Allocator, params: []const Param) Error![]const u8 {
    const encoded = try arena.alloc(EncodedParam, params.len);
    for (encoded, params) |*e, p| e.* = .{
        .name = try encodeAlloc(arena, p.name, false),
        .value = try encodeAlloc(arena, p.value, false),
    };
    std.mem.sort(EncodedParam, encoded, {}, lessParam);
    var out: std.Io.Writer.Allocating = .init(arena);
    for (encoded, 0..) |e, i| {
        out.writer.print("{s}{s}={s}", .{ if (i > 0) "&" else "", e.name, e.value }) catch return error.OutOfMemory;
    }
    return out.written();
}

fn lessHeader(_: void, a: Header, b: Header) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn checkValue(v: []const u8) Error!void {
    if (std.mem.findAny(u8, v, "\r\n") != null) return error.InvalidOptions;
}

fn stringToSign(arena: std.mem.Allocator, date: *const Date, region: []const u8, canonical: []const u8) Error![]const u8 {
    return arena.print("AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
        date.full(), date.day(), region, service, &sha256Hex(canonical),
    });
}

fn signature(c: Credentials, date: *const Date, region: []const u8, to_sign: []const u8) [64]u8 {
    const key = signingKey(c.secret_access_key, date.day(), region);
    return std.fmt.bytesToHex(hmac(&key, to_sign), .lower);
}

// Signs with the `Authorization` header.
pub fn sign(c: Credentials, arena: std.mem.Allocator, unix_seconds: i64, req: Request) Error!Signed {
    try checkCredentials(c);
    const region = c.regionOrGuess();
    const t = try target(c, arena, req.key);
    const date = Date.init(unix_seconds);
    const payload_hash = req.payload_hash orelse unsigned_payload;

    var headers: std.ArrayList(Header) = .empty;
    try headers.append(arena, .{ .name = "host", .value = t.host });
    try headers.append(arena, .{ .name = "x-amz-content-sha256", .value = payload_hash });
    try headers.append(arena, .{ .name = "x-amz-date", .value = try arena.dupe(u8, date.full()) });
    if (c.session_token.len > 0) try headers.append(arena, .{ .name = "x-amz-security-token", .value = c.session_token });
    for (req.headers) |h| {
        try checkValue(h.value);
        try headers.append(arena, .{ .name = h.name, .value = std.mem.trim(u8, h.value, " \t") });
    }
    std.mem.sort(Header, headers.items, {}, lessHeader);

    const query = try canonicalQuery(arena, req.query);
    var canonical: std.Io.Writer.Allocating = .init(arena);
    var signed_names: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &canonical.writer;
        w.print("{s}\n{s}\n{s}\n", .{ req.method, t.path, query }) catch return error.OutOfMemory;
        for (headers.items, 0..) |h, i| {
            w.print("{s}:{s}\n", .{ h.name, h.value }) catch return error.OutOfMemory;
            signed_names.writer.print("{s}{s}", .{ if (i > 0) ";" else "", h.name }) catch return error.OutOfMemory;
        }
        w.print("\n{s}\n{s}", .{ signed_names.written(), payload_hash }) catch return error.OutOfMemory;
    }

    const sig = signature(c, &date, region, try stringToSign(arena, &date, region, canonical.written()));
    const authorization = try arena.print("AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders={s}, Signature={s}", .{
        c.access_key_id, date.day(), region, service, signed_names.written(), &sig,
    });

    var send: std.ArrayList(Header) = .empty;
    for (headers.items) |h| if (!std.mem.eql(u8, h.name, "host")) try send.append(arena, h);
    try send.append(arena, .{ .name = "authorization", .value = authorization });

    return .{
        .url = try arena.print("{s}://{s}{s}{s}{s}", .{
            if (t.endpoint.insecure) "http" else "https", t.host, t.path, if (query.len > 0) "?" else "", query,
        }),
        .headers = send.items,
    };
}

// A query-signed URL valid for `expires` seconds; only `host` is signed, as in Bun.
pub fn presign(c: Credentials, arena: std.mem.Allocator, unix_seconds: i64, req: Request, expires: u32) Error![]const u8 {
    try checkCredentials(c);
    const region = c.regionOrGuess();
    const t = try target(c, arena, req.key);
    const date = Date.init(unix_seconds);

    var params: std.ArrayList(Param) = .empty;
    try params.appendSlice(arena, req.query);
    try params.appendSlice(arena, &.{
        .{ .name = "X-Amz-Algorithm", .value = "AWS4-HMAC-SHA256" },
        .{ .name = "X-Amz-Credential", .value = try arena.print("{s}/{s}/{s}/{s}/aws4_request", .{ c.access_key_id, date.day(), region, service }) },
        .{ .name = "X-Amz-Date", .value = try arena.dupe(u8, date.full()) },
        .{ .name = "X-Amz-Expires", .value = try arena.print("{d}", .{expires}) },
        .{ .name = "X-Amz-SignedHeaders", .value = "host" },
    });
    if (c.session_token.len > 0) try params.append(arena, .{ .name = "X-Amz-Security-Token", .value = c.session_token });
    for (req.query) |p| try checkValue(p.value);

    const query = try canonicalQuery(arena, params.items);
    const canonical = try arena.print("{s}\n{s}\n{s}\nhost:{s}\n\nhost\n{s}", .{
        req.method, t.path, query, t.host, unsigned_payload,
    });
    const sig = signature(c, &date, region, try stringToSign(arena, &date, region, canonical));
    return arena.print("{s}://{s}{s}?{s}&X-Amz-Signature={s}", .{
        if (t.endpoint.insecure) "http" else "https", t.host, t.path, query, &sig,
    });
}
