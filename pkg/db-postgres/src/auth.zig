// SCRAM-SHA-256 (RFC 5802 / 7677) and MD5 password auth.
// Flow adapted from Bun's Zig client (MIT), see NOTICE; crypto is std.crypto.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Md5 = std.crypto.hash.Md5;
const b64 = std.base64.standard;

pub const nonce_raw_len = 18;
// guard against a hostile server pinning the CPU in PBKDF2
const max_iterations = 10_000_000;

pub const Error = error{
    InvalidServerMessage,
    NonceMismatch,
    ServerSignatureMismatch,
    ServerRejected,
    BufferTooSmall,
};

pub const Scram = struct {
    // "n=<user>,r=<nonce>"
    first_bare_buf: [256]u8 = undefined,
    first_bare_len: usize = 0,
    nonce_start: usize = 0,
    server_signature: [HmacSha256.mac_length]u8 = undefined,
    awaiting_final: bool = false,

    /// Postgres ignores the SCRAM user name (it uses the startup message), so pass "*".
    pub fn init(user: []const u8, nonce: []const u8) Error!Scram {
        var self: Scram = .{};
        const prefix = std.fmt.bufPrint(&self.first_bare_buf, "n={s},r=", .{user}) catch return Error.BufferTooSmall;
        self.nonce_start = prefix.len;
        if (prefix.len + nonce.len > self.first_bare_buf.len) return Error.BufferTooSmall;
        @memcpy(self.first_bare_buf[prefix.len..][0..nonce.len], nonce);
        self.first_bare_len = prefix.len + nonce.len;
        return self;
    }

    /// Random printable nonce from 18 raw bytes.
    pub fn randomNonce(io: std.Io, out: *[b64.Encoder.calcSize(nonce_raw_len)]u8) []const u8 {
        var raw: [nonce_raw_len]u8 = undefined;
        io.random(&raw);
        return b64.Encoder.encode(out, &raw);
    }

    fn firstBare(self: *const Scram) []const u8 {
        return self.first_bare_buf[0..self.first_bare_len];
    }

    fn clientNonce(self: *const Scram) []const u8 {
        return self.first_bare_buf[self.nonce_start..self.first_bare_len];
    }

    /// client-first-message: GS2 header (no channel binding) + bare message.
    pub fn clientFirst(self: *const Scram, buf: []u8) Error![]const u8 {
        return std.fmt.bufPrint(buf, "n,,{s}", .{self.firstBare()}) catch Error.BufferTooSmall;
    }

    /// client-final-message for the given server-first-message; caller owns the result.
    pub fn clientFinal(self: *Scram, gpa: std.mem.Allocator, password: []const u8, server_first: []const u8) ![]u8 {
        var r: ?[]const u8 = null;
        var s: ?[]const u8 = null;
        var i: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') continue;
            switch (attr[0]) {
                'r' => r = attr[2..],
                's' => s = attr[2..],
                'i' => i = attr[2..],
                else => {},
            }
        }
        const server_nonce = r orelse return Error.InvalidServerMessage;
        const salt_b64 = s orelse return Error.InvalidServerMessage;
        const iterations = std.fmt.parseInt(u32, i orelse return Error.InvalidServerMessage, 10) catch
            return Error.InvalidServerMessage;
        if (iterations == 0 or iterations > max_iterations) return Error.InvalidServerMessage;
        // server nonce must extend ours
        if (!std.mem.startsWith(u8, server_nonce, self.clientNonce()) or server_nonce.len == self.clientNonce().len)
            return Error.NonceMismatch;

        const salt_len = b64.Decoder.calcSizeForSlice(salt_b64) catch return Error.InvalidServerMessage;
        const salt = try gpa.alloc(u8, salt_len);
        defer gpa.free(salt);
        b64.Decoder.decode(salt, salt_b64) catch return Error.InvalidServerMessage;

        var salted: [HmacSha256.mac_length]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, HmacSha256);
        defer std.crypto.secureZero(u8, &salted);

        const without_proof = try std.fmt.allocPrint(gpa, "c=biws,r={s}", .{server_nonce});
        defer gpa.free(without_proof);
        const auth_message = try std.fmt.allocPrint(gpa, "{s},{s},{s}", .{ self.firstBare(), server_first, without_proof });
        defer gpa.free(auth_message);

        const client_key = hmac(&salted, "Client Key");
        var stored_key: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});
        const client_signature = hmac(&stored_key, auth_message);
        var proof: [HmacSha256.mac_length]u8 = undefined;
        for (&proof, client_key, client_signature) |*out, a, b| out.* = a ^ b;

        const server_key = hmac(&salted, "Server Key");
        self.server_signature = hmac(&server_key, auth_message);
        self.awaiting_final = true;

        var proof_b64: [b64.Encoder.calcSize(proof.len)]u8 = undefined;
        return std.fmt.allocPrint(gpa, "{s},p={s}", .{ without_proof, b64.Encoder.encode(&proof_b64, &proof) });
    }

    pub fn verifyServerFinal(self: *Scram, server_final: []const u8) Error!void {
        if (!self.awaiting_final) return Error.InvalidServerMessage;
        self.awaiting_final = false;
        if (std.mem.startsWith(u8, server_final, "e=")) return Error.ServerRejected;
        if (!std.mem.startsWith(u8, server_final, "v=")) return Error.InvalidServerMessage;

        const sig_b64 = std.mem.trimEnd(u8, server_final[2..], ",");
        var sig: [HmacSha256.mac_length]u8 = undefined;
        const len = b64.Decoder.calcSizeForSlice(sig_b64) catch return Error.InvalidServerMessage;
        if (len != sig.len) return Error.ServerSignatureMismatch;
        b64.Decoder.decode(&sig, sig_b64) catch return Error.InvalidServerMessage;
        if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, sig, self.server_signature))
            return Error.ServerSignatureMismatch;
    }
};

