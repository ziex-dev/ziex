const std = @import("std");

pub const Cbor = @import("WebAuthn/Cbor.zig");

pub const RelyingParty = struct {
    id: []const u8,
    name: []const u8,
    origin: []const u8,

    pub fn fromOrigin(name: []const u8, origin: []const u8) !RelyingParty {
        const uri = std.Uri.parse(origin) catch return error.InvalidOrigin;
        const host = uri.host orelse return error.InvalidOrigin;
        return .{ .id = host.percent_encoded, .name = name, .origin = origin };
    }
};

// Base64url of 24 random bytes and the big-endian issue time in seconds. The browser
// echoes it inside the signed `clientDataJSON`, so the time can't be altered and a
// captured answer stops working once the challenge is `timeout_s` old.
pub const Challenge = [43]u8;

pub const timeout_s = 5 * std.time.s_per_min;

pub fn newChallenge(io: std.Io) Challenge {
    var bytes: [32]u8 = undefined;
    io.random(bytes[0..24]);
    std.mem.writeInt(i64, bytes[24..32], std.Io.Timestamp.now(io, .real).toSeconds(), .big);
    var out: Challenge = undefined;
    _ = b64.Encoder.encode(&out, &bytes);
    return out;
}

pub fn issuedAt(challenge: Challenge) ?i64 {
    var bytes: [32]u8 = undefined;
    b64.Decoder.decode(&bytes, &challenge) catch return null;
    return std.mem.readInt(i64, bytes[24..32], .big);
}

// COSE ids. ES256 covers every platform authenticator, Ed25519 most security keys.
pub const Algorithm = enum(i64) { es256 = -7, ed25519 = -8 };

pub const User = struct {
    // Stable per account and free of personal data, so registering again replaces
    // the authenticator's old passkey instead of adding a second one.
    handle: []const u8,
    name: []const u8,
};

const Descriptor = struct { type: []const u8 = "public-key", id: []const u8 };

pub fn creationOptions(arena: std.mem.Allocator, rp: RelyingParty, user: User, challenge: []const u8, exclude: []const []const u8) ![]const u8 {
    const excluded = try arena.alloc(Descriptor, exclude.len);
    for (excluded, exclude) |*d, id| d.* = .{ .id = id };
    return std.json.Stringify.valueAlloc(arena, .{ .publicKey = .{
        .rp = .{ .id = rp.id, .name = rp.name },
        .user = .{ .id = try encode(arena, user.handle), .name = user.name, .displayName = user.name },
        .challenge = challenge,
        .pubKeyCredParams = [_]struct { type: []const u8 = "public-key", alg: i64 }{
            .{ .alg = @backingInt(Algorithm.es256) },
            .{ .alg = @backingInt(Algorithm.ed25519) },
        },
        .timeout = timeout_s * std.time.ms_per_s,
        .excludeCredentials = excluded,
        .authenticatorSelection = .{ .residentKey = "required", .requireResidentKey = true, .userVerification = "required" },
        .attestation = "none",
    } }, .{});
}

// No allow-list: the browser offers whichever passkeys it holds for the site.
pub fn requestOptions(arena: std.mem.Allocator, rp: RelyingParty, challenge: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .publicKey = .{
        .rpId = rp.id,
        .challenge = challenge,
        .timeout = timeout_s * std.time.ms_per_s,
        .userVerification = "required",
        .allowCredentials = [_]Descriptor{},
    } }, .{});
}

// `public_key` is SEC1 uncompressed for ES256 and the raw 32 bytes for Ed25519.
pub const Credential = struct {
    id: []const u8,
    algorithm: Algorithm,
    public_key: []const u8,
    sign_count: u32,
};

