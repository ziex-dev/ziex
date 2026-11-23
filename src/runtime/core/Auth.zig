// Sign-in with OAuth providers or passkeys, both ending in a session behind an
// opaque cookie. The app owns storage and policy through `store`; `http` carries
// cookies and outgoing requests, and `init` wires it to the current request.
//
//     const auth: zx.Auth = try .init(ctx, store, .{
//         .origin = "https://example.com",
//         .site_name = "Example",
//         .providers = &.{zx.Auth.Oauth.providers.github},
//     });
const Auth = @This();

const std = @import("std");
const HttpClient = @import("http/Client.zig");
const CookieOptions = @import("http.zig").CookieOptions;

pub const Oauth = @import("Auth/Oauth.zig");
pub const WebAuthn = @import("Auth/WebAuthn.zig");
pub const Jwt = @import("Auth/Jwt.zig");

io: std.Io,
http: Http,
store: Store,
options: Options,

pub const Options = struct {
    // Where the browser sees the site, e.g. `https://example.com`. It is the OAuth
    // redirect base and the passkey origin, so never derive it from an untrusted
    // `Host` header. Over plain http (local dev) cookies go without `Secure`.
    origin: []const u8,
    // Shown by the browser when creating a passkey.
    site_name: []const u8,
    // Where sign-in lands when no usable `next` path is given.
    home: []const u8 = "/",
    // Joined with the provider id into the OAuth redirect URI.
    callback_path: []const u8 = "/auth/callback/",
    providers: []const Oauth.Provider = &.{},
    session_max_age_s: i64 = 14 * std.time.s_per_day,
};

// Cookies and outgoing requests, normally from `Http.of`.
pub const Http = struct {
    userdata: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        cookie: *const fn (?*anyopaque, name: []const u8) ?[]const u8,
        setCookie: *const fn (?*anyopaque, Cookie) void,
        // The body of a 2xx response, or an error.
        fetch: *const fn (?*anyopaque, std.mem.Allocator, Oauth.Request) anyerror![]const u8,
    };

    // Reads cookies from `ctx.request`, sets them on `ctx.response`, and sends
    // requests with `zx.http.Client`. Any context with `request`, `response`, `io`
    // and `arena` works: pages, routes, proxies.
    pub fn of(ctx: anytype) !Http {
        const host = try ctx.arena.create(RequestHost);
        host.* = .{ .request = ctx.request, .response = ctx.response, .io = ctx.io };
        return .{ .userdata = host, .vtable = &RequestHost.vtable };
    }
};

// What only the app knows: provider credentials, who may sign in, and where
// sessions and passkeys live. Only token hashes and public keys reach it.
pub const Store = struct {
    userdata: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        // Client id and secret for a provider, or null when it isn't set up.
        config: *const fn (?*anyopaque, std.mem.Allocator, provider: []const u8) ?Oauth.Config,
        // Whether this account may sign in. Asked on every sign-in, by OAuth or passkey.
        authorize: *const fn (?*anyopaque, std.mem.Allocator, Account) anyerror!bool,

        // Sessions are keyed by the hex SHA-256 of the cookie token and must stop
        // matching after `max_age_s`.
        putSession: *const fn (?*anyopaque, token_hash: []const u8, Account, max_age_s: i64) anyerror!void,
        getSession: *const fn (?*anyopaque, std.mem.Allocator, token_hash: []const u8) anyerror!?Account,
        deleteSession: *const fn (?*anyopaque, token_hash: []const u8) anyerror!void,

        putPasskey: *const fn (?*anyopaque, Passkey) anyerror!void,
        getPasskey: *const fn (?*anyopaque, std.mem.Allocator, id: []const u8) anyerror!?Passkey,
        listPasskeys: *const fn (?*anyopaque, std.mem.Allocator, owner: Account) anyerror![]const Passkey,
        usePasskey: *const fn (?*anyopaque, id: []const u8, sign_count: u32) anyerror!void,
        // Only deletes when `owner` matches, so one account can't remove another's.
        deletePasskey: *const fn (?*anyopaque, id: []const u8, owner: Account) anyerror!void,
    };
};

// `id` is the provider's stable account id; `name` is for display and may change.
pub const Account = struct { provider: []const u8, id: []const u8, name: []const u8 };