fn hmac(key: []const u8, msg: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, msg, key);
    return out;
}

/// "md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt))
pub fn md5Password(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    var inner: [Md5.digest_length]u8 = undefined;
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var outer: [Md5.digest_length]u8 = undefined;
    h = Md5.init(.{});
    h.update(&inner_hex);
    h.update(&salt);
    h.final(&outer);

    var out: [35]u8 = undefined;
    @memcpy(out[0..3], "md5");
    out[3..].* = std.fmt.bytesToHex(outer, .lower);
    return out;
}

// --- Tests --- //

const t = std.testing;

test "scram-sha-256 RFC 7677 vector" {
    var scram = try Scram.init("user", "rOprNGfwEbeRWgbNEkqO");
    var first_buf: [128]u8 = undefined;
    try t.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try scram.clientFirst(&first_buf));

    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const final = try scram.clientFinal(t.allocator, "pencil", server_first);
    defer t.allocator.free(final);
    try t.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        final,
    );
    try scram.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
}

test "scram rejects bad server responses" {
    var scram = try Scram.init("*", "abc");
    try t.expectError(Error.NonceMismatch, scram.clientFinal(t.allocator, "pw", "r=zzz123,s=QSXCR+Q6sek8bf92,i=4096"));
    try t.expectError(Error.InvalidServerMessage, scram.clientFinal(t.allocator, "pw", "r=abc123,i=4096"));

    const final = try scram.clientFinal(t.allocator, "pw", "r=abc123,s=QSXCR+Q6sek8bf92,i=16");
    t.allocator.free(final);
    try t.expectError(Error.ServerSignatureMismatch, scram.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
}

test "md5 password" {
    const out = md5Password("user", "pencil", .{ 1, 2, 3, 4 });
    try t.expectEqualStrings("md54376eb6913b38f9aaff38dc7cf19ca76", &out);
}
