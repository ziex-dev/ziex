const std = @import("std");
const lang = @import("lang");

const util = @import("shared/util.zig");
const Manifest = @import("../build/Manifest.zig");
const context = @import("shared/context.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.transpile;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const outdir = args.outdir;
    const copy_only = args.@"copy-only";
    const verbose = args.verbose;
    const map = parseMapMode(args.map);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const opts: TranspileOptions = .{
        .path = args.path,
        .outdir = outdir,
        .verbose = verbose,
        .map = map,
        .dep_file = nonEmpty(args.@"dep-file"),
        .cache_dir = nonEmpty(args.@"cache-dir"),
        .base_path = nonEmpty(args.@"base-path"),
        .manifest = nonEmpty(args.manifest),
        .build_injections = nonEmpty(args.@"build-injections"),
        .exe_path = nonEmpty(args.@"exe-path"),
    };

    if (verbose) {
        std.debug.print("Transpiling: {s} -> {s} (copy_only: {any}, verbose: {any})\n", .{ opts.path, outdir, copy_only, verbose });
    }

    if (copy_only) return copyOnly(io, allocator, opts.path, outdir) catch |err| {
        std.debug.print("Error: Could not copy path '{s} -> {s}': {}\n", .{ opts.path, outdir, err });
        return err;
    };
    const is_default_outdir = std.mem.eql(u8, outdir, ".zx");

    // If the path is a file whose extension is .zx/.mdzx and the user kept the
    // default outdir, write the transpiled source directly to stdout.
    const stat = std.Io.Dir.cwd().statFile(io, opts.path, .{}) catch |err| switch (err) {
        error.IsDir => return transpileCommand(io, allocator, opts),
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ opts.path, err });
            return err;
        },
    };

    if (stat.kind == .file and is_default_outdir and zxExtLen(opts.path) != null) {
        try transpileToStdout(ctx, io, opts.path, map);
        return;
    }

    try transpileCommand(io, allocator, opts);
}

/// Parse the `--map` flag value into a `MapMode`.
fn parseMapMode(sourcemap_str: []const u8) lang.Ast.ParseOptions.MapMode {
    if (std.mem.eql(u8, sourcemap_str, "inline")) return .inlined;
    if (sourcemap_str.len == 0 or std.mem.eql(u8, sourcemap_str, "none")) return .none;
    return .{ .file = sourcemap_str };
}

/// Transpile a single .zx/.mdzx file and write the result to stdout, emitting
/// the configured sourcemap alongside it.
fn transpileToStdout(ctx: CommandContext, io: std.Io, path: []const u8, map: lang.Ast.ParseOptions.MapMode) !void {
    const allocator = ctx.allocator;

    const source = try readFile(io, allocator, path);
    defer allocator.free(source);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{
        .path = path,
        .map = map,
        .lang = sourceLang(path),
    });
    defer result.deinit(allocator);

    try ctx.writer.writeAll(result.zig_source);

    if (result.sourcemap) |*sm| switch (map) {
        .none => {},
        .file => |map_path| {
            const human = try sm.formatHuman(allocator, source, result.zig_source);
            defer allocator.free(human);
            try writeFile(io, map_path, human);
        },
        .inlined => {
            // Ensure embed carries the source path for remapping.
            if (sm.source.len == 0) {
                sm.source = try allocator.dupe(u8, path);
            }
            const embed = try sm.formatEmbed(allocator);
            defer allocator.free(embed);
            try ctx.writer.writeAll("\n");
            try ctx.writer.writeAll(embed);
        },
    };
}

/// Return the slice when non-empty, otherwise `null`.
fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len > 0) s else null;
}

/// Whether a path exists relative to the cwd.
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Create a directory path, ignoring "already exists".
fn createDirSafe(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn copyFileSafe(io: std.Io, src: []const u8, dst: []const u8) !void {
    try std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io, .{});
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Length of a `.zx` / `.mdzx` / `.md` suffix, or `null` if the path is none of those.
fn zxExtLen(path: []const u8) ?usize {
    if (std.mem.endsWith(u8, path, ".mdzx")) return ".mdzx".len;
    if (std.mem.endsWith(u8, path, ".md")) return ".md".len;
    if (std.mem.endsWith(u8, path, ".zx")) return ".zx".len;
    return null;
}

fn sourceLang(path: []const u8) lang.Parse.Language {
    if (std.mem.endsWith(u8, path, ".mdzx")) return .mdzx;
    if (std.mem.endsWith(u8, path, ".md")) return .md;
    return .zx;
}

/// Filesystem-routing Zig roots that may exist as hand-written `.zig`
/// (no `.zx` twin), e.g. `route.zig` / `proxy.zig`.
fn isFsRouteZigRoot(basename: []const u8) bool {
    const roots = [_][]const u8{
        "page.zig",
        "layout.zig",
        "error.zig",
        "route.zig",
        "proxy.zig",
        "notfound.zig",
    };
    for (roots) |root| {
        if (std.mem.eql(u8, basename, root)) return true;
    }
    return false;
}

/// True when `zig_path` (…/foo.zig) has a sibling `foo.zx` / `foo.mdzx` / `foo.md`
/// that owns the output - do not copy the `.zig` from source in that case.
fn hasZxTwin(io: std.Io, zig_path: []const u8) bool {
    if (!std.mem.endsWith(u8, zig_path, ".zig")) return false;
    const stem = zig_path[0 .. zig_path.len - ".zig".len];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ ".zx", ".mdzx", ".md" }) |ext| {
        const twin = std.fmt.bufPrint(&buf, "{s}{s}", .{ stem, ext }) catch continue;
        if (std.Io.Dir.cwd().access(io, twin, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Whether `outdir_rel` still has a corresponding source under `source_root`.
fn sourceExistsForOutRel(io: std.Io, source_root: []const u8, outdir_rel: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const direct = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ source_root, std.fs.path.sep_str, outdir_rel }) catch return false;
    if (fileExists(io, direct)) return true;

    if (std.mem.endsWith(u8, outdir_rel, ".zig")) {
        const stem_rel = outdir_rel[0 .. outdir_rel.len - ".zig".len];
        for ([_][]const u8{ ".zx", ".mdzx", ".md" }) |ext| {
            const twin = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ source_root, std.fs.path.sep_str, stem_rel, ext }) catch continue;
            if (fileExists(io, twin)) return true;
        }
    }
    return false;
}

/// Drop outputs in a persistent outdir that no longer exist in the source tree.
fn pruneStaleOutdir(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    outdir: []const u8,
    verbose: bool,
) !void {
    var out = std.Io.Dir.cwd().openDir(io, outdir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer out.close(io);

    var walker = try out.walk(allocator);
    defer walker.deinit();

    var stale_files = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (stale_files.items) |p| allocator.free(p);
        stale_files.deinit();
    }
    var stale_dirs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (stale_dirs.items) |p| allocator.free(p);
        stale_dirs.deinit();
    }

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.eql(u8, entry.path, "app.zig")) continue;

                if (std.mem.endsWith(u8, entry.path, ".zxcache")) {
                    const zig_rel = entry.path[0 .. entry.path.len - ".zxcache".len];
                    if (sourceExistsForOutRel(io, source_root, zig_rel)) continue;
                } else if (sourceExistsForOutRel(io, source_root, entry.path)) {
                    continue;
                }

                const full = try std.fs.path.join(allocator, &.{ outdir, entry.path });
                try stale_files.append(full);
            },
            .directory => {
                const full = try std.fs.path.join(allocator, &.{ outdir, entry.path });
                try stale_dirs.append(full);
            },
            else => {},
        }
    }

    for (stale_files.items) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => if (verbose) std.debug.print("Warning: Failed to prune {s}: {}\n", .{ path, err }),
        };
        if (verbose) std.debug.print("Pruned stale output: {s}\n", .{path});
    }

    std.mem.sort([]const u8, stale_dirs.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.less);
    for (stale_dirs.items) |path| {
        std.Io.Dir.cwd().deleteDir(io, path) catch {};
    }
}