// A passkey belongs to the provider account that registered it, and signs in only
// while `authorize` still accepts that account.
pub const Passkey = struct {
    id: []const u8,
    owner: Account,
    name: []const u8,
    algorithm: WebAuthn.Algorithm,
    public_key: []const u8,
    sign_count: u32,
    created_at: i64,
    last_used_at: ?i64 = null,
};

// A max age of 0 deletes the cookie.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age_s: i64,
    secure: bool,
    http_only: bool = true,
    same_site: CookieOptions.SameSite = .lax,
    path: []const u8 = "/",
};

pub const Error = error{
    UnknownProvider,
    NotConfigured,
    Expired,
    Denied,
    ProviderFailed,
    NotAllowed,
    PasskeyRejected,
    UnknownPasskey,
    SignInRequired,
};

pub fn init(ctx: anytype, store: Store, options: Options) !Auth {
    return .{ .io = ctx.io, .http = try .of(ctx), .store = store, .options = options };
}

// A null max age means the session lifetime.
const CookieSpec = struct { name: []const u8, max_age_s: ?i64 };

const session_cookie: CookieSpec = .{ .name = "auth_session", .max_age_s = null };
const state_cookie: CookieSpec = .{ .name = "auth_state", .max_age_s = 10 * std.time.s_per_min };
const challenge_cookie: CookieSpec = .{ .name = "auth_challenge", .max_age_s = WebAuthn.timeout_s };

const max_passkey_name = 60;
// Allowed clock skew when checking a passkey challenge's issue time.
const challenge_skew_s = 60;
const log = std.log.scoped(.auth);

pub fn account(auth: Auth, arena: std.mem.Allocator) ?Account {
    const token = auth.getCookie(session_cookie) orelse return null;
    return auth.store.vtable.getSession(auth.store.userdata, arena, &hashToken(token)) catch |err| {
        log.warn("reading session failed: {t}", .{err});
        return null;
    };
}

// For a `Proxy`: returns the signed-in account, or answers the request itself and
// aborts. GET requests are redirected to `login` with `?next=` set to the page;
// anything else gets 401.
//
//     pub fn Proxy(ctx: *zx.ProxyContext) void {
//         const auth = app.auth(ctx) catch return ctx.abort();
//         if (auth.guard(ctx, "/auth/login")) |owner| ctx.state(owner);
//     }
pub fn guard(auth: Auth, ctx: anytype, login: []const u8) ?Account {
    if (auth.account(ctx.arena)) |owner| return owner;

    ctx.response.headers.append("Cache-Control", "no-store");
    if (ctx.request.method == .GET) {
        const search = ctx.request.search;
        const next = if (search.len == 0 or search[0] == '?')
            std.mem.concat(ctx.arena, u8, &.{ ctx.request.pathname, search })
        else
            std.mem.concat(ctx.arena, u8, &.{ ctx.request.pathname, "?", search });
        ctx.response.redirect(withNext(ctx.arena, login, next catch ctx.request.pathname) catch login, .found);
    } else {
        ctx.response.setStatus(.unauthorized);
        ctx.response.text("Sign in required");
    }
    ctx.abort();
    return null;
}

// `url` with `next` added as a query parameter.
pub fn withNext(arena: std.mem.Allocator, url: []const u8, next: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s}{c}next=", .{ url, @as(u8, if (std.mem.indexOfScalar(u8, url, '?') == null) '?' else '&') });
    try std.Uri.Component.percentEncode(&out.writer, next, isPathChar);
    return out.toOwnedSlice();
}

fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
}

pub fn signOut(auth: Auth) void {
    const token = auth.takeCookie(session_cookie) orelse return;
    auth.store.vtable.deleteSession(auth.store.userdata, &hashToken(token)) catch |err| log.warn("ending session failed: {t}", .{err});
}

// The providers that have credentials set up.
pub fn availableProviders(auth: Auth, arena: std.mem.Allocator) ![]const Oauth.Provider {
    var out: std.ArrayList(Oauth.Provider) = .empty;
    for (auth.options.providers) |p| {
        if (auth.store.vtable.config(auth.store.userdata, arena, p.id) != null) try out.append(arena, p);
    }
    return out.items;
}

