// A dual-era tools server. A request carrying the modern per-request `_meta`
// (`io.modelcontextprotocol/protocolVersion`) is served statelessly by that
// revision; anything else gets the legacy `initialize`-handshake behavior. No
// session state is kept either way, so one handler serves both eras.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const methods = @import("gen/methods.zig");
const version = @import("gen/version.zig");
const types = @import("types.zig");

pub const Config = struct {
    name: []const u8,
    version: []const u8 = "1.0.0",
    title: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    // Cache hints on modern `tools/list` and `server/discover` results. Keep
    // `private` unless every caller sees the same tools.
    cache_ttl_ms: u64 = 0,
    cache_scope: CacheScope = .private,
};

pub const CacheScope = enum { public, private };

// The Streamable HTTP headers a modern request mirrors from its body.
pub const Headers = struct {
    protocol_version: ?[]const u8 = null,
    method: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const Reply = struct {
    // Empty for an accepted notification.
    body: []const u8,
    status: std.http.Status = .ok,
};

const meta_protocol_version = "io.modelcontextprotocol/protocolVersion";

// `Context` is passed to every tool handler, e.g. a per-request struct.
pub fn Server(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Handler = *const fn (context: Context, args: ?std.json.Value) anyerror!types.ToolResult;

        const Entry = struct {
            tool: types.Tool,
            handler: Handler,
        };

        allocator: std.mem.Allocator,
        config: Config,
        tools: std.ArrayList(Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator, config: Config) Self {
            return .{ .allocator = allocator, .config = config };
        }

        pub fn deinit(self: *Self) void {
            self.tools.deinit(self.allocator);
        }

        pub fn addTool(self: *Self, tool: types.Tool, handler: Handler) !void {
            try self.tools.append(self.allocator, .{ .tool = tool, .handler = handler });
        }

        // Streamable HTTP endpoint: POST a JSON-RPC message, get JSON back (202 for notifications).
        pub fn serve(self: *Self, ctx: anytype, context: Context) !void {
            const res = ctx.response;
            res.headers.append("Cache-Control", "no-store");
            if (ctx.request.method != .POST) {
                res.headers.append("Allow", "POST");
                return res.setStatus(.method_not_allowed);
            }
            const h = ctx.request.headers;
            const r = try self.reply(ctx.arena, context, ctx.request.text() orelse "", .{
                .protocol_version = h.get("mcp-protocol-version"),
                .method = h.get("mcp-method"),
                .name = h.get("mcp-name"),
            });
            if (r.body.len == 0) return res.setStatus(.accepted);
            res.setStatus(r.status);
            res.setContentType(.@"application/json");
            res.text(r.body);
        }

        // One message in, its response out ("" for a notification). Header
        // checks only run when `headers` is given, i.e. over HTTP.
        pub fn handleMessage(self: *Self, allocator: std.mem.Allocator, context: Context, body: []const u8) ![]const u8 {
            return (try self.reply(allocator, context, body, null)).body;
        }

        pub fn reply(self: *Self, allocator: std.mem.Allocator, context: Context, body: []const u8, headers: ?Headers) !Reply {
            const msg = jsonrpc.parse(allocator, body) catch |err| return switch (err) {
                error.InvalidRequest => fail(allocator, .null, .bad_request, jsonrpc.codes.invalid_request, "Invalid request"),
                error.OutOfMemory => error.OutOfMemory,
                else => fail(allocator, .null, .bad_request, jsonrpc.codes.parse_error, "Parse error"),
            };
            const id = msg.id orelse .null;
            if (msg.is_response) return fail(allocator, id, .bad_request, jsonrpc.codes.invalid_request, "Server does not accept responses");
            if (msg.is_notification) return .{ .body = "" };

            if (requestedVersion(msg.params)) |requested| return self.modern(allocator, context, msg, id, requested, headers);
            return self.legacy(allocator, context, msg, id);
        }

        fn legacy(self: *Self, allocator: std.mem.Allocator, context: Context, msg: jsonrpc.Incoming, id: jsonrpc.Id) !Reply {
            const method = methods.Method.fromString(msg.method) orelse
                return fail(allocator, id, .ok, jsonrpc.codes.method_not_found, "Method not found");
            return .{ .body = switch (method) {
                .initialize => try jsonrpc.writeResult(allocator, id, types.InitializeResult{
                    .protocolVersion = legacyVersion(msg.params),
                    .capabilities = .{ .tools = .{ .listChanged = false } },
                    .serverInfo = self.info(),
                    .instructions = self.config.instructions,
                }),
                .ping => try jsonrpc.writeResult(allocator, id, .{}),
                .tools_list => try jsonrpc.writeResult(allocator, id, types.ToolsListResult{ .tools = try self.descriptors(allocator) }),
                .tools_call => switch (try self.call(allocator, context, msg.params)) {
                    .result => |r| try jsonrpc.writeResult(allocator, id, types.CallToolResult{
                        .content = r.content,
                        .isError = r.isError,
                        .structuredContent = r.structuredContent,
                    }),
                    .invalid => |why| try jsonrpc.writeError(allocator, id, jsonrpc.codes.invalid_params, why),
                },
                else => try jsonrpc.writeError(allocator, id, jsonrpc.codes.method_not_found, "Method not implemented"),
            } };
        }

        fn modern(self: *Self, allocator: std.mem.Allocator, context: Context, msg: jsonrpc.Incoming, id: jsonrpc.Id, requested: []const u8, headers: ?Headers) !Reply {
            if (!isModern(requested)) {
                return .{ .status = .bad_request, .body = try jsonrpc.writeErrorData(allocator, id, jsonrpc.codes.unsupported_protocol_version, "Unsupported protocol version", .{
                    .supported = &version.supported,
                    .requested = requested,
                }) };
            }
            if (headers) |h| if (try mismatch(allocator, h, msg, requested)) |why|
                return fail(allocator, id, .bad_request, jsonrpc.codes.header_mismatch, why);

            const meta = .{ .@"io.modelcontextprotocol/serverInfo" = self.info() };
            const method = methods.Method.fromString(msg.method) orelse
                return fail(allocator, id, .not_found, jsonrpc.codes.method_not_found, "Method not found");
            return .{ .body = switch (method) {
                .server_discover => try jsonrpc.writeResult(allocator, id, .{
                    .resultType = "complete",
                    .supportedVersions = &version.supported,
                    .capabilities = types.ServerCapabilities{ .tools = .{} },
                    .instructions = self.config.instructions,
                    .ttlMs = self.config.cache_ttl_ms,
                    .cacheScope = @tagName(self.config.cache_scope),
                    ._meta = meta,
                }),
                .tools_list => try jsonrpc.writeResult(allocator, id, .{
                    .resultType = "complete",
                    .tools = try self.descriptors(allocator),
                    .ttlMs = self.config.cache_ttl_ms,
                    .cacheScope = @tagName(self.config.cache_scope),
                    ._meta = meta,
                }),
                .tools_call => switch (try self.call(allocator, context, msg.params)) {
                    .result => |r| try jsonrpc.writeResult(allocator, id, .{
                        .resultType = "complete",
                        .content = r.content,
                        .isError = r.isError,
                        .structuredContent = r.structuredContent,
                        ._meta = meta,
                    }),
                    .invalid => |why| try jsonrpc.writeError(allocator, id, jsonrpc.codes.invalid_params, why),
                },
                else => return fail(allocator, id, .not_found, jsonrpc.codes.method_not_found, "Method not found"),
            } };
        }

        fn info(self: *Self) types.Implementation {
            return .{ .name = self.config.name, .version = self.config.version, .title = self.config.title };
        }

        fn descriptors(self: *Self, allocator: std.mem.Allocator) ![]const types.ToolDescriptor {
            const out = try allocator.alloc(types.ToolDescriptor, self.tools.items.len);
            for (self.tools.items, out) |reg, *d| d.* = .{
                .name = reg.tool.name,
                .description = reg.tool.description,
                .inputSchema = .{ .bytes = reg.tool.input_schema_json },
                .annotations = reg.tool.annotations,
            };
            return out;
        }

        const Call = union(enum) { result: types.ToolResult, invalid: []const u8 };

        // A failing tool is a result with `isError`, not a protocol error.
        fn call(self: *Self, allocator: std.mem.Allocator, context: Context, params: ?std.json.Value) !Call {
            const p = params orelse return .{ .invalid = "Missing params" };
            if (p != .object) return .{ .invalid = "params must be object" };
            const name = p.object.get("name") orelse return .{ .invalid = "Missing tool name" };
            if (name != .string) return .{ .invalid = "Tool name must be string" };
            const reg = for (self.tools.items) |t| {
                if (std.mem.eql(u8, t.tool.name, name.string)) break t;
            } else return .{ .invalid = "Unknown tool" };

            const result = reg.handler(context, p.object.get("arguments")) catch |err|
                return .{ .result = try types.ToolResult.err(allocator, try std.fmt.allocPrint(allocator, "Tool error: {s}", .{@errorName(err)})) };
            return .{ .result = result };
        }
    };
}