/// Convert filesystem route segments into URL patterns:
/// - `[param]` → `:param`
/// - `[..]` → `*`
/// The returned slice is owned by `allocator`.
fn normalizeRoutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Replace catch-all folder `[..]` with `*` before bracket normalization.
    const with_wildcard = try replaceAll(allocator, path, "[..]", "*");
    defer allocator.free(with_wildcard);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (with_wildcard) |c| {
        if (c == '[') {
            try out.append(':');
        } else if (c != ']') {
            try out.append(c);
        }
    }
    return out.toOwnedSlice();
}

/// Replace every occurrence of `needle` in `haystack` with `replacement`.
/// Caller owns the returned slice.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, haystack, needle, replacement);
}

/// `replaceAll` that frees the input buffer.
fn replaceAllOwned(allocator: std.mem.Allocator, input: []u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const out = try replaceAll(allocator, input, needle, replacement);
    allocator.free(input);
    return out;
}

/// Strip the `"@`/`@"` placeholder markers, collapse `@@@`→`@` and `@@`→`"`,
/// and trim a trailing lone `@`. These markers carry quotes/signifiers through
/// ZON/JSON serialization so they survive into the generated registry.
fn stripPlaceholders(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var s = try replaceAll(allocator, src, "\"@", "");
    s = try replaceAllOwned(allocator, s, "@\"", "");
    s = try replaceAllOwned(allocator, s, "@@@", "@");
    s = try replaceAllOwned(allocator, s, "@@", "\"");
    if (s.len > 0 and s[s.len - 1] == '@') {
        const trimmed = try allocator.dupe(u8, s[0 .. s.len - 1]);
        allocator.free(s);
        s = trimmed;
    }
    return s;
}

/// Append `//# ziex-map` embed comments to `output_path`.
fn writeInlinePositionMap(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    embed: []const u8,
) !void {
    const comment = try std.fmt.allocPrint(allocator, "\n{s}", .{embed});
    defer allocator.free(comment);
    var file = try std.Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write });
    defer file.close(io);
    const len = try file.length(io);
    try file.writePositionalAll(io, comment, len);
}

// ---- Dep File ---- //

fn writeDepFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, target: []const u8, deps: []const []const u8) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, target);
    try buf.appendSlice(allocator, ":");
    for (deps) |dep| {
        try buf.appendSlice(allocator, " ");
        for (dep) |c| {
            if (c == ' ') {
                try buf.appendSlice(allocator, "\\ ");
            } else {
                try buf.append(allocator, c);
            }
        }
    }
    try buf.appendSlice(allocator, "\n");
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, buf.items, 0);
}

const tree_fingerprint_name = ".zx-tree";

fn collectSourceRelPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_root: []const u8,
) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var rels = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (rels.items) |r| allocator.free(r);
        rels.deinit();
    }

    while (try walker.next(io)) |entry| {
        var actual_kind = entry.kind;
        if (entry.kind == .sym_link) {
            const entry_stat = dir.statFile(io, entry.path, .{}) catch continue;
            actual_kind = entry_stat.kind;
        }
        if (actual_kind != .file) continue;
        if (zxExtLen(entry.path) == null) continue;
        try rels.append(try allocator.dupe(u8, entry.path));
    }

    std.mem.sort([]const u8, rels.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try rels.toOwnedSlice();
}

fn formatTreeFingerprint(allocator: std.mem.Allocator, rels: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (rels) |rel| {
        try buf.appendSlice(allocator, rel);
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

fn writeSourceTreeFingerprint(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    rels: []const []const u8,
) !void {
    createDirSafe(io, cache_dir) catch {};
    const body = try formatTreeFingerprint(allocator, rels);
    defer allocator.free(body);
    const out_path = try std.fs.path.join(allocator, &.{ cache_dir, tree_fingerprint_name });
    defer allocator.free(out_path);
    try writeFile(io, out_path, body);
}

fn sourceTreeFingerprintChanged(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    rels: []const []const u8,
) !bool {
    const expected = try formatTreeFingerprint(allocator, rels);
    defer allocator.free(expected);

    const fp_path = try std.fs.path.join(allocator, &.{ cache_dir, tree_fingerprint_name });
    defer allocator.free(fp_path);
    const prev = std.Io.Dir.cwd().readFileAlloc(io, fp_path, allocator, .limited(4 * 1024 * 1024)) catch return true;
    defer allocator.free(prev);
    return !std.mem.eql(u8, prev, expected);
}

fn invalidateZxCaches(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8, verbose: bool) !void {
    var dir = std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zxcache")) continue;
        const full = try std.fs.path.join(allocator, &.{ cache_dir, entry.path });
        defer allocator.free(full);
        std.Io.Dir.cwd().deleteFile(io, full) catch continue;
        if (verbose) std.debug.print("Invalidated cache: {s}\n", .{full});
    }
}

/// Walk the transpiled Zig AST and, for each `@embedFile("...")` whose target
/// exists on disk (relative to `source_dir`), copy it into the output dir at the
/// same relative spelling (so the emitted `@embedFile` resolves at compile time)
/// and record its absolute source path in `input_files` for the dep file.
fn collectEmbedFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_files: *std.array_list.Managed([]const u8),
    ast: *const std.zig.Ast,
    source_dir: []const u8,
    out_dir: []const u8,
) !void {
    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            else => continue,
        }
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@embedFile")) continue;

        const arg = ast.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse continue;
        if (ast.nodeTag(arg) != .string_literal) continue;
        const raw = ast.tokenSlice(ast.nodeMainToken(arg));
        const embed_path = std.zig.string_literal.parseAlloc(allocator, raw) catch continue;
        defer allocator.free(embed_path);

        const src = std.fs.path.join(allocator, &.{ source_dir, embed_path }) catch continue;
        defer allocator.free(src);

        // Only act on embeds that exist as real source files on disk.
        if (std.Io.Dir.cwd().statFile(io, src, .{})) |_| {} else |_| continue;

        // Copy into the output dir at the embed's relative spelling.
        const dst = std.fs.path.join(allocator, &.{ out_dir, embed_path }) catch continue;
        defer allocator.free(dst);
        if (std.fs.path.dirname(dst)) |parent| {
            createDirSafe(io, parent) catch {};
        }
        copyFileSafe(io, src, dst) catch |err| {
            std.debug.print("Warning: Could not copy embedded file {s}: {}\n", .{ src, err });
        };

        const abs = std.fs.path.resolve(allocator, &.{src}) catch continue;
        input_files.append(abs) catch allocator.free(abs);
    }
}