// The provider URL to send the browser to.
pub fn startOAuth(auth: Auth, arena: std.mem.Allocator, provider_id: []const u8, next: ?[]const u8) ![]const u8 {
    const p, const cfg = try auth.resolve(arena, provider_id);
    const flow: Oauth.Flow = .init(auth.io, p.id, auth.safeNext(next));
    auth.setCookie(state_cookie, try flow.encode(arena));
    return Oauth.authorizeUrl(arena, p, cfg, try auth.callbackUrl(arena, p), flow);
}

// Signs in from the provider's callback and returns the path to land on.
pub fn finishOAuth(auth: Auth, arena: std.mem.Allocator, provider_id: []const u8, callback: Oauth.Callback) ![]const u8 {
    const saved = auth.takeCookie(state_cookie);
    const p, const cfg = try auth.resolve(arena, provider_id);
    // Checked before `error` is believed, so a forged callback can't even end an attempt.
    const flow = Oauth.Flow.decode(arena, saved orelse "", callback.state orelse "", p.id) orelse return error.Expired;
    if (callback.@"error" != null) return error.Denied;
    const code = callback.code orelse return error.Denied;

    const identity = auth.exchange(arena, p, cfg, code, &flow.verifier) catch |err| {
        log.warn("{s} sign-in failed: {t}", .{ p.id, err });
        return error.ProviderFailed;
    };
    const owner: Account = .{ .provider = p.id, .id = identity.id, .name = identity.name };
    try auth.checkAuthorized(arena, owner);
    try auth.startSession(arena, owner);
    return auth.safeNext(flow.next);
}

pub fn passkeys(auth: Auth, arena: std.mem.Allocator, owner: Account) ![]const Passkey {
    return auth.store.vtable.listPasskeys(auth.store.userdata, arena, owner);
}

// JSON for `navigator.credentials.create`; signed in only.
pub fn passkeyCreationOptions(auth: Auth, arena: std.mem.Allocator) ![]const u8 {
    const owner = auth.account(arena) orelse return error.SignInRequired;
    const existing = try auth.store.vtable.listPasskeys(auth.store.userdata, arena, owner);
    const exclude = try arena.alloc([]const u8, existing.len);
    for (exclude, existing) |*id, p| id.* = p.id;

    const challenge = try auth.newChallenge(arena);
    const handle = userHandle(owner);
    return WebAuthn.creationOptions(arena, try auth.relyingParty(), .{ .handle = &handle, .name = owner.name }, &challenge, exclude);
}

// `response` is the browser's `navigator.credentials.create` answer as JSON; `name`
// labels the passkey for its owner.
pub fn addPasskey(auth: Auth, arena: std.mem.Allocator, response: []const u8, name: []const u8) !void {
    const owner = auth.account(arena) orelse return error.SignInRequired;
    const challenge = try auth.takeChallenge();
    const cred = WebAuthn.verifyRegistration(arena, try auth.relyingParty(), challenge, response) catch |err| {
        log.warn("passkey registration refused: {t}", .{err});
        return error.PasskeyRejected;
    };

    try auth.store.vtable.putPasskey(auth.store.userdata, .{
        .id = cred.id,
        .owner = owner,
        .name = passkeyName(name),
        .algorithm = cred.algorithm,
        .public_key = cred.public_key,
        .sign_count = cred.sign_count,
        .created_at = std.Io.Timestamp.now(auth.io, .real).toSeconds(),
    });
}

pub fn removePasskey(auth: Auth, arena: std.mem.Allocator, id: []const u8) !void {
    const owner = auth.account(arena) orelse return error.SignInRequired;
    try auth.store.vtable.deletePasskey(auth.store.userdata, id, owner);
}

// JSON for `navigator.credentials.get`.
pub fn passkeyRequestOptions(auth: Auth, arena: std.mem.Allocator) ![]const u8 {
    const challenge = try auth.newChallenge(arena);
    return WebAuthn.requestOptions(arena, try auth.relyingParty(), &challenge);
}

