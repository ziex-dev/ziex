//! The compilers and sources the playground workers run. Downloads go through Cache
//! Storage (one cache per playground version, shared by both workers and kept across
//! reloads) and run concurrently: every request starts before the first is awaited, and
//! the wasm modules compile in the background while the tarballs unpack.
const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;
const wasi = @import("wasi.zig");
const versions = @import("playground_assets");

const Node = wasi.Node;
const gpa = zx.allocator;

var tools_loaded = false;
var zig_loaded = false;
pub var zig_module: js.Value = .undefined;
pub var zx_module: js.Value = .undefined;
/// Zig's `lib/` (std and friends), mounted at `/lib`.
pub var lib_dir: *Node = undefined;
/// The zx sources (`src/...`), mounted as `zx`.
pub var zx_dir: *Node = undefined;
pub var compiler_rt: *Node = undefined;

const base = "/assets/playground/";
const zx_wasm = base ++ "zx-" ++ versions.zx_version ++ ".wasm";
const zx_tar = base ++ "zx-" ++ versions.zx_version ++ ".tar.gz";
const zig_tar = base ++ "zig-" ++ versions.zig_version ++ ".tar.gz";
const zig_wasm = base ++ "zig-" ++ versions.zig_version ++ ".wasm";
const compiler_rt_lib = base ++ "libcompiler_rt-" ++ versions.zig_version ++ ".a";

const cache_prefix = "ziex-playground-";
const cache_name = cache_prefix ++ versions.zx_version;

/// `zx.wasm` plus the sources it needs: enough to transpile, format and serve LSP.
pub fn loadTools() !void {
    if (tools_loaded) return;
    const got = try fetchAll(&.{ zx_wasm, zig_tar, zx_tar });
    const compiling = try compileStart(got[0]);
    lib_dir = try Node.newDir(gpa);
    try unpack(lib_dir, got[1], "lib/");
    zx_dir = try Node.newDir(gpa);
    try unpack(zx_dir, got[2], "");
    zx_module = try js.awaitValue(compiling);
    tools_loaded = true;
}

/// Everything `loadTools` does, plus `zig.wasm` and the prebuilt compiler_rt.
pub fn loadAll() !void {
    if (zig_loaded) return;
    const got = try fetchAll(&.{ zig_wasm, compiler_rt_lib });
    const compiling = try compileStart(got[0]);
    try loadTools();
    defer got[1].deinit();
    const rt_bytes = try got[1].bytesAlloc(gpa);
    defer gpa.free(rt_bytes);
    compiler_rt = try Node.newFile(gpa, rt_bytes);
    zig_module = try js.awaitValue(compiling);
    zig_loaded = true;
}

/// `WebAssembly.compile(buffer)`: V8 compiles off-thread while the caller keeps going.
fn compileStart(buffer: js.Value) !js.Value {
    defer buffer.deinit();
    const wa = try js.global.get(js.Object, "WebAssembly");
    defer wa.deinit();
    return wa.call(js.Value, "compile", .{buffer});
}

fn unpack(root: *Node, buffer: js.Value, strip: []const u8) !void {
    defer buffer.deinit();
    const bytes = try buffer.bytesAlloc(gpa);
    defer gpa.free(bytes);
    try wasi.untarGz(root, bytes, strip);
}

/// A blob-URL worker can't resolve root-relative URLs.
pub fn originAlloc() ![]u8 {
    const location = try js.global.get(js.Object, "location");
    defer location.deinit();
    return location.getAlloc(js.String, gpa, "origin");
}

/// The `ArrayBuffer` of each path, in order: from the cache when there, else fetched
/// (all at once) and cached. Callers release the buffers.
fn fetchAll(comptime paths: []const []const u8) ![paths.len]js.Value {
    const origin = try originAlloc();
    defer gpa.free(origin);
    var urls: [paths.len][]const u8 = undefined;
    for (&urls, paths) |*u, p| u.* = try std.mem.concat(gpa, u8, &.{ origin, p });
    defer for (urls) |u| gpa.free(u);

    const cache = openCache();
    defer if (cache) |c| c.deinit();

    var responses: [paths.len]js.Value = @splat(.undefined);
    defer for (responses) |r| r.deinit();
    var pending: [paths.len]js.Value = @splat(.undefined);

    // Cache lookups, then downloads for the misses, each batch started before awaiting.
    if (cache) |c| {
        for (&pending, urls) |*p, u| p.* = c.call(js.Value, "match", .{u}) catch .undefined;
        for (&responses, pending) |*r, p| r.* = awaitOwned(p);
    }
    for (&pending, responses, urls) |*p, r, u| {
        p.* = if (r == .undefined) js.global.call(js.Value, "fetch", .{u}) catch .undefined else .undefined;
    }
    for (&responses, pending, urls) |*r, p, u| {
        if (p == .undefined) continue;
        r.* = awaitOwned(p);
        const resp: js.Object = .{ .value = r.* };
        if (!(resp.get(bool, "ok") catch false)) {
            std.log.err("playground: GET {s} failed", .{u});
            return error.FetchFailed;
        }
        if (cache) |c| {
            const copy = resp.call(js.Value, "clone", .{}) catch continue;
            defer copy.deinit();
            const stored = c.call(js.Value, "put", .{ u, copy }) catch continue;
            stored.deinit();
        }
    }

    var bodies: [paths.len]js.Value = undefined;
    for (&bodies, responses) |*b, r| {
        const resp: js.Object = .{ .value = r };
        b.* = resp.call(js.Value, "arrayBuffer", .{}) catch return error.FetchFailed;
    }
    for (&bodies) |*b| b.* = js.awaitValue(b.*) catch return error.FetchFailed;
    return bodies;
}

fn awaitOwned(p: js.Value) js.Value {
    if (p == .undefined) return .undefined;
    defer p.deinit();
    return js.awaitValue(p) catch .undefined;
}

/// This version's cache; older playground caches are dropped. Null without Cache Storage.
fn openCache() ?js.Object {
    const caches = js.global.get(?js.Object, "caches") catch return null;
    const storage = caches orelse return null;
    defer storage.deinit();

    if (storage.call(js.Value, "keys", .{}) catch null) |keys_promise| {
        const keys = awaitOwned(keys_promise);
        defer keys.deinit();
        for (0..keys.len()) |i| {
            const key = keys.at(i);
            defer key.deinit();
            const name = key.string(gpa) catch continue;
            defer gpa.free(name);
            if (std.mem.startsWith(u8, name, cache_prefix) and !std.mem.eql(u8, name, cache_name)) {
                const deleting = storage.call(js.Value, "delete", .{name}) catch continue;
                deleting.deinit();
            }
        }
    }
    const opened = awaitOwned(storage.call(js.Value, "open", .{cache_name}) catch return null);
    if (opened == .undefined) return null;
    return .{ .value = opened };
}
