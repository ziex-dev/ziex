const std = @import("std");
const zx = @import("zx");

const mcp = zx.mcp;
const Harness = zx.testing.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const auth: []const zx.http.Header = &.{.{ .name = "authorization", .value = "Bearer secret" }};

// --- Server --- //

const Ctx = struct { arena: std.mem.Allocator };
const Tools = mcp.Server(*Ctx);

fn hello(c: *Ctx, _: ?std.json.Value) anyerror!mcp.ToolResult {
    return mcp.ToolResult.fromValue(c.arena, .{ .greeting = "hi" });
}

fn rpc(arena: std.mem.Allocator, server: *Tools, body: []const u8) !std.json.Value {
    var c: Ctx = .{ .arena = arena };
    const reply = try server.handleMessage(arena, &c, body);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{});
}

fn errorCode(msg: std.json.Value) i64 {
    return msg.object.get("error").?.object.get("code").?.integer;
}

test "server > dispatches JSON-RPC messages" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = Tools.init(arena, .{ .name = "unit" });
    defer server.deinit();
    try server.addTool(.{ .name = "hello" }, hello);

    var msg = try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":"a","method":"initialize","params":{}}
    );
    try expectEqualStrings("a", msg.object.get("id").?.string);
    const init = msg.object.get("result").?.object;
    try expectEqualStrings(mcp.version.legacy[0], init.get("protocolVersion").?.string);
    try expectEqualStrings("unit", init.get("serverInfo").?.object.get("name").?.string);
    try expect(init.get("capabilities").?.object.get("tools") != null);

    msg = try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"hello"}}
    );
    const result = msg.object.get("result").?.object;
    try expectEqualStrings("hi", result.get("structuredContent").?.object.get("greeting").?.string);
    try expectEqualStrings("{\"greeting\":\"hi\"}", result.get("content").?.array.items[0].object.get("text").?.string);

    var c: Ctx = .{ .arena = arena };
    try expectEqualStrings("", try server.handleMessage(arena, &c,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));
    try expectEqualStrings("", try server.handleMessage(arena, &c,
        \\{"jsonrpc":"2.0","method":"notifications/unknown"}
    ));

    try expectEqual(mcp.error_codes.parse_error, errorCode(try rpc(arena, &server, "{nope")));
    try expectEqual(mcp.error_codes.invalid_request, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"1.0","id":1,"method":"ping"}
    )));
    try expectEqual(mcp.error_codes.method_not_found, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"bogus"}
    )));
    try expectEqual(mcp.error_codes.method_not_found, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"prompts/list"}
    )));
    // An id outside i64 range used to trap in @intFromFloat.
    try expectEqual(mcp.error_codes.method_not_found, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1e300,"method":"bogus"}
    )));
    try expectEqual(mcp.error_codes.invalid_request, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"result":{}}
    )));
    try expectEqual(mcp.error_codes.invalid_params, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing"}}
    )));
    try expectEqual(mcp.error_codes.invalid_params, errorCode(try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    )));
}

// A modern (stateless) request: the version rides in `_meta`.
fn modernBody(arena: std.mem.Allocator, method: []const u8, extra: []const u8) ![]const u8 {
    return arena.print(
        \\{{"jsonrpc":"2.0","id":7,"method":"{s}","params":{{{s}"_meta":{{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{{}}}}}}}}
    , .{ method, extra });
}