// Signs in with the browser's `navigator.credentials.get` answer (JSON) and returns
// the path to land on.
pub fn signInWithPasskey(auth: Auth, arena: std.mem.Allocator, response: []const u8, next: ?[]const u8) ![]const u8 {
    const challenge = try auth.takeChallenge();
    const assertion = WebAuthn.parseAssertion(arena, response) catch return error.PasskeyRejected;
    const key = try auth.store.vtable.getPasskey(auth.store.userdata, arena, assertion.credential_id) orelse return error.UnknownPasskey;
    if (assertion.user_handle) |handle| {
        if (!std.mem.eql(u8, handle, &userHandle(key.owner))) return error.PasskeyRejected;
    }
    const sign_count = WebAuthn.verifyAssertion(arena, try auth.relyingParty(), challenge, assertion, key.algorithm, key.public_key, key.sign_count) catch |err| {
        log.warn("passkey {s} refused: {t}", .{ key.id, err });
        return error.PasskeyRejected;
    };
    try auth.checkAuthorized(arena, key.owner);
    try auth.store.vtable.usePasskey(auth.store.userdata, key.id, sign_count);
    try auth.startSession(arena, key.owner);
    return auth.safeNext(next);
}

// Only paths on this site, so sign-in can't be turned into an open redirect.
// `//host` and `/\host` both leave the site in browsers, and control characters
// could split headers.
pub fn safeNext(auth: Auth, next: ?[]const u8) []const u8 {
    const path = next orelse return auth.options.home;
    if (path.len == 0 or path[0] != '/' or std.mem.startsWith(u8, path, "//")) return auth.options.home;
    for (path) |c| if (c == '\\' or std.ascii.isControl(c)) return auth.options.home;
    return path;
}

fn checkAuthorized(auth: Auth, arena: std.mem.Allocator, owner: Account) !void {
    if (try auth.store.vtable.authorize(auth.store.userdata, arena, owner)) return;
    log.warn("refused {s} account {s} ({s})", .{ owner.provider, owner.id, owner.name });
    return error.NotAllowed;
}

fn resolve(auth: Auth, arena: std.mem.Allocator, provider_id: []const u8) !struct { Oauth.Provider, Oauth.Config } {
    for (auth.options.providers) |p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        return .{ p, auth.store.vtable.config(auth.store.userdata, arena, p.id) orelse return error.NotConfigured };
    }
    return error.UnknownProvider;
}

fn exchange(auth: Auth, arena: std.mem.Allocator, p: Oauth.Provider, cfg: Oauth.Config, code: []const u8, verifier: []const u8) !Oauth.Identity {
    const token = try auth.http.vtable.fetch(auth.http.userdata, arena, try Oauth.tokenRequest(arena, p, cfg, code, try auth.callbackUrl(arena, p), verifier));
    const user = try auth.http.vtable.fetch(auth.http.userdata, arena, try Oauth.userRequest(arena, p, try Oauth.accessToken(arena, token)));
    const identity = try p.parseUser(arena, user);
    if (identity.id.len == 0) return error.MissingAccountId;
    return identity;
}

fn callbackUrl(auth: Auth, arena: std.mem.Allocator, p: Oauth.Provider) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ auth.options.origin, auth.options.callback_path, p.id });
}

fn relyingParty(auth: Auth) !WebAuthn.RelyingParty {
    return WebAuthn.RelyingParty.fromOrigin(auth.options.site_name, auth.options.origin);
}

// A fresh token on every sign-in, so a token planted before it can't ride along.
fn startSession(auth: Auth, arena: std.mem.Allocator, owner: Account) !void {
    if (auth.getCookie(session_cookie)) |old| auth.store.vtable.deleteSession(auth.store.userdata, &hashToken(old)) catch {};
    var bytes: [32]u8 = undefined;
    auth.io.random(&bytes);
    const token = std.fmt.bytesToHex(bytes, .lower);
    try auth.store.vtable.putSession(auth.store.userdata, &hashToken(&token), owner, auth.options.session_max_age_s);
    auth.setCookie(session_cookie, try arena.dupe(u8, &token));
}

