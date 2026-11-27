//! Playground share links for home page code examples, computed while
//! rendering; the playground uses `encodePairs`/`decode` for its own links.
//! A link is `/playground#data=<base64url(zlib(json files map))>`.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Entry = struct { code: []const u8, filename: []const u8 };

pub const Files = std.array_hash_map.String([]const u8);

const zx_import = "const zx = @import(\"zx\");";
const std_import = "const std = @import(\"std\");";

const minimal_layout =
    \\pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component {
    \\    return (
    \\        <html @allocator={ctx.arena} lang="en-US">
    \\            <head>
    \\                <meta charset="UTF-8" />
    \\                <title>Playground</title>
    \\            </head>
    \\            <body>
    \\                {children}
    \\            </body>
    \\        </html>
    \\    );
    \\}
    \\
    \\const zx = @import("zx");
    \\
;

/// The share link for `entries`, or null when none can open in the playground.
pub fn url(gpa: Allocator, entries: []const Entry) !?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var open: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (isPlaygroundOpenable(e.filename, e.code)) try open.append(a, e);
    }
    if (open.items.len == 0) return null;

    const files = try filesFromEntries(a, open.items);
    return try gpa.print("/playground#data={s}", .{try encode(a, files)});
}

// --- Encoding ---

fn encode(a: Allocator, files: Files) ![]const u8 {
    return encodePairs(a, files.keys(), files.values());
}

/// The `#data=` payload for a files map (also used by the playground's Share button).
pub fn encodePairs(a: Allocator, names: []const []const u8, contents: []const []const u8) ![]const u8 {
    var json: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &json.writer };
    try jw.beginObject();
    for (names, contents) |k, v| {
        try jw.objectField(k);
        try jw.write(v);
    }
    try jw.endObject();

    // CompressionStream("deflate") is zlib-wrapped deflate.
    var z: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var c = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .default);
    try c.writer.writeAll(json.written());
    try c.finish();

    const b64 = std.base64.url_safe_no_pad.Encoder;
    const out = try a.alloc(u8, b64.calcSize(z.written().len));
    return b64.encode(out, z.written());
}

/// Inverse of `encodePairs`: the files map in a `#data=` payload, in order.
pub fn decode(a: Allocator, data: []const u8) !Files {
    const trimmed = std.mem.trimEnd(u8, data, "=");
    const b64 = std.base64.url_safe_no_pad.Decoder;
    const z = try a.alloc(u8, try b64.calcSizeForSlice(trimmed));
    try b64.decode(z, trimmed);

    var in: std.Io.Reader = .fixed(z);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    const json = try d.reader.allocRemaining(a, .limited(16 << 20));

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (parsed != .object) return error.InvalidData;
    var files: Files = .empty;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try files.put(a, e.key_ptr.*, e.value_ptr.string);
    }
    return files;
}

// --- Text matching (stand-ins for the original regexes) ---

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `\b<needle>\b` (boundaries only where `needle` starts/ends with a word char).
fn hasWord(hay: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, hay, i, needle)) |at| : (i = at + 1) {
        const before_ok = !isWord(needle[0]) or at == 0 or !isWord(hay[at - 1]);
        const end = at + needle.len;
        const after_ok = !isWord(needle[needle.len - 1]) or end == hay.len or !isWord(hay[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
    return j;
}

/// Each `\bpub\s+fn\s+NAME\s*(` in `code`, calling `f(name, index_after_paren)`.
fn pubFns(code: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, usize) bool) void {
    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, "pub")) |at| : (i = at + 3) {
        if (at > 0 and isWord(code[at - 1])) continue;
        var j = at + 3;
        if (j >= code.len or !std.ascii.isWhitespace(code[j])) continue;
        j = skipWs(code, j);
        if (!std.mem.startsWith(u8, code[j..], "fn")) continue;
        j += 2;
        if (j >= code.len or !std.ascii.isWhitespace(code[j])) continue;
        j = skipWs(code, j);
        const start = j;
        while (j < code.len and isWord(code[j])) j += 1;
        if (j == start) continue;
        const name = code[start..j];
        j = skipWs(code, j);
        if (j >= code.len or code[j] != '(') continue;
        if (f(ctx, name, j + 1)) return;
    }
}

