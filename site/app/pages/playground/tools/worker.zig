//! The playground's editor services, in their own Web Worker so they answer while a
//! build runs in `../worker.zig`: the zx language server (tree-sitter highlighting,
//! ZLS completion, hover, diagnostics) and formatting.
const std = @import("std");
const zx = @import("zx");
const wasi = @import("../wasi.zig");
const assets = @import("../assets.zig");

const Node = wasi.Node;
const gpa = zx.allocator;

/// The page gets replies through callbacks, so a build never holds up other calls.
pub const options: zx.Worker.Options = .{ .calls = .post };

pub const Formatted = struct { ok: bool, text: []const u8 };

/// Formats a `.zx` file with `zx fmt`, or `.zig`/`.zon` with the Zig formatter.
pub fn format(a: std.mem.Allocator, name: []const u8, content: []const u8) !Formatted {
    if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
        const src = try a.dupeSentinel(u8, content, 0);
        const tree = try std.zig.Ast.parse(a, src, .{ .mode = if (std.mem.endsWith(u8, name, ".zon")) .zon else .zig });
        if (tree.errors.len > 0) {
            var w: std.Io.Writer.Allocating = .init(a);
            for (tree.errors) |e| {
                const loc = tree.tokenLocation(0, e.token);
                try w.writer.print("{s}:{d}:{d}: error: ", .{ name, loc.line + 1, loc.column + 1 });
                try tree.renderError(e, &w.writer);
                try w.writer.writeByte('\n');
            }
            return .{ .ok = false, .text = w.written() };
        }
        return .{ .ok = true, .text = try tree.renderAlloc(a) };
    }
    if (!std.mem.endsWith(u8, name, ".zx")) return .{ .ok = false, .text = try std.fmt.allocPrint(a, "No formatter for {s}", .{name}) };

    try assets.loadTools();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cwd = try Node.newDir(arena.allocator());
    try cwd.writePath(name, content);
    var p = try wasi.Process.init(&.{ "zx", "fmt", "--stdout", name }, &.{.{ .name = ".", .dir = cwd }});
    defer p.deinit();
    _ = try wasi.run(&p, assets.zx_module, .{});
    if (p.exit_code != 0) return .{ .ok = false, .text = try a.dupe(u8, orDefault(p.stderr(), "zx fmt failed")) };
    return .{ .ok = true, .text = try a.dupe(u8, p.stdout()) };
}

/// Sends one JSON-RPC message to the zx language server (tree-sitter + ZLS, inside
/// `zx.wasm`) and returns what it answers: responses, diagnostics, logs.
pub fn lsp(a: std.mem.Allocator, message: []const u8) ![]const []const u8 {
    const s = try languageServer();
    s.enter();
    defer s.leave();
    defer {
        // stdio is unused by the server; don't let stray output pile up.
        s.process.out[0].clearRetainingCapacity();
        s.process.out[1].clearRetainingCapacity();
    }
    var out: std.ArrayList([]const u8) = .empty;
    try lspSend(a, s, message, &out);
    return out.items;
}

/// ZLS settings for the playground: `zx` resolves to the bundled sources (under /zx).
const zls_config =
    \\{"prefer_ast_check_as_child_process":false,"import_extensions":["zx"],"modules":[{"name":"zx","path":"/zx/src/root.zig"}]}
;

/// Delivers `message`; the server's own `workspace/configuration` requests are
/// answered here, everything else goes to `out`.
fn lspSend(a: std.mem.Allocator, s: *wasi.Session, message: []const u8, out: *std.ArrayList([]const u8)) !void {
    const ptr = try s.exports.call(u32, "allocMessage", .{message.len});
    s.write(ptr, message);
    s.exports.call(void, "call", .{}) catch {
        // A trap leaves the server in an unknown state; start a fresh one next time.
        lsp_ready = false;
        return error.LanguageServerCrashed;
    };
    const count = try s.exports.call(u32, "outputMessageCount", .{});
    const replies = try a.alloc([]const u8, count);
    for (replies, 0..) |*m, i| {
        const at = try s.exports.call(u32, "outputMessagePtr", .{i});
        const len = try s.exports.call(u32, "outputMessageLen", .{i});
        m.* = try wasi.readGuest(a, at, len);
    }
    for (replies) |reply| {
        if (try configurationReply(a, reply)) |answer| {
            try lspSend(a, s, answer, out);
        } else try out.append(a, reply);
    }
}

fn configurationReply(a: std.mem.Allocator, reply: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, reply, "\"workspace/configuration\"") == null) return null;
    const Request = struct {
        id: std.json.Value,
        method: []const u8,
        params: struct { items: []const std.json.Value = &.{} } = .{},
    };
    const req = std.json.parseFromSliceLeaky(Request, a, reply, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, req.method, "workspace/configuration")) return null;
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(req.id, .{}, &w.writer);
    try w.writer.writeAll(",\"result\":[");
    for (req.params.items, 0..) |_, i| {
        if (i > 0) try w.writer.writeByte(',');
        try w.writer.writeAll(zls_config);
    }
    try w.writer.writeAll("]}");
    return w.written();
}

var lsp_session: wasi.Session = undefined;
var lsp_ready = false;

fn languageServer() !*wasi.Session {
    if (lsp_ready) return &lsp_session;
    try assets.loadTools();
    // `@import("zx")` resolves through ZIEX_MODULE_PATH; the std lib comes from /lib.
    const root = try Node.newDir(gpa);
    try root.put("zx", assets.zx_dir);
    try lsp_session.start(&.{"zx.wasm"}, &.{"ZIEX_MODULE_PATH=/zx/src/root.zig"}, &.{
        .{ .name = ".", .dir = root },
        .{ .name = "/zx", .dir = assets.zx_dir },
        .{ .name = "/lib", .dir = assets.lib_dir },
        .{ .name = "/cache", .dir = try Node.newDir(gpa) },
    }, assets.zx_module);
    lsp_session.enter();
    defer lsp_session.leave();
    try lsp_session.exports.call(void, "createServer", .{});
    lsp_ready = true;
    return &lsp_session;
}

pub const Source = struct { name: []const u8, content: []const u8 };

/// A zx or Zig std source the language server links to (`zx/src/...`, `lib/std/...`,
/// `std/...`), for viewing. Paths are as the server sees them, without the leading `/`.
pub fn readFile(a: std.mem.Allocator, path: []const u8) !Source {
    try assets.loadTools();
    const content = if (std.mem.startsWith(u8, path, "zx/"))
        assets.zx_dir.readPath(path["zx/".len..])
    else if (std.mem.startsWith(u8, path, "lib/"))
        assets.lib_dir.readPath(path["lib/".len..])
    else if (std.mem.startsWith(u8, path, "std/"))
        assets.lib_dir.readPath(path)
    else
        null;
    return .{ .name = try a.dupe(u8, path), .content = try a.dupe(u8, content orelse return error.FileNotFound) };
}

/// Loads the language server's files ahead of the first request.
pub fn warm() void {
    assets.loadTools() catch {};
}

fn orDefault(s: []const u8, default: []const u8) []const u8 {
    return if (std.mem.trim(u8, s, &std.ascii.whitespace).len == 0) default else s;
}
