const std = @import("std");
const esbuild = @import("esbuild");
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    _ = target;
    const from_source = b.option(bool, "from-source", "Build JS bindings from TypeScript (esbuild) instead of the prebuilt npm package") orelse false;
    const type_decl = b.option(bool, "type-decl", "Generate type declarations (from-source only)") orelse true;
    const version = b.option([]const u8, "version", "npm package version to embed") orelse build_zon.version;
    const is_release = optimize != .debug;

    // Feature flags (match InitOptions / app_opts). Default true so the published
    // npm package includes all bindings; `.build = .enabled` apps pass the app's flags.
    const feat_kv_client = b.option(bool, "feature-kv-client", "Include browser KV client bindings") orelse true;
    const feat_kv_server = b.option(bool, "feature-kv-server", "Include server/edge KV bindings") orelse true;
    const feat_fs_client = b.option(bool, "feature-fs-client", "Include the browser file system (OPFS)") orelse true;
    const feat_sqlite = b.option(bool, "feature-sqlite", "Include SQLite/D1 database bindings") orelse true;
    const feat_wasm_client = b.option(bool, "feature-wasm-client", "Include browser wasm init bindings") orelse true;

    // --- Codegen (manual only; committed outputs live under src/wasm/generated/) --- //
    const tags_gen = addTagsCodegen(b);
    const events_gen = addEventsCodegen(b);
    const tagsgen_step = b.step("tagsgen", "Regenerate src/wasm/generated/tags.ts from ElementTag");
    tagsgen_step.dependOn(&tags_gen.step);
    const eventsgen_step = b.step("delegatedeventsgen", "Regenerate src/wasm/generated/events.ts from EventType");
    eventsgen_step.dependOn(&events_gen.step);

    const dist_files = b.addNamedWriteFiles("ziex_js");

    if (!from_source) {
        // --- Prebuilt npm package --- //
        if (b.lazyDependency("prebuilt", .{})) |prebuilt| {
            _ = dist_files.addCopyDirectory(prebuilt.path("."), "", .{});
        }
    } else {
        try buildFromSource(b, dist_files, .{
            .is_release = is_release,
            .type_decl = type_decl,
            .version = version,
            .feat_kv_client = feat_kv_client,
            .feat_kv_server = feat_kv_server,
            .feat_fs_client = feat_fs_client,
            .feat_sqlite = feat_sqlite,
            .feat_wasm_client = feat_wasm_client,
        });
    }

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = dist_files.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    }).step);
}

const FromSourceOptions = struct {
    is_release: bool,
    type_decl: bool,
    version: []const u8,
    feat_kv_client: bool,
    feat_kv_server: bool,
    feat_fs_client: bool,
    feat_sqlite: bool,
    feat_wasm_client: bool,
};

fn buildFromSource(b: *std.Build, dist_files: *std.Build.Step.WriteFile, opts: FromSourceOptions) !void {
    const feature_defines = featureDefines(b, opts.feat_kv_client, opts.feat_kv_server, opts.feat_fs_client, opts.feat_sqlite, opts.feat_wasm_client);

    // --- JS bundles (esbuild) --- //
    const packages = esbuild.addBuild(b, .{
        .name = "ziex",
        .config = .{
            .entrypoints = &.{
                b.path("src/index.ts"),
                b.path("src/jsx/index.ts"),
                b.path("src/wasm/index.ts"),
                b.path("src/runtime/kv.ts"),
                b.path("src/runtime/db.ts"),
                b.path("src/runtime/email.ts"),
                b.path("src/runtime/bucket.ts"),
                b.path("src/platforms/cloudflare/index.ts"),
                b.path("src/platforms/aws-lambda/index.ts"),
                b.path("src/platforms/vercel/index.ts"),
            },
            .format = .esm,
            .platform = .neutral,
            .minify = opts.is_release,
            .define = try mergeDefines(b, &.{
                .{ .key = "__DEV__", .value = if (opts.is_release) "false" else "true" },
            }, feature_defines),
        },
    });

    const wasm_init = esbuild.addBuild(b, .{
        .name = "wasm_init",
        .config = .{
            .entrypoints = &.{b.path("src/wasm/init.ts")},
            .format = .esm,
            .platform = .browser,
            .minify = true,
            .define = try mergeDefines(b, &.{
                .{ .key = "__DEV__", .value = "false" },
            }, feature_defines),
        },
    });

    const wasm_init_dev = esbuild.addBuild(b, .{
        .name = "wasm_init_dev",
        .config = .{
            .entrypoints = &.{b.path("src/wasm/init.ts")},
            .format = .esm,
            .platform = .browser,
            .minify = false,
            .define = try mergeDefines(b, &.{
                .{ .key = "__DEV__", .value = "true" },
            }, feature_defines),
        },
    });

    // --- App init files --- //
    {
        _ = dist_files.addCopyFile(wasm_init.dir.path(b, "init.js"), "wasm/init.js");
        _ = dist_files.addCopyFile(wasm_init_dev.dir.path(b, "init.js"), "wasm/init.dev.js");
    }

    // --- Static package files --- //
    {
        _ = dist_files.addCopyFile(try makePublishPackageJson(b, opts.version), "package.json");
        _ = dist_files.addCopyFile(b.path("../../README.md"), "README.md");
        _ = dist_files.addCopyFile(b.path("bin/ziex"), "bin/ziex");
        _ = dist_files.addCopyFile(makePublishBuildZig(b), "build.zig");
        _ = dist_files.addCopyFile(try makePublishBuildZigZon(b), "build.zig.zon");

        // --- Other bindings --- //
        _ = dist_files.addCopyDirectory(packages.dir, "", .{});
    }

    // --- TypeScript declarations --- //
    if (opts.type_decl) {
        const typescript = @import("typescript");
        const dts = typescript.addBuild(b, .{
            .name = "ziex.d.ts",
            .config = .{
                .project = b.path("tsconfig.json"),
            },
        });
        _ = dist_files.addCopyDirectory(dts.dir.path(b, "pkg/ziex/src"), "", .{});
    }
}