fn hasPubFn(code: []const u8, name: []const u8) bool {
    var found = false;
    const Ctx = struct { name: []const u8, found: *bool };
    pubFns(code, Ctx{ .name = name, .found = &found }, struct {
        fn f(c: Ctx, n: []const u8, _: usize) bool {
            if (std.mem.eql(u8, n, c.name)) c.found.* = true;
            return c.found.*;
        }
    }.f);
    return found;
}

fn hasPageExport(code: []const u8) bool {
    return hasPubFn(code, "Page");
}

fn hasLayoutExport(code: []const u8) bool {
    return hasPubFn(code, "Layout");
}

fn basename(path: []const u8) []const u8 {
    const i = std.mem.findLastAny(u8, path, "/\\") orelse return path;
    return if (i + 1 < path.len) path[i + 1 ..] else path;
}

fn dirname(path: []const u8) []const u8 {
    const i = std.mem.findScalarLast(u8, path, '/') orelse return "";
    return path[0..i];
}

fn lowerEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn lowerEndsWith(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn looksLikeRoute(code: []const u8, filename: []const u8) bool {
    if (lowerEql(basename(filename), "route.zig")) return true;
    if (hasWord(code, "zx.RouteContext")) return true;
    if (hasWord(code, "zx.SocketContext") or hasWord(code, "zx.SocketOpenContext")) return true;
    const handler = for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "Socket", "SocketOpen" }) |m| {
        if (hasPubFn(code, m)) break true;
    } else false;
    const ctx_type = std.mem.find(u8, code, "RouteContext") != null or std.mem.find(u8, code, "SocketContext") != null;
    return handler and ctx_type;
}

fn needsAppMode(code: []const u8, filename: []const u8) bool {
    const name = basename(filename);
    if (looksLikeRoute(code, filename)) return true;
    if (lowerEql(name, "layout.zx") or lowerEql(name, "page.zx")) return true;
    if (hasPageExport(code) or hasLayoutExport(code)) return true;
    if (hasWord(code, "@client")) return true;
    if (hasWord(code, "zx.client.")) return true;
    if (hasWord(code, "zx.server.Action")) return true;
    if (hasWord(code, "zx.PageContext") or hasWord(code, "zx.LayoutContext")) return true;
    if (std.mem.findScalar(u8, filename, '[')) |open| {
        if (std.mem.findScalarPos(u8, filename, open + 2, ']') != null) return true;
    }
    return false;
}

pub fn isPlaygroundOpenable(filename: []const u8, code: []const u8) bool {
    const trimmed = std.mem.trim(u8, code, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    const name = basename(filename);
    if (lowerEql(name, "build.zig")) return false;
    for ([_][]const u8{ ".json", ".sh", ".md", ".css", ".html" }) |ext| {
        if (lowerEndsWith(name, ext)) return false;
    }
    if (lowerEndsWith(name, ".zx") or lowerEndsWith(name, ".zig")) return true;
    if (needsAppMode(trimmed, filename)) return true;
    // `<[A-Za-z/!]`
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, trimmed, i, '<')) |at| : (i = at + 1) {
        if (at + 1 < trimmed.len and (std.ascii.isAlphabetic(trimmed[at + 1]) or trimmed[at + 1] == '/' or trimmed[at + 1] == '!')) return true;
    }
    return false;
}

// --- Snippet processing ---

fn hasImportLine(code: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, " \t\r");
        // ^const\s+NAME\s*=\s*@import("NAME");$
        if (!std.mem.startsWith(u8, l, "const")) continue;
        var j: usize = 5;
        if (j >= l.len or !std.ascii.isWhitespace(l[j])) continue;
        j = skipWs(l, j);
        if (!std.mem.startsWith(u8, l[j..], name)) continue;
        j = skipWs(l, j + name.len);
        if (j >= l.len or l[j] != '=') continue;
        j = skipWs(l, j + 1);
        var want: [32]u8 = undefined;
        const tail = std.mem.print(&want, "@import(\"{s}\");", .{name}) catch continue;
        if (std.mem.eql(u8, l[j..], tail)) return true;
    }
    return false;
}

fn usesStd(code: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, "std.")) |at| : (i = at + 1) {
        if (at + 4 < code.len and isWord(code[at + 4])) return true;
    }
    return false;
}

fn appendImport(a: Allocator, code: []const u8, line: []const u8) ![]const u8 {
    const normalized = std.mem.trimEnd(u8, code, &std.ascii.whitespace);
    return a.print("{s}\n\n{s}", .{ normalized, line });
}

