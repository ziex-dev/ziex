// mysql_native_password, caching_sha2_password and sha256_password credentials.
// Scrambles and the RSA password exchange follow Bun's Zig client (MIT), see NOTICE;
// hashing and big-number math are std.crypto.
const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;
const Modulus = std.crypto.ff.Modulus(4096);
const Fe = Modulus.Fe;

pub const Error = error{
    InvalidPublicKey,
    PasswordTooLong,
    UnsupportedAuthentication,
};

pub const Plugin = enum {
    mysql_native_password,
    caching_sha2_password,
    sha256_password,

    pub fn fromName(plugin_name: []const u8) ?Plugin {
        const map = std.StaticStringMap(Plugin).initComptime(.{
            .{ "mysql_native_password", .mysql_native_password },
            .{ "caching_sha2_password", .caching_sha2_password },
            .{ "sha256_password", .sha256_password },
        });
        return map.get(plugin_name);
    }

    pub fn name(self: Plugin) []const u8 {
        return @tagName(self);
    }
};

/// SHA1(password) XOR SHA1(nonce + SHA1(SHA1(password))); empty for an empty password.
pub fn nativeScramble(password: []const u8, nonce: *const [20]u8) [20]u8 {
    if (password.len == 0) return @splat(0);
    var stage1: [Sha1.digest_length]u8 = undefined;
    var stage2: [Sha1.digest_length]u8 = undefined;
    var stage3: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(password, &stage1, .{});
    Sha1.hash(&stage1, &stage2, .{});
    var h: Sha1 = .init(.{});
    h.update(nonce);
    h.update(&stage2);
    h.final(&stage3);
    for (&stage3, stage1) |*out, s1| out.* ^= s1;
    return stage3;
}

/// SHA256(password) XOR SHA256(SHA256(SHA256(password)) + nonce).
pub fn cachingSha2Scramble(password: []const u8, nonce: *const [20]u8) [32]u8 {
    var d1: [Sha256.digest_length]u8 = undefined;
    var d2: [Sha256.digest_length]u8 = undefined;
    var d3: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(password, &d1, .{});
    Sha256.hash(&d1, &d2, .{});
    var h: Sha256 = .init(.{});
    h.update(&d2);
    h.update(nonce);
    h.final(&d3);
    for (&d3, d1) |*out, a| out.* ^= a;
    return d3;
}

pub const max_scramble_len = 32;

/// First auth response for `plugin`, written to `out`. sha256_password sends the password
/// only over TLS (cleartext, NUL-terminated); otherwise it asks for the server key (`\x01`).
pub fn initialResponse(out: *[512]u8, plugin: Plugin, password: []const u8, nonce: *const [20]u8, tls: bool) ![]const u8 {
    switch (plugin) {
        .mysql_native_password => {
            if (password.len == 0) return out[0..0];
            out[0..20].* = nativeScramble(password, nonce);
            return out[0..20];
        },
        .caching_sha2_password => {
            if (password.len == 0) return out[0..0];
            out[0..32].* = cachingSha2Scramble(password, nonce);
            return out[0..32];
        },
        .sha256_password => {
            if (password.len == 0) {
                out[0] = 0;
                return out[0..1];
            }
            if (!tls) {
                out[0] = 1;
                return out[0..1];
            }
            return cleartext(out, password);
        },
    }
}

/// Password followed by NUL, for sending over TLS.
pub fn cleartext(out: []u8, password: []const u8) Error![]const u8 {
    if (password.len + 1 > out.len) return Error.PasswordTooLong;
    @memcpy(out[0..password.len], password);
    out[password.len] = 0;
    return out[0 .. password.len + 1];
}

// --- RSA password exchange --- //

pub const max_rsa_bytes = 512;
const hash_len = Sha1.digest_length;