test "server > serves the modern era statelessly" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = Tools.init(arena, .{ .name = "unit", .version = "2.0.0", .instructions = "hi", .cache_ttl_ms = 60_000 });
    defer server.deinit();
    try server.addTool(.{ .name = "hello" }, hello);

    // No handshake: discover, list and call each stand alone.
    var msg = try rpc(arena, &server, try modernBody(arena, "server/discover", ""));
    var result = msg.object.get("result").?.object;
    try expectEqualStrings("complete", result.get("resultType").?.string);
    const supported = result.get("supportedVersions").?.array.items;
    try expectEqualStrings("2026-07-28", supported[0].string);
    try expectEqualStrings("2025-11-25", supported[1].string);
    try expect(result.get("capabilities").?.object.get("tools") != null);
    try expectEqualStrings("hi", result.get("instructions").?.string);
    try expectEqual(60_000, result.get("ttlMs").?.integer);
    try expectEqualStrings("private", result.get("cacheScope").?.string);
    try expectEqualStrings("unit", result.get("_meta").?.object.get("io.modelcontextprotocol/serverInfo").?.object.get("name").?.string);

    msg = try rpc(arena, &server, try modernBody(arena, "tools/list", ""));
    result = msg.object.get("result").?.object;
    try expectEqualStrings("complete", result.get("resultType").?.string);
    try expectEqualStrings("hello", result.get("tools").?.array.items[0].object.get("name").?.string);
    try expect(result.get("ttlMs") != null and result.get("cacheScope") != null);

    msg = try rpc(arena, &server, try modernBody(arena, "tools/call", "\"name\":\"hello\","));
    result = msg.object.get("result").?.object;
    try expectEqualStrings("complete", result.get("resultType").?.string);
    try expectEqualStrings("hi", result.get("structuredContent").?.object.get("greeting").?.string);

    // Legacy-only methods don't exist in the modern era.
    try expectEqual(mcp.error_codes.method_not_found, errorCode(try rpc(arena, &server, try modernBody(arena, "initialize", ""))));
    try expectEqual(mcp.error_codes.method_not_found, errorCode(try rpc(arena, &server, try modernBody(arena, "ping", ""))));

    // An unknown version lists what we speak.
    msg = try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}
    );
    try expectEqual(mcp.error_codes.unsupported_protocol_version, errorCode(msg));
    const data = msg.object.get("error").?.object.get("data").?.object;
    try expectEqualStrings("1900-01-01", data.get("requested").?.string);
    try expectEqual(2, data.get("supported").?.array.items.len);

    // Legacy `initialize` gets the client's version when we speak it, else our newest legacy one.
    msg = try rpc(arena, &server,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    );
    try expectEqualStrings("2025-11-25", msg.object.get("result").?.object.get("protocolVersion").?.string);
    try expect(msg.object.get("result").?.object.get("resultType") == null);
}

test "methods > round-trip wire names" {
    try expectEqualStrings("tools/call", mcp.Method.tools_call.toString());
    try expectEqual(mcp.Method.notifications_initialized, mcp.Method.fromString("notifications/initialized").?);
    try expectEqual(null, mcp.Method.fromString("tools/nope"));
}

// --- OAuth --- //