fn processSnippetCode(a: Allocator, code: []const u8) ![]const u8 {
    var out = code;
    if (usesStd(out) and !hasImportLine(out, "std")) out = try appendImport(a, out, std_import);
    if (!hasImportLine(out, "zx")) out = try appendImport(a, out, zx_import);
    return out;
}

fn findPrimaryComponentName(code: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    pubFns(code, &found, struct {
        fn f(out: *?[]const u8, name: []const u8, _: usize) bool {
            const skip = [_][]const u8{ "Page", "Layout", "GET", "POST", "PUT", "DELETE", "PATCH", "Socket", "SocketOpen", "main" };
            for (skip) |s| if (std.mem.eql(u8, name, s)) return false;
            out.* = name;
            return true;
        }
    }.f);
    return found;
}

fn componentTakesAllocator(code: []const u8, name: []const u8) bool {
    const Ctx = struct { code: []const u8, name: []const u8, yes: *bool };
    var yes = false;
    pubFns(code, Ctx{ .code = code, .name = name, .yes = &yes }, struct {
        fn f(c: Ctx, n: []const u8, after: usize) bool {
            if (!std.mem.eql(u8, n, c.name)) return false;
            var j = skipWs(c.code, after);
            if (!std.mem.startsWith(u8, c.code[j..], "allocator")) return false;
            j = skipWs(c.code, j + "allocator".len);
            c.yes.* = j < c.code.len and c.code[j] == ':';
            return true;
        }
    }.f);
    return yes;
}

fn wrapComponentAsPage(a: Allocator, code: []const u8) ![]const u8 {
    if (hasPageExport(code)) return code;
    const name = findPrimaryComponentName(code) orelse return code;
    const wants_client = hasWord(code, "@client") or hasWord(code, "zx.client.");
    return a.print(
        \\pub fn Page(ctx: zx.PageContext) !zx.Component {{
        \\    return (
        \\        <main @allocator={{ctx.arena}}>
        \\            <{s}{s}{s} />
        \\        </main>
        \\    );
        \\}}
        \\
        \\{s}
    , .{
        name,
        if (componentTakesAllocator(code, name)) " @allocator={ctx.arena}" else "",
        if (wants_client) " @client" else "",
        code,
    });
}

// --- App paths ---

fn stripAppPrefix(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "app/")) path[4..] else path;
}

fn normalizePath(a: Allocator, raw: []const u8) ![]const u8 {
    const p = try std.mem.replaceOwned(u8, a, raw, "\\", "/");
    return std.mem.trimStart(u8, p, "/");
}

fn firstRouteParam(code: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, "params.get(")) |at| : (i = at + 1) {
        var j = skipWs(code, at + "params.get(".len);
        if (j >= code.len or (code[j] != '"' and code[j] != '\'')) continue;
        j += 1;
        const start = j;
        while (j < code.len and isWord(code[j])) j += 1;
        if (j == start or j >= code.len or (code[j] != '"' and code[j] != '\'')) continue;
        const end = j;
        j = skipWs(code, j + 1);
        if (j < code.len and code[j] == ')') return code[start..end];
    }
    return null;
}

fn normalizeRouteAppPath(a: Allocator, raw: []const u8) ![]const u8 {
    var path = stripAppPrefix(try normalizePath(a, raw));
    // Playground serves API/WebSocket handlers from app/routes/...
    if (std.mem.startsWith(u8, path, "pages/")) {
        path = try a.print("routes/{s}", .{path["pages/".len..]});
    } else if (!std.mem.startsWith(u8, path, "routes/")) {
        path = if (std.mem.findScalar(u8, path, '/') == null or std.mem.eql(u8, path, "route.zig"))
            "routes/api/route.zig"
        else
            try a.print("routes/{s}", .{path});
    }
    if (!std.mem.endsWith(u8, path, "/route.zig") and !std.mem.eql(u8, path, "routes/route.zig")) {
        const dir = dirname(path);
        path = if (dir.len > 0) try a.print("{s}/route.zig", .{dir}) else "routes/api/route.zig";
    }
    return a.print("app/{s}", .{path});
}

