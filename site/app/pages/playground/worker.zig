//! The playground's build engine, in its own Web Worker (`zx.worker`): transpiles with
//! `zx.wasm`, compiles with `zig.wasm`, runs the result, and hands the page back a
//! document for the preview iframe. Both compilers run under the WASI host in
//! `wasi.zig` against an in-memory filesystem. Editor services live in `tools/`.
const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;
const wasi = @import("wasi.zig");
const tpl = @import("templates.zig");
const share = @import("../home/share.zig");
const assets = @import("assets.zig");

const Node = wasi.Node;
const gpa = zx.allocator;

/// The page gets replies through callbacks, so a build never holds up other calls.
pub const options: zx.Worker.Options = .{ .calls = .post };

pub const File = tpl.File;
pub const Mode = tpl.Mode;
pub const Template = tpl.Template;

pub const Preview = struct {
    ok: bool,
    /// Build steps, compiler errors and program logs.
    log: []const u8,
    kind: Kind = .none,
    status: u16 = 0,
    content_type: []const u8 = "",
    /// An HTML document for the iframe (`kind == .html`) or a response body.
    body: []const u8 = "",

    pub const Kind = enum(u8) { none, html, text };
};

// --- Worker API ---

pub fn templates(a: std.mem.Allocator) ![]const Template {
    return tpl.all(a);
}

/// Files in a `#data=` share payload.
pub fn openShare(a: std.mem.Allocator, data: []const u8) ![]const File {
    const files = try share.decode(a, data);
    const out = try a.alloc(File, files.count());
    for (out, files.keys(), files.values()) |*f, k, v| f.* = .{ .name = k, .content = v };
    return out;
}

/// The `#data=` payload for `files`.
pub fn shareData(a: std.mem.Allocator, files: []const File) ![]const u8 {
    const names = try a.alloc([]const u8, files.len);
    const contents = try a.alloc([]const u8, files.len);
    for (files, names, contents) |f, *n, *c| {
        n.* = f.name;
        c.* = f.content;
    }
    return share.encodePairs(a, names, contents);
}

/// Builds `files` (reusing the last build when nothing changed) and renders `path`.
pub fn run(a: std.mem.Allocator, mode: Mode, files: []const File, path: []const u8) !Preview {
    var log: std.Io.Writer.Allocating = .init(a);
    const w = &log.writer;
    for (files) |f| if (std.mem.endsWith(u8, f.name, ".zx") and std.mem.trim(u8, f.content, &std.ascii.whitespace).len == 0) {
        try w.print("{s} is empty. Add code or remove the file.\n", .{f.name});
        return .{ .ok = false, .log = log.written() };
    };

    assets.loadAll() catch |err| {
        try w.print("Couldn't load the compiler ({t})\n", .{err});
        return .{ .ok = false, .log = log.written() };
    };

    const key = hashFiles(mode, files);
    if (last_build == null or last_build.?.key != key) {
        if (last_build) |*b| b.deinit();
        last_build = null;
        last_build = build(w, mode, files) catch |err| switch (err) {
            error.BuildFailed => return .{ .ok = false, .log = log.written() },
            else => {
                try w.print("\nBuild stopped ({t})\n", .{err});
                return .{ .ok = false, .log = log.written() };
            },
        };
        last_build.?.key = key;
    } else try w.writeAll("Build is up to date.\n");

    var preview = switch (last_build.?.output) {
        .program => |module| try renderProgram(a, w, module),
        .app => |*app| try renderApp(a, w, app, path),
    };
    preview.log = log.written();
    return preview;
}

/// Downloads the compilers now, so the first Run doesn't wait for them.
pub fn warm() void {
    assets.loadAll() catch {};
}

var cache_dir: ?*Node = null;

/// Drops the compiler's cache and the last build.
pub fn clearCache() void {
    if (last_build) |*b| b.deinit();
    last_build = null;
    cache_dir = Node.newDir(gpa) catch null;
}