test "oauth > bearer, challenge, pkce" {
    try expectEqualStrings("abc", mcp.oauth.bearer("Bearer abc").?);
    try expectEqualStrings("abc", mcp.oauth.bearer("  bearer \tabc ").?);
    try expectEqual(null, mcp.oauth.bearer(null));
    try expectEqual(null, mcp.oauth.bearer("Bearer "));
    try expectEqual(null, mcp.oauth.bearer("Bearerabc"));
    try expectEqual(null, mcp.oauth.bearer("Basic abc"));

    const www = try mcp.oauth.wwwAuthenticate(gpa, .{ .resource_metadata_url = "https://x/meta", .scope = "mcp" });
    defer gpa.free(www);
    try expectEqualStrings("Bearer realm=\"mcp\", resource_metadata=\"https://x/meta\", scope=\"mcp\"", www);

    // RFC 7636 appendix B.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    try expect(mcp.oauth.verifyPkce(verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
    try expect(!mcp.oauth.verifyPkce(verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cN"));
    try expect(!mcp.oauth.verifyPkce(verifier, "short"));
}

// --- Over HTTP --- //

fn url(buf: []u8, harness: *Harness, query: []const u8) ![]const u8 {
    return std.mem.print(buf, "http://127.0.0.1:{d}/mcp{s}", .{ harness.tcp.?.port, query });
}

test "http > client talks to a mounted server" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{ "", "?sse=1" }) |query| {
        var buf: [128]u8 = undefined;
        var client: mcp.Client = .{ .io = io, .allocator = gpa, .url = try url(&buf, &harness, query), .headers = auth };
        defer client.deinit();

        const init = try client.initialize(arena);
        try expectEqualStrings(mcp.version.legacy[0], init.protocolVersion);
        try expectEqualStrings("test", init.serverInfo.name);
        try expectEqualStrings("hi", init.instructions.?);
        try expectEqualStrings("s1", client.sessionId().?);

        try client.ping(arena);

        const tools = try client.listTools(arena);
        try expectEqual(3, tools.len);
        try expectEqualStrings("echo", tools[0].name);
        try expectEqualStrings("Echo text", tools[0].description.?);
        try expect(tools[0].annotations.?.readOnlyHint.?);
        try expectEqualStrings("string", tools[0].inputSchema.object.get("properties").?.object.get("text").?.object.get("type").?.string);

        var result = try client.callTool(arena, "echo", .{ .text = "hello" });
        try expect(!result.isError);
        try expectEqualStrings("hello", try result.text(arena));

        // Session id and negotiated version ride along after the handshake.
        result = try client.callTool(arena, "whoami", null);
        try expectEqualStrings("s1 " ++ mcp.version.legacy[0], try result.text(arena));

        result = try client.callTool(arena, "fail", null);
        try expect(result.isError);
        try expectEqualStrings("Tool error: Boom", try result.text(arena));

        try expectError(error.Rpc, client.callTool(arena, "nope", null));
        try expectEqual(mcp.error_codes.invalid_params, client.last_error.?.code);
        try expectEqualStrings("Unknown tool", client.last_error.?.message);
    }
}

fn modernHeaders(comptime method: []const u8, comptime name: ?[]const u8) []const zx.testing.Header {
    const base = [_]zx.testing.Header{
        .{ .name = "authorization", .value = "Bearer secret" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "mcp-protocol-version", .value = "2026-07-28" },
        .{ .name = "mcp-method", .value = method },
    };
    return if (name) |n| &(base ++ [_]zx.testing.Header{.{ .name = "mcp-name", .value = n }}) else &base;
}

test "http > modern requests are checked against their headers" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .headers = modernHeaders("server/discover", null), .body = try modernBody(arena, "server/discover", "") });
    try expectEqual(200, res.status);
    try expect(std.mem.find(u8, res.body, "\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"]") != null);

    const call = try modernBody(arena, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":\"hey\"},");
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .headers = modernHeaders("tools/call", "echo"), .body = call });
    try expectEqual(200, res.status);
    try expect(std.mem.find(u8, res.body, "\"resultType\":\"complete\"") != null);
    // Base64 sentinel form of "echo".
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .headers = modernHeaders("tools/call", "=?base64?ZWNobw==?="), .body = call });
    try expectEqual(200, res.status);

    // Headers that disagree with the body, or are missing, are refused.
    for ([_][]const zx.testing.Header{
        modernHeaders("tools/call", "fail"),
        modernHeaders("tools/call", null),
        modernHeaders("tools/list", "echo"),
        &.{ .{ .name = "authorization", .value = "Bearer secret" }, .{ .name = "mcp-method", .value = "tools/call" }, .{ .name = "mcp-name", .value = "echo" } },
    }) |headers| {
        res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .headers = headers, .body = call });
        try expectEqual(400, res.status);
        try expect(std.mem.find(u8, res.body, "-32020") != null);
    }

    res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .headers = modernHeaders("nope/nope", null), .body = try modernBody(arena, "nope/nope", "") });
    try expectEqual(404, res.status);
    try expect(std.mem.find(u8, res.body, "-32601") != null);

    res = try harness.fetch(arena, .{
        .method = .POST,
        .path = "/mcp",
        .headers = &.{ .{ .name = "authorization", .value = "Bearer secret" }, .{ .name = "mcp-protocol-version", .value = "1900-01-01" }, .{ .name = "mcp-method", .value = "tools/list" } },
        .body =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}
        ,
    });
    try expectEqual(400, res.status);
    try expect(std.mem.find(u8, res.body, "-32022") != null);
}