fn featureDefines(
    b: *std.Build,
    feat_kv_client: bool,
    feat_kv_server: bool,
    feat_fs_client: bool,
    feat_sqlite: bool,
    feat_wasm_client: bool,
) []const esbuild.BuildConfig.Define {
    return b.allocator.dupe(esbuild.BuildConfig.Define, &.{
        .{ .key = "__FEAT_KV__", .value = if (feat_kv_client) "true" else "false" },
        .{ .key = "__FEAT_KV_SERVER__", .value = if (feat_kv_server) "true" else "false" },
        .{ .key = "__FEAT_FS__", .value = if (feat_fs_client) "true" else "false" },
        .{ .key = "__FEAT_DB__", .value = if (feat_sqlite) "true" else "false" },
        .{ .key = "__FEAT_WASM__", .value = if (feat_wasm_client) "true" else "false" },
    }) catch @panic("OOM");
}

/// Regenerate `src/wasm/generated/tags.ts` from `src/element.zig` `Tag` enum.
fn addTagsCodegen(b: *std.Build) *std.Build.Step.Run {
    const host = b.graph.host;
    const gen_exe = b.addExecutable(.{
        .name = "gen_tags",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_tags.zig"),
            .target = host,
            .imports = &.{
                .{ .name = "element", .module = b.createModule(.{
                    .root_source_file = b.path("../../src/element.zig"),
                    .target = host,
                }) },
            },
        }),
    });
    const run = b.addRunArtifact(gen_exe);
    run.setCwd(b.path("."));
    run.addArg("src/wasm/generated/tags.ts");
    run.addArg("src/wasm/generated/tag_indices.ts");
    return run;
}

/// Regenerate `src/wasm/generated/events.ts` from `EventType`.
fn addEventsCodegen(b: *std.Build) *std.Build.Step.Run {
    const host = b.graph.host;
    const gen_exe = b.addExecutable(.{
        .name = "gen_delegated_events",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_delegated_events.zig"),
            .target = host,
            .imports = &.{
                .{ .name = "event_type", .module = b.createModule(.{
                    .root_source_file = b.path("../../src/runtime/client/event_type.zig"),
                    .target = host,
                }) },
            },
        }),
    });
    const run = b.addRunArtifact(gen_exe);
    run.setCwd(b.path("."));
    run.addArg("src/wasm/generated/events.ts");
    run.addArg("src/wasm/generated/event_bits.ts");
    return run;
}

fn mergeDefines(
    b: *std.Build,
    base: []const esbuild.BuildConfig.Define,
    extra: []const esbuild.BuildConfig.Define,
) ![]const esbuild.BuildConfig.Define {
    const out = try b.allocator.alloc(esbuild.BuildConfig.Define, base.len + extra.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

fn makePublishBuildZig(b: *std.Build) std.Build.LazyPath {
    return b.addWriteFiles().add(
        "build.zig",
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    _ = b; // stub
        \\}
        \\
        ,
    );
}

fn makePublishBuildZigZon(b: *std.Build) !std.Build.LazyPath {
    // Re-serialize the package manifest without `.dependencies` (build-only plugins).
    const publish = .{
        .name = build_zon.name,
        .fingerprint = build_zon.fingerprint,
        .version = build_zon.version,
        .minimum_zig_version = build_zon.minimum_zig_version,
        .paths = build_zon.paths,
    };

    var aw: std.Io.Writer.Allocating = .init(b.allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(publish, .{ .whitespace = true }, &aw.writer);
    try aw.writer.writeByte('\n');

    const out = try b.allocator.dupe(u8, aw.written());
    defer b.allocator.free(out);
    return b.addWriteFiles().add("build.zig.zon", out);
}

fn makePublishPackageJson(b: *std.Build, version: []const u8) !std.Build.LazyPath {
    const src = try b.root.root_dir.handle.readFileAlloc(b.graph.io, "package.json", b.allocator, .unlimited);
    defer b.allocator.free(src);

    var parsed = try std.json.parseFromSlice(std.json.Value, b.allocator, src, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    try obj.put(b.allocator, "version", .{ .string = version });
    try obj.put(b.allocator, "main", .{ .string = "index.js" });
    try obj.put(b.allocator, "module", .{ .string = "index.js" });
    try obj.put(b.allocator, "types", .{ .string = "index.d.ts" });
    try obj.put(b.allocator, "scripts", .{ .object = .empty });
    _ = obj.swapRemove("private");
    _ = obj.swapRemove("devDependencies");
    _ = obj.swapRemove("peerDependencies");
    _ = obj.swapRemove("release");
    _ = obj.swapRemove("prettier");

    // Keep the CLI dependency pinned to the same version we are publishing.
    if (obj.getPtr("dependencies")) |deps_val| {
        if (deps_val.* == .object) {
            if (deps_val.object.getPtr("@ziex/cli")) |cli_dep| {
                cli_dep.* = .{ .string = version };
            }
        }
    }

    const json = try std.json.Stringify.valueAlloc(b.allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer b.allocator.free(json);
    const out = try std.mem.concat(b.allocator, u8, &.{ json, "\n" });
    defer b.allocator.free(out);

    return b.addWriteFiles().add("package.json", out);
}
