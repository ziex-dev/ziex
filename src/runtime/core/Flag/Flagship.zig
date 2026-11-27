const Flagship = @This();

const std = @import("std");
const builtin = @import("builtin");
const Flag = @import("../Flag.zig");
const http = @import("../http.zig");
const wire = @import("wire.zig");
const host = @import("../../wasm/imports.zig");

// Cloudflare Flagship. Inside a Worker the `binding` is used when present,
// otherwise flags are evaluated over the REST API.
io: std.Io,
binding: ?[]const u8 = null,
base_url: []const u8 = default_base_url,
account_id: ?[]const u8 = null,
app_id: ?[]const u8 = null,
api_token: ?[]const u8 = null,

pub const default_base_url = "https://api.cloudflare.com/client/v4";
pub const default_binding = "FLAGS";

pub const Env = enum {
    CLOUDFLARE_ACCOUNT_ID,
    FLAGSHIP_APP_ID,
    CLOUDFLARE_API_TOKEN,
    FLAGSHIP_BASE_URL,
    FLAGSHIP_BINDING,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const account_id = Env.CLOUDFLARE_ACCOUNT_ID;
    pub const app_id = Env.FLAGSHIP_APP_ID;
    pub const api_token = Env.CLOUDFLARE_API_TOKEN;
    pub const base_url = Env.FLAGSHIP_BASE_URL;
    pub const binding = Env.FLAGSHIP_BINDING;
};

pub fn flag(f: *Flagship) Flag {
    return .{ .userdata = f, .vtable = &.{ .resolve = &resolve } };
}

fn resolve(userdata: ?*anyopaque, arena: std.mem.Allocator, key: []const u8, kind: Flag.Kind, context: Flag.Context) Flag.Error!Flag.Resolution {
    const f: *Flagship = @ptrCast(@alignCast(userdata));
    if (builtin.os.tag == .wasi) if (f.binding) |name| {
        if (try evaluate(arena, name, key, kind, context)) |reply| return reply.resolution();
    };
    return f.rest(arena, key, context);
}

fn rest(f: *Flagship, arena: std.mem.Allocator, key: []const u8, context: Flag.Context) Flag.Error!Flag.Resolution {
    const account_id = f.account_id orelse return error.ProviderNotReady;
    const app_id = f.app_id orelse return error.ProviderNotReady;
    const token = f.api_token orelse return error.ProviderNotReady;

    const url = arena.print("{s}/accounts/{s}/flagship/apps/{s}/evaluate", .{
        std.mem.trimEnd(u8, f.base_url, "/"), account_id, app_id,
    }) catch return error.General;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = arena.print("Bearer {s}", .{token}) catch return error.General },
    };

    const res = try wire.post(f.io, arena, url, &headers, .{ .flagKey = key, .context = context });
    switch (res.status) {
        .ok => {},
        .not_found => return error.FlagNotFound,
        .bad_request => return error.InvalidContext,
        else => return error.General,
    }
    // Accepts both the bare details and the Cloudflare `{"result": …}` envelope.
    const envelope = try wire.parse(struct { result: ?wire.Reply = null }, arena, res.body);
    const reply = envelope.result orelse try wire.parse(wire.Reply, arena, res.body);
    return reply.resolution();
}

// Null when the Worker has no such binding.
fn evaluate(arena: std.mem.Allocator, binding: []const u8, key: []const u8, kind: Flag.Kind, context: Flag.Context) Flag.Error!?wire.Reply {
    const method, const default = switch (kind) {
        .boolean => .{ "getBooleanDetails", "false" },
        .string => .{ "getStringDetails", "\"\"" },
        .int, .float => .{ "getNumberDetails", "0" },
        .object => .{ "getObjectDetails", "{}" },
    };
    const args = arena.print("[{f},{s},{s}]", .{
        std.json.fmt(key, .{}), default, try wire.json(arena, context),
    }) catch return error.General;

    var out: [*]u8 = undefined;
    const n = host.wait(.env_call, .{ binding, method, args, &out });
    if (n == host.missing or n == host.unsupported) return null;
    if (n <= 0) return error.General;

    const owned = host.owned(out, n);
    defer host.free(owned);
    // The reply borrows from its input.
    const bytes = arena.dupe(u8, owned) catch return error.General;
    return try wire.parse(wire.Reply, arena, bytes);
}