// Only the hash is stored, so a leaked session table can't sign anyone in. Tokens
// are 256 random bits, so a fast hash is enough.
fn hashToken(token: []const u8) [2 * Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn newChallenge(auth: Auth, arena: std.mem.Allocator) !WebAuthn.Challenge {
    const challenge = WebAuthn.newChallenge(auth.io);
    auth.setCookie(challenge_cookie, try arena.dupe(u8, &challenge));
    return challenge;
}

// The cookie's max age is up to the browser, so the issue time signed into the
// challenge is what actually bounds it.
fn takeChallenge(auth: Auth) !WebAuthn.Challenge {
    const value = auth.takeCookie(challenge_cookie) orelse return error.Expired;
    if (value.len != @sizeOf(WebAuthn.Challenge)) return error.Expired;
    const challenge = value[0..@sizeOf(WebAuthn.Challenge)].*;
    const issued = WebAuthn.issuedAt(challenge) orelse return error.Expired;
    const now = std.Io.Timestamp.now(auth.io, .real).toSeconds();
    if (now - issued > WebAuthn.timeout_s or issued - now > challenge_skew_s) return error.Expired;
    return challenge;
}

// Stable per account without handing the account id to the authenticator.
fn userHandle(owner: Account) [16]u8 {
    var h: Sha256 = .init(.{});
    h.update(owner.provider);
    h.update(":");
    h.update(owner.id);
    return h.finalResult()[0..16].*;
}

// Trimmed, at most `max_passkey_name` bytes cut on a code point boundary, and
// "Passkey" when empty.
fn passkeyName(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return "Passkey";
    if (trimmed.len <= max_passkey_name) return trimmed;
    var end: usize = max_passkey_name;
    while (end > 0 and trimmed[end] & 0xc0 == 0x80) end -= 1;
    return trimmed[0..end];
}

// `__Host-` pins a cookie to this exact host, but needs `Secure`.
fn cookieName(auth: Auth, comptime spec: CookieSpec) []const u8 {
    return if (auth.secure()) "__Host-" ++ spec.name else spec.name;
}

fn secure(auth: Auth) bool {
    return std.mem.startsWith(u8, auth.options.origin, "https://");
}

fn getCookie(auth: Auth, comptime spec: CookieSpec) ?[]const u8 {
    return auth.http.vtable.cookie(auth.http.userdata, auth.cookieName(spec));
}

fn setCookie(auth: Auth, comptime spec: CookieSpec, value: []const u8) void {
    auth.http.vtable.setCookie(auth.http.userdata, .{
        .name = auth.cookieName(spec),
        .value = value,
        .max_age_s = spec.max_age_s orelse auth.options.session_max_age_s,
        .secure = auth.secure(),
    });
}

// Single use: cleared whether or not it was there.
fn takeCookie(auth: Auth, comptime spec: CookieSpec) ?[]const u8 {
    defer auth.http.vtable.setCookie(auth.http.userdata, .{ .name = auth.cookieName(spec), .value = "", .max_age_s = 0, .secure = auth.secure() });
    return auth.getCookie(spec);
}

const Sha256 = std.crypto.hash.sha2.Sha256;

const RequestHost = struct {
    request: @import("http/Request.zig"),
    response: @import("http/Response.zig"),
    io: std.Io,

    const vtable: Http.VTable = .{ .cookie = cookie, .setCookie = setCookie_, .fetch = fetch };

    fn from(ud: ?*anyopaque) *RequestHost {
        return @ptrCast(@alignCast(ud));
    }

    fn cookie(ud: ?*anyopaque, name: []const u8) ?[]const u8 {
        return from(ud).request.cookies.get(name);
    }

    fn setCookie_(ud: ?*anyopaque, c: Cookie) void {
        from(ud).response.cookies.set(c.name, c.value, .{
            .path = c.path,
            .secure = c.secure,
            .http_only = c.http_only,
            .same_site = c.same_site,
            .max_age = .fromSeconds(c.max_age_s),
        });
    }

    // Redirects aren't followed, so a token request's body never goes anywhere but
    // the endpoint it was built for.
    fn fetch(ud: ?*anyopaque, arena: std.mem.Allocator, request: Oauth.Request) anyerror![]const u8 {
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.appendSlice(arena, request.headers);
        try headers.append(arena, .{ .name = "User-Agent", .value = "ziex" });

        var client: HttpClient = .{ .io = from(ud).io, .allocator = arena };
        defer client.deinit();
        const response = try client.fetch(.{
            .url = request.url,
            .method = request.method,
            .headers = headers.items,
            .payload = request.body,
            .redirect = .manual,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        if (response.status.class() != .success) {
            log.warn("{s} returned {d}", .{ request.url, @backingInt(response.status) });
            return error.ProviderError;
        }
        return response.body;
    }
};
