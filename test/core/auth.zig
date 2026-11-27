const std = @import("std");
const zx = @import("zx");

const Auth = zx.Auth;
const Oauth = Auth.Oauth;
const WebAuthn = Auth.WebAuthn;
const Jwt = Auth.Jwt;
const Cbor = WebAuthn.Cbor;

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Es256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

const flag_up = 0x01;
const flag_uv = 0x04;
const flag_at = 0x40;

// One browser's cookie jar and an in-memory store, behind both vtables.
const Host = struct {
    arena: std.mem.Allocator,
    cookies: std.array_hash_map.String([]const u8) = .empty,
    sessions: std.array_hash_map.String(Auth.Account) = .empty,
    keys: std.array_hash_map.String(Auth.Passkey) = .empty,
    allowed: []const u8 = "42",
    origin: []const u8 = "https://example.com",
    // What the fake provider sends back.
    access_token: []const u8 = "{\"access_token\":\"gho_x\"}",
    user: []const u8 = "{\"id\":42,\"login\":\"octo\"}",

    const http_vtable: Auth.Http.VTable = .{ .cookie = cookie, .setCookie = setCookie, .fetch = fetch };
    const store_vtable: Auth.Store.VTable = .{
        .config = config,
        .authorize = authorize,
        .putSession = putSession,
        .getSession = getSession,
        .deleteSession = deleteSession,
        .putPasskey = putPasskey,
        .getPasskey = getPasskey,
        .listPasskeys = listPasskeys,
        .usePasskey = usePasskey,
        .deletePasskey = deletePasskey,
    };

    fn auth(host: *Host) Auth {
        return .{
            .io = io,
            .http = .{ .userdata = host, .vtable = &http_vtable },
            .store = .{ .userdata = host, .vtable = &store_vtable },
            .options = .{
                .origin = host.origin,
                .site_name = "Example",
                .home = "/admin",
                .providers = &.{ Oauth.providers.github, other_provider },
            },
        };
    }

    fn jar(host: *Host, comptime name: []const u8) ?[]const u8 {
        const secure = std.mem.startsWith(u8, host.origin, "https://");
        return host.cookies.get(if (secure) "__Host-" ++ name else name);
    }

    fn from(ud: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(ud));
    }

    fn cookie(ud: ?*anyopaque, name: []const u8) ?[]const u8 {
        return from(ud).cookies.get(name);
    }

    fn setCookie(ud: ?*anyopaque, c: Auth.Cookie) void {
        const host = from(ud);
        if (c.max_age_s == 0) {
            _ = host.cookies.orderedRemove(c.name);
        } else {
            host.cookies.put(host.arena, c.name, c.value) catch unreachable;
        }
    }

    fn config(_: ?*anyopaque, _: std.mem.Allocator, provider: []const u8) ?Oauth.Config {
        if (std.mem.eql(u8, provider, "unset")) return null;
        return .{ .client_id = "id", .client_secret = "secret" };
    }

    fn authorize(ud: ?*anyopaque, _: std.mem.Allocator, owner: Auth.Account) anyerror!bool {
        return std.mem.eql(u8, owner.id, from(ud).allowed);
    }

    fn fetch(ud: ?*anyopaque, _: std.mem.Allocator, request: Oauth.Request) anyerror![]const u8 {
        if (std.mem.eql(u8, request.url, Oauth.providers.github.token_url)) {
            if (std.mem.find(u8, request.body.?, "&code_verifier=") == null) return error.MissingVerifier;
            return from(ud).access_token;
        }
        return from(ud).user;
    }

    fn putSession(ud: ?*anyopaque, token_hash: []const u8, owner: Auth.Account, _: i64) anyerror!void {
        const host = from(ud);
        try host.sessions.put(host.arena, try host.arena.dupe(u8, token_hash), owner);
    }

    fn getSession(ud: ?*anyopaque, _: std.mem.Allocator, token_hash: []const u8) anyerror!?Auth.Account {
        return from(ud).sessions.get(token_hash);
    }

    fn deleteSession(ud: ?*anyopaque, token_hash: []const u8) anyerror!void {
        _ = from(ud).sessions.orderedRemove(token_hash);
    }

    fn putPasskey(ud: ?*anyopaque, p: Auth.Passkey) anyerror!void {
        const host = from(ud);
        try host.keys.put(host.arena, p.id, p);
    }

    fn getPasskey(ud: ?*anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!?Auth.Passkey {
        return from(ud).keys.get(id);
    }

    fn listPasskeys(ud: ?*anyopaque, arena: std.mem.Allocator, owner: Auth.Account) anyerror![]const Auth.Passkey {
        var out: std.ArrayList(Auth.Passkey) = .empty;
        for (from(ud).keys.values()) |p| if (std.mem.eql(u8, p.owner.id, owner.id)) try out.append(arena, p);
        return out.items;
    }

    fn usePasskey(ud: ?*anyopaque, id: []const u8, sign_count: u32) anyerror!void {
        from(ud).keys.getPtr(id).?.sign_count = sign_count;
    }

    fn deletePasskey(ud: ?*anyopaque, id: []const u8, owner: Auth.Account) anyerror!void {
        const host = from(ud);
        const p = host.keys.get(id) orelse return;
        if (std.mem.eql(u8, p.owner.id, owner.id)) _ = host.keys.orderedRemove(id);
    }
};

const other_provider: Oauth.Provider = .{
    .id = "other",
    .name = "Other",
    .authorize_url = "https://other.test/authorize",
    .token_url = "https://other.test/token",
    .user_url = "https://other.test/user",
    .scope = "",
    .parseUser = Oauth.providers.github.parseUser,
};