fn normalizePageAppPath(a: Allocator, raw: []const u8, code: []const u8) ![]const u8 {
    var path = stripAppPrefix(try normalizePath(a, raw));
    if (std.mem.startsWith(u8, path, "pages/")) path = path["pages/".len..];
    if (std.mem.findScalar(u8, path, '/') == null) {
        if (firstRouteParam(code)) |param| return a.print("app/pages/[{s}]/page.zx", .{param});
        return "app/pages/page.zx";
    }
    // Any *.zx under a route folder becomes that folder's page.zx.
    if (lowerEndsWith(basename(path), ".zx")) return a.print("app/pages/{s}/page.zx", .{dirname(path)});
    return a.print("app/pages/{s}", .{path});
}

fn mapEntryToAppPath(a: Allocator, filename: []const u8, code: []const u8) ![]const u8 {
    const raw = try normalizePath(a, filename);
    if (lowerEql(basename(raw), "layout.zx") or hasLayoutExport(code)) {
        var path = stripAppPrefix(raw);
        if (std.mem.startsWith(u8, path, "pages/")) path = path["pages/".len..];
        if (std.mem.findScalar(u8, path, '/') == null) return "app/pages/layout.zx";
        return a.print("app/pages/{s}/layout.zx", .{dirname(path)});
    }
    if (looksLikeRoute(code, filename)) return normalizeRouteAppPath(a, raw);
    return normalizePageAppPath(a, raw, code);
}

// --- Minimal app shell ---

const Link = struct { href: []const u8, label: []const u8 };

fn urlFromAppPath(a: Allocator, path: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, path, "app/pages/layout.zx") or std.mem.eql(u8, path, "app/main.zig")) return null;
    if (std.mem.endsWith(u8, path, "/page.zx")) {
        // "app/pages/page.zx" is the root; "app/pages/x/page.zx" is /x.
        const rest = if (std.mem.startsWith(u8, path, "app/pages/")) path["app/pages/".len..] else path;
        const route = if (std.mem.endsWith(u8, rest, "/page.zx")) rest[0 .. rest.len - "/page.zx".len] else "";
        if (route.len == 0) return "/";
        return try a.print("/{s}", .{route});
    }
    if (std.mem.endsWith(u8, path, "route.zig")) {
        var route = path;
        for ([_][]const u8{ "app/routes/", "app/pages/" }) |p| {
            if (std.mem.startsWith(u8, route, p)) route = route[p.len..];
        }
        if (std.mem.endsWith(u8, route, "/route.zig")) route = route[0 .. route.len - "/route.zig".len] else if (std.mem.endsWith(u8, route, "route.zig")) route = route[0 .. route.len - "route.zig".len];
        if (route.len == 0) return "/api";
        return try a.print("/{s}", .{route});
    }
    return null;
}

fn exampleValueForParam(param: []const u8) []const u8 {
    if (lowerEndsWith(param, "id")) return "42";
    if (lowerEql(param, "slug") or lowerEql(param, "name")) return "hello";
    return "example";
}

fn concreteExampleHref(a: Allocator, pattern: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '[') if (std.mem.findScalarPos(u8, pattern, i + 1, ']')) |close| {
            if (close > i + 1) {
                try out.appendSlice(a, exampleValueForParam(pattern[i + 1 .. close]));
                i = close + 1;
                continue;
            }
        };
        try out.append(a, pattern[i]);
        i += 1;
    }
    return out.items;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn collectExampleLinks(a: Allocator, files: Files) ![]Link {
    const paths = try a.dupe([]const u8, files.keys());
    std.mem.sort([]const u8, paths, {}, lessStr);
    var links: std.ArrayList(Link) = .empty;
    outer: for (paths) |path| {
        const pattern = (try urlFromAppPath(a, path)) orelse continue;
        if (std.mem.eql(u8, pattern, "/")) continue;
        const href = try concreteExampleHref(a, pattern);
        for (links.items) |l| if (std.mem.eql(u8, l.href, href)) continue :outer;
        try links.append(a, .{ .href = href, .label = pattern });
    }
    return links.items;
}

const Unsupported = struct { caching: bool, websocket: bool, non_get: []const []const u8 };

fn containsAfter(hay: []const u8, word: []const u8, then: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, hay, i, word)) |at| : (i = at + 1) {
        const before_ok = at == 0 or !isWord(hay[at - 1]);
        const end = at + word.len;
        const after_ok = end == hay.len or !isWord(hay[end]);
        if (before_ok and after_ok and std.mem.findPos(u8, hay, end, then) != null) return true;
    }
    return false;
}