// --- Build ---

const Build = struct {
    key: u64 = 0,
    output: union(enum) {
        program: js.Value,
        app: App,
    },

    const App = struct {
        ssr: js.Value,
        client_url: []u8,
        glue: []u8,
    };

    fn deinit(b: *Build) void {
        switch (b.output) {
            .program => |m| m.deinit(),
            .app => |app| {
                app.ssr.deinit();
                revokeUrl(app.client_url);
                gpa.free(app.client_url);
                gpa.free(app.glue);
            },
        }
    }
};

var last_build: ?Build = null;

fn hashFiles(mode: Mode, files: []const File) u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(mode));
    for (files) |f| {
        h.update(f.name);
        h.update(&.{0});
        h.update(f.content);
        h.update(&.{0});
    }
    return h.final();
}

fn build(w: *std.Io.Writer, mode: Mode, files: []const File) !Build {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The project as zig sees it: user files, the shared main, transpiled `.zig`.
    const project = try Node.newDir(arena);
    for (files) |f| try project.writePath(f.name, f.content);
    const main = tpl.sharedMain(mode);
    if (project.readPath(main.name) == null) try project.writePath(main.name, main.content);

    var timer: Timer = .start();
    try w.writeAll("Transpiling… ");
    switch (mode) {
        .playground => for (files) |f| {
            if (!std.mem.endsWith(u8, f.name, ".zx")) continue;
            const cwd = try Node.newDir(arena);
            try cwd.writePath(f.name, f.content);
            const out = try runZx(arena, cwd, &.{ "zx", "transpile", "--map", "inline", f.name }, w) orelse return error.BuildFailed;
            const zig_name = try arena.print("{s}.zig", .{f.name[0 .. f.name.len - ".zx".len]});
            try project.writePath(zig_name, out);
        },
        .app => {
            for (tpl.stubs) |s| try project.writePath(s.name, s.content);
            const app_dir = project.get("app") orelse {
                try w.writeAll("failed\nApp mode needs files under app/\n");
                return error.BuildFailed;
            };
            const cwd = try Node.newDir(arena);
            try cwd.put("app", app_dir);
            try cwd.put("stubs", project.get("stubs").?);
            const out = try Node.newDir(arena);
            try cwd.put("out", out);
            _ = try runZx(arena, cwd, &.{
                "zx",                 "transpile",                  "app",        "--outdir",    "out", "--map", "inline",
                "--build-injections", "stubs/build_injections.zon", "--manifest", "out/app.zon",
            }, w) orelse return error.BuildFailed;
            // Transpiled sources land next to the app's own; the manifest stands in for the build's.
            try mergeGenerated(out, app_dir);
            if (out.readPath("app.zon")) |manifest| try project.writePath("stubs/manifest.zon", manifest);
            if (project.readPath("app/app.zig") == null) {
                try w.writeAll("failed\nTranspile did not produce app/app.zig\n");
                return error.BuildFailed;
            }
        },
    }
    try w.print("done ({f})\n", .{timer.lap()});

    try project.put("zx", assets.zx_dir);
    try project.put("libcompiler_rt.a", assets.compiler_rt);

    switch (mode) {
        .playground => {
            try w.writeAll("Building… ");
            const wasm = try runZig(arena, project, &.{
                "zig",              "build-exe",        "--dep",      "zx", "-Mroot=main.zig", "-Mzx=zx/src/root.zig",
                "--name",           "main",             "libcompiler_rt.a", "-fno-compiler-rt", "-fno-entry",
            }, "main.wasm", w) orelse return error.BuildFailed;
            try w.print("done ({f})\n", .{timer.lap()});
            return .{ .output = .{ .program = try wasi.compile(wasm) } };
        },
        .app => {
            try w.writeAll("Building server… ");
            const ssr = try runZig(arena, project, appArgs(.ssr), "ziex_ssr.wasm", w) orelse return error.BuildFailed;
            try w.print("done ({f})\nBuilding client… ", .{timer.lap()});
            const client = try runZig(arena, project, appArgs(.client), "ziex_client.wasm", w) orelse return error.BuildFailed;
            try w.print("done ({f})\n", .{timer.lap()});
            const glue = try zx.Build.webglue.generate(gpa, client);
            errdefer gpa.free(glue);
            const ssr_module = try wasi.compile(ssr);
            errdefer ssr_module.deinit();
            return .{ .output = .{ .app = .{ .ssr = ssr_module, .client_url = try blobUrl(client), .glue = glue } } };
        },
    }
}