fn signIn(host: *Host, arena: std.mem.Allocator) !void {
    const auth = host.auth();
    _ = try auth.startOAuth(arena, "github", null);
    const state = host.jar("auth_state").?[0..32];
    _ = try auth.finishOAuth(arena, "github", .{ .state = state, .code = "c", .@"error" = null });
}

// --- Sessions and OAuth --- //

test "oauth > sign-in, then sign-out" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    const url = try auth.startOAuth(arena, "github", "/admin/finance");
    try expect(std.mem.startsWith(u8, url, Oauth.providers.github.authorize_url ++ "?response_type=code&"));
    const forged: [32]u8 = @splat('f');
    try expectError(error.Expired, auth.finishOAuth(arena, "github", .{ .state = &forged, .code = "c", .@"error" = null }));
    try expect(auth.account(arena) == null);

    _ = try auth.startOAuth(arena, "github", "/admin/finance");
    const state = host.jar("auth_state").?[0..32];
    try expectEqualStrings("/admin/finance", try auth.finishOAuth(arena, "github", .{ .state = state, .code = "c", .@"error" = null }));
    try expectEqualStrings("octo", auth.account(arena).?.name);
    try expectEqualStrings("42", auth.account(arena).?.id);
    try expect(host.jar("auth_state") == null);

    auth.signOut();
    try expect(auth.account(arena) == null);
    try expectEqual(0, host.sessions.count());
}

test "oauth > state is single use" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    _ = try auth.startOAuth(arena, "github", null);
    const state = try arena.dupe(u8, host.jar("auth_state").?[0..32]);
    _ = try auth.finishOAuth(arena, "github", .{ .state = state, .code = "c", .@"error" = null });
    try expectError(error.Expired, auth.finishOAuth(arena, "github", .{ .state = state, .code = "c", .@"error" = null }));
}

test "oauth > a callback for another provider is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    _ = try auth.startOAuth(arena, "github", null);
    const state = host.jar("auth_state").?[0..32];
    try expectError(error.Expired, auth.finishOAuth(arena, "other", .{ .state = state, .code = "c", .@"error" = null }));
    try expect(auth.account(arena) == null);
}

test "oauth > provider error is only believed with a valid state" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    _ = try auth.startOAuth(arena, "github", null);
    try expectError(error.Expired, auth.finishOAuth(arena, "github", .{ .state = null, .code = null, .@"error" = "access_denied" }));
    _ = try auth.startOAuth(arena, "github", null);
    const state = host.jar("auth_state").?[0..32];
    try expectError(error.Denied, auth.finishOAuth(arena, "github", .{ .state = state, .code = null, .@"error" = "access_denied" }));
}

test "oauth > provider failures don't sign in" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "{\"error\":\"bad_verification_code\"}",
        "{\"access_token\":\"x\\r\\nX-Injected: 1\"}",
        "{\"access_token\":\"\"}",
        "not json",
    }) |token| {
        var host: Host = .{ .arena = arena, .access_token = token };
        try expectError(error.ProviderFailed, signIn(&host, arena));
        try expectEqual(0, host.sessions.count());
    }
    var host: Host = .{ .arena = arena, .user = "{\"login\":\"no-id\"}" };
    try expectError(error.ProviderFailed, signIn(&host, arena));
}

test "oauth > authorize refuses a sign-in" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena, .allowed = "7" };

    try expectError(error.NotAllowed, signIn(&host, arena));
    try expect(host.auth().account(arena) == null);
    try expectEqual(0, host.sessions.count());
}

test "oauth > unknown and unconfigured providers" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();
    try expectError(error.UnknownProvider, auth.startOAuth(arena, "gitlab", null));

    var unset = auth;
    unset.options.providers = &.{.{
        .id = "unset",
        .name = "",
        .authorize_url = "",
        .token_url = "",
        .user_url = "",
        .scope = "",
        .parseUser = Oauth.providers.github.parseUser,
    }};
    try expectError(error.NotConfigured, unset.startOAuth(arena, "unset", null));
    try expectEqual(0, (try unset.availableProviders(arena)).len);
    try expectEqual(2, (try auth.availableProviders(arena)).len);
}

test "session > a new sign-in replaces the old token" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };

    try signIn(&host, arena);
    const first = try arena.dupe(u8, host.jar("auth_session").?);
    try signIn(&host, arena);
    try expect(!std.mem.eql(u8, first, host.jar("auth_session").?));
    try expectEqual(1, host.sessions.count());
    // Only the hash is stored.
    try expect(host.sessions.get(first) == null);
}

test "cookies > __Host- and Secure only over https" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var secure: Host = .{ .arena = arena };
    try signIn(&secure, arena);
    try expect(secure.cookies.get("__Host-auth_session") != null);

    var local: Host = .{ .arena = arena, .origin = "http://localhost:3000" };
    try signIn(&local, arena);
    try expect(local.cookies.get("auth_session") != null);
    try expect(local.cookies.get("__Host-auth_session") == null);
}

test "safeNext > only paths on this site" {
    var host: Host = .{ .arena = gpa };
    const auth = host.auth();
    try expectEqualStrings("/admin", auth.safeNext(null));
    try expectEqualStrings("/admin", auth.safeNext(""));
    try expectEqualStrings("/admin/posts", auth.safeNext("/admin/posts"));
    try expectEqualStrings("/blog?x=1", auth.safeNext("/blog?x=1"));
    try expectEqualStrings("/admin", auth.safeNext("//evil.example"));
    try expectEqualStrings("/admin", auth.safeNext("/\\evil.example"));
    try expectEqualStrings("/admin", auth.safeNext("https://evil.example"));
    try expectEqualStrings("/admin", auth.safeNext("admin"));
    try expectEqualStrings("/admin", auth.safeNext("/admin/\r\nSet-Cookie:x"));
    try expectEqualStrings("/admin", auth.safeNext("/admin\x7f"));
}

