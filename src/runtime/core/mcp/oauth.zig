const std = @import("std");
const types = @import("types.zig");
const Oauth = @import("../Auth/Oauth.zig");

pub const verifyPkce = Oauth.verifyPkce;

pub const ProtectedResource = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8 = &.{},
    bearer_methods_supported: []const []const u8 = &.{"header"},
    resource_documentation: ?[]const u8 = null,
};

pub const AuthorizationServer = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8 = null,
    response_types_supported: []const []const u8 = &.{"code"},
    grant_types_supported: []const []const u8 = &.{ "authorization_code", "refresh_token" },
    code_challenge_methods_supported: []const []const u8 = &.{"S256"},
    token_endpoint_auth_methods_supported: []const []const u8 = &.{ "none", "client_secret_post" },
    scopes_supported: []const []const u8 = &.{},
};

pub const ClientRegistration = struct {
    client_id: []const u8,
    client_id_issued_at: i64,
    client_secret_expires_at: i64 = 0,
    client_name: ?[]const u8 = null,
    redirect_uris: []const []const u8,
    grant_types: []const []const u8 = &.{ "authorization_code", "refresh_token" },
    response_types: []const []const u8 = &.{"code"},
    token_endpoint_auth_method: []const u8 = "none",
    scope: ?[]const u8 = null,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_in: u32,
    scope: ?[]const u8 = null,
};

pub const ErrorBody = struct {
    @"error": []const u8,
    error_description: ?[]const u8 = null,
};

pub fn writeProtectedResource(allocator: std.mem.Allocator, doc: ProtectedResource) ![]u8 {
    return types.stringify(allocator, doc);
}

pub fn writeAuthorizationServer(allocator: std.mem.Allocator, doc: AuthorizationServer) ![]u8 {
    return types.stringify(allocator, doc);
}

pub fn writeClientRegistration(allocator: std.mem.Allocator, doc: ClientRegistration) ![]u8 {
    return types.stringify(allocator, doc);
}

pub fn writeTokenResponse(allocator: std.mem.Allocator, access_token: []const u8, expires_in: u32, scope: ?[]const u8) ![]u8 {
    return types.stringify(allocator, TokenResponse{
        .access_token = access_token,
        .expires_in = expires_in,
        .scope = scope,
    });
}

pub fn writeOAuthError(allocator: std.mem.Allocator, err_code: []const u8, description: ?[]const u8) ![]u8 {
    return types.stringify(allocator, ErrorBody{
        .@"error" = err_code,
        .error_description = description,
    });
}

pub const Challenge = struct {
    resource_metadata_url: []const u8,
    scope: ?[]const u8 = null,
    realm: []const u8 = "mcp",
};

// `WWW-Authenticate` value pointing clients at the protected-resource metadata.
pub fn wwwAuthenticate(allocator: std.mem.Allocator, challenge: Challenge) ![]u8 {
    if (challenge.scope) |scope| {
        return std.fmt.allocPrint(allocator, "Bearer realm=\"{s}\", resource_metadata=\"{s}\", scope=\"{s}\"", .{ challenge.realm, challenge.resource_metadata_url, scope });
    }
    return std.fmt.allocPrint(allocator, "Bearer realm=\"{s}\", resource_metadata=\"{s}\"", .{ challenge.realm, challenge.resource_metadata_url });
}

pub fn bearer(authorization: ?[]const u8) ?[]const u8 {
    const h = std.mem.trim(u8, authorization orelse return null, " \t");
    if (h.len < 7 or !std.ascii.eqlIgnoreCase(h[0..6], "Bearer") or (h[6] != ' ' and h[6] != '\t')) return null;
    const rest = std.mem.trimStart(u8, h[6..], " \t");
    return if (rest.len == 0) null else rest;
}