/// Re-run companion copies (`@embedFile` + relative `@import`s) for a cached
/// `.zx`/`.mdzx` whose transpilation was skipped.
fn copyCompanionsForCached(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
    zig_path: []const u8,
    source_dir: []const u8,
    out_dir: []const u8,
    verbose: bool,
) !void {
    const zig_src = try readFile(io, allocator, zig_path);
    defer allocator.free(zig_src);

    const zig_src_z = try allocator.dupeSentinel(u8, zig_src, 0);
    defer allocator.free(zig_src_z);

    var ast = try std.zig.Ast.parse(allocator, zig_src_z, .{ .mode = .zig });
    defer ast.deinit(allocator);

    try collectEmbedFiles(io, allocator, input_files, &ast, source_dir, out_dir);
    try collectAndCopyCompanions(io, allocator, input_files, companions_visited, &ast, source_dir, out_dir, verbose);
}

/// Copy relative `@import("…")` targets that exist on disk (`.zig`, `.zon`, …),
/// then recurse into copied `.zig` files for further imports/embeds.
fn collectAndCopyCompanions(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
    ast: *const std.zig.Ast,
    source_dir: []const u8,
    out_dir: []const u8,
    verbose: bool,
) anyerror!void {
    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            else => continue,
        }
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) continue;

        const arg = ast.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse continue;
        if (ast.nodeTag(arg) != .string_literal) continue;
        const raw = ast.tokenSlice(ast.nodeMainToken(arg));
        const import_path = std.zig.string_literal.parseAlloc(allocator, raw) catch continue;
        defer allocator.free(import_path);

        // Module imports (`std`, `zx`, …) have no extension - skip.
        if (std.fs.path.extension(import_path).len == 0) continue;

        const src = std.fs.path.join(allocator, &.{ source_dir, import_path }) catch continue;
        defer allocator.free(src);
        std.Io.Dir.cwd().access(io, src, .{}) catch continue;
        if (hasZxTwin(io, src)) continue;

        const dst = std.fs.path.join(allocator, &.{ out_dir, import_path }) catch continue;
        defer allocator.free(dst);

        copyCompanionRecursive(io, allocator, input_files, companions_visited, src, dst, verbose) catch |err| {
            std.debug.print("Warning: Could not copy companion {s}: {}\n", .{ src, err });
        };
    }
}

/// Copy one companion into the outdir and, if it is Zig source, follow its
/// `@import` / `@embedFile` graph.
fn copyCompanionRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
    source_path: []const u8,
    output_path: []const u8,
    verbose: bool,
) anyerror!void {
    const abs_source = std.fs.path.resolve(allocator, &.{source_path}) catch
        try allocator.dupe(u8, source_path);
    if (companions_visited.contains(abs_source)) {
        allocator.free(abs_source);
        return;
    }
    try companions_visited.put(abs_source, {});
    try input_files.append(try allocator.dupe(u8, abs_source));

    if (std.fs.path.dirname(output_path)) |parent| {
        try createDirSafe(io, parent);
    }
    try copyFileSafe(io, source_path, output_path);
    if (verbose) std.debug.print("Copied companion: {s} -> {s}\n", .{ source_path, output_path });

    if (!std.mem.endsWith(u8, source_path, ".zig")) return;

    const zig_src = try readFile(io, allocator, source_path);
    defer allocator.free(zig_src);
    const zig_src_z = try allocator.dupeSentinel(u8, zig_src, 0);
    defer allocator.free(zig_src_z);

    var ast = try std.zig.Ast.parse(allocator, zig_src_z, .{ .mode = .zig });
    defer ast.deinit(allocator);

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const out_dir = std.fs.path.dirname(output_path) orelse ".";
    try collectEmbedFiles(io, allocator, input_files, &ast, source_dir, out_dir);
    try collectAndCopyCompanions(io, allocator, input_files, companions_visited, &ast, source_dir, out_dir, verbose);
}

/// Walk the transpiled Zig AST (`ast`, already produced by `lang.Ast.parse`)
/// and append each `@import("...")` target that resolves to an existing
/// `.zx`/`.mdzx` source (relative to `source_dir`) to `out`.
fn collectZxImports(
    io: std.Io,
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed([]const u8),
    ast: *const std.zig.Ast,
    source_dir: []const u8,
) !void {
    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            else => continue,
        }

        const main_tok = ast.nodeMainToken(node);
        if (!std.mem.eql(u8, ast.tokenSlice(main_tok), "@import")) continue;

        // First argument: the import path string literal.
        const arg = ast.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse continue;
        if (ast.nodeTag(arg) != .string_literal) continue;
        const raw = ast.tokenSlice(ast.nodeMainToken(arg));
        const import_path = std.zig.string_literal.parseAlloc(allocator, raw) catch continue;
        defer allocator.free(import_path);

        // Map the rewritten `.zig` target back to its `.zx`/`.mdzx` source. Plain
        // `@import("std")` / module imports have no extension and are skipped.
        const stem = if (std.mem.endsWith(u8, import_path, ".zig"))
            import_path[0 .. import_path.len - ".zig".len]
        else if (std.mem.endsWith(u8, import_path, ".zx"))
            import_path[0 .. import_path.len - ".zx".len]
        else if (std.mem.endsWith(u8, import_path, ".mdzx"))
            import_path[0 .. import_path.len - ".mdzx".len]
        else if (std.mem.endsWith(u8, import_path, ".md"))
            import_path[0 .. import_path.len - ".md".len]
        else
            continue;

        for ([_][]const u8{ ".zx", ".mdzx", ".md" }) |ext| {
            const cand = std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext }) catch continue;
            const resolved = std.fs.path.join(allocator, &.{ source_dir, cand }) catch {
                allocator.free(cand);
                continue;
            };
            defer allocator.free(resolved);
            if (std.Io.Dir.cwd().statFile(io, resolved, .{})) |_| {
                // Return the import spelling relative to source_dir (e.g. `icon.zx`).
                out.append(cand) catch allocator.free(cand);
                break;
            } else |_| allocator.free(cand);
        }
    }
}

/// Transpile `source_path` into `output_path`, then recursively transpile every
/// `.zx`/`.mdzx` file it `@import`s (resolved relative to the importing file)
/// into the same `outdir`.
fn transpileFileRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    global_components: *std.array_list.Managed(ClientComponentSerializable),
    opts: TranspileOptions,
    source_path: []const u8,
    output_path: []const u8,
    visited: *std.StringHashMap(void),
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
) !void {
    const abs_source = std.fs.path.resolve(allocator, &.{source_path}) catch
        try allocator.dupe(u8, source_path);
    if (visited.contains(abs_source)) {
        allocator.free(abs_source);
        return;
    }
    // `visited` owns abs_source; also record it as a dep file input.
    try visited.put(abs_source, {});
    try input_files.append(try allocator.dupe(u8, abs_source));

    // Transpile this file, collecting its `.zx` imports from the parsed AST.
    var imports = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (imports.items) |p| allocator.free(p);
        imports.deinit();
    }
    try transpileFile(io, allocator, global_components, opts, source_path, output_path, &imports, input_files, companions_visited);

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const out_dir = std.fs.path.dirname(output_path) orelse opts.outdir;

    for (imports.items) |rel| {
        const dep_source = try std.fs.path.join(allocator, &.{ source_dir, rel });
        defer allocator.free(dep_source);

        const ext_len = zxExtLen(rel) orelse continue;
        const out_rel = try std.mem.concat(allocator, u8, &.{ rel[0 .. rel.len - ext_len], ".zig" });
        defer allocator.free(out_rel);

        const dep_output = try std.fs.path.join(allocator, &.{ out_dir, out_rel });
        defer allocator.free(dep_output);

        try transpileFileRecursive(io, allocator, global_components, opts, dep_source, dep_output, visited, input_files, companions_visited);
    }
}

// ---- Component Cache (per-file incremental) ---- //