test "withNext > percent-encodes the path" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectEqualStrings("/auth/login?next=/admin/a%3Fb%3D1%26c", try Auth.withNext(arena, "/auth/login", "/admin/a?b=1&c"));
    try expectEqualStrings("/auth/login?x=1&next=/", try Auth.withNext(arena, "/auth/login?x=1", "/"));
}

test "urls > endpoints, start, login and error codes" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host: Host = .{ .arena = arena };
    var auth = host.auth();
    try expectEqualStrings("https://example.com/auth/logout", try auth.url(arena, .logout));
    try expectEqualStrings("https://example.com/auth/passkey/login/options", try auth.url(arena, .@"passkey/login/options"));
    try expectEqualStrings("https://example.com/auth/start/github", try auth.startUrl(arena, "github", null));
    try expectEqualStrings("https://example.com/auth/start/github?next=/admin/x", try auth.startUrl(arena, "github", "/admin/x"));
    try expectEqualStrings("https://example.com/auth/login?next=/admin", try auth.loginUrl(arena, "/admin"));

    auth.options.path = "/account";
    auth.options.login_path = "/sign-in";
    try expectEqualStrings("https://example.com/account/passkey/remove", try auth.url(arena, .@"passkey/remove"));
    try expectEqualStrings("https://example.com/sign-in", try auth.loginUrl(arena, null));
    const url = try auth.startOAuth(arena, "github", null);
    try expect(std.mem.find(u8, url, "redirect_uri=https%3A%2F%2Fexample.com%2Faccount%2Fcallback%2Fgithub") != null);

    try expectEqualStrings("expired", Auth.errorCode(error.Expired));
    try expectEqualStrings("not_allowed", Auth.errorCode(error.NotAllowed));
    try expectEqualStrings("failed", Auth.errorCode(error.Unexpected));
}

// --- OAuth pieces --- //

test "oauth > authorizeUrl" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const flow: Oauth.Flow = .{ .state = @splat('s'), .verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".*, .provider = "github", .next = "" };
    const url = try Oauth.authorizeUrl(arena_state.allocator(), Oauth.providers.github, .{ .client_id = "id 1", .client_secret = "" }, "https://x.test/cb", flow);
    try expectEqualStrings(
        "https://github.com/login/oauth/authorize?response_type=code&client_id=id%201&redirect_uri=https%3A%2F%2Fx.test%2Fcb&scope=read%3Auser" ++
            "&state=ssssssssssssssssssssssssssssssss&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256",
        url,
    );
}

test "oauth > accessToken" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectEqualStrings("gho_x", try Oauth.accessToken(arena,
        \\{"access_token":"gho_x","token_type":"bearer","scope":"read:user"}
    ));
    try expectEqualStrings("a.b-c_d~e+f/g==", try Oauth.accessToken(arena, "{\"access_token\":\"a.b-c_d~e+f/g==\"}"));
    try expectError(error.TokenExchangeFailed, Oauth.accessToken(arena, "{\"error\":\"bad_verification_code\"}"));
    try expectError(error.TokenExchangeFailed, Oauth.accessToken(arena, "{\"access_token\":\"a b\"}"));
    try expectError(error.TokenExchangeFailed, Oauth.accessToken(arena, "not json"));
}

test "oauth > providers parse a stable id and a display name" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = Oauth.providers;
    const cases = [_]struct { Oauth.Provider, []const u8, []const u8, []const u8 }{
        .{ p.github, "{\"id\":1,\"login\":\"octo\"}", "1", "octo" },
        .{ p.gitlab, "{\"id\":2,\"username\":\"fox\"}", "2", "fox" },
        .{ p.discord, "{\"id\":\"80351110224678912\",\"username\":\"nelly\",\"global_name\":\"Nelly\"}", "80351110224678912", "Nelly" },
        .{ p.discord, "{\"id\":\"3\",\"username\":\"nelly\",\"global_name\":null}", "3", "nelly" },
        .{ p.facebook, "{\"id\":\"10\",\"name\":\"Mark\"}", "10", "Mark" },
        .{ p.spotify, "{\"id\":\"sp\",\"display_name\":null}", "sp", "sp" },
        .{ p.x, "{\"data\":{\"id\":\"2244994945\",\"name\":\"X Dev\",\"username\":\"XDevelopers\"}}", "2244994945", "XDevelopers" },
        .{ p.google, "{\"sub\":\"1099\",\"name\":\"Ada\",\"email\":\"ada@example.com\"}", "1099", "Ada" },
        .{ p.microsoft, "{\"sub\":\"AAA\",\"email\":\"a@example.com\"}", "AAA", "a@example.com" },
        .{ p.twitch, "{\"sub\":\"55\",\"preferred_username\":\"streamer\"}", "55", "streamer" },
        .{ p.slack, "{\"ok\":true,\"sub\":\"U1\",\"name\":\"\"}", "U1", "U1" },
    };
    for (cases) |c| {
        const identity = try c[0].parseUser(arena, c[1]);
        try expectEqualStrings(c[2], identity.id);
        try expectEqualStrings(c[3], identity.name);
    }
    // An email alone never stands in for the id.
    try expectError(error.MissingField, p.google.parseUser(arena, "{\"email\":\"a@example.com\"}"));
}

