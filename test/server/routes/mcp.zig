const std = @import("std");
const zx = @import("zx");
const mcp = zx.mcp;

// Bearer "secret" required; `?sse=1` answers as an event stream.
const Ctx = struct {
    arena: std.mem.Allocator,
    session_id: []const u8,
    protocol_version: []const u8,
};

const Tools = mcp.Server(*Ctx);

pub fn GET(ctx: zx.RouteContext) !void {
    return POST(ctx);
}

pub fn POST(ctx: zx.RouteContext) !void {
    const headers = ctx.request.headers;
    const token = mcp.oauth.bearer(headers.get("authorization")) orelse "";
    if (!std.mem.eql(u8, token, "secret")) {
        ctx.response.setStatus(.unauthorized);
        ctx.response.headers.append("WWW-Authenticate", try mcp.oauth.wwwAuthenticate(ctx.arena, .{
            .resource_metadata_url = "http://localhost/.well-known/oauth-protected-resource",
            .scope = "mcp",
        }));
        ctx.response.setContentType(.@"application/json");
        return ctx.response.text(try mcp.oauth.writeOAuthError(ctx.arena, "invalid_token", "Authentication required"));
    }

    var server = Tools.init(ctx.arena, .{ .name = "test", .version = "1.0.0", .instructions = "hi" });
    defer server.deinit();
    try server.addTool(.{
        .name = "echo",
        .description = "Echo text",
        .input_schema_json =
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
        ,
        .annotations = .{ .readOnlyHint = true },
    }, echo);
    try server.addTool(.{ .name = "whoami" }, whoami);
    try server.addTool(.{ .name = "fail" }, fail);

    var c: Ctx = .{
        .arena = ctx.arena,
        .session_id = headers.get("mcp-session-id") orelse "",
        .protocol_version = headers.get("mcp-protocol-version") orelse "",
    };
    ctx.response.headers.append(mcp.session_id_header, "s1");

    if (ctx.request.query.get("sse") == null) return server.serve(ctx, &c);

    const reply = try server.handleMessage(ctx.arena, &c, ctx.request.text() orelse "");
    if (reply.len == 0) return ctx.response.setStatus(.accepted);
    ctx.response.headers.append("Content-Type", "text/event-stream");
    ctx.response.text(try std.fmt.allocPrint(ctx.arena,
        \\event: message
        \\data: {{"jsonrpc":"2.0","method":"notifications/message","params":{{"level":"info","data":"working"}}}}
        \\
        \\event: message
        \\data: {s}
        \\
        \\
    , .{reply}));
}

fn echo(c: *Ctx, args: ?std.json.Value) anyerror!mcp.ToolResult {
    const text = (args orelse return error.MissingArgs).object.get("text") orelse return error.MissingArgs;
    return mcp.ToolResult.text(c.arena, text.string);
}

fn whoami(c: *Ctx, _: ?std.json.Value) anyerror!mcp.ToolResult {
    return mcp.ToolResult.text(c.arena, try std.fmt.allocPrint(c.arena, "{s} {s}", .{ c.session_id, c.protocol_version }));
}

fn fail(_: *Ctx, _: ?std.json.Value) anyerror!mcp.ToolResult {
    return error.Boom;
}