const ComponentCacheFile = struct {
    shape: []const u8,
    components: []const ClientComponentSerializable,
};

fn writeComponentCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    components: []const ClientComponentSerializable,
) !void {
    const payload = ComponentCacheFile{
        .shape = lang.Transpile.shape,
        .components = components,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    try writeFile(io, cache_path, json);
}

fn readComponentCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    global_components: *std.array_list.Managed(ClientComponentSerializable),
) !void {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(
        ComponentCacheFile,
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.shape, lang.Transpile.shape)) return error.TranspileShapeMismatch;
    for (parsed.value.components) |component| {
        try global_components.append(.{
            .type = component.type,
            .id = try allocator.dupe(u8, component.id),
            .name = try allocator.dupe(u8, component.name),
            .path = try allocator.dupe(u8, component.path),
            .import = try allocator.dupe(u8, component.import),
            .route = try allocator.dupe(u8, component.route),
        });
    }
}

fn copyOnly(io: std.Io, allocator: std.mem.Allocator, source_path: []const u8, dest_dir: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch |err| switch (err) {
        error.IsDir => return try copyDirectory(io, allocator, source_path, dest_dir),
        else => return err,
    };
    if (stat.kind == .directory) try copyDirectory(io, allocator, source_path, dest_dir);
    if (stat.kind == .file) try copyFileToDir(io, allocator, source_path, dest_dir);
}

// ---- Path Utilities ---- //

/// Extract route from source path based on filesystem routing
/// If the file is in a pages directory, returns the route (e.g., "/about", "/")
/// Otherwise returns empty string
fn extractRouteFromPath(allocator: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    const sep = std.fs.path.sep_str;
    const pages_sep = "pages" ++ sep;

    // Check if source_path contains "pages" directory
    if (std.mem.indexOf(u8, source_path, pages_sep)) |pages_index| {
        // Get the path after "pages/"
        const after_pages = source_path[pages_index + pages_sep.len ..];

        // Find the directory containing the file (remove filename)
        const dir_path = std.fs.path.dirname(after_pages) orelse "";

        // Convert directory path to route
        if (dir_path.len == 0) {
            return try allocator.dupe(u8, "/");
        }

        // Normalize separators first, then [id]→:id and [..]→*
        var with_slashes = std.array_list.Managed(u8).init(allocator);
        defer with_slashes.deinit();
        try with_slashes.append('/');

        for (dir_path) |c| {
            if (c == std.fs.path.sep) {
                try with_slashes.append('/');
            } else {
                try with_slashes.append(c);
            }
        }

        return try normalizeRoutePath(allocator, with_slashes.items);
    }

    // Not in pages directory, return empty string
    return try allocator.dupe(u8, "");
}

fn getBasename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Escapes backslashes in a path string for use in Zig string literals.
/// On Windows, backslashes need to be escaped as \\ in string literals.
fn escapePathForZigString(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var result = std.Io.Writer.Allocating.init(allocator);
    errdefer result.deinit();
    const writer = &result.writer;

    for (path) |byte| {
        if (byte == '\\') {
            // Escape backslash for Zig string literal
            try writer.writeAll("\\\\");
        } else {
            try writer.writeByte(byte);
        }
    }

    return result.toOwnedSlice();
}

/// Resolve a relative path against a base directory
fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, relative_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative_path)) {
        return try allocator.dupe(u8, relative_path);
    }

    var base = base_dir;
    const sep = std.fs.path.sep_str;
    if (std.mem.endsWith(u8, base_dir, sep)) {
        base = base_dir[0 .. base_dir.len - sep.len];
    }

    const joined = try std.fs.path.join(allocator, &.{ base, relative_path });
    defer allocator.free(joined);

    return try std.fs.path.resolve(allocator, &.{joined});
}

/// Calculate relative path from base to target
fn relativePath(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const sep = std.fs.path.sep_str;

    var base_normalized = base;
    var target_normalized = target;
    if (std.mem.endsWith(u8, base, sep)) {
        base_normalized = base[0 .. base.len - sep.len];
    }
    if (std.mem.endsWith(u8, target, sep)) {
        target_normalized = target[0 .. target.len - sep.len];
    }

    var base_parts = std.ArrayList([]const u8).empty;
    defer base_parts.deinit(allocator);
    var target_parts = std.ArrayList([]const u8).empty;
    defer target_parts.deinit(allocator);

    var base_iter = std.mem.splitScalar(u8, base_normalized, std.fs.path.sep);
    while (base_iter.next()) |part| {
        if (part.len > 0) {
            try base_parts.append(allocator, part);
        }
    }

    var target_iter = std.mem.splitScalar(u8, target_normalized, std.fs.path.sep);
    while (target_iter.next()) |part| {
        if (part.len > 0) {
            try target_parts.append(allocator, part);
        }
    }

    var common_len: usize = 0;
    const min_len = @min(base_parts.items.len, target_parts.items.len);
    while (common_len < min_len and std.mem.eql(u8, base_parts.items[common_len], target_parts.items[common_len])) {
        common_len += 1;
    }

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i = common_len;
    while (i < base_parts.items.len) : (i += 1) {
        if (result.items.len > 0) {
            try result.appendSlice(allocator, sep);
        }
        try result.appendSlice(allocator, "..");
    }

    i = common_len;
    while (i < target_parts.items.len) : (i += 1) {
        if (result.items.len > 0) {
            try result.appendSlice(allocator, sep);
        }
        try result.appendSlice(allocator, target_parts.items[i]);
    }

    if (result.items.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if output_dir is a subdirectory of dir_path and return the relative path if so
fn getOutputDirRelativePath(allocator: std.mem.Allocator, dir_path: []const u8, output_dir: []const u8) !?[]const u8 {
    const sep = std.fs.path.sep_str;

    var normalized_dir = dir_path;
    if (std.mem.endsWith(u8, dir_path, sep)) {
        normalized_dir = dir_path[0 .. dir_path.len - sep.len];
    }

    var normalized_output = output_dir;
    if (std.mem.endsWith(u8, output_dir, sep)) {
        normalized_output = output_dir[0 .. output_dir.len - sep.len];
    }

    if (!std.mem.startsWith(u8, normalized_output, normalized_dir)) {
        return null;
    }

    if (std.mem.eql(u8, normalized_dir, normalized_output)) {
        return null;
    }

    const remaining = normalized_output[normalized_dir.len..];
    if (remaining.len == 0) {
        return null;
    }

    if (!std.mem.startsWith(u8, remaining, sep)) {
        return null;
    }

    const relative_path = remaining[sep.len..];
    if (relative_path.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, relative_path);
}

// ============================================================================
// File Operations
// ============================================================================

fn copyFileToDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_file: []const u8,
    dest_dir: []const u8,
) !void {
    _ = allocator;
    try createDirSafe(io, dest_dir);
    try copyFileSafe(io, source_file, std.fs.path.basename(source_file));
}

/// Copy a directory recursively from source to destination
fn copyDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    dest_dir: []const u8,
) !void {
    var source = try std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true });
    defer source.close(io);

    try createDirSafe(io, dest_dir);

    var dest = try std.Io.Dir.cwd().openDir(io, dest_dir, .{});
    defer dest.close(io);

    var walker = try source.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const dst_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    createDirSafe(io, parent) catch {};
                }
                const src_path = try std.fs.path.join(allocator, &.{ source_dir, entry.path });
                defer allocator.free(src_path);
                try copyFileSafe(io, src_path, dst_path);
            },
            .directory => try createDirSafe(io, dst_path),
            else => continue,
        }
    }
}