test "oauth > every built-in provider is https and distinct" {
    const p = Oauth.providers;
    const all = [_]Oauth.Provider{ p.discord, p.facebook, p.github, p.gitlab, p.google, p.linkedin, p.microsoft, p.slack, p.spotify, p.twitch, p.x };
    for (all, 0..) |provider, i| {
        for ([_][]const u8{ provider.authorize_url, provider.token_url, provider.user_url }) |url| try expect(std.mem.startsWith(u8, url, "https://"));
        for (all[0..i]) |seen| try expect(!std.mem.eql(u8, seen.id, provider.id));
    }
}

test "oauth > basic client auth keeps the secret out of the body" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req = try Oauth.tokenRequest(arena, Oauth.providers.x, .{ .client_id = "id:1", .client_secret = "s&2" }, "c", "https://x.test/cb", "v");
    try expect(std.mem.find(u8, req.body.?, "client_secret") == null);
    var auth: ?[]const u8 = null;
    for (req.headers) |h| if (std.mem.eql(u8, h.name, "Authorization")) {
        auth = h.value;
    };
    // base64("id%3A1:s%262")
    try expectEqualStrings("Basic aWQlM0ExOnMlMjYy", auth.?);

    const post = try Oauth.tokenRequest(arena, Oauth.providers.github, .{ .client_id = "id", .client_secret = "s" }, "c", "https://x.test/cb", "v");
    try expect(std.mem.find(u8, post.body.?, "&client_secret=s&") != null);
    for (post.headers) |h| try expect(!std.mem.eql(u8, h.name, "Authorization"));
}

test "oauth > an empty scope is left out" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const flow: Oauth.Flow = .init(io, "spotify", "/");
    const url = try Oauth.authorizeUrl(arena_state.allocator(), Oauth.providers.spotify, .{ .client_id = "id", .client_secret = "" }, "https://x.test/cb", flow);
    try expect(std.mem.find(u8, url, "scope=") == null);
}

test "oauth > Flow round-trips and binds state and provider" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flow: Oauth.Flow = .init(io, "github", "/admin/finance");

    const cookie = try flow.encode(arena);
    const back = Oauth.Flow.decode(arena, cookie, &flow.state, "github").?;
    try expectEqualStrings("/admin/finance", back.next);
    try std.testing.expectEqualSlices(u8, &flow.verifier, &back.verifier);
    try expect(Oauth.Flow.decode(arena, cookie, &flow.state, "gitlab") == null);
    try expect(Oauth.Flow.decode(arena, cookie, &@as([32]u8, @splat('f')), "github") == null);
    try expect(Oauth.Flow.decode(arena, cookie, "short", "github") == null);
    try expect(Oauth.Flow.decode(arena, "garbage", &flow.state, "github") == null);
    try expect(Oauth.Flow.decode(arena, try std.mem.concat(arena, u8, &.{ cookie, ".x" }), &flow.state, "github") == null);
}

test "oauth > Flow.challenge is the RFC 7636 S256 transform" {
    const flow: Oauth.Flow = .{ .state = @splat('0'), .verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".*, .provider = "", .next = "" };
    try expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &flow.challenge());
}

// --- Passkeys --- //

// What a browser and authenticator would send, built from a known key.
const Fake = struct {
    const rp: WebAuthn.RelyingParty = .{ .id = "example.com", .name = "Test", .origin = "https://example.com" };
    const cred_id = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };

    fn keyPair() !Es256.KeyPair {
        return Es256.KeyPair.generateDeterministic(@splat(7));
    }

    fn clientData(arena: std.mem.Allocator, kind: []const u8, challenge: []const u8, origin: []const u8) ![]const u8 {
        return arena.print(
            \\{{"type":"{s}","challenge":"{s}","origin":"{s}","crossOrigin":false}}
        , .{ kind, challenge, origin });
    }

    fn authData(arena: std.mem.Allocator, flags: u8, count: u32, attested: []const u8) ![]const u8 {
        var rp_hash: [32]u8 = undefined;
        Sha256.hash(rp.id, &rp_hash, .{});
        var tail: [5]u8 = undefined;
        tail[0] = flags;
        std.mem.writeInt(u32, tail[1..5], count, .big);
        return std.mem.concat(arena, u8, &.{ &rp_hash, &tail, attested });
    }

    fn registration(arena: std.mem.Allocator, challenge: []const u8, origin: []const u8) ![]const u8 {
        const sec1 = (try keyPair()).public_key.toUncompressedSec1();
        // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
        const cose = try std.mem.concat(arena, u8, &.{
            &.{ 0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20 }, sec1[1..33],
            &.{ 0x22, 0x58, 0x20 },                                           sec1[33..65],
        });
        const attested = try std.mem.concat(arena, u8, &.{ &@as([16]u8, @splat(0)), &.{ 0, cred_id.len }, &cred_id, cose });
        const auth_data = try authData(arena, flag_up | flag_uv | flag_at, 0, attested);
        // {"fmt": "none", "attStmt": {}, "authData": h'…'}
        const object = try std.mem.concat(arena, u8, &.{
            &.{ 0xa3, 0x63 },                       "fmt",
            &.{0x64},                               "none",
            &.{0x67},                               "attStmt",
            &.{ 0xa0, 0x68 },                       "authData",
            &.{ 0x59, 0, @intCast(auth_data.len) }, auth_data,
        });
        return arena.print(
            \\{{"id":"{s}","name":" Laptop ","response":{{"clientDataJSON":"{s}","attestationObject":"{s}"}}}}
        , .{
            try WebAuthn.encode(arena, &cred_id),
            try WebAuthn.encode(arena, try clientData(arena, "webauthn.create", challenge, origin)),
            try WebAuthn.encode(arena, object),
        });
    }

    fn assertion(arena: std.mem.Allocator, challenge: []const u8, flags: u8, count: u32) !WebAuthn.Assertion {
        const client = try clientData(arena, "webauthn.get", challenge, rp.origin);
        const auth_data = try authData(arena, flags, count, "");
        var client_hash: [32]u8 = undefined;
        Sha256.hash(client, &client_hash, .{});
        const sig = try (try keyPair()).sign(try std.mem.concat(arena, u8, &.{ auth_data, &client_hash }), null);
        var der: [Es256.Signature.der_encoded_length_max]u8 = undefined;
        return .{
            .credential_id = try WebAuthn.encode(arena, &cred_id),
            .client_data = client,
            .authenticator_data = auth_data,
            .signature = try arena.dupe(u8, sig.toDer(&der)),
        };
    }

    fn assertionJson(arena: std.mem.Allocator, a: WebAuthn.Assertion, user_handle: ?[]const u8) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, .{
            .id = a.credential_id,
            .response = .{
                .clientDataJSON = try WebAuthn.encode(arena, a.client_data),
                .authenticatorData = try WebAuthn.encode(arena, a.authenticator_data),
                .signature = try WebAuthn.encode(arena, a.signature),
                .userHandle = if (user_handle) |h| try WebAuthn.encode(arena, h) else null,
            },
        }, .{});
    }

    // The challenge `Auth` handed out, read from the options JSON.
    fn challengeOf(arena: std.mem.Allocator, options: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSliceLeaky(struct { publicKey: struct { challenge: []const u8 } }, arena, options, .{ .ignore_unknown_fields = true });
        return parsed.publicKey.challenge;
    }
};