pub fn verifyRegistration(arena: std.mem.Allocator, rp: RelyingParty, challenge: Challenge, body: []const u8) !Credential {
    const msg = std.json.parseFromSliceLeaky(struct {
        id: []const u8,
        response: struct { clientDataJSON: []const u8, attestationObject: []const u8 },
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;

    try checkClientData(arena, rp, challenge, "webauthn.create", try decode(arena, msg.response.clientDataJSON));
    const data = try authenticatorData(rp, try attestedAuthData(try decode(arena, msg.response.attestationObject)));
    if (data.flags & flag_attested == 0) return error.InvalidResponse;

    // aaguid(16) | id length(2) | id | COSE key
    if (data.rest.len < 18) return error.InvalidResponse;
    const id_len = std.mem.readInt(u16, data.rest[16..18], .big);
    if (id_len == 0 or id_len > 1023 or data.rest.len < 18 + id_len) return error.InvalidResponse;
    const id = try encode(arena, data.rest[18..][0..id_len]);
    if (!std.mem.eql(u8, id, msg.id)) return error.InvalidResponse;

    var reader: Cbor = .{ .data = data.rest[18 + id_len ..] };
    const key = try coseKey(arena, &reader);
    return .{ .id = id, .algorithm = key.algorithm, .public_key = key.bytes, .sign_count = data.sign_count };
}

pub const Assertion = struct {
    credential_id: []const u8,
    client_data: []const u8,
    authenticator_data: []const u8,
    signature: []const u8,
    user_handle: ?[]const u8 = null,
};

pub fn parseAssertion(arena: std.mem.Allocator, body: []const u8) !Assertion {
    const msg = std.json.parseFromSliceLeaky(struct {
        id: []const u8,
        response: struct {
            clientDataJSON: []const u8,
            authenticatorData: []const u8,
            signature: []const u8,
            userHandle: ?[]const u8 = null,
        },
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    const handle = msg.response.userHandle orelse "";
    return .{
        .credential_id = msg.id,
        .client_data = try decode(arena, msg.response.clientDataJSON),
        .authenticator_data = try decode(arena, msg.response.authenticatorData),
        .signature = try decode(arena, msg.response.signature),
        .user_handle = if (handle.len == 0) null else try decode(arena, handle),
    };
}

// Returns the counter to store. Synced passkeys always report 0; otherwise a
// counter that stops rising suggests a cloned authenticator.
pub fn verifyAssertion(arena: std.mem.Allocator, rp: RelyingParty, challenge: Challenge, assertion: Assertion, algorithm: Algorithm, public_key: []const u8, stored_count: u32) !u32 {
    try checkClientData(arena, rp, challenge, "webauthn.get", assertion.client_data);
    const data = try authenticatorData(rp, assertion.authenticator_data);

    var client_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(assertion.client_data, &client_hash, .{});
    try verifySignature(algorithm, public_key, assertion.signature, &.{ assertion.authenticator_data, &client_hash });

    if ((data.sign_count != 0 or stored_count != 0) and data.sign_count <= stored_count) return error.CounterRegressed;
    return data.sign_count;
}

fn checkClientData(arena: std.mem.Allocator, rp: RelyingParty, challenge: Challenge, kind: []const u8, raw: []const u8) !void {
    const client = std.json.parseFromSliceLeaky(struct {
        type: []const u8,
        challenge: []const u8,
        origin: []const u8,
        crossOrigin: bool = false,
    }, arena, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (!std.mem.eql(u8, client.type, kind)) return error.InvalidResponse;
    if (client.challenge.len != challenge.len or !std.crypto.timing_safe.eql(Challenge, client.challenge[0..challenge.len].*, challenge))
        return error.ChallengeMismatch;
    if (!std.mem.eql(u8, client.origin, rp.origin) or client.crossOrigin) return error.OriginMismatch;
}

const flag_user_present = 0x01;
const flag_user_verified = 0x04;
const flag_attested = 0x40;

const AuthenticatorData = struct { flags: u8, sign_count: u32, rest: []const u8 };

// rpIdHash(32) | flags(1) | signCount(4) | …
fn authenticatorData(rp: RelyingParty, data: []const u8) !AuthenticatorData {
    if (data.len < 37) return error.InvalidResponse;
    var rp_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(rp.id, &rp_hash, .{});
    if (!std.mem.eql(u8, data[0..32], &rp_hash)) return error.RelyingPartyMismatch;
    const flags = data[32];
    if (flags & flag_user_present == 0 or flags & flag_user_verified == 0) return error.UserNotVerified;
    return .{ .flags = flags, .sign_count = std.mem.readInt(u32, data[33..37], .big), .rest = data[37..] };
}

// The attestation statement itself is ignored; only `authData` matters with "none".
fn attestedAuthData(object: []const u8) ![]const u8 {
    var r: Cbor = .{ .data = object };
    const pairs = r.expect(.map) catch return error.InvalidResponse;
    for (0..pairs) |_| {
        const key = r.next() catch return error.InvalidResponse;
        if (key == .text and std.mem.eql(u8, key.text, "authData")) return r.expect(.bytes) catch error.InvalidResponse;
        r.skip() catch return error.InvalidResponse;
    }
    return error.InvalidResponse;
}

const CoseKey = struct { algorithm: Algorithm, bytes: []const u8 };

fn coseKey(arena: std.mem.Allocator, r: *Cbor) !CoseKey {
    var kty: ?i64 = null;
    var alg: ?i64 = null;
    var crv: ?i64 = null;
    var x: ?[]const u8 = null;
    var y: ?[]const u8 = null;
    for (0..r.expect(.map) catch return error.InvalidResponse) |_| switch (r.expect(.int) catch return error.InvalidResponse) {
        1 => kty = r.expect(.int) catch return error.InvalidResponse,
        3 => alg = r.expect(.int) catch return error.InvalidResponse,
        -1 => crv = r.expect(.int) catch return error.InvalidResponse,
        -2 => x = r.expect(.bytes) catch return error.InvalidResponse,
        -3 => y = r.expect(.bytes) catch return error.InvalidResponse,
        else => r.skip() catch return error.InvalidResponse,
    };

    const algorithm = std.enums.fromInt(Algorithm, alg orelse return error.InvalidResponse) orelse return error.UnsupportedAlgorithm;
    switch (algorithm) {
        .es256 => {
            if (kty != 2 or crv != 1) return error.UnsupportedAlgorithm;
            const px = x orelse return error.InvalidResponse;
            const py = y orelse return error.InvalidResponse;
            if (px.len != 32 or py.len != 32) return error.InvalidResponse;
            const sec1 = try std.mem.concat(arena, u8, &.{ &.{0x04}, px, py });
            _ = Es256.PublicKey.fromSec1(sec1) catch return error.InvalidResponse;
            return .{ .algorithm = algorithm, .bytes = sec1 };
        },
        .ed25519 => {
            if (kty != 1 or crv != 6) return error.UnsupportedAlgorithm;
            const px = x orelse return error.InvalidResponse;
            if (px.len != Ed25519.PublicKey.encoded_length) return error.InvalidResponse;
            _ = Ed25519.PublicKey.fromBytes(px[0..32].*) catch return error.InvalidResponse;
            return .{ .algorithm = algorithm, .bytes = px };
        },
    }
}

fn verifySignature(algorithm: Algorithm, public_key: []const u8, signature: []const u8, parts: []const []const u8) !void {
    switch (algorithm) {
        .es256 => {
            const pk = Es256.PublicKey.fromSec1(public_key) catch return error.BadSignature;
            const sig = Es256.Signature.fromDer(signature) catch return error.BadSignature;
            var v = sig.verifier(pk) catch return error.BadSignature;
            for (parts) |p| v.update(p);
            v.verify() catch return error.BadSignature;
        },
        .ed25519 => {
            if (public_key.len != Ed25519.PublicKey.encoded_length or signature.len != Ed25519.Signature.encoded_length) return error.BadSignature;
            const pk = Ed25519.PublicKey.fromBytes(public_key[0..32].*) catch return error.BadSignature;
            var v = Ed25519.Signature.fromBytes(signature[0..64].*).verifier(pk) catch return error.BadSignature;
            for (parts) |p| v.update(p);
            v.verify() catch return error.BadSignature;
        },
    }
}

const b64 = std.base64.url_safe_no_pad;

pub fn encode(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, b64.Encoder.calcSize(raw.len));
    return b64.Encoder.encode(out, raw);
}

pub fn decode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, b64.Decoder.calcSizeForSlice(text) catch return error.InvalidResponse);
    b64.Decoder.decode(out, text) catch return error.InvalidResponse;
    return out;
}

// Runs a passkey ceremony from any `[data-passkey="register"|"login"]` button:
// fetches `data-options`, hands them to the browser, posts its answer to
// `data-verify` and follows the `{"redirect": url}` that comes back. A register
// button may name the passkey label input in `data-name`. On failure the page goes
// to `data-error`, or `data-exists` when the authenticator already holds a passkey.
// Render it after the buttons; browsers without passkeys get them hidden.
pub const script =
    \\(() => {
    \\  const buttons = document.querySelectorAll("[data-passkey]");
    \\  if (!window.PublicKeyCredential) return buttons.forEach((b) => (b.hidden = true));
    \\  const decode = (s) => Uint8Array.from(atob(s.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
    \\  const encode = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
    \\  const post = async (url, body) => {
    \\    const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body ?? {}) });
    \\    return res.json();
    \\  };
    \\  async function run(d) {
    \\    const options = await post(d.options);
    \\    if (options.redirect) return location.assign(options.redirect);
    \\    const pk = options.publicKey;
    \\    pk.challenge = decode(pk.challenge);
    \\    let body;
    \\    if (d.passkey === "register") {
    \\      pk.user.id = decode(pk.user.id);
    \\      pk.excludeCredentials = pk.excludeCredentials.map((c) => ({ ...c, id: decode(c.id) }));
    \\      const cred = await navigator.credentials.create({ publicKey: pk });
    \\      body = {
    \\        id: cred.id,
    \\        name: document.getElementById(d.name)?.value ?? "",
    \\        response: { clientDataJSON: encode(cred.response.clientDataJSON), attestationObject: encode(cred.response.attestationObject) },
    \\      };
    \\    } else {
    \\      const cred = await navigator.credentials.get({ publicKey: pk });
    \\      body = {
    \\        id: cred.id,
    \\        response: {
    \\          clientDataJSON: encode(cred.response.clientDataJSON),
    \\          authenticatorData: encode(cred.response.authenticatorData),
    \\          signature: encode(cred.response.signature),
    \\          userHandle: cred.response.userHandle ? encode(cred.response.userHandle) : null,
    \\        },
    \\      };
    \\    }
    \\    location.assign((await post(d.verify, body)).redirect);
    \\  }
    \\  buttons.forEach((b) => b.addEventListener("click", () => {
    \\    b.disabled = true;
    \\    run(b.dataset)
    \\      .catch((err) => {
    \\        // Cancelling the browser prompt is not an error worth a page.
    \\        if (err.name === "NotAllowedError" || err.name === "AbortError") return;
    \\        location.assign((err.name === "InvalidStateError" && b.dataset.exists) || b.dataset.error);
    \\      })
    \\      .finally(() => (b.disabled = false));
    \\  }));
    \\})();
;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Es256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
