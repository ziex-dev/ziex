// The test app's sign-in: an in-memory store and a `fake` OAuth provider whose
// endpoints are served by this same server.
const std = @import("std");
const zx = @import("zx");

const Auth = zx.Auth;

var mutex: std.Io.Mutex = .init;
var sessions: std.StringArrayHashMapUnmanaged(Auth.Account) = .empty;

// Set by the test once the server is listening.
pub var port: u16 = 0;

pub fn of(ctx: anytype) !Auth {
    const base = try std.fmt.allocPrint(ctx.arena, "http://127.0.0.1:{d}", .{port});
    const providers = try ctx.arena.dupe(Auth.Oauth.Provider, &.{.{
        .id = "fake",
        .name = "Fake",
        .authorize_url = try std.fmt.allocPrint(ctx.arena, "{s}/auth/provider/authorize", .{base}),
        .token_url = try std.fmt.allocPrint(ctx.arena, "{s}/auth/provider/token", .{base}),
        .user_url = try std.fmt.allocPrint(ctx.arena, "{s}/auth/provider/user", .{base}),
        .scope = "user",
        .parseUser = Auth.Oauth.providers.github.parseUser,
    }});
    const io = try ctx.arena.create(std.Io);
    io.* = ctx.io;
    return .init(ctx, .{ .userdata = io, .vtable = &store }, .{
        .origin = base,
        .site_name = "Test",
        .home = "/auth/me",
        .providers = providers,
    });
}

const store: Auth.Store.VTable = .{
    .config = config,
    .authorize = authorize,
    .putSession = putSession,
    .getSession = getSession,
    .deleteSession = deleteSession,
    .putPasskey = undefined,
    .getPasskey = undefined,
    .listPasskeys = listPasskeys,
    .usePasskey = undefined,
    .deletePasskey = undefined,
};

fn ioOf(ud: ?*anyopaque) std.Io {
    return @as(*const std.Io, @ptrCast(@alignCast(ud))).*;
}

fn config(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) ?Auth.Oauth.Config {
    return .{ .client_id = "client", .client_secret = "secret" };
}

fn authorize(_: ?*anyopaque, _: std.mem.Allocator, owner: Auth.Account) anyerror!bool {
    return std.mem.eql(u8, owner.id, "42");
}

fn putSession(ud: ?*anyopaque, token_hash: []const u8, owner: Auth.Account, _: i64) anyerror!void {
    const io = ioOf(ud);
    try mutex.lock(io);
    defer mutex.unlock(io);
    const gpa = std.heap.page_allocator;
    try sessions.put(gpa, try gpa.dupe(u8, token_hash), .{
        .provider = try gpa.dupe(u8, owner.provider),
        .id = try gpa.dupe(u8, owner.id),
        .name = try gpa.dupe(u8, owner.name),
    });
}

fn getSession(ud: ?*anyopaque, _: std.mem.Allocator, token_hash: []const u8) anyerror!?Auth.Account {
    const io = ioOf(ud);
    try mutex.lock(io);
    defer mutex.unlock(io);
    return sessions.get(token_hash);
}

fn deleteSession(ud: ?*anyopaque, token_hash: []const u8) anyerror!void {
    const io = ioOf(ud);
    try mutex.lock(io);
    defer mutex.unlock(io);
    _ = sessions.orderedRemove(token_hash);
}

fn listPasskeys(_: ?*anyopaque, _: std.mem.Allocator, _: Auth.Account) anyerror![]const Auth.Passkey {
    return &.{};
}