test "webauthn > registration then sign-in" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rp = Fake.rp;
    const challenge = WebAuthn.newChallenge(io);

    const cred = try WebAuthn.verifyRegistration(arena, rp, challenge, try Fake.registration(arena, &challenge, rp.origin));
    try expectEqualStrings("qrvM3Q", cred.id);
    try expectEqual(WebAuthn.Algorithm.es256, cred.algorithm);

    const uv = flag_up | flag_uv;
    try expectEqual(5, try WebAuthn.verifyAssertion(arena, rp, challenge, try Fake.assertion(arena, &challenge, uv, 5), cred.algorithm, cred.public_key, 4));
    try expectEqual(0, try WebAuthn.verifyAssertion(arena, rp, challenge, try Fake.assertion(arena, &challenge, uv, 0), cred.algorithm, cred.public_key, 0));
    try expectError(error.CounterRegressed, WebAuthn.verifyAssertion(arena, rp, challenge, try Fake.assertion(arena, &challenge, uv, 5), cred.algorithm, cred.public_key, 5));
    try expectError(error.UserNotVerified, WebAuthn.verifyAssertion(arena, rp, challenge, try Fake.assertion(arena, &challenge, flag_up, 0), cred.algorithm, cred.public_key, 0));
    try expectError(error.ChallengeMismatch, WebAuthn.verifyAssertion(arena, rp, @splat('A'), try Fake.assertion(arena, &challenge, uv, 0), cred.algorithm, cred.public_key, 0));

    var tampered = try Fake.assertion(arena, &challenge, uv, 0);
    tampered.authenticator_data = try Fake.authData(arena, uv, 9, "");
    try expectError(error.BadSignature, WebAuthn.verifyAssertion(arena, rp, challenge, tampered, cred.algorithm, cred.public_key, 0));

    const other: WebAuthn.RelyingParty = .{ .id = rp.id, .name = rp.name, .origin = "https://evil.example" };
    try expectError(error.OriginMismatch, WebAuthn.verifyAssertion(arena, other, challenge, try Fake.assertion(arena, &challenge, uv, 0), cred.algorithm, cred.public_key, 0));
    const other_id: WebAuthn.RelyingParty = .{ .id = "evil.example", .name = rp.name, .origin = rp.origin };
    try expectError(error.RelyingPartyMismatch, WebAuthn.verifyAssertion(arena, other_id, challenge, try Fake.assertion(arena, &challenge, uv, 0), cred.algorithm, cred.public_key, 0));
}

test "webauthn > registration from another origin is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const challenge = WebAuthn.newChallenge(io);
    try expectError(error.OriginMismatch, WebAuthn.verifyRegistration(arena, Fake.rp, challenge, try Fake.registration(arena, &challenge, "https://evil.example")));
    try expectError(error.InvalidResponse, WebAuthn.verifyRegistration(arena, Fake.rp, challenge, "{}"));
}

test "webauthn > challenges carry their issue time" {
    const before = std.Io.Timestamp.now(io, .real).toSeconds();
    const challenge = WebAuthn.newChallenge(io);
    const issued = WebAuthn.issuedAt(challenge).?;
    try expect(issued >= before and issued <= before + 5);
    try expect(!std.mem.eql(u8, &challenge, &WebAuthn.newChallenge(io)));
}

test "webauthn > RelyingParty.fromOrigin" {
    try expectEqualStrings("example.com", (try WebAuthn.RelyingParty.fromOrigin("", "https://example.com")).id);
    try expectEqualStrings("localhost", (try WebAuthn.RelyingParty.fromOrigin("", "http://localhost:3000")).id);
    try expectError(error.InvalidOrigin, WebAuthn.RelyingParty.fromOrigin("", "example.com"));
}