fn detectUnsupported(a: Allocator, files: Files) !Unsupported {
    var all: std.ArrayList(u8) = .empty;
    for (files.values(), 0..) |v, i| {
        if (i > 0) try all.append(a, '\n');
        try all.appendSlice(a, v);
    }
    const code = all.items;
    var non_get: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "POST", "PUT", "DELETE", "PATCH" }) |m| {
        if (hasPubFn(code, m)) try non_get.append(a, m);
    }
    var dot_caching = false;
    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, ".caching")) |at| : (i = at + 1) {
        const j = skipWs(code, at + ".caching".len);
        if (j < code.len and code[j] == '=') dot_caching = true;
    }
    return .{
        .caching = hasWord(code, "@caching") or dot_caching or hasWord(code, "zx.cache.") or
            containsAfter(code, "PageOptions", "caching") or containsAfter(code, "LayoutOptions", "caching"),
        .websocket = hasPubFn(code, "Socket") or hasPubFn(code, "SocketOpen") or
            hasWord(code, "zx.SocketContext") or hasWord(code, "zx.SocketOpenContext") or
            hasWord(code, ".socket.upgrade") or hasWord(code, "zx.websocket"),
        .non_get = non_get.items,
    };
}

fn escapeZigString(a: Allocator, s: []const u8) ![]const u8 {
    const step = try std.mem.replaceOwned(u8, a, s, "\\", "\\\\");
    return std.mem.replaceOwned(u8, a, step, "\"", "\\\"");
}

