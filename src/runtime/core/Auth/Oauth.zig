const std = @import("std");

pub const Identity = struct { id: []const u8, name: []const u8 };

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    user_url: []const u8,
    // Left out of the authorize URL when empty.
    scope: []const u8,
    // How the token request proves the client: secret in the form body, or HTTP
    // Basic (RFC 6749 §2.3.1) for providers that only accept that.
    client_auth: enum { post, basic } = .post,
    // Reads a stable account id and a display name from the user-info response.
    parseUser: *const fn (std.mem.Allocator, []const u8) anyerror!Identity,
};

// Common providers. Each one's account id is the provider's stable, non-reassignable
// user id, never an email or username, which can change hands. Register the redirect
// URI `<origin><callback_path><id>` with the provider.
pub const providers = struct {
    pub const discord: Provider = .{
        .id = "discord",
        .name = "Discord",
        .authorize_url = "https://discord.com/oauth2/authorize",
        .token_url = "https://discord.com/api/oauth2/token",
        .user_url = "https://discord.com/api/users/@me",
        .scope = "identify",
        .parseUser = parseDiscordUser,
    };

    pub const facebook: Provider = .{
        .id = "facebook",
        .name = "Facebook",
        .authorize_url = "https://www.facebook.com/dialog/oauth",
        .token_url = "https://graph.facebook.com/oauth/access_token",
        .user_url = "https://graph.facebook.com/me?fields=id,name",
        .scope = "public_profile",
        .parseUser = parseFacebookUser,
    };

    pub const github: Provider = .{
        .id = "github",
        .name = "GitHub",
        .authorize_url = "https://github.com/login/oauth/authorize",
        .token_url = "https://github.com/login/oauth/access_token",
        .user_url = "https://api.github.com/user",
        .scope = "read:user",
        .parseUser = parseGitHubUser,
    };

    pub const gitlab: Provider = .{
        .id = "gitlab",
        .name = "GitLab",
        .authorize_url = "https://gitlab.com/oauth/authorize",
        .token_url = "https://gitlab.com/oauth/token",
        .user_url = "https://gitlab.com/api/v4/user",
        .scope = "read_user",
        .parseUser = parseGitLabUser,
    };

    pub const google: Provider = .{
        .id = "google",
        .name = "Google",
        .authorize_url = "https://accounts.google.com/o/oauth2/v2/auth",
        .token_url = "https://oauth2.googleapis.com/token",
        .user_url = "https://openidconnect.googleapis.com/v1/userinfo",
        .scope = "openid profile email",
        .parseUser = parseOidcUser,
    };

    pub const linkedin: Provider = .{
        .id = "linkedin",
        .name = "LinkedIn",
        .authorize_url = "https://www.linkedin.com/oauth/v2/authorization",
        .token_url = "https://www.linkedin.com/oauth/v2/accessToken",
        .user_url = "https://api.linkedin.com/v2/userinfo",
        .scope = "openid profile",
        .parseUser = parseOidcUser,
    };

    // Any work, school or personal Microsoft account (the `common` tenant). For one
    // organization only, copy this with the tenant id in place of `common`.
    pub const microsoft: Provider = .{
        .id = "microsoft",
        .name = "Microsoft",
        .authorize_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        .token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        .user_url = "https://graph.microsoft.com/oidc/userinfo",
        .scope = "openid profile email",
        .parseUser = parseOidcUser,
    };

    pub const slack: Provider = .{
        .id = "slack",
        .name = "Slack",
        .authorize_url = "https://slack.com/openid/connect/authorize",
        .token_url = "https://slack.com/api/openid.connect.token",
        .user_url = "https://slack.com/api/openid.connect.userInfo",
        .scope = "openid profile",
        .parseUser = parseOidcUser,
    };

    pub const spotify: Provider = .{
        .id = "spotify",
        .name = "Spotify",
        .authorize_url = "https://accounts.spotify.com/authorize",
        .token_url = "https://accounts.spotify.com/api/token",
        .user_url = "https://api.spotify.com/v1/me",
        .scope = "",
        .parseUser = parseSpotifyUser,
    };

    pub const twitch: Provider = .{
        .id = "twitch",
        .name = "Twitch",
        .authorize_url = "https://id.twitch.tv/oauth2/authorize",
        .token_url = "https://id.twitch.tv/oauth2/token",
        .user_url = "https://id.twitch.tv/oauth2/userinfo",
        .scope = "openid",
        .parseUser = parseOidcUser,
    };

    pub const x: Provider = .{
        .id = "x",
        .name = "X",
        .authorize_url = "https://x.com/i/oauth2/authorize",
        .token_url = "https://api.x.com/2/oauth2/token",
        .user_url = "https://api.x.com/2/users/me",
        .scope = "users.read tweet.read",
        .client_auth = .basic,
        .parseUser = parseXUser,
    };
};