test "webauthn > requestOptions" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try expectEqualStrings(
        \\{"publicKey":{"rpId":"example.com","challenge":"c","timeout":300000,"userVerification":"required","allowCredentials":[]}}
    , try WebAuthn.requestOptions(arena_state.allocator(), Fake.rp, "c"));
}

test "passkeys > register, sign in, remove through Auth" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    try expectError(error.SignInRequired, auth.passkeyCreationOptions(arena));
    try signIn(&host, arena);
    const owner = auth.account(arena).?;

    const create = try Fake.challengeOf(arena, try auth.passkeyCreationOptions(arena));
    try auth.addPasskey(arena, try Fake.registration(arena, create, Fake.rp.origin), " Laptop ");
    const keys = try auth.passkeys(arena, owner);
    try expectEqual(1, keys.len);
    try expectEqualStrings("Laptop", keys[0].name);
    // The challenge cookie is single use.
    try expectError(error.Expired, auth.addPasskey(arena, try Fake.registration(arena, create, Fake.rp.origin), ""));

    auth.signOut();
    const get = try Fake.challengeOf(arena, try auth.passkeyRequestOptions(arena));
    const body = try Fake.assertionJson(arena, try Fake.assertion(arena, get, flag_up | flag_uv, 0), null);
    try expectEqualStrings("/admin/posts", try auth.signInWithPasskey(arena, body, "/admin/posts"));
    try expectEqualStrings("octo", auth.account(arena).?.name);
    // Replaying the same answer needs the cookie, which is gone.
    try expectError(error.Expired, auth.signInWithPasskey(arena, body, null));

    try auth.removePasskey(arena, keys[0].id);
    try expectEqual(0, (try auth.passkeys(arena, owner)).len);
}

test "passkeys > a mismatched user handle is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    try signIn(&host, arena);
    const create = try Fake.challengeOf(arena, try auth.passkeyCreationOptions(arena));
    try auth.addPasskey(arena, try Fake.registration(arena, create, Fake.rp.origin), "");
    auth.signOut();

    const get = try Fake.challengeOf(arena, try auth.passkeyRequestOptions(arena));
    const body = try Fake.assertionJson(arena, try Fake.assertion(arena, get, flag_up | flag_uv, 0), "someone else");
    try expectError(error.PasskeyRejected, auth.signInWithPasskey(arena, body, null));
    try expect(auth.account(arena) == null);
}

test "passkeys > an expired challenge is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();

    // A challenge issued 10 minutes ago, still sitting in the cookie.
    var bytes: [32]u8 = @splat(1);
    std.mem.writeInt(i64, bytes[24..32], std.Io.Timestamp.now(io, .real).toSeconds() - 10 * std.time.s_per_min, .big);
    var old: WebAuthn.Challenge = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&old, &bytes);
    try host.cookies.put(arena, "__Host-auth_challenge", &old);

    const body = try Fake.assertionJson(arena, try Fake.assertion(arena, &old, flag_up | flag_uv, 0), null);
    try expectError(error.Expired, auth.signInWithPasskey(arena, body, null));
}

test "passkeys > long names are cut on a code point boundary" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: Host = .{ .arena = arena };
    const auth = host.auth();
    try signIn(&host, arena);

    const create = try Fake.challengeOf(arena, try auth.passkeyCreationOptions(arena));
    var long: std.ArrayList(u8) = .empty;
    try long.append(arena, 'a');
    for (0..40) |_| try long.appendSlice(arena, "\xc3\xa9");
    try auth.addPasskey(arena, try Fake.registration(arena, create, Fake.rp.origin), long.items);
    const name = (try auth.passkeys(arena, auth.account(arena).?))[0].name;
    try expect(std.unicode.utf8ValidateSlice(name));
    try expect(name.len <= 60);
}

// --- CBOR --- //

test "cbor > reads maps, ints, bytes and text" {
    // {1: 2, -3: h'0102', "a": [true]}
    var r: Cbor = .{ .data = &.{ 0xa3, 0x01, 0x02, 0x22, 0x42, 0x01, 0x02, 0x61, 'a', 0x81, 0xf5 } };
    try expectEqual(3, try r.expect(.map));
    try expectEqual(1, try r.expect(.int));
    try expectEqual(2, try r.expect(.int));
    try expectEqual(-3, try r.expect(.int));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, try r.expect(.bytes));
    try expectEqualStrings("a", try r.expect(.text));
    try r.skip();
    try expectEqual(r.data.len, r.pos);
}

test "cbor > rejects truncated, indefinite, oversized and deeply nested items" {
    var short: Cbor = .{ .data = &.{ 0x42, 0x01 } };
    try expectError(error.UnexpectedEnd, short.next());
    var indefinite: Cbor = .{ .data = &.{0x9f} };
    try expectError(error.InvalidCbor, indefinite.next());
    var deep: Cbor = .{ .data = &(@as([32]u8, @splat(0x81)) ++ [_]u8{0x00}) };
    try expectError(error.InvalidCbor, deep.skip());
    var wrong: Cbor = .{ .data = &.{0x01} };
    try expectError(error.InvalidCbor, wrong.expect(.bytes));
    // A map claiming 2^64-1 pairs.
    var huge: Cbor = .{ .data = &.{ 0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } };
    try expectError(error.UnexpectedEnd, huge.skip());
    var big_bytes: Cbor = .{ .data = &.{ 0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } };
    try expectError(error.UnexpectedEnd, big_bytes.next());
}

// --- JWT --- //

const Claims = struct { sub: []const u8, exp: i64, iss: ?[]const u8 = null, aud: ?[]const u8 = null };
const secret = "0123456789abcdef0123456789abcdef";
const now: i64 = 1_700_000_000;

