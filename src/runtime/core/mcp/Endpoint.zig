// An MCP server plus the OAuth around it, mounted under one catch-all route
// (`app/routes/mcp/[..]/route.zig`):
//
//   <path>                                          JSON-RPC, bearer-protected when a store is set
//   <path>/.well-known/oauth-protected-resource     RFC 9728 resource metadata
//   <path>/.well-known/oauth-authorization-server   RFC 8414 (also at openid-configuration)
//   <path>/oauth/register                           RFC 7591 dynamic client registration
//   <path>/oauth/authorize                          validates, then sends the browser to `consent_path`
//   <path>/oauth/token                              authorization_code with PKCE S256
//
// The issuer and resource are `<origin><path>`. RFC 8414 and RFC 9728 put their
// metadata at the site root with the path appended, e.g.
// `/.well-known/oauth-authorization-server/mcp`, and many clients (MCP Inspector
// among them) only look there. `handle` answers those too, so also mount it at
// `app/routes/.well-known/[..]/route.zig`.
const Endpoint = @This();

const std = @import("std");
const Auth = @import("../Auth.zig");
const oauth = @import("oauth.zig");
const types = @import("types.zig");

io: std.Io,
// Null serves the tools to anyone and turns the OAuth paths off.
store: ?Store = null,
options: Options,

pub const Options = struct {
    // Where clients reach the site, e.g. `https://example.com`. Never derive it
    // from an untrusted `Host` header.
    origin: []const u8,
    // Where the catch-all route is mounted.
    path: []const u8 = "/mcp",
    // App page that shows an `Authorization` and answers with `approve` or `deny`.
    // It receives the authorize query, to pass back through `authorization`.
    consent_path: []const u8 = "",
    scope: []const u8 = "mcp",
    code_max_age_s: i64 = 10 * std.time.s_per_min,
    token_max_age_s: i64 = 30 * std.time.s_per_day,
    documentation: ?[]const u8 = null,
};

pub const Client = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    redirect_uris: []const []const u8,
    issued_at: i64,
};

// What an authorization code or access token stands for.
pub const Grant = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    approved_by: ?[]const u8 = null,
    // Codes only.
    code_challenge: []const u8 = "",
    expires_at: i64,
};

// Where clients, codes and tokens live. Codes and tokens arrive only as their
// hex SHA-256, so a leaked table can't be replayed.
pub const Store = struct {
    userdata: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        putClient: *const fn (?*anyopaque, Client) anyerror!void,
        getClient: *const fn (?*anyopaque, std.mem.Allocator, id: []const u8) anyerror!?Client,
        putCode: *const fn (?*anyopaque, code_hash: []const u8, Grant) anyerror!void,
        // Must return a code at most once.
        takeCode: *const fn (?*anyopaque, std.mem.Allocator, code_hash: []const u8) anyerror!?Grant,
        putToken: *const fn (?*anyopaque, token_hash: []const u8, Grant) anyerror!void,
        // Null once the token is revoked.
        getToken: *const fn (?*anyopaque, std.mem.Allocator, token_hash: []const u8) anyerror!?Grant,
    };
};

// A validated authorization request, for the consent page to show.
pub const Authorization = struct {
    client: Client,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    resource: ?[]const u8 = null,
};

pub const Error = error{
    NotConfigured,
    InvalidRequest,
    UnknownClient,
    InvalidRedirectUri,
    PkceRequired,
    InvalidResource,
};

const Path = enum {
    root,
    @".well-known/oauth-protected-resource",
    @".well-known/oauth-authorization-server",
    @".well-known/openid-configuration",
    @"oauth/register",
    @"oauth/authorize",
    @"oauth/token",

    fn method(path: Path) std.http.Method {
        return switch (path) {
            .root => .POST,
            .@"oauth/register", .@"oauth/token" => .POST,
            else => .GET,
        };
    }
};