// OpenID Connect userinfo: `sub` is the stable id; the display name is the first
// of `preferred_username`, `name` and `email` that is set.
pub fn parseOidcUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct {
        sub: []const u8,
        preferred_username: ?[]const u8 = null,
        name: ?[]const u8 = null,
        email: ?[]const u8 = null,
    }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = user.sub, .name = firstSet(&.{ user.preferred_username, user.name, user.email }) orelse user.sub };
}

// Numeric ids are stable; logins can be renamed and re-registered by someone else.
fn parseGitHubUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct { id: u64, login: []const u8 }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = try std.fmt.allocPrint(arena, "{d}", .{user.id}), .name = user.login };
}

fn parseGitLabUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct { id: u64, username: []const u8 }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = try std.fmt.allocPrint(arena, "{d}", .{user.id}), .name = user.username };
}

fn parseDiscordUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct { id: []const u8, username: []const u8, global_name: ?[]const u8 = null }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = user.id, .name = user.global_name orelse user.username };
}

fn parseFacebookUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct { id: []const u8, name: ?[]const u8 = null }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = user.id, .name = user.name orelse user.id };
}

fn parseSpotifyUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const user = try std.json.parseFromSliceLeaky(struct { id: []const u8, display_name: ?[]const u8 = null }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = user.id, .name = user.display_name orelse user.id };
}

fn parseXUser(arena: std.mem.Allocator, body: []const u8) !Identity {
    const res = try std.json.parseFromSliceLeaky(struct { data: struct { id: []const u8, username: []const u8 } }, arena, body, .{ .ignore_unknown_fields = true });
    return .{ .id = res.data.id, .name = res.data.username };
}

fn firstSet(values: []const ?[]const u8) ?[]const u8 {
    for (values) |v| if (v) |s| if (s.len > 0) return s;
    return null;
}

pub const Config = struct { client_id: []const u8, client_secret: []const u8 };

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8 = null,
};

// The query the provider sends back to the callback.
pub const Callback = struct { state: ?[]const u8, code: ?[]const u8, @"error": ?[]const u8 };

pub fn authorizeUrl(arena: std.mem.Allocator, p: Provider, cfg: Config, redirect_uri: []const u8, flow: Flow) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s}{c}response_type=code", .{ p.authorize_url, @as(u8, if (std.mem.indexOfScalar(u8, p.authorize_url, '?') == null) '?' else '&') });
    try param(&out.writer, "client_id", cfg.client_id);
    try param(&out.writer, "redirect_uri", redirect_uri);
    if (p.scope.len > 0) try param(&out.writer, "scope", p.scope);
    try param(&out.writer, "state", &flow.state);
    try param(&out.writer, "code_challenge", &flow.challenge());
    try param(&out.writer, "code_challenge_method", "S256");
    return out.toOwnedSlice();
}

pub fn tokenRequest(arena: std.mem.Allocator, p: Provider, cfg: Config, code: []const u8, redirect_uri: []const u8, verifier: []const u8) !Request {
    var body: std.Io.Writer.Allocating = .init(arena);
    try body.writer.writeAll("grant_type=authorization_code");
    try param(&body.writer, "client_id", cfg.client_id);
    if (p.client_auth == .post) try param(&body.writer, "client_secret", cfg.client_secret);
    try param(&body.writer, "code", code);
    try param(&body.writer, "redirect_uri", redirect_uri);
    try param(&body.writer, "code_verifier", verifier);

    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    });
    if (p.client_auth == .basic) try headers.append(arena, .{ .name = "Authorization", .value = try basicAuth(arena, cfg) });
    return .{ .method = .POST, .url = p.token_url, .body = try body.toOwnedSlice(), .headers = headers.items };
}