const ClientComponentSerializable = struct {
    type: lang.Ast.ClientComponentMetadata.Type,
    id: []const u8,
    name: []const u8,
    path: []const u8,
    import: []const u8,
    route: []const u8,
};

fn writeClientComponents(writer: anytype, allocator: std.mem.Allocator, components: []const ClientComponentSerializable) !void {
    try writer.writeAll("pub const components = [_]zx.client.ComponentMeta{\n");
    if (components.len > 0) {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        std.zon.stringify.serialize(components, .{ .whitespace = true }, &aw.writer) catch @panic("OOM");
        const zon_str = try stripPlaceholders(allocator, aw.written());
        defer allocator.free(zon_str);

        try writer.writeAll(zon_str[2 .. zon_str.len - 1]);
    }
    try writer.writeAll("\n};\n\n");
}

const Route = struct {
    path: []const u8,
    page_import: ?[]const u8 = null,
    layout_import: ?[]const u8 = null,
    notfound_import: ?[]const u8 = null,
    error_import: ?[]const u8 = null,
    route_import: ?[]const u8 = null, // API route import
    proxy_import: ?[]const u8 = null, // Proxy middleware import (cascades at runtime like layouts)

    fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        const fields = [_]?[]const u8{
            self.page_import,
            self.layout_import,
            self.notfound_import,
            self.error_import,
            self.route_import,
            self.proxy_import,
        };
        for (fields) |maybe| if (maybe) |s| allocator.free(s);
    }
};

fn mergeBuildInjectionsFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    manifest: *Manifest,
    build_injections_path: []const u8,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, build_injections_path, allocator, .unlimited);
    defer allocator.free(source);
    if (source.len == 0) return;

    const source_z = try std.mem.concatWithSentinel(allocator, u8, &.{source}, 0);
    defer allocator.free(source_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const build_injections = try std.zon.parse.fromSlice([]const Manifest.AddElementOptions, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = source_z,
        .diagnostics = &diagnostics,
    });

    try manifest.mergeBuildInjections(build_injections);
}

fn genRoutes(io: std.Io, allocator: std.mem.Allocator, output_dir: []const u8, _: ?[]const u8, client_components: []const ClientComponentSerializable, manifest: ?*Manifest, verbose: bool) !void {
    var routes = std.array_list.Managed(Route).init(allocator);
    defer {
        for (routes.items) |*route| route.deinit(allocator);
        routes.deinit();
    }

    // Scan pages directory
    const pages_dir = try std.fs.path.join(allocator, &.{ output_dir, "pages" });
    defer allocator.free(pages_dir);

    const has_pages = fileExists(io, pages_dir);
    if (has_pages) {
        if (verbose) std.debug.print("Scanning pages directory: {s}\n", .{pages_dir});
        var layout_stack = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (layout_stack.items) |layout| allocator.free(layout);
            layout_stack.deinit();
        }
        try scanPagesRecursive(io, allocator, pages_dir, "", &layout_stack, "pages", &routes);
    }

    // Scan routes directory for API routes
    const routes_dir = try std.fs.path.join(allocator, &.{ output_dir, "routes" });
    defer allocator.free(routes_dir);

    const has_routes = fileExists(io, routes_dir);
    if (has_routes) {
        if (verbose) std.debug.print("Scanning routes directory: {s}\n", .{routes_dir});
        try scanRoutesRecursive(io, allocator, routes_dir, "", "routes", &routes);
    }

    if (!has_pages and !has_routes) {
        if (verbose) std.debug.print("No pages or routes directory found, skipping app.zig generation\n", .{});
        return error.NoPagesOrRoutes;
    }

    if (manifest) |m| {
        const entries = try allocator.alloc(Manifest.RouteEntry, routes.items.len);
        defer allocator.free(entries);
        for (routes.items, entries) |route, *entry| {
            entry.* = .{
                .path = route.path,
                .page_import = route.page_import,
                .layout_import = route.layout_import,
                .notfound_import = route.notfound_import,
                .error_import = route.error_import,
                .route_import = route.route_import,
                .proxy_import = route.proxy_import,
            };
        }
        try m.setRoutes(entries);
    }

    var content = std.Io.Writer.Allocating.init(allocator);
    defer content.deinit();
    const writer = &content.writer;

    try writer.writeAll("pub const routes = [_]zx.App.Route{\n");
    for (routes.items) |route| try writeRoute(writer, route);
    try writer.writeAll("};\n\n");

    // Generate a RoutePaths enum of all unique route paths.
    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        try writer.writeAll("pub const RoutePaths = enum {\n");
        for (routes.items) |route| {
            if ((try seen.getOrPut(route.path)).found_existing) continue;
            try writer.print("    @\"{s}\",\n", .{route.path});
        }
        try writer.writeAll("};\n\n");
    }

    try writeClientComponents(writer, allocator, client_components);
    try writer.writeAll("const zx = @import(\"zx\");\n");

    const meta_path = try std.fs.path.join(allocator, &.{ output_dir, "app.zig" });
    defer allocator.free(meta_path);

    const content_z = try allocator.dupeSentinel(u8, content.written(), 0);
    defer allocator.free(content_z);
    var ast = try std.zig.Ast.parse(allocator, content_z, .{ .mode = .zig });
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) return error.ParseError;

    const rendered_zig_source = try ast.renderAlloc(allocator);
    defer allocator.free(rendered_zig_source);

    try writeFile(io, meta_path, rendered_zig_source);

    if (verbose) std.debug.print("Generated app.zig at: {s}\n", .{meta_path});
}

fn writeRoute(writer: anytype, route: Route) !void {
    const indent = "    ";

    try writer.print("{s}.{{\n", .{indent});
    try writer.print("{s}    .path = \"{s}\",\n", .{ indent, route.path });

    // Page (optional for API-only routes)
    if (route.page_import) |page| {
        try writer.print("{s}    .page = @import(\"{s}\"),\n", .{ indent, page });
    }

    if (route.layout_import) |layout| {
        try writer.print("{s}    .layout = @import(\"{s}\"),\n", .{ indent, layout });
    }

    if (route.notfound_import) |notfound| {
        try writer.print("{s}    .notfound = @import(\"{s}\"),\n", .{ indent, notfound });
    }

    if (route.error_import) |err_import| {
        try writer.print("{s}    .@\"error\" = @import(\"{s}\"),\n", .{ indent, err_import });
    }

    // API route handlers (built via route)
    if (route.route_import) |route_import| {
        try writer.print("{s}    .route = @import(\"{s}\"),\n", .{ indent, route_import });
    }

    // Proxy middleware (Proxy() cascades at runtime like layouts, PageProxy/RouteProxy don't cascade)
    if (route.proxy_import) |proxy_import| {
        try writer.print("{s}    .proxy = @import(\"{s}\"),\n", .{ indent, proxy_import });
    }

    try writer.print("{s}}},\n", .{indent});
}