test "http > auth and method errors" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [128]u8 = undefined;
    var client: mcp.Client = .{ .io = io, .allocator = gpa, .url = try url(&buf, &harness, "") };
    defer client.deinit();
    try expectError(error.Unauthorized, client.initialize(arena));

    var res = try harness.fetch(arena, .{ .method = .POST, .path = "/mcp", .body = "{}" });
    try expectEqual(401, res.status);
    try expect(std.mem.find(u8, res.header("www-authenticate").?, "resource_metadata=") != null);

    res = try harness.fetch(arena, .{ .path = "/mcp", .headers = &.{.{ .name = "authorization", .value = "Bearer secret" }} });
    try expectEqual(405, res.status);
    try expectEqualStrings("POST", res.header("allow").?);

    res = try harness.fetch(arena, .{
        .method = .POST,
        .path = "/mcp",
        .headers = &.{.{ .name = "authorization", .value = "Bearer secret" }},
        .body =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        ,
    });
    try expectEqual(202, res.status);
}

fn queryParam(url_: []const u8, name: []const u8) ?[]const u8 {
    const q = url_[(std.mem.findScalar(u8, url_, '?') orelse return null) + 1 ..];
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

const form: []const zx.testing.Header = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};

test "http > endpoint runs the OAuth flow and guards the tools" {
    var harness = try Harness.start(.std, io, gpa, .{ .thread_pool = .{ .count = 2 } });
    defer harness.stop();
    @import("app").mcp_oauth.port = harness.tcp.?.port;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try arena.print("http://127.0.0.1:{d}/secure/mcp", .{harness.tcp.?.port});

    // Signed out: the challenge points at metadata under the same route.
    var res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp", .body = "{}" });
    try expectEqual(401, res.status);
    try expect(std.mem.find(u8, res.header("www-authenticate").?, "/secure/mcp/.well-known/oauth-protected-resource") != null);

    res = try harness.fetch(arena, .{ .path = "/secure/mcp/.well-known/oauth-protected-resource" });
    try expectEqual(200, res.status);
    const prm = try std.json.parseFromSliceLeaky(struct { resource: []const u8, authorization_servers: []const []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true });
    try expectEqualStrings(base, prm.resource);
    try expectEqualStrings(base, prm.authorization_servers[0]);

    res = try harness.fetch(arena, .{ .path = "/secure/mcp/.well-known/openid-configuration" });
    const meta = try std.json.parseFromSliceLeaky(struct { issuer: []const u8, token_endpoint: []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true });
    try expectEqualStrings(base, meta.issuer);
    try expectEqualStrings(try arena.print("{s}/oauth/token", .{base}), meta.token_endpoint);

    // RFC 8414 / 9728 also put them at the root with the path appended.
    res = try harness.fetch(arena, .{ .path = "/.well-known/oauth-authorization-server/secure/mcp" });
    try expectEqual(200, res.status);
    try expectEqualStrings(base, (try std.json.parseFromSliceLeaky(struct { issuer: []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true })).issuer);
    res = try harness.fetch(arena, .{ .path = "/.well-known/oauth-protected-resource/secure/mcp" });
    try expectEqual(200, res.status);
    res = try harness.fetch(arena, .{ .path = "/.well-known/openid-configuration/secure/mcp" });
    try expectEqual(200, res.status);
    for ([_][]const u8{ "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/other", "/.well-known/oauth-authorization-server/secure/mcpx" }) |path| {
        res = try harness.fetch(arena, .{ .path = path });
        try expectEqual(404, res.status);
    }

    res = try harness.fetch(arena, .{ .path = "/secure/mcp/oauth/token" });
    try expectEqual(405, res.status);
    res = try harness.fetch(arena, .{ .path = "/secure/mcp/nope" });
    try expectEqual(404, res.status);

    // Registration takes https or loopback http only.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/register", .body = "{\"redirect_uris\":[\"http://localhost.evil.com/cb\"]}" });
    try expectEqual(400, res.status);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/register", .body = "{\"client_name\":\"t\",\"redirect_uris\":[\"http://127.0.0.1:9/cb\"]}" });
    try expectEqual(201, res.status);
    const client_id = (try std.json.parseFromSliceLeaky(struct { client_id: []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true })).client_id;

    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
    const authorize = try arena.print("/secure/mcp/oauth/authorize?response_type=code&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb&code_challenge={s}&code_challenge_method=S256&state=xyz", .{ client_id, challenge });

    res = try harness.fetch(arena, .{ .path = try arena.print("/secure/mcp/oauth/authorize?response_type=code&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fother&code_challenge={s}&code_challenge_method=S256", .{ client_id, challenge }) });
    try expectEqual(400, res.status);
    res = try harness.fetch(arena, .{ .path = try arena.print("/secure/mcp/oauth/authorize?response_type=code&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb", .{client_id}) });
    try expectEqual(400, res.status);

    // Authorize → consent page → back to the client with a code.
    res = try harness.fetch(arena, .{ .path = authorize });
    try expectEqual(302, res.status);
    const consent = res.header("location").?;
    try expect(std.mem.startsWith(u8, consent, "/secure/consent?response_type=code&client_id="));

    res = try harness.fetch(arena, .{ .path = try arena.print("{s}&deny=1", .{consent}) });
    try expectEqualStrings("http://127.0.0.1:9/cb?error=access_denied&state=xyz", res.header("location").?);

    res = try harness.fetch(arena, .{ .path = consent });
    try expectEqual(302, res.status);
    const callback = res.header("location").?;
    try expect(std.mem.startsWith(u8, callback, "http://127.0.0.1:9/cb?code="));
    try expectEqualStrings("xyz", queryParam(callback, "state").?);
    const code = queryParam(callback, "code").?;

    // A wrong verifier burns the code.
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/token", .headers = form, .body = try arena.print("grant_type=authorization_code&code={s}&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb&code_verifier=wrong", .{ code, client_id }) });
    try expectEqual(400, res.status);
    try expect(std.mem.find(u8, res.body, "invalid_grant") != null);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/token", .headers = form, .body = try arena.print("grant_type=authorization_code&code={s}&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb&code_verifier={s}", .{ code, client_id, verifier }) });
    try expectEqual(400, res.status);

    // A fresh code exchanges once.
    res = try harness.fetch(arena, .{ .path = consent });
    const code2 = queryParam(res.header("location").?, "code").?;
    const exchange = try arena.print("grant_type=authorization_code&code={s}&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcb&code_verifier={s}", .{ code2, client_id, verifier });
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/token", .headers = form, .body = exchange });
    try expectEqual(200, res.status);
    const access = try std.json.parseFromSliceLeaky(struct { access_token: []const u8, token_type: []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true });
    try expectEqualStrings("Bearer", access.token_type);
    res = try harness.fetch(arena, .{ .method = .POST, .path = "/secure/mcp/oauth/token", .headers = form, .body = exchange });
    try expectEqual(400, res.status);

    // The token opens the tools.
    var client: mcp.Client = .{
        .io = io,
        .allocator = gpa,
        .url = base,
        .headers = &.{.{ .name = "authorization", .value = try arena.print("Bearer {s}", .{access.access_token}) }},
    };
    defer client.deinit();
    try expectEqualStrings("secure", (try client.initialize(arena)).serverInfo.name);
    try expectEqualStrings("hello", try (try client.callTool(arena, "hello", null)).text(arena));

    var stranger: mcp.Client = .{ .io = io, .allocator = gpa, .url = base, .headers = &.{.{ .name = "authorization", .value = "Bearer nope" }} };
    defer stranger.deinit();
    try expectError(error.Unauthorized, stranger.initialize(arena));
}