/// Copies `out/**.{zig,zon}` from `zx transpile` into the app dir.
fn mergeGenerated(src: *Node, dst: *Node) !void {
    for (src.children.keys(), src.children.values()) |name, node| switch (node.kind) {
        .dir => {
            const sub = dst.get(name) orelse blk: {
                const d = try Node.newDir(dst.alloc);
                try dst.put(name, d);
                break :blk d;
            };
            try mergeGenerated(node, sub);
        },
        .file => if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) try dst.put(name, node),
    };
}

const Side = enum { ssr, client };

fn appArgs(comptime side: Side) []const []const u8 {
    const common = .{
        "zig",                 "build-exe",            "-target",                     if (side == .ssr) "wasm32-wasi" else "wasm32-freestanding",
        "-O",                  "ReleaseSmall",         "--dep",                       "zx",
        "-Mroot=app/main.zig", "--dep",                "zx_info",                     "--dep",
        "app",                 "--dep",                "app_opts",                    "--dep",
        "manifest",            "-Mzx=zx/src/root.zig", "-Mzx_info=stubs/zx_info.zig", "--dep",
        "zx",                  "-Mapp=app/app.zig",    "-Mapp_opts=stubs/app_opts.zig", "-Mmanifest=stubs/manifest.zon",
        "--name",              if (side == .ssr) "ziex_ssr" else "ziex_client",
        "libcompiler_rt.a",    "-fno-compiler-rt",     "--export-memory",             "-rdynamic",
    };
    const all = comptime if (side == .client) common ++ .{ "-fno-entry", "--stack", "524288", "--max-memory=16777216" } else common;
    const arr: [all.len][]const u8 = all;
    return &arr;
}

/// Runs `zx` in `cwd`; returns stdout, or null after logging the failure.
fn runZx(arena: std.mem.Allocator, cwd: *Node, args: []const []const u8, w: *std.Io.Writer) !?[]const u8 {
    var p = try wasi.Process.init(args, &.{.{ .name = ".", .dir = cwd }});
    defer p.deinit();
    const ran = try wasi.run(&p, assets.zx_module, .{});
    if (!ran or p.exit_code != 0) {
        try w.print("failed\n{s}\n", .{orDefault(p.stderr(), "zx transpile failed")});
        return null;
    }
    return try arena.dupe(u8, p.stdout());
}

/// Runs `zig` with the project as cwd; returns the emitted `out_name`, or null after logging errors.
fn runZig(arena: std.mem.Allocator, project: *Node, args: []const []const u8, out_name: []const u8, w: *std.Io.Writer) !?[]const u8 {
    var p = try wasi.Process.init(args, &.{
        .{ .name = ".", .dir = project },
        .{ .name = "/lib", .dir = assets.lib_dir },
        .{ .name = "/cache", .dir = cache_dir orelse blk: {
            cache_dir = try Node.newDir(gpa);
            break :blk cache_dir.?;
        } },
    });
    defer p.deinit();
    p.merge_output = true;
    const ran = try wasi.run(&p, assets.zig_module, .{});
    if (!ran or p.exit_code != 0) {
        try w.print("failed\n{s}\n", .{orDefault(p.stderr(), "zig exited with an error")});
        return null;
    }
    const out = project.readPath(out_name) orelse {
        try w.print("failed\nzig produced no {s}\n", .{out_name});
        return null;
    };
    return try arena.dupe(u8, out);
}