// Answers any request under `options.path`; `server` is a `*zx.mcp.Server(C)`.
pub fn handle(ep: Endpoint, ctx: anytype, server: anytype, context: anytype) !void {
    const res = ctx.response;
    const path = ep.route(ctx.request.pathname) orelse return res.setStatus(.not_found);
    if (path == .root) {
        if (ep.store != null and try ep.grant(ctx.arena, ctx.request.headers.get("authorization")) == null) return ep.unauthorized(ctx);
        return server.serve(ctx, context);
    }

    res.headers.append("Cache-Control", "no-store");
    if (ep.store == null) return res.setStatus(.not_found);
    if (ctx.request.method != path.method()) {
        res.headers.append("Allow", @tagName(path.method()));
        return res.setStatus(.method_not_allowed);
    }

    const arena = ctx.arena;
    switch (path) {
        .root => unreachable,
        .@".well-known/oauth-protected-resource" => json(ctx, try oauth.writeProtectedResource(arena, .{
            .resource = try ep.url(arena, ""),
            .authorization_servers = &.{try ep.url(arena, "")},
            .scopes_supported = &.{ep.options.scope},
            .resource_documentation = ep.options.documentation,
        })),
        .@".well-known/oauth-authorization-server", .@".well-known/openid-configuration" => json(ctx, try oauth.writeAuthorizationServer(arena, .{
            .issuer = try ep.url(arena, ""),
            .authorization_endpoint = try ep.url(arena, "/oauth/authorize"),
            .token_endpoint = try ep.url(arena, "/oauth/token"),
            .registration_endpoint = try ep.url(arena, "/oauth/register"),
            .grant_types_supported = &.{"authorization_code"},
            .token_endpoint_auth_methods_supported = &.{"none"},
            .scopes_supported = &.{ep.options.scope},
        })),
        .@"oauth/register" => try ep.register(ctx),
        .@"oauth/authorize" => {
            if (ep.options.consent_path.len == 0) return res.setStatus(.not_found);
            const a = ep.authorization(arena, ctx.request.query) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    res.setStatus(.bad_request);
                    return res.text(@errorName(err));
                },
            };
            res.redirect(try withQuery(arena, ep.options.consent_path, &.{
                .{ "response_type", "code" },
                .{ "client_id", a.client.id },
                .{ "redirect_uri", a.redirect_uri },
                .{ "code_challenge", a.code_challenge },
                .{ "code_challenge_method", "S256" },
                .{ "state", a.state },
                .{ "scope", a.scope },
                .{ "resource", a.resource },
            }), .found);
        },
        .@"oauth/token" => try ep.token(ctx),
    }
}

// Validates an authorize request from anything with `get(name) ?[]const u8`,
// e.g. `ctx.request.query` or the consent form's `ctx.request.formData()`.
pub fn authorization(ep: Endpoint, arena: std.mem.Allocator, params: anytype) !Authorization {
    const store = ep.store orelse return error.NotConfigured;
    if (!std.mem.eql(u8, params.get("response_type") orelse "", "code")) return error.InvalidRequest;
    const client_id = nonEmpty(params.get("client_id")) orelse return error.InvalidRequest;
    const redirect_uri = nonEmpty(params.get("redirect_uri")) orelse return error.InvalidRequest;

    const client = (try store.vtable.getClient(store.userdata, arena, client_id)) orelse return error.UnknownClient;
    for (client.redirect_uris) |uri| {
        if (std.mem.eql(u8, uri, redirect_uri)) break;
    } else return error.InvalidRedirectUri;

    const challenge = nonEmpty(params.get("code_challenge")) orelse return error.PkceRequired;
    if (challenge.len != 43 or !std.mem.eql(u8, params.get("code_challenge_method") orelse "", "S256")) return error.PkceRequired;

    const resource = nonEmpty(params.get("resource"));
    if (resource) |r| if (!std.mem.eql(u8, r, try ep.url(arena, ""))) return error.InvalidResource;

    return .{
        .client = client,
        .redirect_uri = redirect_uri,
        .code_challenge = challenge,
        .state = nonEmpty(params.get("state")),
        .scope = nonEmpty(params.get("scope")),
        .resource = resource,
    };
}