fn buildSampleHomePage(a: Allocator, files: Files) ![]const u8 {
    const links = try collectExampleLinks(a, files);
    const unsupported = try detectUnsupported(a, files);

    var w: std.Io.Writer.Allocating = .init(a);
    const out = &w.writer;
    try out.writeAll(
        \\pub fn Page(ctx: zx.PageContext) !zx.Component {
        \\    return (
        \\        <main @allocator={ctx.arena}>
        \\            <h1>Playground</h1>
        \\            <p>Minimal app shell for this snippet.</p>
        \\
    );
    if (links.len > 0) {
        try out.writeAll("\n            <div>\n                <h2>Try these paths</h2>\n                <ul>\n");
        for (links, 0..) |l, i| {
            if (i > 0) try out.writeAll("\n");
            const href = try escapeZigString(a, l.href);
            try out.print("                <li><a href=\"{s}\">{s}</a> → <code>{s}</code></li>", .{ href, try escapeZigString(a, l.label), href });
        }
        try out.writeAll("\n                </ul>\n            </div>\n");
    } else {
        try out.writeAll("\n            <p>Edit files under <code>app/</code> and run to preview.</p>\n");
    }

    var notices: std.ArrayList([]const u8) = .empty;
    if (unsupported.caching) try notices.append(a, "Caching is not supported in the playground.");
    if (unsupported.websocket) try notices.append(a, "WebSockets are not supported in the playground.");
    if (unsupported.non_get.len > 0) {
        const methods = try std.mem.join(a, "/", unsupported.non_get);
        try notices.append(a, try a.print("{s} route handlers are not supported in the playground (GET only).", .{methods}));
    }
    if (notices.items.len > 0) {
        try out.writeAll("\n            <div>\n                <h2>Not supported here</h2>\n                <ul>\n");
        for (notices.items, 0..) |n, i| {
            if (i > 0) try out.writeAll("\n");
            try out.print("                    <li>{s}</li>", .{try escapeZigString(a, n)});
        }
        try out.writeAll("\n                </ul>\n            </div>");
    }
    try out.writeAll("\n        </main>\n    );\n}\n\nconst zx = @import(\"zx\");\n");
    return w.written();
}

fn ensureMinimalAppShell(a: Allocator, files: *Files) !void {
    if (!files.contains("app/pages/layout.zx")) try files.put(a, "app/pages/layout.zx", minimal_layout);

    const unsupported = try detectUnsupported(a, files.*);
    const links = try collectExampleLinks(a, files.*);
    const has_unsupported = unsupported.caching or unsupported.websocket or unsupported.non_get.len > 0;
    const needs_home = !files.contains("app/pages/page.zx") or links.len > 0 or has_unsupported;

    // A snippet that owns `/` moves to /demo so the generated home can link to it.
    if (needs_home) if (files.get("app/pages/page.zx")) |home| {
        if (!files.contains("app/pages/demo/page.zx")) try files.put(a, "app/pages/demo/page.zx", home);
        _ = files.orderedRemove("app/pages/page.zx");
    };
    if (!files.contains("app/pages/page.zx")) try files.put(a, "app/pages/page.zx", try buildSampleHomePage(a, files.*));
}

fn filesFromEntries(a: Allocator, entries: []const Entry) !Files {
    var files: Files = .empty;
    var cleaned: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        const code = std.mem.trim(u8, e.code, &std.ascii.whitespace);
        if (code.len == 0) continue;
        const name = std.mem.trim(u8, e.filename, &std.ascii.whitespace);
        try cleaned.append(a, .{ .code = code, .filename = if (name.len > 0) name else "Playground.zx" });
    }
    if (cleaned.items.len == 0) {
        try files.put(a, "Playground.zx", "");
        return files;
    }

    const use_app = for (cleaned.items) |e| {
        if (needsAppMode(e.code, e.filename)) break true;
    } else false;
    if (!use_app) {
        try files.put(a, "Playground.zx", try processSnippetCode(a, cleaned.items[0].code));
        return files;
    }

    for (cleaned.items) |e| {
        var code = try processSnippetCode(a, e.code);
        const path = try mapEntryToAppPath(a, e.filename, code);
        if (std.mem.endsWith(u8, path, "/page.zx") and !hasPageExport(code) and !looksLikeRoute(code, e.filename)) {
            code = try processSnippetCode(a, try wrapComponentAsPage(a, code));
        }
        // Keep the first entry that maps to a path.
        if (!files.contains(path)) try files.put(a, path, code);
    }
    try ensureMinimalAppShell(a, &files);
    return files;
}

// --- Filenames for home page examples ---

pub fn filenameFromSection(a: Allocator, section: []const u8, label: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(a, section);
    const fallback = try a.print("{s}.zx", .{try std.mem.replaceOwned(u8, a, try std.ascii.allocLowerString(a, label), " ", "-")});
    if (section.len == 0) return fallback;
    if (std.mem.find(u8, lower, "layout") != null) return "layout.zx";
    if (std.mem.find(u8, lower, "websocket") != null) return "routes/ws/route.zig";
    if (std.mem.find(u8, lower, "api route") != null or isRouteWord(lower)) return "route.zig";
    if (std.mem.find(u8, lower, "dynamic path") != null) return "pages/[id]/page.zx";
    if (std.mem.endsWith(u8, lower, ": page") or std.mem.find(u8, lower, "routing: page") != null) return "page.zx";
    if (std.mem.find(u8, lower, "client-side") != null) return "page.zx";
    return fallback;
}

// `(^|:\s*)route\b`
fn isRouteWord(lower: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, lower, i, "route")) |at| : (i = at + 1) {
        const end = at + 5;
        if (end < lower.len and isWord(lower[end])) continue;
        var j = at;
        while (j > 0 and std.ascii.isWhitespace(lower[j - 1])) j -= 1;
        if (at == 0 or (j > 0 and lower[j - 1] == ':')) return true;
    }
    return false;
}

test "urlFromAppPath maps page paths to routes" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("/", (try urlFromAppPath(a, "app/pages/page.zx")).?);
    const about = (try urlFromAppPath(a, "app/pages/about/page.zx")).?;
    defer a.free(about);
    try std.testing.expectEqualStrings("/about", about);
    try std.testing.expect((try urlFromAppPath(a, "app/pages/layout.zx")) == null);
}

test "share url round trips through zlib + base64url" {
    const gpa = std.testing.allocator;
    const link = (try url(gpa, &.{.{ .code = "pub fn Hello(allocator: zx.Allocator) zx.Component { return (<p @allocator={allocator}>Hi</p>); }", .filename = "hello.zx" }})).?;
    defer gpa.free(link);
    try std.testing.expect(std.mem.startsWith(u8, link, "/playground#data="));
}

test "share payload decodes back to the same files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try encodePairs(a, &.{ "Playground.zx", "style.css" }, &.{ "<p>hi</p>", "body{}" });
    const files = try decode(a, data);
    try std.testing.expectEqual(@as(usize, 2), files.count());
    try std.testing.expectEqualStrings("body{}", files.get("style.css").?);
}