// --- Render ---

fn renderProgram(a: std.mem.Allocator, w: *std.Io.Writer, module: js.Value) !Preview {
    const cwd = try Node.newDir(a);
    var p = try wasi.Process.init(&.{"main.wasm"}, &.{.{ .name = ".", .dir = cwd }});
    defer p.deinit();
    const ran = try wasi.run(&p, module, .{});
    try w.writeAll(p.stderr());
    if (!ran or p.exit_code != 0) {
        try w.print("Program exited with code {d}\n", .{p.exit_code orelse 1});
        return .{ .ok = false, .log = "" };
    }
    return .{ .ok = true, .log = "", .kind = .html, .status = 200, .body = try a.dupe(u8, p.stdout()) };
}

/// The response the SSR wasm writes through the `http_*` host ops.
const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "",
    body: std.ArrayList(u8) = .empty,
    log: *std.Io.Writer,
    arena: std.mem.Allocator,
};

var response: ?*Response = null;

fn renderApp(a: std.mem.Allocator, w: *std.Io.Writer, app: *Build.App, raw_path: []const u8) !Preview {
    const path = if (raw_path.len == 0) "/" else raw_path;
    const q = std.mem.findScalar(u8, path, '?');
    const pathname = path[0 .. q orelse path.len];
    const search = if (q) |i| path[i..] else "";
    const url = try a.print("https://playground.local{s}", .{path});

    var res: Response = .{ .log = w, .arena = a };
    response = &res;
    defer response = null;

    const cwd = try Node.newDir(a);
    var p = try wasi.Process.init(&.{ "ziex_ssr.wasm", "--pathname", pathname, "--method", "GET", "--search", search, "--url", url }, &.{.{ .name = ".", .dir = cwd }});
    defer p.deinit();
    const ran = try wasi.run(&p, app.ssr, .{ .imports = &.{
        .{ .module = "__zx", .name = "call", .@"export" = "pg_zx_call" },
        .{ .module = "__zx", .name = "wait", .@"export" = "pg_zx_call" },
        .{ .module = "__zx", .name = "_log", .@"export" = "pg_zx_log" },
    } });
    try w.writeAll(p.stderr());
    if (!ran) {
        try w.writeAll("The server crashed while rendering\n");
        return .{ .ok = false, .log = "" };
    }

    const ct = res.content_type;
    const is_html = ct.len == 0 or std.ascii.findIgnoreCase(ct, "html") != null;
    return .{
        .ok = true,
        .log = "",
        .kind = if (is_html) .html else .text,
        .status = res.status,
        .content_type = ct,
        .body = if (is_html) try previewDocument(a, res.body.items, app) else res.body.items,
    };
}

/// SSR html, made to hydrate inside a `srcdoc` iframe: site-relative URLs, the client
/// wasm from a blob URL, and the `__zx_web` glue before the deferred `init.js`.
fn previewDocument(a: std.mem.Allocator, html: []const u8, app: *Build.App) ![]const u8 {
    const origin = try assets.originAlloc();
    defer gpa.free(origin);
    const with_wasm = try std.mem.replaceOwned(u8, a, html, "__PLAYGROUND_CLIENT_WASM__", app.client_url);
    const head_extra = try a.print("<base href=\"{s}/\"><script>{s}</script>", .{ origin, app.glue });

    if (std.ascii.findIgnoreCase(with_wasm, "<head")) |i| {
        if (std.mem.findScalarPos(u8, with_wasm, i, '>')) |end| {
            return std.mem.concat(a, u8, &.{ with_wasm[0 .. end + 1], head_extra, with_wasm[end + 1 ..] });
        }
    }
    return std.mem.concat(a, u8, &.{ head_extra, with_wasm });
}