/// (password + NUL) XOR nonce (cycled), RSA-OAEP(SHA-1) encrypted with the server's PEM public key.
/// `seed` is the OAEP random seed. Returns a slice of `out`.
pub fn encryptPassword(out: *[max_rsa_bytes]u8, pem: []const u8, password: []const u8, nonce: *const [20]u8, seed: [hash_len]u8) ![]const u8 {
    var der_buf: [2048]u8 = undefined;
    const der = try pemToDer(&der_buf, pem);
    const key = try parsePublicKey(der);
    const k = (key.n.bits() + 7) / 8;
    if (k > max_rsa_bytes) return Error.InvalidPublicKey;
    // OAEP leaves k - 2*hLen - 2 bytes for the message
    if (k < 2 * hash_len + 2 or password.len + 1 > k - 2 * hash_len - 2) return Error.PasswordTooLong;

    var message: [max_rsa_bytes]u8 = undefined;
    const msg = message[0 .. password.len + 1];
    @memcpy(msg[0..password.len], password);
    msg[password.len] = 0;
    for (msg, 0..) |*b, i| b.* ^= nonce[i % nonce.len];
    defer std.crypto.secureZero(u8, &message);

    var em: [max_rsa_bytes]u8 = undefined;
    oaepEncode(em[0..k], msg, seed);

    const m = Fe.fromBytes(key.n, em[0..k], .big) catch return Error.InvalidPublicKey;
    const c = key.n.powPublic(m, key.e) catch return Error.InvalidPublicKey;
    c.toBytes(out[0..k], .big) catch return Error.InvalidPublicKey;
    return out[0..k];
}

/// RFC 8017 EME-OAEP with SHA-1 and an empty label.
fn oaepEncode(em: []u8, msg: []const u8, seed: [hash_len]u8) void {
    const db_len = em.len - hash_len - 1;
    const masked_seed = em[1..][0..hash_len];
    const db = em[1 + hash_len ..];
    em[0] = 0;
    Sha1.hash("", db[0..hash_len], .{});
    @memset(db[hash_len .. db_len - msg.len - 1], 0);
    db[db_len - msg.len - 1] = 1;
    @memcpy(db[db_len - msg.len ..], msg);

    mgfXor(db, &seed);
    masked_seed.* = seed;
    mgfXor(masked_seed, db);
}

/// `dst ^= MGF1-SHA1(seed, dst.len)`.
fn mgfXor(dst: []u8, seed: []const u8) void {
    var counter: u32 = 0;
    var at: usize = 0;
    while (at < dst.len) : (counter += 1) {
        var h: Sha1 = .init(.{});
        h.update(seed);
        h.update(&std.mem.toBytes(std.mem.nativeToBig(u32, counter)));
        var block: [hash_len]u8 = undefined;
        h.final(&block);
        const n = @min(hash_len, dst.len - at);
        for (dst[at..][0..n], block[0..n]) |*d, b| d.* ^= b;
        at += n;
    }
}

fn pemToDer(out: []u8, pem: []const u8) Error![]const u8 {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return Error.InvalidPublicKey;
    const header_end = std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return Error.InvalidPublicKey;
    const footer = std.mem.indexOfPos(u8, pem, header_end, "-----END") orelse return Error.InvalidPublicKey;

    var packed_b64: [4096]u8 = undefined;
    var n: usize = 0;
    for (pem[header_end..footer]) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        if (n == packed_b64.len) return Error.InvalidPublicKey;
        packed_b64[n] = ch;
        n += 1;
    }
    const size = std.base64.standard.Decoder.calcSizeForSlice(packed_b64[0..n]) catch return Error.InvalidPublicKey;
    if (size > out.len) return Error.InvalidPublicKey;
    std.base64.standard.Decoder.decode(out[0..size], packed_b64[0..n]) catch return Error.InvalidPublicKey;
    return out[0..size];
}