// Issues a code and returns where to send the browser.
pub fn approve(ep: Endpoint, arena: std.mem.Allocator, a: Authorization, approved_by: ?[]const u8) ![]const u8 {
    const store = ep.store orelse return error.NotConfigured;
    const code = randomToken(ep.io);
    try store.vtable.putCode(store.userdata, &Auth.hashToken(&code), .{
        .client_id = a.client.id,
        .redirect_uri = a.redirect_uri,
        .scope = a.scope,
        .resource = a.resource,
        .approved_by = approved_by,
        .code_challenge = a.code_challenge,
        .expires_at = ep.now() + ep.options.code_max_age_s,
    });
    return withQuery(arena, a.redirect_uri, &.{ .{ "code", &code }, .{ "state", a.state } });
}

pub fn deny(_: Endpoint, arena: std.mem.Allocator, a: Authorization) ![]const u8 {
    return withQuery(arena, a.redirect_uri, &.{ .{ "error", "access_denied" }, .{ "state", a.state } });
}

// The grant behind an `Authorization: Bearer` header, if it is live.
pub fn grant(ep: Endpoint, arena: std.mem.Allocator, authorization_header: ?[]const u8) !?Grant {
    const store = ep.store orelse return null;
    const bearer = oauth.bearer(authorization_header) orelse return null;
    const g = (try store.vtable.getToken(store.userdata, arena, &Auth.hashToken(bearer))) orelse return null;
    if (g.expires_at <= ep.now()) return null;
    if (g.resource) |r| if (!std.mem.eql(u8, r, try ep.url(arena, ""))) return null;
    return g;
}

fn register(ep: Endpoint, ctx: anytype) !void {
    const store = ep.store.?;
    const arena = ctx.arena;
    const Body = struct {
        redirect_uris: []const []const u8 = &.{},
        client_name: ?[]const u8 = null,
        scope: ?[]const u8 = null,
    };
    const body = std.json.parseFromSliceLeaky(Body, arena, ctx.request.text() orelse "", types.parse_opts) catch
        return fail(ctx, .bad_request, "invalid_client_metadata", "Invalid client metadata");
    if (body.redirect_uris.len == 0) return fail(ctx, .bad_request, "invalid_redirect_uri", "redirect_uris required");
    for (body.redirect_uris) |uri| if (!try allowedRedirect(arena, uri))
        return fail(ctx, .bad_request, "invalid_redirect_uri", "Only https or loopback http redirect URIs are allowed");

    const id = randomToken(ep.io);
    const client: Client = .{
        .id = try arena.dupe(u8, &id),
        .name = body.client_name,
        .redirect_uris = body.redirect_uris,
        .issued_at = ep.now(),
    };
    try store.vtable.putClient(store.userdata, client);

    ctx.response.setStatus(.created);
    json(ctx, try oauth.writeClientRegistration(arena, .{
        .client_id = client.id,
        .client_id_issued_at = client.issued_at,
        .client_name = client.name,
        .redirect_uris = client.redirect_uris,
        .grant_types = &.{"authorization_code"},
        .scope = body.scope,
    }));
}

fn token(ep: Endpoint, ctx: anytype) !void {
    const store = ep.store.?;
    const form = ctx.request.formData();
    if (!std.mem.eql(u8, form.get("grant_type") orelse "", "authorization_code"))
        return fail(ctx, .bad_request, "unsupported_grant_type", "Only authorization_code is supported");
    const code = nonEmpty(form.get("code")) orelse return fail(ctx, .bad_request, "invalid_request", "code is required");

    const g = (try store.vtable.takeCode(store.userdata, ctx.arena, &Auth.hashToken(code))) orelse
        return fail(ctx, .bad_request, "invalid_grant", "Invalid or expired code");
    if (g.expires_at <= ep.now()) return fail(ctx, .bad_request, "invalid_grant", "Invalid or expired code");
    if (!std.mem.eql(u8, g.client_id, form.get("client_id") orelse "") or !std.mem.eql(u8, g.redirect_uri, form.get("redirect_uri") orelse ""))
        return fail(ctx, .bad_request, "invalid_grant", "client_id or redirect_uri mismatch");
    if (!oauth.verifyPkce(form.get("code_verifier") orelse "", g.code_challenge))
        return fail(ctx, .bad_request, "invalid_grant", "PKCE verification failed");

    const access = randomToken(ep.io);
    var t = g;
    t.code_challenge = "";
    t.expires_at = ep.now() + ep.options.token_max_age_s;
    try store.vtable.putToken(store.userdata, &Auth.hashToken(&access), t);
    json(ctx, try oauth.writeTokenResponse(ctx.arena, &access, @intCast(ep.options.token_max_age_s), g.scope));
}