fn scanPagesRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    current_path: []const u8,
    layout_stack: *std.array_list.Managed([]const u8),
    import_prefix: []const u8,
    routes: *std.array_list.Managed(Route),
) !void {
    const has_page = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "page.zig" }));
    const has_route = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "route.zig" }));
    const has_proxy = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "proxy.zig" }));
    const has_layout = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "layout.zig" }));
    const has_notfound = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "notfound.zig" }));
    const has_error = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "error.zig" }));

    var current_layout_import: ?[]const u8 = null;
    if (has_layout) {
        current_layout_import = try std.mem.concat(allocator, u8, &.{ import_prefix, "/layout.zig" });
        try layout_stack.append(current_layout_import.?);
    }

    if (has_page or has_route or has_proxy) {
        const page_import = if (has_page) try std.mem.concat(allocator, u8, &.{ import_prefix, "/page.zig" }) else null;
        const route_import = if (has_route) try std.mem.concat(allocator, u8, &.{ import_prefix, "/route.zig" }) else null;
        const proxy_import = if (has_proxy) try std.mem.concat(allocator, u8, &.{ import_prefix, "/proxy.zig" }) else null;
        const layout_import = if (has_layout) try std.mem.concat(allocator, u8, &.{ import_prefix, "/layout.zig" }) else null;
        const notfound_import = if (has_notfound) try std.mem.concat(allocator, u8, &.{ import_prefix, "/notfound.zig" }) else null;
        const error_import = if (has_error) try std.mem.concat(allocator, u8, &.{ import_prefix, "/error.zig" }) else null;

        const route_path = if (current_path.len == 0)
            try allocator.dupe(u8, "/")
        else
            try allocator.dupe(u8, current_path);
        defer allocator.free(route_path);

        const normalized_route_path = try normalizeRoutePath(allocator, route_path);

        // Only add route if it has a page or route handler (not just proxy)
        if (has_page or has_route) {
            try routes.append(.{
                .path = normalized_route_path,
                .page_import = page_import,
                .route_import = route_import,
                .proxy_import = proxy_import,
                .layout_import = layout_import,
                .notfound_import = notfound_import,
                .error_import = error_import,
            });
        } else {
            allocator.free(normalized_route_path);
            if (page_import) |p| allocator.free(p);
            if (route_import) |r| allocator.free(r);
            if (proxy_import) |pr| allocator.free(pr);
            if (layout_import) |l| allocator.free(l);
            if (notfound_import) |n| allocator.free(n);
            if (error_import) |e| allocator.free(e);
        }
    }

    var dir = try std.Io.Dir.cwd().openDir(io, current_dir, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".zx")) continue;

        const child_dir = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(child_dir);

        const child_path = if (current_path.len == 0 or std.mem.eql(u8, current_path, "/"))
            try std.mem.concat(allocator, u8, &.{ "/", entry.name })
        else
            try std.mem.concat(allocator, u8, &.{ current_path, "/", entry.name });
        defer allocator.free(child_path);

        const child_import_prefix = try std.mem.concat(allocator, u8, &.{ import_prefix, "/", entry.name });
        defer allocator.free(child_import_prefix);

        try scanPagesRecursive(io, allocator, child_dir, child_path, layout_stack, child_import_prefix, routes);
    }

    if (current_layout_import) |layout| {
        _ = layout_stack.pop();
        allocator.free(layout);
    }
}

/// Scan routes directory for API route files (route.zig) and proxy middleware (proxy.zig)
fn scanRoutesRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    current_path: []const u8,
    import_prefix: []const u8,
    routes: *std.array_list.Managed(Route),
) !void {
    const has_route = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "route.zig" }));
    const has_proxy = fileExists(io, try std.fs.path.join(allocator, &.{ current_dir, "proxy.zig" }));

    if (has_route) {
        const route_import = try std.mem.concat(allocator, u8, &.{ import_prefix, "/route.zig" });
        const proxy_import = if (has_proxy) try std.mem.concat(allocator, u8, &.{ import_prefix, "/proxy.zig" }) else null;

        const route_path = if (current_path.len == 0)
            try allocator.dupe(u8, "/")
        else
            try allocator.dupe(u8, current_path);
        defer allocator.free(route_path);

        const normalized_route_path = try normalizeRoutePath(allocator, route_path);

        try routes.append(.{
            .path = normalized_route_path,
            .route_import = route_import,
            .proxy_import = proxy_import,
        });
    }

    var dir = std.Io.Dir.cwd().openDir(io, current_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".zx")) continue;

        const child_dir = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(child_dir);

        const child_path = if (current_path.len == 0 or std.mem.eql(u8, current_path, "/"))
            try std.mem.concat(allocator, u8, &.{ "/", entry.name })
        else
            try std.mem.concat(allocator, u8, &.{ current_path, "/", entry.name });
        defer allocator.free(child_path);

        const child_import_prefix = try std.mem.concat(allocator, u8, &.{ import_prefix, "/", entry.name });
        defer allocator.free(child_import_prefix);

        try scanRoutesRecursive(io, allocator, child_dir, child_path, child_import_prefix, routes);
    }
}

fn transpileFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    global_components: *std.array_list.Managed(ClientComponentSerializable),
    opts: TranspileOptions,
    source_path: []const u8,
    output_path: []const u8,
    imports_out: ?*std.array_list.Managed([]const u8),
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
) !void {
    const source = try readFile(io, allocator, source_path);
    defer allocator.free(source);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    // Convert to relative path for deterministic component IDs and sourcemaps
    var relative_source_path: []const u8 = source_path;
    var rel_path_allocated = false;
    if (std.fs.path.isAbsolute(source_path)) {
        if (std.process.currentPathAlloc(io, allocator)) |cwd| {
            defer allocator.free(cwd);
            if (relativePath(allocator, cwd, source_path)) |rel| {
                relative_source_path = rel;
                rel_path_allocated = true;
            } else |_| {}
        } else |_| {}
    }
    defer if (rel_path_allocated) allocator.free(relative_source_path);

    var result = try lang.Ast.parse(allocator, source_z, .{
        .path = relative_source_path,
        .map = opts.map,
        .lang = sourceLang(source_path),
    });
    defer result.deinit(allocator);

    const ast_source_dir = std.fs.path.dirname(source_path) orelse ".";
    if (imports_out) |out| {
        try collectZxImports(io, allocator, out, &result.zig_ast, ast_source_dir);
    }
    // Copy only companions reachable via `@embedFile` / relative `@import`.
    {
        const ast_out_dir = std.fs.path.dirname(output_path) orelse opts.outdir;
        try collectEmbedFiles(io, allocator, input_files, &result.zig_ast, ast_source_dir, ast_out_dir);
        try collectAndCopyCompanions(io, allocator, input_files, companions_visited, &result.zig_ast, ast_source_dir, ast_out_dir, opts.verbose);
    }

    // Extract route from source path
    const component_route = try extractRouteFromPath(allocator, relative_source_path);
    defer allocator.free(component_route);

    // Append components from this file to the global list
    for (result.client_components.items) |component| {
        const cloned_id = try allocator.dupe(u8, component.id);
        const cloned_name = try allocator.dupe(u8, component.name);
        const cloned_route = try allocator.dupe(u8, component_route);

        var cloned_path: []const u8 = undefined;
        var cloned_import: []const u8 = undefined;

        switch (component.type) {
            .client => {
                // For .client components, use the output .zig file path (relative to output_dir)
                const output_rel_to_dir = try relativePath(allocator, opts.outdir, output_path);
                defer allocator.free(output_rel_to_dir);

                // Remove leading "./" if present
                const clean_path = if (std.mem.startsWith(u8, output_rel_to_dir, "./"))
                    output_rel_to_dir[2..]
                else
                    output_rel_to_dir;

                cloned_path = try allocator.dupe(u8, clean_path);

                // Generate Zig import with componentWithProps wrapper for props hydration.
                // Format: zx.componentWithProps(@import("path").ComponentName)
                // Placeholders (stripped later by stripPlaceholders):
                //   "@ and @" - markers to strip outer quotes from ZON serialization
                //   @@@ - literal @ (for @import)
                //   @@ - literal " (for quotes inside @import())
                cloned_import = try std.fmt.allocPrint(allocator, "@zx.client.ComponentMeta.init(@@@import(@@{s}@@).{s})@", .{ clean_path, component.name });
            },
            else => return error.InvalidComponentType,
        }

        try global_components.append(.{
            .type = component.type,
            .id = cloned_id,
            .name = cloned_name,
            .path = cloned_path,
            .import = cloned_import,
            .route = cloned_route,
        });
    }

    if (std.fs.path.dirname(output_path)) |dir| try createDirSafe(io, dir);
    try writeFile(io, output_path, result.zig_source);

    // Handle position map based on config
    if (result.sourcemap) |*sm| switch (opts.map) {
        .none => {},
        .file => |map_path| {
            const human = try sm.formatHuman(allocator, source, result.zig_source);
            defer allocator.free(human);
            try writeFile(io, map_path, human);
            if (opts.verbose) std.debug.print("Position map: {s}\n", .{map_path});
        },
        .inlined => {
            if (sm.source.len == 0) {
                sm.source = try allocator.dupe(u8, relative_source_path);
            }
            const embed = try sm.formatEmbed(allocator);
            defer allocator.free(embed);
            try writeInlinePositionMap(io, allocator, output_path, embed);
            if (opts.verbose) std.debug.print("Inlined position map in: {s}\n", .{output_path});
        },
    };

    if (opts.verbose) std.debug.print("Transpiled: {s} -> {s}\n", .{ source_path, output_path });
}