const Der = struct {
    tag: u8,
    body: []const u8,
    rest: []const u8,

    fn read(bytes: []const u8) Error!Der {
        if (bytes.len < 2) return Error.InvalidPublicKey;
        var len: usize = bytes[1];
        var at: usize = 2;
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            if (n == 0 or n > 3 or bytes.len < 2 + n) return Error.InvalidPublicKey;
            len = 0;
            for (bytes[2..][0..n]) |b| len = (len << 8) | b;
            at += n;
        }
        if (bytes.len - at < len) return Error.InvalidPublicKey;
        return .{ .tag = bytes[0], .body = bytes[at..][0..len], .rest = bytes[at + len ..] };
    }
};

/// SubjectPublicKeyInfo or bare PKCS#1 RSAPublicKey.
fn parsePublicKey(der: []const u8) Error!rsa.PublicKey {
    const outer = try Der.read(der);
    if (outer.tag != 0x30) return Error.InvalidPublicKey;
    const first = try Der.read(outer.body);
    const rsa_key = switch (first.tag) {
        // SPKI: SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
        0x30 => blk: {
            const bits = try Der.read(first.rest);
            if (bits.tag != 0x03 or bits.body.len < 1) return Error.InvalidPublicKey;
            const seq = try Der.read(bits.body[1..]);
            if (seq.tag != 0x30) return Error.InvalidPublicKey;
            break :blk seq.body;
        },
        // PKCS#1: SEQUENCE { INTEGER n, INTEGER e }
        0x02 => outer.body,
        else => return Error.InvalidPublicKey,
    };
    const n = try Der.read(rsa_key);
    const e = try Der.read(n.rest);
    if (n.tag != 0x02 or e.tag != 0x02) return Error.InvalidPublicKey;
    const modulus = std.mem.trimStart(u8, n.body, &.{0});
    return rsa.PublicKey.fromBytes(std.mem.trimStart(u8, e.body, &.{0}), modulus) catch Error.InvalidPublicKey;
}

// --- Tests --- //

const t = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "native password scramble" {
    const nonce = "abcdefghijklmnopqrst";
    try t.expectEqualSlices(u8, &hex("8817c50fa779daef010ee7577825b0847df9842e"), &nativeScramble("secret", nonce));
    try t.expectEqualSlices(u8, &@as([20]u8, @splat(0)), &nativeScramble("", nonce));
}

test "caching_sha2 scramble" {
    const nonce = "abcdefghijklmnopqrst";
    try t.expectEqualSlices(u8, &hex("c76e2898612a4cf042c77fa8c4702c4c64c0c2c557c53c4d75595aaa6abae809"), &cachingSha2Scramble("secret", nonce));
}

test "plugin names and initial responses" {
    try t.expectEqual(@as(?Plugin, .caching_sha2_password), Plugin.fromName("caching_sha2_password"));
    try t.expectEqual(@as(?Plugin, null), Plugin.fromName("authentication_ldap_client"));
    try t.expectEqualStrings("mysql_native_password", Plugin.mysql_native_password.name());

    var buf: [512]u8 = undefined;
    const nonce = "abcdefghijklmnopqrst";
    try t.expectEqual(@as(usize, 20), (try initialResponse(&buf, .mysql_native_password, "pw", nonce, false)).len);
    try t.expectEqual(@as(usize, 32), (try initialResponse(&buf, .caching_sha2_password, "pw", nonce, false)).len);
    try t.expectEqual(@as(usize, 0), (try initialResponse(&buf, .caching_sha2_password, "", nonce, false)).len);
    try t.expectEqualSlices(u8, "\x01", try initialResponse(&buf, .sha256_password, "pw", nonce, false));
    try t.expectEqualSlices(u8, "pw\x00", try initialResponse(&buf, .sha256_password, "pw", nonce, true));
}

const test_pem =
    \\-----BEGIN PUBLIC KEY-----
    \\MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDS17NFUyEwmpS5/FaEUWLTShqd
    \\NgowXOSf9LRohCSxIFZkcPQ7tLYBgJxb90+n/4TE3xEL+bgI4CXLAzc7LWFVCdep
    \\YUHUGJj00jha4NCYPnkkzyvJzK8Vw29GYmDTxNMra3/jeNrfIBbMTrhua2zusLth
    \\DYb0tKJHu8ffEEBJXQIDAQAB
    \\-----END PUBLIC KEY-----
    \\
