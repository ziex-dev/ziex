// Parsers for structured data that can arrive from clients, storage or other services.
const std = @import("std");
const zx = @import("zx");
const Smith = std.testing.Smith;
const util = @import("util.zig");

const zxon = zx.util.zxon;

const Status = enum { pending, active, done };
const Inner = struct { value: i32, flag: bool };
const Props = struct {
    count: i32,
    ratio: f32 = 0,
    label: []const u8 = "",
    tags: []const []const u8 = &.{},
    inner: ?Inner = null,
    status: Status = .pending,
    scores: [2]u8 = .{ 0, 0 },
};

test "fuzz: zxon parse" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const input = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const props = zxon.parse(Props, a, input, .{}) catch return;
            // Whatever parses must re-encode and parse back to the same value.
            var w: std.Io.Writer.Allocating = .init(a);
            try zxon.serialize(props, &w.writer, .{});
            const again = try zxon.parse(Props, a, w.written(), .{});
            try std.testing.expectEqual(props.count, again.count);
            try std.testing.expectEqualStrings(props.label, again.label);
            try std.testing.expectEqual(props.status, again.status);
            try std.testing.expectEqual(props.tags.len, again.tags.len);
        }
    }.run, .{ .corpus = util.seeds(&.{
        "[1]",
        "[-5,1.5,\"a\\\"b\\n\",[\"x\",\"y\"],[3,true],2,[1,2]]",
        "[0,0,\"\",[],null,1,[0,0]]",
    }) });
}

test "fuzz: kv typed decode" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [512]u8 = undefined;
            const input = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = zx.Kv.Meta.split(zx.Kv.Meta.Typed, input);
            _ = zx.Kv.decodeTyped(Props, arena.allocator(), input) catch {};
        }
    }.run, .{ .corpus = util.seeds(&.{"[1,1]\n[2]"}) });
}

test "fuzz: mcp jsonrpc parse" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [512]u8 = undefined;
            const input = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const msg = zx.mcp.jsonrpc.parse(arena.allocator(), input) catch return;
            // Replies echo the id back.
            _ = try zx.mcp.jsonrpc.writeError(arena.allocator(), msg.id orelse .null, -32600, "x");
        }
    }.run, .{ .corpus = util.seeds(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1e300,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    }) });
}

const jwt_secret = "0123456789abcdef0123456789abcdef";

test "fuzz: jwt decode" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const Jwt = zx.Auth.Jwt;
            const Claims = struct { sub: []const u8 = "", admin: bool = false };
            const validation: Jwt.Validation = .{ .now = 1_700_000_000, .issuer = if (s.value(bool)) "iss" else null, .audience = if (s.value(bool)) "aud" else null };
            const key: Jwt.VerifyingKey = .{ .HS256 = jwt_secret };

            var header_buf: [128]u8 = undefined;
            var payload_buf: [512]u8 = undefined;
            const header = util.bytes(s, &header_buf);
            const payload = util.bytes(s, &payload_buf);

            // Raw token: must never verify without the secret.
            var token_buf: [1024]u8 = undefined;
            const raw = util.bytes(s, &token_buf);
            if (Jwt.decode(a, Claims, raw, key, validation)) |_| return error.ForgedToken else |_| {}

            // Correctly signed token with fuzzed header/payload exercises claim parsing.
            const b64 = std.base64.url_safe_no_pad.Encoder;
            var signed: std.ArrayList(u8) = .empty;
            try signed.appendSlice(a, b64.encode(try a.alloc(u8, b64.calcSize(header.len)), header));
            try signed.append(a, '.');
            try signed.appendSlice(a, b64.encode(try a.alloc(u8, b64.calcSize(payload.len)), payload));
            var mac: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed.items, jwt_secret);
            try signed.append(a, '.');
            try signed.appendSlice(a, b64.encode(try a.alloc(u8, b64.calcSize(mac.len)), &mac));
            _ = Jwt.decode(a, Claims, signed.items, key, validation) catch {};
        }
    }.run, .{});
}

test "fuzz: oauth flow cookie decode" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [512]u8 = undefined;
            const cookie = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const returned = if (cookie.len >= 32) cookie[0..32] else "0123456789abcdef0123456789abcdef";
            const flow = zx.Auth.Oauth.Flow.decode(arena.allocator(), cookie, returned, "github") orelse return;
            try std.testing.expectEqualStrings("github", flow.provider);
        }
    }.run, .{});
}

test "fuzz: webauthn assertion parse" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const body = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = zx.Auth.WebAuthn.parseAssertion(arena.allocator(), body) catch {};
        }
    }.run, .{ .corpus = util.seeds(&.{
        "{\"id\":\"abc\",\"response\":{\"clientDataJSON\":\"e30\",\"authenticatorData\":\"AAAA\",\"signature\":\"AA\",\"userHandle\":\"dQ\"}}",
    }) });
}