fn transpileDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    global_components: *std.array_list.Managed(ClientComponentSerializable),
    input_files: *std.array_list.Managed([]const u8),
    companions_visited: *std.StringHashMap(void),
    opts: TranspileOptions,
    progress: std.Progress.Node,
) !void {
    var task = progress.start("Transpiling .zx files", 0);
    defer task.end();

    // Detect added/removed sources before per-file cache hits; invalidate
    // `.zxcache` when the tree membership changes (renames, new pages, etc.).
    if (opts.cache_dir) |cache_dir| {
        const rels = collectSourceRelPaths(io, allocator, opts.path) catch null;
        if (rels) |owned| {
            defer {
                for (owned) |r| allocator.free(r);
                allocator.free(owned);
            }
            if (sourceTreeFingerprintChanged(io, allocator, cache_dir, owned) catch true) {
                if (opts.verbose) std.debug.print("Source tree changed; invalidating transpile caches\n", .{});
                invalidateZxCaches(io, allocator, cache_dir, opts.verbose) catch |err| {
                    std.debug.print("Warning: Failed to invalidate transpile caches: {}\n", .{err});
                };
            }
        }
    }

    var dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);

    const output_dir_relative = try getOutputDirRelativePath(allocator, opts.path, opts.outdir);
    defer if (output_dir_relative) |rel| allocator.free(rel);

    const sep = std.fs.path.sep_str;

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        task.completeOne();
        var actual_kind = entry.kind;
        if (entry.kind == .sym_link) {
            const entry_stat = dir.statFile(io, entry.path, .{}) catch continue;
            actual_kind = entry_stat.kind;
        }

        if (actual_kind != .file) continue;

        if (output_dir_relative) |rel| {
            if (std.mem.startsWith(u8, entry.path, rel)) {
                if (entry.path.len == rel.len) {
                    continue;
                }
                if (std.mem.startsWith(u8, entry.path[rel.len..], sep)) {
                    continue;
                }
            }
        }

        const is_zx = std.mem.endsWith(u8, entry.path, ".zx");
        const is_mdzx = std.mem.endsWith(u8, entry.path, ".mdzx");
        const is_md = std.mem.endsWith(u8, entry.path, ".md") and !is_mdzx;

        const input_path = try std.fs.path.join(allocator, &.{ opts.path, entry.path });
        defer allocator.free(input_path);

        if (is_zx or is_mdzx or is_md) {
            const ext_len = zxExtLen(entry.path).?;
            const output_rel_path = try std.mem.concat(allocator, u8, &.{
                entry.path[0 .. entry.path.len - ext_len],
                ".zig",
            });
            defer allocator.free(output_rel_path);

            const output_path = try std.fs.path.join(allocator, &.{ opts.outdir, output_rel_path });
            defer allocator.free(output_path);

            // Track this input for the dep file (absolute path for Make format).
            // Embedded-file deps are collected by `transpileFile` via the AST.
            const abs_input = std.fs.path.resolve(allocator, &.{input_path}) catch
                try allocator.dupe(u8, input_path);
            try input_files.append(abs_input);

            const cache_base = opts.cache_dir orelse opts.outdir;
            const cache_out_path = try std.fs.path.join(allocator, &.{ cache_base, output_rel_path });
            defer allocator.free(cache_out_path);

            // Cache file alongside the .zig output (not .zig extension so compiler ignores it)
            const cache_path = try std.mem.concat(allocator, u8, &.{ cache_out_path, ".zxcache" });
            defer allocator.free(cache_path);

            // Check if output is up-to-date (mtime + matching Transpile.shape in .zxcache)
            const should_skip = blk: {
                const input_stat = std.Io.Dir.cwd().statFile(io, input_path, .{}) catch break :blk false;
                const cache_stat = std.Io.Dir.cwd().statFile(io, cache_out_path, .{}) catch break :blk false;
                std.Io.Dir.cwd().access(io, cache_path, .{}) catch break :blk false;
                if (cache_stat.mtime.nanoseconds < input_stat.mtime.nanoseconds) break :blk false;
                // Shape mismatch / legacy `.zxcache` (bare component array) → retranspile
                readComponentCache(io, allocator, cache_path, global_components) catch break :blk false;
                break :blk true;
            };

            if (should_skip) {
                if (opts.cache_dir) |_| {
                    if (std.fs.path.dirname(output_path)) |parent_dir| {
                        std.Io.Dir.cwd().createDirPath(io, parent_dir) catch {};
                    }
                    std.Io.Dir.cwd().copyFile(cache_out_path, std.Io.Dir.cwd(), output_path, io, .{}) catch |err| {
                        std.debug.print("Warning: Failed to copy cached file {s} to {s}: {}\n", .{ cache_out_path, output_path, err });
                    };
                }
                // Transpilation was skipped - replay companion copies from the
                // cached `.zig` (`@embedFile` + relative `@import`s).
                {
                    const embed_src_dir = std.fs.path.dirname(input_path) orelse ".";
                    const embed_out_dir = std.fs.path.dirname(output_path) orelse opts.outdir;
                    copyCompanionsForCached(io, allocator, input_files, companions_visited, cache_out_path, embed_src_dir, embed_out_dir, opts.verbose) catch |err| {
                        std.debug.print("Warning: Failed to copy companions for cached {s}: {}\n", .{ input_path, err });
                    };
                }
                if (opts.verbose) std.debug.print("Skipped (up-to-date): {s}\n", .{input_path});
            } else {
                const components_before = global_components.items.len;
                transpileFile(io, allocator, global_components, opts, input_path, output_path, null, input_files, companions_visited) catch |err| {
                    global_components.items.len = components_before;
                    std.debug.print("Error transpiling {s}: {}\n", .{ input_path, err });
                    continue;
                };

                if (opts.cache_dir) |_| {
                    if (std.fs.path.dirname(cache_out_path)) |parent_dir| {
                        std.Io.Dir.cwd().createDirPath(io, parent_dir) catch {};
                    }
                    std.Io.Dir.cwd().copyFile(output_path, std.Io.Dir.cwd(), cache_out_path, io, .{}) catch |err| {
                        std.debug.print("Warning: Failed to update cache file {s}: {}\n", .{ cache_out_path, err });
                    };
                }

                writeComponentCache(io, allocator, cache_path, global_components.items[components_before..]) catch |err| {
                    std.debug.print("Warning: Failed to write component cache for {s}: {}\n", .{ input_path, err });
                };
            }
        } else if (isFsRouteZigRoot(getBasename(entry.path)) and !hasZxTwin(io, input_path)) {
            // Hand-written filesystem-routing roots (`route.zig`, `proxy.zig`, …)
            // with no `.zx` twin - copy and follow their import/embed graph.
            const output_path = try std.fs.path.join(allocator, &.{ opts.outdir, entry.path });
            defer allocator.free(output_path);
            copyCompanionRecursive(io, allocator, input_files, companions_visited, input_path, output_path, opts.verbose) catch |err| {
                std.debug.print("Warning: Failed to copy route root {s}: {}\n", .{ input_path, err });
            };
        }
    }
}