test "jwt > RFC 7515 A.1 HS256 example" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9" ++
        ".eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ" ++
        ".dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var key: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&key, "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow");

    const claims = try Jwt.decode(arena, struct { iss: []const u8 }, token, .{ .HS256 = &key }, .{ .now = 1300819370, .issuer = "joe" });
    try expectEqualStrings("joe", claims.iss);
    try expectError(error.Expired, Jwt.decode(arena, struct {}, token, .{ .HS256 = &key }, .{ .now = 1300819380 + 30 }));
}

test "jwt > round-trips with each algorithm" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const keys = [_]Jwt.SigningKey{
        .{ .HS256 = secret },
        .{ .ES256 = Es256.KeyPair.generate(io) },
        .{ .EdDSA = Ed25519.KeyPair.generate(io) },
    };
    for (keys) |key| {
        const token = try Jwt.encode(arena, Claims{ .sub = "user-1", .exp = now + 60, .aud = "app" }, key);
        const claims = try Jwt.decode(arena, Claims, token, key.verifyingKey(), .{ .now = now, .audience = "app" });
        try expectEqualStrings("user-1", claims.sub);
        try expect(std.mem.find(u8, token, "aXNz") == null); // null `iss` left out
    }
}

test "jwt > the key decides the algorithm" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pair = Es256.KeyPair.generate(io);
    const es = try Jwt.encode(arena, Claims{ .sub = "a", .exp = now + 60 }, .{ .ES256 = pair });
    try expectError(error.AlgorithmMismatch, Jwt.decode(arena, Claims, es, .{ .HS256 = secret }, .{ .now = now }));

    // An HMAC "signed" with the public key, the classic confusion attack.
    const sec1 = pair.public_key.toUncompressedSec1();
    const forged = try Jwt.encode(arena, Claims{ .sub = "a", .exp = now + 60 }, .{ .HS256 = &sec1 });
    try expectError(error.AlgorithmMismatch, Jwt.decode(arena, Claims, forged, .{ .ES256 = pair.public_key }, .{ .now = now }));

    // alg: none with an empty signature.
    const none = "eyJhbGciOiJub25lIn0." ++ "eyJzdWIiOiJhIiwiZXhwIjo5OTk5OTk5OTk5fQ.";
    try expectError(error.AlgorithmMismatch, Jwt.decode(arena, Claims, none, .{ .HS256 = secret }, .{ .now = now }));
}

test "jwt > tampering, claims and malformed tokens" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const key: Jwt.VerifyingKey = .{ .HS256 = secret };
    const token = try Jwt.encode(arena, Claims{ .sub = "a", .exp = now + 60, .iss = "me", .aud = "app" }, .{ .HS256 = secret });

    const other = try Jwt.encode(arena, Claims{ .sub = "b", .exp = now + 60 }, .{ .HS256 = secret });
    const first = std.mem.findScalar(u8, token, '.').?;
    const sig = std.mem.findScalarLast(u8, token, '.').?;
    const swapped = try std.mem.concat(arena, u8, &.{ token[0..first], other[first..std.mem.findScalarLast(u8, other, '.').?], token[sig..] });
    try expectError(error.BadSignature, Jwt.decode(arena, Claims, swapped, key, .{ .now = now }));

    try expectError(error.Expired, Jwt.decode(arena, Claims, token, key, .{ .now = now + 60 + 30 }));
    _ = try Jwt.decode(arena, Claims, token, key, .{ .now = now + 60 + 29 });
    try expectError(error.IssuerMismatch, Jwt.decode(arena, Claims, token, key, .{ .now = now, .issuer = "you" }));
    try expectError(error.AudienceMismatch, Jwt.decode(arena, Claims, token, key, .{ .now = now, .audience = "other" }));

    const nbf = try Jwt.encode(arena, .{ .exp = now + 600, .nbf = now + 300 }, .{ .HS256 = secret });
    try expectError(error.NotYetValid, Jwt.decode(arena, struct {}, nbf, key, .{ .now = now }));
    const forever = try Jwt.encode(arena, .{ .sub = "a" }, .{ .HS256 = secret });
    try expectError(error.MissingExpiry, Jwt.decode(arena, struct {}, forever, key, .{ .now = now }));
    _ = try Jwt.decode(arena, struct {}, forever, key, .{ .now = now, .require_exp = false });
    const audiences = try Jwt.encode(arena, .{ .exp = now + 60, .aud = [_][]const u8{ "x", "app" } }, .{ .HS256 = secret });
    _ = try Jwt.decode(arena, struct {}, audiences, key, .{ .now = now, .audience = "app" });

    const crit = "eyJhbGciOiJIUzI1NiIsImNyaXQiOlsiYjY0Il19";
    try expectError(error.Malformed, Jwt.decode(arena, Claims, try std.mem.concat(arena, u8, &.{ crit, token[first..] }), key, .{ .now = now }));
    for ([_][]const u8{ "", "a", "a.b", "a.b.c.d", "!!.!!.!!" }) |bad| {
        try expectError(error.Malformed, Jwt.decode(arena, Claims, bad, key, .{ .now = now }));
    }
    try expectError(error.WeakKey, Jwt.encode(arena, .{}, .{ .HS256 = "short" }));
    try expectError(error.WeakKey, Jwt.decode(arena, Claims, token, .{ .HS256 = "short" }, .{ .now = now }));
}

// --- Over HTTP --- //

const Harness = zx.testing.Harness;

fn setCookies(arena: std.mem.Allocator, res: zx.testing.FetchResult) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (res.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) try out.append(arena, h.value);
    return out.items;
}