fn fail(allocator: std.mem.Allocator, id: jsonrpc.Id, status: std.http.Status, code: i64, message: []const u8) !Reply {
    return .{ .status = status, .body = try jsonrpc.writeError(allocator, id, code, message) };
}

fn requestedVersion(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const meta = p.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const v = meta.object.get(meta_protocol_version) orelse return null;
    return if (v == .string) v.string else null;
}

fn isModern(v: []const u8) bool {
    for (version.modern) |m| if (std.mem.eql(u8, m, v)) return true;
    return false;
}

// The client's version when it's a legacy one we speak, else our newest legacy one.
fn legacyVersion(params: ?std.json.Value) []const u8 {
    const p = params orelse return version.legacy[0];
    if (p != .object) return version.legacy[0];
    const asked = p.object.get("protocolVersion") orelse return version.legacy[0];
    if (asked != .string) return version.legacy[0];
    for (version.legacy) |l| if (std.mem.eql(u8, l, asked.string)) return l;
    return version.legacy[0];
}

// Why the mirrored headers disagree with the body, if they do.
fn mismatch(allocator: std.mem.Allocator, h: Headers, msg: jsonrpc.Incoming, requested: []const u8) !?[]const u8 {
    if (!std.mem.eql(u8, h.protocol_version orelse "", requested)) return "MCP-Protocol-Version header does not match _meta";
    if (!std.mem.eql(u8, h.method orelse "", msg.method)) return "Mcp-Method header does not match method";

    const key: []const u8 = if (std.mem.eql(u8, msg.method, "tools/call") or std.mem.eql(u8, msg.method, "prompts/get"))
        "name"
    else if (std.mem.eql(u8, msg.method, "resources/read"))
        "uri"
    else
        return null;
    const body_name: []const u8 = blk: {
        const p = msg.params orelse break :blk "";
        if (p != .object) break :blk "";
        const v = p.object.get(key) orelse break :blk "";
        break :blk if (v == .string) v.string else "";
    };
    const header_name = decodeHeader(allocator, h.name orelse return "Mcp-Name header is required") catch
        return "Mcp-Name header is malformed";
    if (!std.mem.eql(u8, header_name, body_name)) return "Mcp-Name header does not match body";
    return null;
}

// `=?base64?…?=` carries values that aren't plain header-safe ASCII.
fn decodeHeader(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const prefix = "=?base64?";
    const suffix = "?=";
    if (value.len < prefix.len + suffix.len or !std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, suffix)) return value;
    const encoded = value[prefix.len .. value.len - suffix.len];
    const decoder = std.base64.standard.Decoder;
    const out = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(out, encoded);
    return out;
}