fn unauthorized(ep: Endpoint, ctx: anytype) !void {
    const res = ctx.response;
    res.setStatus(.unauthorized);
    res.headers.append("Cache-Control", "no-store");
    res.headers.append("WWW-Authenticate", try oauth.wwwAuthenticate(ctx.arena, .{
        .resource_metadata_url = try ep.url(ctx.arena, "/.well-known/oauth-protected-resource"),
        .scope = ep.options.scope,
    }));
    json(ctx, try oauth.writeOAuthError(ctx.arena, "invalid_token", "Authentication required"));
}

fn route(ep: Endpoint, pathname: []const u8) ?Path {
    const base = std.mem.trimEnd(u8, ep.options.path, "/");
    if (std.mem.startsWith(u8, pathname, "/.well-known/")) {
        const doc = pathname["/.well-known/".len..];
        inline for (.{ .@".well-known/oauth-protected-resource", .@".well-known/oauth-authorization-server", .@".well-known/openid-configuration" }) |p| {
            const name = @tagName(p)[".well-known/".len..];
            if (std.mem.startsWith(u8, doc, name) and std.mem.eql(u8, std.mem.trimEnd(u8, doc[name.len..], "/"), base)) return p;
        }
        return null;
    }
    if (!std.mem.startsWith(u8, pathname, base)) return null;
    const rest = pathname[base.len..];
    if (rest.len > 0 and rest[0] != '/') return null;
    const sub = std.mem.trim(u8, rest, "/");
    if (sub.len == 0) return .root;
    if (std.mem.eql(u8, sub, "root")) return null;
    return std.meta.stringToEnum(Path, sub);
}

fn url(ep: Endpoint, arena: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    return arena.print("{s}{s}{s}", .{
        std.mem.trimEnd(u8, ep.options.origin, "/"),
        std.mem.trimEnd(u8, ep.options.path, "/"),
        suffix,
    });
}

fn now(ep: Endpoint) i64 {
    return std.Io.Timestamp.now(ep.io, .real).toSeconds();
}

fn randomToken(io: std.Io) [64]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len > 0) s else null;
}

fn json(ctx: anytype, body: []const u8) void {
    ctx.response.setContentType(.@"application/json");
    ctx.response.text(body);
}

fn fail(ctx: anytype, status: std.http.Status, code: []const u8, description: []const u8) !void {
    ctx.response.setStatus(status);
    json(ctx, try oauth.writeOAuthError(ctx.arena, code, description));
}

// https anywhere, plain http only back to this machine.
fn allowedRedirect(arena: std.mem.Allocator, uri: []const u8) !bool {
    const parsed = std.Uri.parse(uri) catch return false;
    if (parsed.fragment != null) return false;
    if (std.mem.eql(u8, parsed.scheme, "https")) return parsed.host != null;
    if (!std.mem.eql(u8, parsed.scheme, "http")) return false;
    const host = try (parsed.host orelse return false).toRawMaybeAlloc(arena);
    for ([_][]const u8{ "localhost", "127.0.0.1", "[::1]", "::1" }) |h| {
        if (std.mem.eql(u8, host, h)) return true;
    }
    return false;
}

fn withQuery(arena: std.mem.Allocator, base: []const u8, pairs: []const struct { []const u8, ?[]const u8 }) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll(base);
    var sep: u8 = if (std.mem.findScalar(u8, base, '?') != null) '&' else '?';
    for (pairs) |pair| {
        const value = pair[1] orelse continue;
        try w.writeByte(sep);
        sep = '&';
        try w.writeAll(pair[0]);
        try w.writeByte('=');
        try std.Uri.Component.percentEncode(w, value, isUnreserved);
    }
    return aw.written();
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}
