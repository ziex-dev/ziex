const std = @import("std");

pub const Algorithm = enum { HS256, ES256, EdDSA };

// HS256 secrets shorter than the hash are refused (RFC 7518 §3.2).
pub const min_secret_len = HmacSha256.mac_length;

// Tokens longer than this are refused before anything is decoded.
pub const max_len = 16 * 1024;

pub const SigningKey = union(Algorithm) {
    HS256: []const u8,
    ES256: Es256.KeyPair,
    EdDSA: Ed25519.KeyPair,

    pub fn verifyingKey(key: SigningKey) VerifyingKey {
        return switch (key) {
            .HS256 => |secret| .{ .HS256 = secret },
            .ES256 => |pair| .{ .ES256 = pair.public_key },
            .EdDSA => |pair| .{ .EdDSA = pair.public_key },
        };
    }
};

pub const VerifyingKey = union(Algorithm) {
    HS256: []const u8,
    ES256: Es256.PublicKey,
    EdDSA: Ed25519.PublicKey,
};

pub const Error = error{
    Malformed,
    WeakKey,
    AlgorithmMismatch,
    BadSignature,
    Expired,
    NotYetValid,
    MissingExpiry,
    IssuerMismatch,
    AudienceMismatch,
    OutOfMemory,
};

pub const Validation = struct {
    // Unix seconds, e.g. `std.Io.Timestamp.now(io, .real).toSeconds()`.
    now: i64,
    // Allowed clock skew for `exp` and `nbf`.
    leeway_s: i64 = 30,
    // When set, `iss` must equal it.
    issuer: ?[]const u8 = null,
    // When set, `aud` (a string or an array) must contain it.
    audience: ?[]const u8 = null,
    // A token without `exp` never expires, so one is required unless turned off.
    require_exp: bool = true,
};

// Serializes `claims` (null optional fields left out) and signs it.
pub fn encode(arena: std.mem.Allocator, claims: anytype, key: SigningKey) Error![]const u8 {
    const header = switch (key) {
        inline else => |_, alg| "{\"alg\":\"" ++ @tagName(alg) ++ "\",\"typ\":\"JWT\"}",
    };
    const payload = std.json.Stringify.valueAlloc(arena, claims, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;

    var out: std.ArrayList(u8) = .empty;
    try appendBase64(arena, &out, header);
    try out.append(arena, '.');
    try appendBase64(arena, &out, payload);

    var sig_buf: [64]u8 = undefined;
    const sig = try sign(key, out.items, &sig_buf);
    try out.append(arena, '.');
    try appendBase64(arena, &out, sig);
    return out.toOwnedSlice(arena);
}

// Verifies the signature and registered claims, then parses the payload as `Claims`
// (unknown fields ignored).
pub fn decode(arena: std.mem.Allocator, comptime Claims: type, token: []const u8, key: VerifyingKey, validation: Validation) Error!Claims {
    if (token.len > max_len) return error.Malformed;
    const first = std.mem.indexOfScalar(u8, token, '.') orelse return error.Malformed;
    const second = first + 1 + (std.mem.indexOfScalar(u8, token[first + 1 ..], '.') orelse return error.Malformed);
    if (std.mem.indexOfScalar(u8, token[second + 1 ..], '.') != null) return error.Malformed;

    const header = std.json.parseFromSliceLeaky(struct {
        alg: []const u8,
        crit: ?std.json.Value = null,
    }, arena, try decodeBase64(arena, token[0..first]), .{ .ignore_unknown_fields = true }) catch return error.Malformed;
    // No extensions are understood, so any critical one fails the token (RFC 7515 §4.1.11).
    if (header.crit != null) return error.Malformed;
    if (!std.mem.eql(u8, header.alg, @tagName(key))) return error.AlgorithmMismatch;

    try verify(key, token[0..second], try decodeBase64(arena, token[second + 1 ..]));

    const payload = try decodeBase64(arena, token[first + 1 .. second]);
    const registered = std.json.parseFromSliceLeaky(struct {
        exp: ?f64 = null,
        nbf: ?f64 = null,
        iss: ?[]const u8 = null,
        aud: ?std.json.Value = null,
    }, arena, payload, .{ .ignore_unknown_fields = true }) catch return error.Malformed;

    const now: f64 = @floatFromInt(validation.now);
    const leeway: f64 = @floatFromInt(validation.leeway_s);
    if (registered.exp) |exp| {
        if (now >= exp + leeway) return error.Expired;
    } else if (validation.require_exp) return error.MissingExpiry;
    if (registered.nbf) |nbf| if (now + leeway < nbf) return error.NotYetValid;

    if (validation.issuer) |want| {
        if (!std.mem.eql(u8, registered.iss orelse "", want)) return error.IssuerMismatch;
    }
    if (validation.audience) |want| {
        if (!hasAudience(registered.aud orelse return error.AudienceMismatch, want)) return error.AudienceMismatch;
    }

    return std.json.parseFromSliceLeaky(Claims, arena, payload, .{ .ignore_unknown_fields = true }) catch error.Malformed;
}

fn hasAudience(aud: std.json.Value, want: []const u8) bool {
    switch (aud) {
        .string => |s| return std.mem.eql(u8, s, want),
        .array => |list| for (list.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, want)) return true;
        },
        else => {},
    }
    return false;
}

fn sign(key: SigningKey, input: []const u8, buf: *[64]u8) Error![]const u8 {
    switch (key) {
        .HS256 => |secret| {
            if (secret.len < min_secret_len) return error.WeakKey;
            HmacSha256.create(buf[0..HmacSha256.mac_length], input, secret);
            return buf[0..HmacSha256.mac_length];
        },
        .ES256 => |pair| {
            buf.* = (pair.sign(input, null) catch return error.WeakKey).toBytes();
            return buf;
        },
        .EdDSA => |pair| {
            buf.* = (pair.sign(input, null) catch return error.WeakKey).toBytes();
            return buf;
        },
    }
}

fn verify(key: VerifyingKey, input: []const u8, signature: []const u8) Error!void {
    switch (key) {
        .HS256 => |secret| {
            if (secret.len < min_secret_len) return error.WeakKey;
            if (signature.len != HmacSha256.mac_length) return error.BadSignature;
            var expected: [HmacSha256.mac_length]u8 = undefined;
            HmacSha256.create(&expected, input, secret);
            if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, signature[0..HmacSha256.mac_length].*)) return error.BadSignature;
        },
        // JWS carries ECDSA signatures as raw r || s, not DER (RFC 7518 §3.4).
        .ES256 => |pk| {
            if (signature.len != Es256.Signature.encoded_length) return error.BadSignature;
            const sig = Es256.Signature.fromBytes(signature[0..Es256.Signature.encoded_length].*);
            sig.verify(input, pk) catch return error.BadSignature;
        },
        .EdDSA => |pk| {
            if (signature.len != Ed25519.Signature.encoded_length) return error.BadSignature;
            const sig = Ed25519.Signature.fromBytes(signature[0..Ed25519.Signature.encoded_length].*);
            sig.verify(input, pk) catch return error.BadSignature;
        },
    }
}

fn appendBase64(arena: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) Error!void {
    const dest = try out.addManyAsSlice(arena, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(dest, raw);
}

fn decodeBase64(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    const out = try arena.alloc(u8, b64.Decoder.calcSizeForSlice(text) catch return error.Malformed);
    b64.Decoder.decode(out, text) catch return error.Malformed;
    return out;
}

const b64 = std.base64.url_safe_no_pad;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Es256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
