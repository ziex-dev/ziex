// Model Context Protocol: a tools server, the OAuth around it, and a client.
// `mcp/gen` is generated from the spec by `zig build gen -- mcp`.
//
// One catch-all route serves everything, e.g. `app/routes/mcp/[..]/route.zig`:
//
//   pub fn Route(ctx: zx.RouteContext) !void {
//       var server = zx.mcp.Server(*Ctx).init(ctx.arena, .{ .name = "docs" });
//       try server.addTool(.{ .name = "search" }, search);
//       const endpoint: zx.mcp.Endpoint = .{ .io = ctx.io, .store = store, .options = .{
//           .origin = "https://example.com",
//           .consent_path = "/mcp-consent",
//       } };
//       try endpoint.handle(ctx, &server, &my_ctx);
//   }
//
// Leave `store` null for a public server with no OAuth.

pub const version = @import("mcp/gen/version.zig");
pub const methods = @import("mcp/gen/methods.zig");
pub const error_codes = @import("mcp/gen/error_codes.zig");
pub const defs = @import("mcp/gen/defs_index.zig").defs;

pub const jsonrpc = @import("mcp/jsonrpc.zig");
pub const types = @import("mcp/types.zig");
pub const oauth = @import("mcp/oauth.zig");

pub const Server = @import("mcp/server.zig").Server;
pub const Config = @import("mcp/server.zig").Config;
pub const CacheScope = @import("mcp/server.zig").CacheScope;
pub const Client = @import("mcp/Client.zig");
pub const Endpoint = @import("mcp/Endpoint.zig");

pub const Method = methods.Method;
pub const Tool = types.Tool;
pub const ToolResult = types.ToolResult;
pub const ToolAnnotations = types.ToolAnnotations;

pub const protocol_version = version.protocol_version;
pub const protocol_version_header = "MCP-Protocol-Version";
pub const session_id_header = "Mcp-Session-Id";