// Both parts form-encoded before joining, as RFC 6749 §2.3.1 asks.
fn basicAuth(arena: std.mem.Allocator, cfg: Config) ![]const u8 {
    var pair: std.Io.Writer.Allocating = .init(arena);
    try std.Uri.Component.percentEncode(&pair.writer, cfg.client_id, isUnreserved);
    try pair.writer.writeByte(':');
    try std.Uri.Component.percentEncode(&pair.writer, cfg.client_secret, isUnreserved);
    const raw = pair.written();
    const out = try arena.alloc(u8, "Basic ".len + std.base64.standard.Encoder.calcSize(raw.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(out["Basic ".len..], raw);
    return out;
}

// Only RFC 6750 token characters, since the token goes into a request header.
pub fn accessToken(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const token = std.json.parseFromSliceLeaky(struct {
        access_token: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.TokenExchangeFailed;
    if (token.@"error" != null) return error.TokenExchangeFailed;
    const value = token.access_token orelse return error.TokenExchangeFailed;
    if (value.len == 0) return error.TokenExchangeFailed;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~+/=", c) != null)) return error.TokenExchangeFailed;
    return value;
}

pub fn userRequest(arena: std.mem.Allocator, p: Provider, access_token: []const u8) !Request {
    return .{
        .method = .GET,
        .url = p.user_url,
        .headers = try arena.dupe(std.http.Header, &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{access_token}) },
        }),
    };
}

// One sign-in attempt, kept in a cookie as `<state>.<verifier>.<provider>.<next>`
// with the last two base64url-encoded. The state ties the callback to this browser,
// the provider to the one the attempt started with, and the PKCE verifier makes an
// intercepted code useless to anyone without the cookie.
pub const Flow = struct {
    state: [32]u8,
    verifier: [43]u8,
    provider: []const u8,
    next: []const u8,

    pub fn init(io: std.Io, provider: []const u8, next: []const u8) Flow {
        var state: [16]u8 = undefined;
        var verifier: [32]u8 = undefined;
        io.random(&state);
        io.random(&verifier);
        var flow: Flow = .{ .state = std.fmt.bytesToHex(state, .lower), .verifier = undefined, .provider = provider, .next = next };
        _ = b64.Encoder.encode(&flow.verifier, &verifier);
        return flow;
    }

    pub fn challenge(flow: Flow) [43]u8 {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&flow.verifier, &digest, .{});
        var out: [43]u8 = undefined;
        _ = b64.Encoder.encode(&out, &digest);
        return out;
    }

    pub fn encode(flow: Flow, arena: std.mem.Allocator) ![]const u8 {
        const provider = try arena.alloc(u8, b64.Encoder.calcSize(flow.provider.len));
        const next = try arena.alloc(u8, b64.Encoder.calcSize(flow.next.len));
        return std.mem.join(arena, ".", &.{
            &flow.state,
            &flow.verifier,
            b64.Encoder.encode(provider, flow.provider),
            b64.Encoder.encode(next, flow.next),
        });
    }

    // Null unless `cookie` is well formed and carries the `returned` state and `provider`.
    pub fn decode(arena: std.mem.Allocator, cookie: []const u8, returned: []const u8, provider: []const u8) ?Flow {
        var parts = std.mem.splitScalar(u8, cookie, '.');
        const state = parts.next() orelse return null;
        const verifier = parts.next() orelse return null;
        const encoded_provider = parts.next() orelse return null;
        const encoded_next = parts.next() orelse return null;
        if (parts.next() != null or state.len != 32 or verifier.len != 43 or returned.len != 32) return null;
        if (!std.crypto.timing_safe.eql([32]u8, state[0..32].*, returned[0..32].*)) return null;

        const saved_provider = decodeAlloc(arena, encoded_provider) orelse return null;
        if (!std.mem.eql(u8, saved_provider, provider)) return null;
        const next = decodeAlloc(arena, encoded_next) orelse return null;
        return .{ .state = state[0..32].*, .verifier = verifier[0..43].*, .provider = saved_provider, .next = next };
    }
};

fn decodeAlloc(arena: std.mem.Allocator, encoded: []const u8) ?[]const u8 {
    const out = arena.alloc(u8, b64.Decoder.calcSizeForSlice(encoded) catch return null) catch return null;
    b64.Decoder.decode(out, encoded) catch return null;
    return out;
}

const b64 = std.base64.url_safe_no_pad;
const Sha256 = std.crypto.hash.sha2.Sha256;

fn param(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("&{s}=", .{name});
    try std.Uri.Component.percentEncode(w, value, isUnreserved);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null;
}