// `name=value` of the first Set-Cookie for `name` that isn't a deletion.
fn cookiePair(arena: std.mem.Allocator, res: zx.testing.FetchResult, name: []const u8) !?[]const u8 {
    for (try setCookies(arena, res)) |c| {
        if (!std.mem.startsWith(u8, c, name) or c[name.len] != '=') continue;
        const pair = c[0 .. std.mem.findScalar(u8, c, ';') orelse c.len];
        if (pair.len > name.len + 1) return pair;
    }
    return null;
}

test "http > sign in through a provider, guard a route, sign out" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();
    @import("app").auth_app.port = harness.tcp.?.port;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Signed out: pages redirect to the login, everything else is refused.
    var res = try harness.fetch(arena, .{ .path = "/auth/me?tab=1" });
    try expectEqual(302, res.status);
    try expectEqualStrings("/auth/login?next=/auth/me%3Ftab%3D1", res.header("location").?);
    try expectEqualStrings("no-store", res.header("cache-control").?);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/me" });
    try expectEqual(401, res.status);

    // Start: the state goes to the provider and into a cookie.
    res = try harness.fetch(arena, .{ .path = "/auth/start/fake?next=/auth/me" });
    try expectEqual(303, res.status);
    const location = res.header("location").?;
    try expect(std.mem.find(u8, location, "/auth/provider/authorize?response_type=code&client_id=client&") != null);
    const state = location[std.mem.find(u8, location, "&state=").? + 7 ..][0..32];
    const flow = (try cookiePair(arena, res, "auth_state")).?;
    const flow_attrs = (try setCookies(arena, res))[0];
    try expect(std.mem.find(u8, flow_attrs, "HttpOnly") != null);
    try expect(std.mem.find(u8, flow_attrs, "Path=/") != null);

    // A callback without the cookie is refused, and so is a bad code.
    res = try harness.fetch(arena, .{ .path = try arena.print("/auth/callback/fake?state={s}&code=good", .{state}) });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/login?err=expired", res.header("location").?);
    res = try harness.fetch(arena, .{
        .path = try arena.print("/auth/callback/fake?state={s}&code=bad", .{state}),
        .headers = &.{.{ .name = "Cookie", .value = flow }},
    });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/login?err=provider", res.header("location").?);

    // The real callback: token exchange and user lookup go to the provider.
    res = try harness.fetch(arena, .{ .path = "/auth/start/fake?next=/auth/me" });
    const location2 = res.header("location").?;
    const state2 = location2[std.mem.find(u8, location2, "&state=").? + 7 ..][0..32];
    const flow2 = (try cookiePair(arena, res, "auth_state")).?;
    res = try harness.fetch(arena, .{
        .path = try arena.print("/auth/callback/fake?state={s}&code=good", .{state2}),
        .headers = &.{.{ .name = "Cookie", .value = flow2 }},
    });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/me", res.header("location").?);
    const session = (try cookiePair(arena, res, "auth_session")).?;
    for (try setCookies(arena, res)) |c| if (std.mem.startsWith(u8, c, "auth_session=")) {
        try expect(std.mem.find(u8, c, "HttpOnly") != null);
        try expect(std.mem.find(u8, c, "SameSite=Lax") != null);
    };

    res = try harness.fetch(arena, .{ .path = "/auth/me", .headers = &.{.{ .name = "Cookie", .value = session }} });
    try expectEqual(200, res.status);
    try expectEqualStrings("octo", res.body);

    // Signed in, passkey registration can start.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/passkey/register/options", .headers = &.{.{ .name = "Cookie", .value = session }} });
    try expectEqual(200, res.status);
    try expect(std.mem.startsWith(u8, res.body, "{\"publicKey\":"));

    // Sign out ends the session on the server, not just in the browser.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/logout", .headers = &.{.{ .name = "Cookie", .value = session }} });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/login?ok=signed_out", res.header("location").?);
    res = try harness.fetch(arena, .{ .path = "/auth/me", .headers = &.{.{ .name = "Cookie", .value = session }} });
    try expectEqual(302, res.status);
}

test "http > handle routes, methods and results" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();
    @import("app").auth_app.port = harness.tcp.?.port;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "/auth/nope", "/auth/start", "/auth/start/", "/auth/logout/x", "/auth/passkey/login/x" }) |path| {
        const res = try harness.fetch(arena, .{ .path = path });
        try expectEqual(404, res.status);
        try expectEqualStrings("no-store", res.header("cache-control").?);
    }

    var res = try harness.fetch(arena, .{ .path = "/auth/logout" });
    try expectEqual(405, res.status);
    try expectEqualStrings("POST", res.header("allow").?);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/start/fake" });
    try expectEqual(405, res.status);

    res = try harness.fetch(arena, .{ .path = "/auth/start/nope" });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/login?err=unknown_provider", res.header("location").?);

    // Passkey calls answer the page script in JSON.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/passkey/login/options" });
    try expectEqual(200, res.status);
    try expect(std.mem.startsWith(u8, res.header("content-type").?, "application/json"));
    try expect(std.mem.startsWith(u8, res.body, "{\"publicKey\":"));
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/passkey/login?next=/auth/me", .body = "{}" });
    try expectEqualStrings("{\"redirect\":\"/auth/login?err=expired\"}", res.body);

    // Signed out, account actions send the browser to sign in first.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/passkey/register/options" });
    try expectEqualStrings("{\"redirect\":\"/auth/login?next=/auth/me\"}", res.body);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/auth/passkey/remove" });
    try expectEqual(303, res.status);
    try expectEqualStrings("/auth/login?next=/auth/me", res.header("location").?);
}