const TranspileOptions = struct {
    path: []const u8,
    outdir: []const u8,
    verbose: bool,
    map: lang.Ast.ParseOptions.MapMode = .none,
    dep_file: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    base_path: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    build_injections: ?[]const u8 = null,
    exe_path: ?[]const u8 = null,
};

fn transpileCommand(io: std.Io, allocator: std.mem.Allocator, opts: TranspileOptions) !void {
    var manifest: ?Manifest = null;
    if (opts.manifest) |manifest_path| {
        manifest = Manifest.init(io, allocator, manifest_path) catch |err| {
            std.debug.print("Warning: Failed to open manifest: {}\n", .{err});
            return;
        };

        if (opts.build_injections) |build_injections_path| {
            mergeBuildInjectionsFromFile(io, allocator, &manifest.?, build_injections_path) catch |err| {
                std.debug.print("Warning: Failed to merge build injections into manifest: {}\n", .{err});
            };
        }
        if (opts.exe_path) |exe_path| {
            manifest.?.exe_path = allocator.dupe(u8, exe_path) catch |err| {
                std.debug.print("Warning: Failed to set executable path in manifest: {}\n", .{err});
                return;
            };
        }
        manifest.?.transpile_dir = allocator.dupe(u8, opts.outdir) catch |err| {
            std.debug.print("Warning: Failed to set transpile_dir in manifest: {}\n", .{err});
            return;
        };
    }
    defer if (manifest) |*m| m.deinit();

    // Start root progress for the entire transpile operation
    var progress = std.Progress.start(io, .{ .root_name = "Transpile" });
    defer progress.end();

    var all_client_cmps = std.array_list.Managed(ClientComponentSerializable).init(allocator);
    defer {
        for (all_client_cmps.items) |*component| {
            allocator.free(component.id);
            allocator.free(component.name);
            allocator.free(component.path);
            allocator.free(component.import);
            allocator.free(component.route);
        }
        all_client_cmps.deinit();
    }

    var input_files = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (input_files.items) |f| allocator.free(f);
        input_files.deinit();
    }

    var companions_visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = companions_visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        companions_visited.deinit();
    }

    const stat = std.Io.Dir.cwd().statFile(io, opts.path, .{}) catch |err| switch (err) {
        error.IsDir => std.Io.File.Stat{
            .inode = 0,
            .size = 0,
            .nlink = 0,
            .permissions = .default_dir,
            .kind = .directory,
            .atime = null,
            .mtime = .{ .nanoseconds = 0 },
            .ctime = .{ .nanoseconds = 0 },
            .block_size = 4096,
        },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ opts.path, err });
            return err;
        },
    };

    switch (stat.kind) {
        .directory => {
            try transpileDirectory(io, allocator, &all_client_cmps, &input_files, &companions_visited, opts, progress);
        },
        .file => {
            const is_zx = std.mem.endsWith(u8, opts.path, ".zx");
            const is_mdzx = std.mem.endsWith(u8, opts.path, ".mdzx");
            const is_md = std.mem.endsWith(u8, opts.path, ".md") and !is_mdzx;

            if (!is_zx and !is_mdzx and !is_md) {
                std.debug.print("Error: File must have .zx, .mdzx, or .md extension, got '{s}'\n", .{opts.path});
                return error.InvalidFileExtension;
            }

            var task = progress.start("Transpiling file", 1);
            defer task.end();

            const basename = getBasename(opts.path);
            const ext_len = zxExtLen(opts.path).?;
            const output_rel_path = try std.mem.concat(allocator, u8, &.{ basename[0 .. basename.len - ext_len], ".zig" });
            defer allocator.free(output_rel_path);
            const outpath = try std.fs.path.join(allocator, &.{ opts.outdir, output_rel_path });
            defer allocator.free(outpath);

            var visited = std.StringHashMap(void).init(allocator);
            defer {
                var it = visited.keyIterator();
                while (it.next()) |k| allocator.free(k.*);
                visited.deinit();
            }
            try transpileFileRecursive(io, allocator, &all_client_cmps, opts, opts.path, outpath, &visited, &input_files, &companions_visited);
            task.completeOne();
        },
        else => {
            std.debug.print("Error: Path must be a file or directory\n", .{});
            return error.InvalidPath;
        },
    }

    // Persistent outdirs retain deleted pages unless pruned before route generation.
    if (stat.kind == .directory and opts.cache_dir != null) {
        pruneStaleOutdir(io, allocator, opts.path, opts.outdir, opts.verbose) catch |err| {
            std.debug.print("Warning: Failed to prune stale transpile outputs: {}\n", .{err});
        };
    }

    if (stat.kind == .directory) {
        if (opts.cache_dir) |cache_dir| {
            const rels = collectSourceRelPaths(io, allocator, opts.path) catch null;
            if (rels) |owned| {
                defer {
                    for (owned) |r| allocator.free(r);
                    allocator.free(owned);
                }
                writeSourceTreeFingerprint(io, allocator, cache_dir, owned) catch |err| {
                    std.debug.print("Warning: Failed to write source tree fingerprint: {}\n", .{err});
                };
            }
        }
    }

    if (opts.dep_file) |dep_file_path| {
        writeDepFile(io, allocator, dep_file_path, dep_file_path, input_files.items) catch |err| {
            std.debug.print("Warning: Failed to write dep file: {}\n", .{err});
        };
    }

    // --- @rendering -> Client Side Rendering Related Files Generation --- //
    var client_cmps = std.array_list.Managed(ClientComponentSerializable).init(allocator);
    defer client_cmps.deinit();

    for (all_client_cmps.items) |component| {
        switch (component.type) {
            .client => try client_cmps.append(component),
            else => return error.InvalidComponentType,
        }
    }

    // Generate app.zig with routes and client components
    genRoutes(io, allocator, opts.outdir, opts.base_path, client_cmps.items, if (manifest) |*m| m else null, opts.verbose) catch |err| switch (err) {
        error.NoPagesOrRoutes => {}, // No routes to generate is not an error
        else => std.debug.print("Warning: Failed to generate app.zig: {}\n", .{err}),
    };

    // => manifest/app.zon
    if (manifest) |*m| {
        m.commit(io) catch |err| {
            std.debug.print("Warning: Failed to write manifest: {}\n", .{err});
        };
    }
}