;
const test_n = "d2d7b3455321309a94b9fc56845162d34a1a9d360a305ce49ff4b4688424b120566470f43bb4b601809c5bf74fa7ff84c4df110bf9b808e025cb03373b2d615509d7a96141d41898f4d2385ae0d0983e7924cf2bc9ccaf15c36f466260d3c4d32b6b7fe378dadf2016cc4eb86e6b6ceeb0bb610d86f4b4a247bbc7df1040495d";
const test_d = "4fcfa6e4cf1af9330aa97c83a382cb4dfff7231b99afc4fa263293381d0d669f3f14b64d3d6ca298defe5131c4cd6b43eee221a9ced583469607cb27d516d088984fb242f93784ae08d21a4b303b977fb89484eb4d304b2ef863d4bd1d7ade20fda4ec2c97db6dc0be98c158def77024e86f87fd619dee8d4c670215a256c901";

/// Test-only RSA-OAEP(SHA-1) decryption with the private key above.
fn decryptForTest(cipher: []const u8) ![]u8 {
    const n_bytes = hex(test_n);
    const d_bytes = hex(test_d);
    const n = try Modulus.fromBytes(&n_bytes, .big);
    const c = try Fe.fromBytes(n, cipher, .big);
    const m = try n.powWithEncodedExponent(c, &d_bytes, .big);
    var em: [n_bytes.len]u8 = undefined;
    try m.toBytes(&em, .big);

    try t.expectEqual(@as(u8, 0), em[0]);
    const masked_seed = em[1..][0..hash_len];
    const db = em[1 + hash_len ..];
    var seed: [hash_len]u8 = masked_seed.*;
    mgfXor(&seed, db);
    mgfXor(db, &seed);
    var l_hash: [hash_len]u8 = undefined;
    Sha1.hash("", &l_hash, .{});
    try t.expectEqualSlices(u8, &l_hash, db[0..hash_len]);
    const one = std.mem.indexOfScalarPos(u8, db, hash_len, 1) orelse return error.BadPadding;
    return t.allocator.dupe(u8, db[one + 1 ..]);
}

test "RSA OAEP password encryption decrypts to password XOR nonce" {
    const nonce = "abcdefghijklmnopqrst";
    var out: [max_rsa_bytes]u8 = undefined;
    const seed: [hash_len]u8 = @splat(0x5a);
    const cipher = try encryptPassword(&out, test_pem, "p@ssw0rd-that-is-long", nonce, seed);
    try t.expectEqual(@as(usize, 128), cipher.len);

    const plain = try decryptForTest(cipher);
    defer t.allocator.free(plain);
    const password = "p@ssw0rd-that-is-long\x00";
    try t.expectEqual(password.len, plain.len);
    for (plain, password, 0..) |got, want, i| try t.expectEqual(want ^ nonce[i % nonce.len], got);
}

test "RSA encryption is randomized by the seed and rejects bad input" {
    const nonce = "abcdefghijklmnopqrst";
    var a: [max_rsa_bytes]u8 = undefined;
    var b: [max_rsa_bytes]u8 = undefined;
    const c1 = try encryptPassword(&a, test_pem, "x", nonce, @splat(1));
    const c2 = try encryptPassword(&b, test_pem, "x", nonce, @splat(2));
    try t.expect(!std.mem.eql(u8, c1, c2));

    try t.expectError(Error.InvalidPublicKey, encryptPassword(&a, "not a key", "x", nonce, @splat(1)));
    try t.expectError(Error.InvalidPublicKey, encryptPassword(&a, "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n", "x", nonce, @splat(1)));
    // 128-byte key leaves 86 bytes for the message
    const long: [90]u8 = @splat('x');
    try t.expectError(Error.PasswordTooLong, encryptPassword(&a, test_pem, &long, nonce, @splat(1)));
}
