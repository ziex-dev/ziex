// An OAuth-protected MCP server under `/secure/mcp/*`, with an in-memory store
// and a consent page that approves (or with `?deny=1` denies) without asking.
const std = @import("std");
const zx = @import("zx");
const mcp = zx.mcp;

// Set by the test once the server is listening.
pub var port: u16 = 0;

const Ctx = struct { arena: std.mem.Allocator };

pub const api = struct {
    pub fn Route(ctx: zx.RouteContext) !void {
        var server = mcp.Server(*Ctx).init(ctx.arena, .{ .name = "secure" });
        defer server.deinit();
        try server.addTool(.{ .name = "hello" }, hello);
        var c: Ctx = .{ .arena = ctx.arena };
        try (try endpoint(ctx)).handle(ctx, &server, &c);
    }
};

pub const consent = struct {
    pub fn GET(ctx: zx.RouteContext) !void {
        const ep = try endpoint(ctx);
        const a = ep.authorization(ctx.arena, ctx.request.query) catch |err| {
            ctx.response.setStatus(.bad_request);
            return ctx.response.text(@errorName(err));
        };
        const to = if (ctx.request.query.get("deny") != null) try ep.deny(ctx.arena, a) else try ep.approve(ctx.arena, a, "tester");
        ctx.response.redirect(to, .found);
    }
};

fn hello(c: *Ctx, _: ?std.json.Value) anyerror!mcp.ToolResult {
    return mcp.ToolResult.text(c.arena, "hello");
}

fn endpoint(ctx: zx.RouteContext) !mcp.Endpoint {
    const io = try ctx.arena.create(std.Io);
    io.* = ctx.io;
    return .{
        .io = ctx.io,
        .store = .{ .userdata = io, .vtable = &store },
        .options = .{
            .origin = try std.fmt.allocPrint(ctx.arena, "http://127.0.0.1:{d}", .{port}),
            .path = "/secure/mcp",
            .consent_path = "/secure/consent",
        },
    };
}

var mutex: std.Io.Mutex = .init;
var clients: std.StringArrayHashMapUnmanaged(mcp.Endpoint.Client) = .empty;
var codes: std.StringArrayHashMapUnmanaged(mcp.Endpoint.Grant) = .empty;
var tokens: std.StringArrayHashMapUnmanaged(mcp.Endpoint.Grant) = .empty;
const gpa = std.heap.page_allocator;

const store: mcp.Endpoint.Store.VTable = .{
    .putClient = putClient,
    .getClient = getClient,
    .putCode = putCode,
    .takeCode = takeCode,
    .putToken = putToken,
    .getToken = getToken,
};

fn lock(ud: ?*anyopaque) !std.Io {
    const io = @as(*const std.Io, @ptrCast(@alignCast(ud))).*;
    try mutex.lock(io);
    return io;
}

fn dupe(s: []const u8) ![]const u8 {
    return gpa.dupe(u8, s);
}

fn dupeOpt(s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try gpa.dupe(u8, v) else null;
}

fn dupeGrant(g: mcp.Endpoint.Grant) !mcp.Endpoint.Grant {
    return .{
        .client_id = try dupe(g.client_id),
        .redirect_uri = try dupe(g.redirect_uri),
        .scope = try dupeOpt(g.scope),
        .resource = try dupeOpt(g.resource),
        .approved_by = try dupeOpt(g.approved_by),
        .code_challenge = try dupe(g.code_challenge),
        .expires_at = g.expires_at,
    };
}

fn putClient(ud: ?*anyopaque, c: mcp.Endpoint.Client) anyerror!void {
    const io = try lock(ud);
    defer mutex.unlock(io);
    const uris = try gpa.alloc([]const u8, c.redirect_uris.len);
    for (c.redirect_uris, uris) |u, *out| out.* = try dupe(u);
    try clients.put(gpa, try dupe(c.id), .{ .id = try dupe(c.id), .name = try dupeOpt(c.name), .redirect_uris = uris, .issued_at = c.issued_at });
}

fn getClient(ud: ?*anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!?mcp.Endpoint.Client {
    const io = try lock(ud);
    defer mutex.unlock(io);
    return clients.get(id);
}

fn putCode(ud: ?*anyopaque, hash: []const u8, g: mcp.Endpoint.Grant) anyerror!void {
    const io = try lock(ud);
    defer mutex.unlock(io);
    try codes.put(gpa, try dupe(hash), try dupeGrant(g));
}

fn takeCode(ud: ?*anyopaque, _: std.mem.Allocator, hash: []const u8) anyerror!?mcp.Endpoint.Grant {
    const io = try lock(ud);
    defer mutex.unlock(io);
    const kv = codes.fetchOrderedRemove(hash) orelse return null;
    return kv.value;
}

fn putToken(ud: ?*anyopaque, hash: []const u8, g: mcp.Endpoint.Grant) anyerror!void {
    const io = try lock(ud);
    defer mutex.unlock(io);
    try tokens.put(gpa, try dupe(hash), try dupeGrant(g));
}

fn getToken(ud: ?*anyopaque, _: std.mem.Allocator, hash: []const u8) anyerror!?mcp.Endpoint.Grant {
    const io = try lock(ud);
    defer mutex.unlock(io);
    return tokens.get(hash);
}
