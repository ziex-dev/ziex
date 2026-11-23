// MCP client over Streamable HTTP, on top of `zx.http.Client`.
//
//   var client: zx.mcp.Client = .{ .io = io, .allocator = gpa, .url = "https://example.com/mcp" };
//   defer client.deinit();
//   _ = try client.initialize(arena);
//   const result = try client.callTool(arena, "search", .{ .query = "zig" });
const Client = @This();

const std = @import("std");
const http = @import("../http.zig");
const types = @import("types.zig");
const version = @import("gen/version.zig");
const Method = @import("gen/methods.zig").Method;

const log = std.log.scoped(.zx_mcp);

io: std.Io,
allocator: std.mem.Allocator,
url: []const u8,
// Sent with every request, e.g. `Authorization: Bearer <token>`.
headers: []const http.Header = &.{},
info: types.Implementation = .{ .name = "ziex", .version = "0.0.0" },
// Set when a call fails with `error.Rpc`; points into that call's arena.
last_error: ?RpcError = null,
_internal: Internal = .{},

const Internal = struct {
    http: ?http.Client = null,
    session_id: ?[]u8 = null,
    protocol_version: ?[]u8 = null,
    next_id: i64 = 1,
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Error = http.Client.Error || error{
    Rpc,
    Unauthorized,
    HttpStatus,
    InvalidResponse,
};

pub fn deinit(client: *Client) void {
    if (client._internal.http) |*h| h.deinit();
    if (client._internal.session_id) |s| client.allocator.free(s);
    if (client._internal.protocol_version) |s| client.allocator.free(s);
    client._internal = .{};
}

pub fn sessionId(client: *const Client) ?[]const u8 {
    return client._internal.session_id;
}

// Handshake: `initialize`, then `notifications/initialized`.
pub fn initialize(client: *Client, arena: std.mem.Allocator) Error!types.InitializeResult {
    const value = try client.request(arena, .initialize, .{
        .protocolVersion = version.legacy[0],
        .capabilities = .{},
        .clientInfo = client.info,
    });
    const result = std.json.parseFromValueLeaky(types.InitializeResult, arena, value, types.parse_opts) catch return error.InvalidResponse;
    try replace(client.allocator, &client._internal.protocol_version, result.protocolVersion);
    try client.notify(arena, .notifications_initialized, null);
    return result;
}

pub fn ping(client: *Client, arena: std.mem.Allocator) Error!void {
    _ = try client.request(arena, .ping, null);
}

// All tools, following `nextCursor` pages.
pub fn listTools(client: *Client, arena: std.mem.Allocator) Error![]const types.ToolInfo {
    const Page = struct { tools: []const types.ToolInfo = &.{}, nextCursor: ?[]const u8 = null };
    var tools: std.ArrayList(types.ToolInfo) = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        const value = if (cursor) |c|
            try client.request(arena, .tools_list, .{ .cursor = c })
        else
            try client.request(arena, .tools_list, null);
        const page = std.json.parseFromValueLeaky(Page, arena, value, types.parse_opts) catch return error.InvalidResponse;
        try tools.appendSlice(arena, page.tools);
        cursor = page.nextCursor orelse return tools.items;
    }
}

// A tool failure comes back as `isError = true`, not as a Zig error.
pub fn callTool(client: *Client, arena: std.mem.Allocator, name: []const u8, arguments: anytype) Error!types.CallResult {
    const value = if (@TypeOf(arguments) == @TypeOf(null))
        try client.request(arena, .tools_call, .{ .name = name })
    else
        try client.request(arena, .tools_call, .{ .name = name, .arguments = arguments });
    return std.json.parseFromValueLeaky(types.CallResult, arena, value, types.parse_opts) catch error.InvalidResponse;
}