fn blobUrl(bytes: []const u8) ![]u8 {
    const Array = try js.global.get(js.Object, "Array");
    defer Array.deinit();
    const parts = try Array.new(.{});
    defer parts.deinit();
    _ = try parts.call(f64, "push", .{js.bytes(bytes)});
    const Blob = try js.global.get(js.Object, "Blob");
    defer Blob.deinit();
    const blob = try Blob.new(.{ parts, .{ .type = "application/wasm" } });
    defer blob.deinit();
    const Url = try js.global.get(js.Object, "URL");
    defer Url.deinit();
    return Url.callAlloc(js.String, gpa, "createObjectURL", .{blob});
}

fn revokeUrl(url: []const u8) void {
    const Url = js.global.get(js.Object, "URL") catch return;
    defer Url.deinit();
    Url.call(void, "revokeObjectURL", .{url}) catch {};
}

// --- `__zx` host for the SSR wasm (mirrors `ops` in pkg/ziex/src/runtime/host.ts) ---

const Op = enum(u32) {
    io_now,
    io_resolution,
    io_sleep,
    io_random,
    net_fetch,
    net_take,
    net_open,
    net_read,
    net_close,
    http_commit,
    http_write,
    http_end,
    ws_upgrade,
    ws_write,
    ws_close,
    ws_recv,
    ws_subscribe,
    ws_unsubscribe,
    ws_publish,
    ws_is_subscribed,
    sys_park,
    kv_get,
    kv_put,
    kv_delete,
    kv_list,
    _,
};

const unsupported: i32 = -38;

fn zxCall(op: u32, a: u32, b: u32, c: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) i32 {
    const res = response orelse return unsupported;
    switch (@as(Op, @enumFromInt(op))) {
        .http_commit => {
            res.status = @intCast(a);
            const meta = wasi.readGuest(res.arena, b, c) catch return 0;
            const Meta = struct { headers: []const [2][]const u8 = &.{} };
            const parsed = std.json.parseFromSliceLeaky(Meta, res.arena, meta, .{ .ignore_unknown_fields = true }) catch return 0;
            for (parsed.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], "content-type")) {
                res.content_type = h[1];
            };
            return 0;
        },
        .http_write => {
            const bytes = wasi.readGuest(res.arena, a, b) catch return -1;
            res.body.appendSlice(res.arena, bytes) catch return -1;
            return 0;
        },
        .http_end, .io_sleep, .kv_put, .kv_delete, .kv_list => return 0,
        .kv_get, .ws_recv, .net_fetch, .net_open => return -1,
        else => return unsupported,
    }
}

fn zxLog(_: u32, ptr: u32, len: u32) callconv(.c) void {
    const res = response orelse return;
    const msg = wasi.readGuest(res.arena, ptr, len) catch return;
    res.log.print("{s}\n", .{msg}) catch {};
}

// Only the worker wasm hosts guests; the page and server just see the types.
comptime {
    if (@hasDecl(@import("root"), "zx_worker")) {
        @export(&zxCall, .{ .name = "pg_zx_call" });
        @export(&zxLog, .{ .name = "pg_zx_log" });
    }
}

// --- Helpers ---

fn orDefault(s: []const u8, default: []const u8) []const u8 {
    return if (std.mem.trim(u8, s, &std.ascii.whitespace).len == 0) default else s;
}

const Timer = struct {
    last: f64,

    fn start() Timer {
        return .{ .last = nowMs() };
    }

    const Lap = struct {
        ms: f64,
        pub fn format(l: Lap, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (l.ms >= 1000) return w.print("{d:.1}s", .{l.ms / 1000});
            return w.print("{d:.0}ms", .{l.ms});
        }
    };

    fn lap(t: *Timer) Lap {
        const n = nowMs();
        defer t.last = n;
        return .{ .ms = n - t.last };
    }
};

fn nowMs() f64 {
    const perf = js.global.get(js.Object, "performance") catch return 0;
    defer perf.deinit();
    return perf.call(f64, "now", .{}) catch 0;
}