// Sends a request and returns its `result`. Pass `null` for no params.
pub fn request(client: *Client, arena: std.mem.Allocator, comptime method: Method, params: anytype) Error!std.json.Value {
    const id = client._internal.next_id;
    client._internal.next_id += 1;

    const body = try encode(arena, id, method.toString(), params);
    const reply = try client.post(arena, body);
    const msg = try findResponse(arena, reply, id);

    if (msg.object.get("error")) |e| {
        client.last_error = std.json.parseFromValueLeaky(RpcError, arena, e, types.parse_opts) catch return error.InvalidResponse;
        log.debug("{s}: {d} {s}", .{ method.toString(), client.last_error.?.code, client.last_error.?.message });
        return error.Rpc;
    }
    return msg.object.get("result") orelse error.InvalidResponse;
}

pub fn notify(client: *Client, arena: std.mem.Allocator, comptime method: Method, params: anytype) Error!void {
    _ = try client.post(arena, try encode(arena, null, method.toString(), params));
}

const Reply = struct {
    content_type: []const u8,
    body: []const u8,
};

fn post(client: *Client, arena: std.mem.Allocator, body: []const u8) Error!Reply {
    var headers: std.ArrayList(http.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json, text/event-stream" },
    });
    if (client._internal.session_id) |s| try headers.append(arena, .{ .name = "mcp-session-id", .value = s });
    if (client._internal.protocol_version) |v| try headers.append(arena, .{ .name = "mcp-protocol-version", .value = v });
    try headers.appendSlice(arena, client.headers);

    if (client._internal.http == null) client._internal.http = .{ .io = client.io, .allocator = client.allocator };
    const res = try client._internal.http.?.fetch(.{ .url = client.url, .method = .POST, .headers = headers.items, .payload = body });
    defer res.deinit(client.allocator);

    if (res.header("mcp-session-id")) |s| try replace(client.allocator, &client._internal.session_id, s);

    switch (res.status) {
        .unauthorized, .forbidden => return error.Unauthorized,
        else => if (res.status.class() != .success) {
            log.warn("{d} {s}: {s}", .{ @backingInt(res.status), client.url, res.body });
            return error.HttpStatus;
        },
    }
    return .{
        .content_type = try arena.dupe(u8, res.header("content-type") orelse ""),
        .body = try arena.dupe(u8, res.body),
    };
}

// The JSON-RPC response for `id`, from a JSON body or an SSE stream.
fn findResponse(arena: std.mem.Allocator, reply: Reply, id: i64) Error!std.json.Value {
    if (!std.mem.startsWith(u8, reply.content_type, "text/event-stream")) {
        const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, types.parse_opts) catch return error.InvalidResponse;
        return if (isResponseTo(msg, id)) msg else error.InvalidResponse;
    }

    var events = std.mem.splitSequence(u8, reply.body, "\n\n");
    while (events.next()) |event| {
        var data: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, event, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            if (data.items.len > 0) try data.append(arena, '\n');
            try data.appendSlice(arena, std.mem.trimStart(u8, line[5..], " "));
        }
        if (data.items.len == 0) continue;
        const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, data.items, types.parse_opts) catch continue;
        if (isResponseTo(msg, id)) return msg;
    }
    return error.InvalidResponse;
}

fn isResponseTo(msg: std.json.Value, id: i64) bool {
    if (msg != .object or msg.object.get("method") != null) return false;
    const got = msg.object.get("id") orelse return false;
    return got == .integer and got.integer == id;
}

fn encode(arena: std.mem.Allocator, id: ?i64, method: []const u8, params: anytype) ![]u8 {
    if (@TypeOf(params) == @TypeOf(null)) {
        if (id) |i| return types.stringify(arena, .{ .jsonrpc = "2.0", .id = i, .method = method });
        return types.stringify(arena, .{ .jsonrpc = "2.0", .method = method });
    }
    if (id) |i| return types.stringify(arena, .{ .jsonrpc = "2.0", .id = i, .method = method, .params = params });
    return types.stringify(arena, .{ .jsonrpc = "2.0", .method = method, .params = params });
}

fn replace(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| {
        if (std.mem.eql(u8, old, value)) return;
        allocator.free(old);
        slot.* = null;
    }
    slot.* = try allocator.dupe(u8, value);
}
