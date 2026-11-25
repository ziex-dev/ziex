const std = @import("std");
const html_util = @import("../util/html.zig");
const build_zig = @import("../../build.zig");
const CliConstant = @import("../cli/shared/constant.zig");
const WorkerName = @import("../runtime/core/Worker/name.zig");
pub const InitOptions = @import("init/InitOptions.zig");
pub const BuildConfig = @import("init/BuildConfig.zig");

const LazyPath = std.Build.LazyPath;
const AddElementOptions = @import("../Build.zig").AddElementOptions;

pub fn init(b: *std.Build, exe: *std.Build.Step.Compile, options: InitOptions) !Build {
    const target = exe.root_module.resolved_target;
    const optimize = exe.root_module.optimize;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });

    const ziex_lsp = b.option(bool, "ziex-lsp", "Enable `zig build zx -- lsp`, used by code editors whenz `zx` cli is not in PATH") orelse false;
    const zig_path = options.cli.zig_path orelse b.graph.zig_exe;

    const server_backend = if (options.app) |app| app.server.backend else InitOptions.AppOptions.Server.Backend.auto;
    const is_wasi = if (target) |t| t.result.os.tag == .wasi else false;
    const enable_httpz = !is_wasi and switch (server_backend) {
        // .auto => optimize != .debug,
        .auto => true, // default to httpz for now
        .httpz => true,
        .std => false,
    };

    const zx_dep = b.dependencyFromBuildZig(build_zig, .{
        .optimize = optimize,
        .target = target,

        .@"feature-sqlite" = if (options.app != null and options.app.?.features.sqlite != null) true else null,
        .@"feature-postgres" = if (options.app != null and options.app.?.features.postgres != null) true else null,

        .@"enable-httpz" = enable_httpz,
        .lsp = false,
    });

    const zx_host_dep = b.dependencyFromBuildZig(build_zig, .{
        .optimize = options.cli.optimize,
        .lsp = ziex_lsp,
        .@"cli-log-level" = options.cli.log_level,
    });

    const zx_cli = zx_host_dep.artifact("zx");

    const client = if (options.app) |app| app.client else InitOptions.ClientOptions.default;
    const features = if (options.app) |app| app.features else InitOptions.AppOptions.FeatureOptions.default;

    const build_client_wasm = client.wasm.link;
    const wasm_optimize = client.wasm.optimize orelse optimize;

    const zx_module = zx_dep.module("zx");
    const zx_wasm_module: ?*std.Build.Module = if (build_client_wasm) blk: {
        const zx_wasm_dep = b.dependencyFromBuildZig(build_zig, .{
            .optimize = wasm_optimize,
            .target = wasm_target,

            .lsp = false,
            .@"is-client" = true,
            .@"feature-sqlite" = if (features.sqlite) |s| s.client != null else false,
        });
        break :blk zx_wasm_dep.module("zx");
    } else null;
    // `zx.worker` wasm: sqlite here doesn't reach the page's wasm.
    const zx_worker_module: ?*std.Build.Module = if (build_client_wasm) blk: {
        const zx_worker_dep = b.dependencyFromBuildZig(build_zig, .{
            .optimize = wasm_optimize,
            .target = wasm_target,

            .lsp = false,
            .@"is-client" = true,
            .@"feature-sqlite" = if (features.sqlite) |s| s.client != null or s.worker != null else false,
        });
        break :blk zx_worker_dep.module("zx");
    } else null;

    const ziex_js_root: LazyPath = blk: {
        const from_source = client.bindings.build != null;
        const ziex_js_dep = zx_dep.builder.lazyDependency("ziex_js", .{
            .optimize = optimize,
            .target = target,
            .@"from-source" = from_source,
            .@"type-decl" = false,
            .@"feature-kv-client" = if (features.kv) |k| k.client != null else false,
            .@"feature-kv-server" = if (features.kv) |k| k.server != null else false,
            .@"feature-fs-client" = (if (features.fs) |f| f.client != null else false) or
                (if (features.sqlite) |s| s.client != null else false),
            .@"feature-sqlite" = if (features.sqlite) |s| s.server != null else false,
            .@"feature-wasm-client" = build_client_wasm,
        }) orelse break :blk b.path(".");
        break :blk ziex_js_dep.namedWriteFiles("ziex_js").getDirectory();
    };

    var opts: Resolved = .{
        .base_path = null,
        .site_path = b.path("app"),
        .cli_path = null,
        .steps = .default,
        .client = client,
        .static_path = options.static_path,
        .ziex_js_root = ziex_js_root,
        .version = options.version,
        .server_only_stub_mode = .strict,
        .zig_path = zig_path,
        .zx_module_path = blk: {
            const dep_root = zx_host_dep.builder.root.root_dir.path orelse ".";
            const joined = if (std.fs.path.isAbsolute(dep_root))
                b.pathJoin(&.{ dep_root, "src", "root.zig" })
            else
                std.fs.path.resolve(b.allocator, &.{
                    b.root.root_dir.path orelse ".",
                    dep_root,
                    "src",
                    "root.zig",
                }) catch b.pathJoin(&.{ dep_root, "src", "root.zig" });
            break :blk std.fs.path.resolve(b.allocator, &.{joined}) catch joined;
        },
    };

    if (options.app) |site_opts| {
        opts.site_path = site_opts.path orelse opts.site_path;
        opts.base_path = site_opts.base_path;
        opts.features = site_opts.features;
    }

    opts.cli_path = options.cli.path;

    if (opts.cli_path == null) {
        const build_zon = @import("../../build.zig.zon");
        if (findZxInPath(b, build_zon.version)) |zx_path| {
            // std.debug.print("ziex: using zx from system path: {s}\n", .{zx_path});
            opts.cli_path = .{ .cwd_relative = zx_path };
        } else {
            // std.debug.print("ziex: building zx from source\n", .{});
        }
    }

    if (options.cli.steps) |cli_steps| {
        opts.steps = cli_steps;
    }

    // --- Ziex Options --- //
    const config = buildConfig(b);
    const cli_command: []const u8 = if (config.command) |c| @tagName(c) else "--";
    const is_dev_build = config.command == .dev;
    const incremental = config.incremental;

    // An edge build with `--prerender` gets its prerendered routes from the
    // static dir, so the worker never runs them and needn't contain them.
    const is_edge = if (exe.root_module.resolved_target) |t| t.result.os.tag == .wasi else false;
    const app_opts = addAppOpts(b, .{
        .base_path = opts.base_path,
        .server_port = config.port,
        .server_address = config.address,
        .cli_command = cli_command,
        .enable_httpz = enable_httpz,
        .features = opts.features,
        .omit_prerendered = is_edge and config.prerender and config.command == null,
    });
    zx_module.addOptions("app_opts", app_opts);

    // --- Dirs Setup --- //
    const static_lazypath = b.graph.path(.install_prefix, "static");
    const assetsdir = static_lazypath.path(b, "assets");

    // --- ZX Transpilation ---
    const transpile_store = b.graph.path(.local_cache, CliConstant.ziex_cache_dirname).path(b, CliConstant.transpile_store_dirname);
    const transpile_cmd = cliRun(b, zx_cli, opts);
    transpile_cmd.setName("translate-zx");
    transpile_cmd.addArg("transpile");
    transpile_cmd.addDirectoryArg(opts.site_path);
    // transpile_cmd.addArg("--verbose");
    transpile_cmd.addArg("--outdir");
    transpile_cmd.addDirectoryArg(transpile_store);
    transpile_cmd.addArg("--dep-file");
    _ = transpile_cmd.addDepFileOutputArg("transpile.d");
    if (opts.base_path) |bp| {
        transpile_cmd.addArgs(&.{ "--base-path", bp });
    }
    // Always generate inlined position maps so dev mode can remap errors to .zx files
    transpile_cmd.addArgs(&.{ "--map", "inline" });
    // Persistent transpile cache (mtime + Transpile.shape); survives zig-cache invalidation.
    transpile_cmd.addArgs(&.{"--cache-dir"});
    transpile_cmd.addDirectoryArg(transpile_store);
    transpile_cmd.expectExitCode(0);
    // Imports are tracked by the dep file; the route list covers added/removed routes.
    transpile_cmd.addArg("--roots");
    transpile_cmd.addFileArg(b.addWriteFiles().add("routes", routeRoots(b, opts.site_path)));

    const uses_local_bindings = opts.client.bindings.href == null;
    const use_stable_assets = is_dev_build or optimize == .debug;
    const client_asset_stem = if (is_dev_build) "app.dev" else "app";
    const client_asset_href_stem = html_util.prefixPathWithBasePath(
        b.allocator,
        opts.base_path,
        if (is_dev_build) "/assets/_/app.dev" else "/assets/_/app",
    );
    // --- Static Directory Setup --- //
    var static_install_steps: [2]?*std.Build.Step = .{ null, null };
    {
        const site_sub_path = opts.site_path.src_path.sub_path;
        if (b.root.access(b.graph.io, site_sub_path, .{})) |_| {
            b.dependOnDirectoryContents(opts.site_path);
        } else |_| {
            b.dependOnDirectoryContents(b.path(std.fs.path.dirname(site_sub_path) orelse ""));
        }

        const public_dir = opts.site_path.path(b, "public");
        if (b.root.access(b.graph.io, public_dir.src_path.sub_path, .{})) |_| {
            const install_static = b.addInstallDirectory(.{
                .source_dir = public_dir,
                .install_dir = .prefix,
                .install_subdir = "static",
            });
            install_static.step.name = "install public/";
            exe.step.dependOn(&install_static.step);
            static_install_steps[0] = &install_static.step;
        } else |_| {}

        const assets_dir = opts.site_path.path(b, "assets");
        if (b.root.access(b.graph.io, assets_dir.src_path.sub_path, .{})) |_| {
            const install_assets = b.addInstallDirectory(.{
                .source_dir = assets_dir,
                .install_dir = .prefix,
                .install_subdir = "static/assets",
            });
            install_assets.step.name = "install assets/";
            exe.step.dependOn(&install_assets.step);
            static_install_steps[1] = &install_assets.step;
        } else |_| {}
    }

    const link_client_bindings = opts.client.bindings.link;

    // --- JS Bindings Package Install --- //
    if (opts.client.bindings.install_subdir) |subdir| {
        const install_pkg = b.addInstallDirectory(.{
            .source_dir = opts.ziex_js_root,
            .install_dir = .prefix,
            .include_extensions = &.{ ".js", ".ts" },
            .install_subdir = subdir,
        });
        install_pkg.step.name = "install js bindings package";
        b.getInstallStep().dependOn(&install_pkg.step);
    }

    // --- Ziex Injections --- //
    const injections = try b.allocator.create(Injections);
    injections.* = .{};
    for (opts.element_injections) |inj| {
        injections.add(b, inj);
    }
    if (link_client_bindings) {
        if (opts.client.bindings.href) |bindings_href| {
            const href = if (std.mem.startsWith(u8, bindings_href, "http://") or std.mem.startsWith(u8, bindings_href, "https://"))
                bindings_href
            else
                html_util.prefixPathWithBasePath(b.allocator, opts.base_path, bindings_href);
            injections.add(b, .{
                .parent = .head,
                .position = .ending,
                .id = AddElementOptions.Id.jsglue,
                .element = .{
                    .tag = .script,
                    .attributes = &.{
                        .{ .name = "defer" },
                        .{ .name = "src", .value = b.fmt("{s}", .{href}) },
                    },
                },
            });
        } else if (use_stable_assets and build_client_wasm) {
            injections.add(b, .{
                .parent = .head,
                .position = .ending,
                .id = AddElementOptions.Id.jsglue,
                .element = .{
                    .tag = .script,
                    .attributes = &.{
                        .{ .name = "defer" },
                        .{ .name = "src", .value = b.fmt("{s}.js", .{client_asset_href_stem}) },
                    },
                },
            });
        }
    }

    if (build_client_wasm and use_stable_assets) {
        injections.add(b, .{
            .parent = .head,
            .position = .ending,
            .id = AddElementOptions.Id.wasmlink,
            .element = .{
                .tag = .link,
                .attributes = &.{
                    .{ .name = "id", .value = "__$wasmlink" },
                    .{ .name = "rel", .value = "preload" },
                    .{ .name = "as", .value = "fetch" },
                    .{ .name = "href", .value = b.fmt("{s}.wasm", .{client_asset_href_stem}) },
                    .{ .name = "crossorigin" },
                },
            },
        });
    }

    const manifest_seed = try injections.seedBuildInjections(b);
    transpile_cmd.addArg("--build-injections");
    transpile_cmd.addFileArg(manifest_seed);

    transpile_cmd.addArg("--manifest");
    const base_manifest_path = transpile_cmd.addOutputFileArg("app.zon");
    transpile_cmd.addArgs(&.{"--exe-path"});
    transpile_cmd.addArg(b.fmt("bin/{s}", .{exe.out_filename}));
    exe.step.dependOn(&transpile_cmd.step);

    // --- Ziex Site Main Executable --- //
    var user_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    var import_it = exe.root_module.import_table.iterator();
    while (import_it.next()) |entry| {
        try user_imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* });
    }

    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    for (user_imports.items) |import| {
        try imports.append(import);
    }

    // Copy all imports from the original zx_module
    var zx_import_it = zx_module.import_table.iterator();
    while (zx_import_it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "app")) {
            try imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* });
        }
    }

    // Build imports for the "app" module (app.zig needs access to zx and all other imports)
    var meta_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    for (imports.items) |import| {
        try meta_imports.append(import);
    }
    try meta_imports.append(.{ .name = "zx", .module = zx_module });

    // Inject the real generated app module into zx and directly into the user's root module
    const app_module = b.createModule(.{
        .root_source_file = transpile_store.path(b, "app.zig"),
        .imports = meta_imports.items,
    });
    app_module.addImport("app", app_module);
    zx_module.addImport("app", app_module);
    exe.root_module.addImport("app", app_module);
    exe.root_module.addImport("zx", zx_module);
    if (exe.root_module.resolved_target) |t| {
        if (t.result.os.tag == .wasi) {
            exe.rdynamic = true;
            exe.export_memory = true;
            // Edge runtimes instantiate a fresh memory per request, so the 16 MiB default stack is paid every time.
            if (exe.stack_size == null) exe.stack_size = 2 << 20;
        }
    }

    exe.step.dependOn(&transpile_cmd.step);
    exe.step.name = b.fmt("install server exe", .{});
    if (incremental) exe.incremental = true;
    b.installArtifact(exe);

    // --- Ziex WASM Main Executable --- //
    // Client sqlite stores its database on the browser file system.
    const fs_client = (if (opts.features.fs) |f| f.client != null else false) or
        (if (opts.features.sqlite) |s| s.client != null else false);
    var client_root: ?*std.Build.Module = null;
    const clients: ?*Clients = if (build_client_wasm) try b.allocator.create(Clients) else null;
    const manifest_path: LazyPath = if (build_client_wasm) blk: {
        // With fs, main.zig is not the root: with libc linked, std would export a C entry for its `pub fn main`.
        const app_main = b.createModule(.{
            .root_source_file = exe.root_module.root_source_file,
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_exe = b.addExecutable(.{
            .name = b.fmt("main", .{}),
            .root_module = if (fs_client) b.createModule(.{
                .root_source_file = b.addWriteFiles().add("client_root.zig", client_root_source),
                .target = wasm_target,
                .optimize = wasm_optimize,
            }) else app_main,
        });
        if (fs_client) {
            wasm_exe.root_module.addImport("__zx_app_main", app_main);
            withFdHandles(b, wasm_exe);
        }

        wasm_exe.entry = .disabled;
        wasm_exe.export_memory = true;
        wasm_exe.rdynamic = true;
        wasm_exe.root_module.strip = !is_dev_build;
        if (incremental) wasm_exe.incremental = true;

        // Create a site-specific wasm module (same approach as server module)
        var wasm_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
        for (user_imports.items) |import| {
            if (std.mem.eql(u8, import.name, "zx")) continue;

            const requires_libc = try moduleRequiresLibC(b.allocator, import.module);
            const wasm_module = if (requires_libc)
                makeServerOnlyStubModule(b, import.name, opts.server_only_stub_mode)
            else
                import.module;

            try wasm_imports.append(.{ .name = import.name, .module = wasm_module });
            app_main.addImport(import.name, wasm_module);
        }

        const user_wasm_imports = b.allocator.dupe(std.Build.Module.Import, wasm_imports.items) catch @panic("OOM");

        var wasm_import_it = zx_wasm_module.?.import_table.iterator();
        while (wasm_import_it.next()) |entry| {
            try wasm_imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* });
        }

        const wasm_app_module = b.createModule(.{
            .root_source_file = zx_wasm_module.?.root_source_file,
            .target = wasm_target,
            .optimize = zx_wasm_module.?.optimize,
            .imports = wasm_imports.items,
        });

        // Build imports for wasm app
        var wasm_app_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
        for (wasm_imports.items) |import| {
            try wasm_app_imports.append(import);
        }
        try wasm_app_imports.append(.{ .name = "zx", .module = wasm_app_module });

        const wasm_meta_module = b.createModule(.{
            .root_source_file = transpile_store.path(b, "app.zig"),
            .imports = wasm_app_imports.items,
        });
        wasm_app_module.addImport("app", wasm_meta_module);
        const zons = b.addWriteFiles();
        transpile_cmd.addArg("--client-dir");
        transpile_cmd.addDirectoryArg(zons.getDirectory());
        clients.?.* = .{
            .b = b,
            .zons = zons,
            .zx = zx_module,
            .app = app_module,
            .wasm_zx = wasm_app_module,
            .wasm_app = wasm_meta_module,
            .target = wasm_target,
            .optimize = wasm_optimize,
            .stub_mode = opts.server_only_stub_mode,
        };
        // Client/wasm builds must not analyze Httpz (no httpz module on that dep).
        const wasm_app_opts = addAppOpts(b, .{
            .base_path = opts.base_path,
            .server_port = config.port,
            .server_address = config.address,
            .cli_command = cli_command,
            .enable_httpz = false,
            .features = opts.features,
        });
        wasm_app_module.addOptions("app_opts", wasm_app_opts);

        app_main.addImport("zx", wasm_app_module);
        if (fs_client) wasm_exe.root_module.addImport("zx", wasm_app_module);
        wasm_exe.step.dependOn(&transpile_cmd.step);
        client_root = wasm_exe.root_module;

        // Workers get their own zx and app modules, from a zx built with worker-only features.
        // Their URLs reach `zx.worker` in the page's wasm through `zx_worker_assets`.
        const worker_paths = workerPaths(b, opts.site_path);
        const worker_assets = b.addWriteFiles();
        var worker_entries: std.ArrayList(u8) = .empty;
        if (worker_paths.len > 0) {
            const zx_worker = zx_worker_module.?;
            var worker_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
            try worker_imports.appendSlice(user_wasm_imports);
            var it = zx_worker.import_table.iterator();
            while (it.next()) |entry| try worker_imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* });
            const worker_zx = b.createModule(.{
                .root_source_file = zx_worker.root_source_file,
                .target = wasm_target,
                .optimize = zx_worker.optimize,
                .imports = worker_imports.items,
            });
            var worker_app_imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
            try worker_app_imports.appendSlice(user_wasm_imports);
            try worker_app_imports.append(.{ .name = "zx", .module = worker_zx });
            const worker_app = b.createModule(.{
                .root_source_file = transpile_store.path(b, "app.zig"),
                .imports = worker_app_imports.items,
            });
            worker_zx.addImport("app", worker_app);
            worker_zx.addOptions("app_opts", wasm_app_opts);
            for (worker_paths, 0..) |rel, i| {
                const worker = addWorker(b, rel, wasm_target, wasm_optimize, worker_zx, worker_app);
                worker.root_module.strip = !is_dev_build;
                worker.step.dependOn(&transpile_cmd.step);
                const href = addWorkerAsset(b, zx_cli, opts, worker, rel, is_dev_build, use_stable_assets);
                _ = worker_assets.addCopyFile(href, b.fmt("{d}.href", .{i}));
                const type_name = WorkerName.typeNameFromPath(b.allocator.alloc(u8, rel.len) catch @panic("OOM"), rel);
                worker_entries.print(b.allocator, "    .{{ \"{s}\", @embedFile(\"{d}.href\") }},\n", .{ type_name, i }) catch @panic("OOM");
            }
        }
        wasm_app_module.addImport("zx_worker_assets", b.createModule(.{
            .root_source_file = worker_assets.add("worker_assets.zig", b.fmt(
                \\// `worker.zig` type name -> URL of its wasm.
                \\pub fn href(comptime type_name: []const u8) []const u8 {{
                \\    inline for (entries) |entry| {{
                \\        if (comptime @import("std").mem.eql(u8, entry[0], type_name)) return entry[1];
                \\    }}
                \\    @compileError("zx.worker: " ++ type_name ++ " is not a worker.zig");
                \\}}
                \\
                \\const entries = .{{
                \\{s}}};
                \\
            , .{worker_entries.items})),
        }));

        const wasm_binpath = wasm_exe.getEmittedBin();
        const zxjs_path = opts.ziex_js_root.path(b, if (is_dev_build) "wasm/init.dev.js" else "wasm/init.js");

        if (use_stable_assets) {
            if (uses_local_bindings and link_client_bindings) {
                const js_asset = addStaticAssetCopy(b, zx_cli, opts, zxjs_path, client_asset_stem, ".js", true, true, "script");
                js_asset.addArg("--wasm");
                js_asset.addFileArg(wasm_binpath);
                js_asset.setName("install client bindings");
                b.getInstallStep().dependOn(&js_asset.step);
            }

            const wasm_asset = addStaticAssetCopy(b, zx_cli, opts, wasm_binpath, client_asset_stem, ".wasm", !uses_local_bindings, true, "wasmlink");
            wasm_asset.setName("install client wasm");
            wasm_asset.step.dependOn(&wasm_exe.step);
            b.getInstallStep().dependOn(&wasm_asset.step);

            break :blk base_manifest_path;
        }

        var wasm_manifest_in = base_manifest_path;
        var js_run: ?*std.Build.Step.Run = null;
        if (uses_local_bindings and link_client_bindings) {
            const js_asset = addStaticAssetRun(b, zx_cli, opts, base_manifest_path, zxjs_path, client_asset_href_stem, client_asset_stem, ".js", "script", true, false);
            js_asset.run.addArg("--wasm");
            js_asset.run.addFileArg(wasm_binpath);
            js_asset.run.setName("install client bindings");
            b.getInstallStep().dependOn(&js_asset.run.step);
            js_run = js_asset.run;
            wasm_manifest_in = js_asset.manifest_out;
        }

        const wasm_asset_run = addStaticAssetRun(
            b,
            zx_cli,
            opts,
            wasm_manifest_in,
            wasm_binpath,
            client_asset_href_stem,
            client_asset_stem,
            ".wasm",
            "wasmlink",
            !uses_local_bindings,
            false,
        );
        wasm_asset_run.run.setName("install client wasm");
        wasm_asset_run.run.step.dependOn(&wasm_exe.step);
        if (js_run) |js| wasm_asset_run.run.step.dependOn(&js.step);
        b.getInstallStep().dependOn(&wasm_asset_run.run.step);
        exe.step.dependOn(&wasm_asset_run.run.step);

        break :blk wasm_asset_run.manifest_out;
    } else base_manifest_path;

    const manifest_mod = b.createModule(.{ .root_source_file = manifest_path });
    zx_module.addImport("manifest", manifest_mod);

    const install_manifest = b.addInstallFileWithDir(manifest_path, .prefix, "manifest/app.zon");
    install_manifest.step.name = "install app manifest";
    b.default_step.dependOn(&install_manifest.step);

    // --- Prerender --- //
    // Pre-renders static pages from a host build of the app into the same static dir
    // the edge host serves, so prerendered routes skip the worker entirely.
    if (config.prerender and config.command == null) {
        const prerender_cmd = appRun(b, zx_cli, opts);
        prerender_cmd.setName("prerender");
        prerender_cmd.setCwd(b.path("."));
        prerender_cmd.addArgs(&.{ "build", "--static", "--prerendered-only", "--zig-path", opts.zig_path });
        if (optimize) |mode| prerender_cmd.addArgs(&.{ "--build-args", b.fmt("-Doptimize={s}", .{@tagName(mode)}) });
        prerender_cmd.addArg("--outdir");
        prerender_cmd.addDirectoryArg(static_lazypath);
        prerender_cmd.has_side_effects = true;

        // Run after every other write into static/ so prerendered output lands last.
        prerender_cmd.step.dependOn(&transpile_cmd.step);
        for (static_install_steps) |step| if (step) |st| prerender_cmd.step.dependOn(st);
        for (b.getInstallStep().dependencies.items) |dep| prerender_cmd.step.dependOn(dep);
        b.getInstallStep().dependOn(&prerender_cmd.step);
    }

    // --- Steps: zx (Root of the Ziex CLI) --- //
    {
        const zx_step = b.step(
            "zx",
            b.fmt("Ziex CLI - \x1b[2m{s}\x1b[0m", .{"zig build zx -- <args>"}),
        );
        const zx_cmd = cliRun(b, zx_cli, opts);
        zx_step.dependOn(&zx_cmd.step);
        zx_cmd.addPassthruArgs();
    }

    // --- `zx build --check`: type-check server and client without emitting binaries --- //
    // Only defined in check mode, where it replaces the default step.
    if (config.command == .check) {
        const check_step = b.step("check", "Type-check the app without emitting binaries");
        const server_check = b.addExecutable(.{ .name = "check-server", .root_module = exe.root_module });
        server_check.step.dependOn(&transpile_cmd.step);
        check_step.dependOn(&server_check.step);
        if (client_root) |root| {
            const client_check = b.addExecutable(.{ .name = "check-client", .root_module = root });
            client_check.entry = .disabled;
            client_check.rdynamic = true;
            if (fs_client) withFdHandles(b, client_check);
            client_check.step.dependOn(&transpile_cmd.step);
            check_step.dependOn(&client_check.step);
        }
        b.default_step = check_step;
    }

    // --- Steps: Serve --- //
    if (opts.steps.serve) |serve_step_name| {
        const serve_cmd = appRun(b, zx_cli, opts);
        serve_cmd.addArg("serve");
        serve_cmd.addArgs(&.{ "--zig-path", opts.zig_path });
        const serve_step = b.step(serve_step_name, "Run the Ziex app with production behavior");
        serve_step.dependOn(&serve_cmd.step);
        serve_cmd.addPassthruArgs();
    }

    // --- Steps: Dev --- //
    if (opts.steps.dev) |dev_step_name| {
        const dev_cmd = appRun(b, zx_cli, opts);
        dev_cmd.addArg("dev");
        dev_cmd.addArgs(&.{ "--zig-path", opts.zig_path });
        const dev_step = b.step(dev_step_name, "Run the Ziex app in development mode");
        dev_step.dependOn(&dev_cmd.step);
        dev_cmd.addPassthruArgs();
    }

    // --- Steps: Static --- //
    if (opts.steps.static) |static_step_name| {
        const static_cmd = appRun(b, zx_cli, opts);
        static_cmd.addArgs(&.{ "build", "--static" });
        static_cmd.addArgs(&.{ "--zig-path", opts.zig_path });
        const static_step = b.step(static_step_name, "Build the Ziex app as a static site");
        static_step.dependOn(&static_cmd.step);
        static_cmd.addPassthruArgs();
    }

    // --- Steps: Bundle --- //
    if (opts.steps.bundle) |bundle_step_name| {
        const bundle_cmd = appRun(b, zx_cli, opts);
        bundle_cmd.addArgs(&.{ "bundle", "--zig-path", opts.zig_path });
        const bundle_step = b.step(bundle_step_name, "Bundle the Ziex app for production deployment");
        bundle_step.dependOn(&bundle_cmd.step);
        bundle_cmd.addPassthruArgs();
    }

    return .{
        .build = b,
        .zx_module = zx_module,
        .app = .{ .exe = exe, .module = app_module },
        .cmd = .{
            .transpile = transpile_cmd,
        },
        .outdir = transpile_store,
        .assetsdir = assetsdir,
        .cli = .{
            .exe = zx_cli,
        },
        .transformer = .{ .b = b, .userdata = injections },
        .clients = clients,
    };
}

const Clients = struct {
    const Module = std.Build.Module;

    b: *std.Build,
    zons: *std.Build.Step.WriteFile,
    zx: *Module,
    app: *Module,
    wasm_zx: *Module,
    wasm_app: *Module,
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    stub_mode: ServerOnlyStubMode,
    added: std.AutoHashMapUnmanaged(*Module, void) = .empty,
    wasm: std.AutoHashMapUnmanaged(*Module, *Module) = .empty,
    clones: std.ArrayList(struct { src: *Module, dst: *Module }) = .empty,

    fn add(self: *Clients, mod: *Module) void {
        const b = self.b;
        self.syncAll();
        if (self.added.contains(mod)) return;
        const root = mod.root_source_file orelse return;
        if (root != .generated or !self.usesZx(mod)) return;

        const name = b.fmt("__zx_client_module_{d}", .{self.added.count()});
        self.added.put(b.allocator, mod, {}) catch @panic("OOM");
        self.app.addImport(name, mod);
        self.wasm_app.addImport(name, self.toWasm(name, mod));
        _ = self.zons.addCopyFile(root.dirname().path(b, "__zx_client.zon"), b.fmt("{s}.zon", .{name}));
    }

    fn toWasm(self: *Clients, name: []const u8, mod: *Module) *Module {
        const b = self.b;
        if (mod == self.zx) return self.wasm_zx;
        if (self.wasm.get(mod)) |m| return m;

        if (!self.usesZx(mod)) {
            const libc = moduleRequiresLibC(b.allocator, mod) catch @panic("OOM");
            const m = if (libc) makeServerOnlyStubModule(b, name, self.stub_mode) else mod;
            self.wasm.put(b.allocator, mod, m) catch @panic("OOM");
            return m;
        }

        const m = b.createModule(.{
            .root_source_file = mod.root_source_file,
            .target = self.target,
            .optimize = self.optimize,
        });
        self.wasm.put(b.allocator, mod, m) catch @panic("OOM");
        self.clones.append(b.allocator, .{ .src = mod, .dst = m }) catch @panic("OOM");
        self.sync(mod, m);
        return m;
    }

    fn sync(self: *Clients, src: *Module, dst: *Module) void {
        var it = src.import_table.iterator();
        while (it.next()) |e| {
            if (dst.import_table.contains(e.key_ptr.*)) continue;
            dst.addImport(e.key_ptr.*, self.toWasm(e.key_ptr.*, e.value_ptr.*));
        }
    }

    fn syncAll(self: *Clients) void {
        var i: usize = 0;
        while (i < self.clones.items.len) : (i += 1) {
            self.sync(self.clones.items[i].src, self.clones.items[i].dst);
        }
    }

    fn usesZx(self: *Clients, mod: *Module) bool {
        var seen: std.AutoHashMapUnmanaged(*Module, void) = .empty;
        defer seen.deinit(self.b.allocator);
        return self.reaches(mod, &seen);
    }

    fn reaches(self: *Clients, mod: *Module, seen: *std.AutoHashMapUnmanaged(*Module, void)) bool {
        if (mod == self.zx) return true;
        if ((seen.getOrPut(self.b.allocator, mod) catch @panic("OOM")).found_existing) return false;
        var it = mod.import_table.iterator();
        while (it.next()) |e| {
            if (self.reaches(e.value_ptr.*, seen)) return true;
        }
        return false;
    }
};

/// Resolved init state passed to CLI/asset helpers.
const Resolved = struct {
    site_path: LazyPath,
    base_path: ?[]const u8,
    cli_path: ?LazyPath,
    steps: InitOptions.CliOptions.Steps,
    features: InitOptions.AppOptions.FeatureOptions = .default,
    client: InitOptions.ClientOptions,
    static_path: ?LazyPath,
    /// Root of the JS bindings package (`pkg/ziex` prebuilt or esbuild output when `bindings.build` is set).
    ziex_js_root: LazyPath,
    element_injections: []const AddElementOptions = &.{},
    version: ?[]const u8 = null,
    server_only_stub_mode: ServerOnlyStubMode = .strict,
    zig_path: []const u8,
    /// Absolute/cwd-relative path to the ziex `src/root.zig` module for LSP.
    zx_module_path: []const u8,
};

const AppOptsParams = struct {
    base_path: ?[]const u8,
    server_port: ?u16,
    server_address: ?[]const u8,
    cli_command: []const u8,
    enable_httpz: bool,
    features: InitOptions.AppOptions.FeatureOptions,
    omit_prerendered: bool = false,
};

/// Reads `-Dziex-config`, which the zx CLI sets; a plain `zig build` uses the defaults.
fn buildConfig(b: *std.Build) BuildConfig {
    const source = b.option([]const u8, BuildConfig.option_name, "Ziex settings as ZON, set by the zx CLI (`zig build zx -- <command>`)") orelse return .{};
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return BuildConfig.parse(b.allocator, source, &diagnostics) catch |err| {
        switch (err) {
            error.ParseZon => diagnostics.log("-D" ++ BuildConfig.option_name),
            else => std.log.err("-D" ++ BuildConfig.option_name ++ ": {t}", .{err}),
        }
        std.process.exit(1);
    };
}

fn addAppOpts(b: *std.Build, params: AppOptsParams) *std.Build.Step.Options {
    const app_opts = b.addOptions();
    app_opts.addOption(?[]const u8, "app_base_path", params.base_path);
    app_opts.addOption(?u16, "server_port", params.server_port);
    app_opts.addOption(?[]const u8, "server_address", params.server_address);
    app_opts.addOption([]const u8, "cli_command", params.cli_command);
    app_opts.addOption(bool, "enable_httpz", params.enable_httpz);
    app_opts.addOption(bool, "omit_prerendered", params.omit_prerendered);
    app_opts.addOption(bool, "feat_sqlite_server", if (params.features.sqlite) |s| s.server != null else false);
    app_opts.addOption(bool, "feat_sqlite_client", if (params.features.sqlite) |s| s.client != null else false);
    app_opts.addOption(bool, "feat_pg_server", if (params.features.postgres) |s| s.server != null else false);
    app_opts.addOption(bool, "feat_kv_server", if (params.features.kv) |k| k.server != null else false);
    app_opts.addOption(bool, "feat_kv_client", if (params.features.kv) |k| k.client != null else false);
    app_opts.addOption(bool, "feat_cache_server", if (params.features.cache) |c| c.server != null else false);
    const ai: InitOptions.AppOptions.FeatureOptions.AiOptions.AiServerOptions = if (params.features.ai) |a| a.server orelse .{} else .{};
    app_opts.addOption(bool, "feat_ai_server", if (params.features.ai) |a| a.server != null else false);
    app_opts.addOption([]const u8, "ai_provider", @tagName(ai.provider));
    app_opts.addOption(?[]const u8, "ai_model", ai.model);
    app_opts.addOption(?[]const u8, "ai_image_model", ai.image_model);
    app_opts.addOption(?[]const u8, "ai_base_url", ai.base_url);
    const flag: InitOptions.AppOptions.FeatureOptions.FlagOptions.FlagServerOptions = if (params.features.flag) |f| f.server orelse .{} else .{};
    app_opts.addOption(bool, "feat_flag_server", if (params.features.flag) |f| f.server != null else false);
    app_opts.addOption([]const u8, "flag_provider", @tagName(flag.provider));
    app_opts.addOption(?[]const u8, "flag_base_url", flag.base_url);
    app_opts.addOption(?[]const u8, "flag_app_id", flag.app_id);
    app_opts.addOption(?[]const u8, "flag_binding", flag.binding);
    const email: InitOptions.AppOptions.FeatureOptions.EmailOptions.EmailServerOptions = if (params.features.email) |e| e.server orelse .{} else .{};
    app_opts.addOption(bool, "feat_email_server", if (params.features.email) |e| e.server != null else false);
    app_opts.addOption([]const u8, "email_provider", @tagName(email.provider));
    app_opts.addOption(?[]const u8, "email_from", email.from);
    app_opts.addOption(?[]const u8, "email_base_url", email.base_url);
    app_opts.addOption(?[]const u8, "email_binding", email.binding);
    return app_opts;
}

fn cliRun(b: *std.Build, zx_exe: *std.Build.Step.Compile, opts: Resolved) *std.Build.Step.Run {
    const run = appRun(b, zx_exe, opts);
    run.setEnvironmentVariable("ZIEX_MODULE_PATH", opts.zx_module_path);
    run.setEnvironmentVariable("ZIEX_ZIG_PATH", opts.zig_path);
    return run;
}

// Sets no env: a step's env map is frozen at configure time and replaces the
// caller's, so the app would miss vars exported later (e.g. API keys).
fn appRun(b: *std.Build, zx_exe: *std.Build.Step.Compile, opts: Resolved) *std.Build.Step.Run {
    const run = if (opts.cli_path) |cli_path| blk: {
        const r = std.Build.Step.Run.create(b, "run zx");
        r.addFileArg(cli_path);
        break :blk r;
    } else b.addRunArtifact(zx_exe);
    return run;
}

/// Newline-separated route files under `site_path`, relative to it. Every route
/// directory is a configure dependency, so the list stays current under `--watch`.
// `worker.zig` files under the route dirs, relative to the app root (`pages/foo/worker.zig`).
fn workerPaths(b: *std.Build, site_path: std.Build.LazyPath) []const []const u8 {
    const io = b.graph.io;
    const owner = site_path.src_path.owner;
    var rels: std.ArrayList([]const u8) = .empty;
    for (CliConstant.route_dirnames) |dirname| {
        const sub = b.pathJoin(&.{ site_path.src_path.sub_path, dirname });
        var dir = owner.root.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch |err| std.debug.panic("unable to walk {s}: {t}", .{ sub, err })) |entry| {
            if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "worker.zig")) continue;
            const rel = b.pathJoin(&.{ dirname, entry.path });
            std.mem.replaceScalar(u8, rel, '\\', '/');
            rels.append(b.allocator, rel) catch @panic("OOM");
        }
    }
    return rels.items;
}

// One wasm per `worker.zig`, at `assets/_/workers/<name>.wasm` where `zx.worker` looks for it.
fn addWorker(
    b: *std.Build,
    rel: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    zx_module: *std.Build.Module,
    app_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const type_name = WorkerName.typeNameFromPath(b.allocator.alloc(u8, rel.len) catch @panic("OOM"), rel);
    const asset = WorkerName.asset(b.allocator.alloc(u8, type_name.len) catch @panic("OOM"), type_name);
    const root = b.addWriteFiles().add("worker_root.zig", b.fmt(
        \\const zx = @import("zx");
        \\const app = @import("app");
        \\
        \\pub const zx_worker = true;
        \\pub const std_options = zx.std_options;
        \\pub const std_options_cwd = zx.Io.Web.cwd;
        \\
        \\comptime {{
        \\    zx.Worker.serve(app.workers.@"{s}");
        \\}}
        \\
    , .{type_name}));
    const exe = b.addExecutable(.{
        .name = b.fmt("worker-{s}", .{asset}),
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_module },
                .{ .name = "app", .module = app_module },
            },
        }),
    });
    exe.entry = .disabled;
    exe.export_memory = true;
    exe.rdynamic = true;
    // Workers always get files: OPFS sync access handles.
    withFdHandles(b, exe);
    return exe;
}

// Installs a worker's wasm like the app's: `assets/_/<route>/worker.dev.wasm` in dev,
// `worker.<hash>.wasm` otherwise. Returns a file holding its URL.
fn addWorkerAsset(
    b: *std.Build,
    zx_cli: *std.Build.Step.Compile,
    opts: Resolved,
    exe: *std.Build.Step.Compile,
    rel: []const u8,
    is_dev_build: bool,
    stable: bool,
) LazyPath {
    // `pages/examples/worker/worker.zig` -> `examples/worker`.
    const dir = std.fs.path.dirname(rel) orelse "";
    const route = if (std.mem.indexOfScalar(u8, dir, '/')) |i| dir[i + 1 ..] else "";
    const sub = if (route.len == 0) "_" else b.fmt("_/{s}", .{route});
    const stem = if (is_dev_build) "worker.dev" else "worker";

    const run = cliRun(b, zx_cli, opts);
    run.setName(b.fmt("install worker {s}", .{rel}));
    run.addArgs(&.{ "app", "asset" });
    run.addFileArg(exe.getEmittedBin());
    run.addArg("--outdir");
    const out = run.addOutputDirectoryArg("asset");
    run.addArgs(&.{ "--file-stem", stem, "--ext", ".wasm", "--clean" });
    run.addArgs(&.{ "--href-stem", html_util.prefixPathWithBasePath(b.allocator, opts.base_path, b.fmt("/assets/{s}/{s}", .{ sub, stem })) });
    if (stable) run.addArg("--no-hash");
    run.addArg("--href-out");
    const href = run.addOutputFileArg("href");
    run.expectExitCode(0);

    const install = b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .{ .custom = "static/assets/" },
        .install_subdir = sub,
    });
    install.step.dependOn(&run.step);
    b.getInstallStep().dependOn(&install.step);
    return href;
}

fn routeRoots(b: *std.Build, site_path: std.Build.LazyPath) []const u8 {
    const io = b.graph.io;
    const owner = site_path.src_path.owner;
    var rels: std.ArrayList([]const u8) = .empty;
    for (CliConstant.route_dirnames) |dirname| {
        const sub = b.pathJoin(&.{ site_path.src_path.sub_path, dirname });
        var dir = owner.root.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        b.dependOnDirectoryContents(owner.path(sub));

        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch |err| std.debug.panic("unable to walk {s}: {t}", .{ sub, err })) |entry| switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(owner.path(b.pathJoin(&.{ sub, entry.path }))),
            .file, .sym_link => if (CliConstant.isRouteRoot(entry.basename)) {
                rels.append(b.allocator, b.pathJoin(&.{ dirname, entry.path })) catch @panic("OOM");
            },
            else => {},
        };
    }
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn less(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.less);

    var out: std.ArrayList(u8) = .empty;
    for (rels.items) |rel| {
        out.appendSlice(b.allocator, rel) catch @panic("OOM");
        out.append(b.allocator, '\n') catch @panic("OOM");
    }
    return out.items;
}

fn moduleRequiresLibCRec(module: *std.Build.Module, visited: *std.AutoHashMap(*std.Build.Module, void)) !bool {
    if (visited.contains(module)) return false;
    try visited.put(module, {});

    if ((module.link_libc orelse false) or (module.link_libcpp orelse false)) {
        return true;
    }

    var it = module.import_table.iterator();
    while (it.next()) |entry| {
        if (try moduleRequiresLibCRec(entry.value_ptr.*, visited)) {
            return true;
        }
    }

    for (module.link_objects.items) |obj| {
        switch (obj) {
            .system_lib => |lib| {
                if (std.mem.eql(u8, lib.name, "c") or
                    std.mem.eql(u8, lib.name, "stdc++") or
                    std.mem.eql(u8, lib.name, "c++"))
                {
                    return true;
                }
            },
            .other_step => |compile_step| {
                if (try moduleRequiresLibCRec(compile_step.root_module, visited)) {
                    return true;
                }
            },
            else => {},
        }
    }

    return false;
}

// Forwards the root decls std reads from the app's main.zig.
const client_root_source =
    \\const std = @import("std");
    \\const app = @import("__zx_app_main");
    \\
    \\// Analyzing `main` reaches the client's `@export`s; it is never called.
    \\comptime {
    \\    if (@hasDecl(app, "main")) _ = &app.main;
    \\}
    \\
    \\pub const std_options: std.Options = if (@hasDecl(app, "std_options")) app.std_options else .{};
    \\pub const panic = if (@hasDecl(app, "panic")) app.panic else std.debug.FullPanic(std.debug.defaultPanic);
    \\pub const std_options_cwd = @import("zx").Io.Web.cwd;
    \\
;

// Freestanding `fd_t` is `void`; with libc std uses `std.c`'s i32. Nothing from the empty libc is linked.
fn withFdHandles(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.link_libc = true;
    compile.setLibCFile(b.addWriteFiles().add("libc.txt",
        \\include_dir=/zx-no-libc
        \\sys_include_dir=/zx-no-libc
        \\crt_dir=/zx-no-libc
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\darwin_sdk_dir=
        \\haiku_dir=
        \\
    ));
}

fn moduleRequiresLibC(allocator: std.mem.Allocator, module: *std.Build.Module) !bool {
    var visited = std.AutoHashMap(*std.Build.Module, void).init(allocator);
    defer visited.deinit();
    return moduleRequiresLibCRec(module, &visited);
}

fn makeServerOnlyStubModule(b: *std.Build, name: []const u8, mode: ServerOnlyStubMode) *std.Build.Module {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });
    const contents = switch (mode) {
        .strict => b.fmt(
            \\// Auto-generated by ziex: strict server-only stub for `{s}`.
            \\//
            \\// This module is intentionally unavailable in wasm builds.
            \\comptime {{
            \\    @compileError(
            \\        "'{s}' is a server-only module and cannot be used from client " ++
            \\        "(wasm) code. Guard its usage with `if (builtin.target.cpu.arch " ++
            \\        "!= .wasm32)` or move it behind a server-only import boundary.",
            \\    );
            \\}}
            \\
        , .{ name, name }),
        .lazy => b.fmt(
            \\// Auto-generated by ziex: server-only stub for `{s}`.
            \\//
            \\// This module links libc/libc++ and cannot be compiled for the
            \\// wasm32-freestanding client build. Ziex has substituted this stub
            \\// so that `@import("{s}")` still resolves on the client, letting
            \\// the same source file compile for both server and client.
            \\//
            \\// Guard any usage of this module behind a comptime target check,
            \\// e.g.:
            \\//
            \\//     const builtin = @import("builtin");
            \\//     if (builtin.target.cpu.arch != .wasm32) {{
            \\//         // ... use the module here ...
            \\//     }}
            \\//
            \\// This lazy mode keeps shared imports compiling; unknown members on
            \\// this stub will still produce Zig's default "no member named" error.
            \\const __ziex_server_only_msg =
            \\    "'{s}' is a server-only module and cannot be used from client " ++
            \\    "(wasm) code. Guard its usage with `if (builtin.target.cpu.arch " ++
            \\    "!= .wasm32)` or move it behind a server-only import boundary.";
            \\
            \\pub const __ziex_server_only = @compileError(__ziex_server_only_msg);
            \\
        , .{ name, name, name }),
    };

    const wf = b.addWriteFiles();
    const stub_path = wf.add(b.fmt("ziex_server_only_stub_{s}.zig", .{name}), contents);

    return b.createModule(.{
        .root_source_file = stub_path,
        .target = wasm_target,
    });
}

fn findZxInPath(b: *std.Build, expected_version: []const u8) ?[]const u8 {
    // TODO: disable for now, always use from source
    if (true) return null;
    const zx_path = b.findProgram(&.{"zx"}, &.{}) catch return null;
    var exit_code: u8 = undefined;
    const stdout = b.runAllowFail(&.{ zx_path, "version" }, &exit_code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (!std.mem.eql(u8, trimmed, expected_version)) return null;
    return zx_path;
}

fn addStaticAssetCopy(
    b: *std.Build,
    zx_exe: *std.Build.Step.Compile,
    opts: Resolved,
    src: LazyPath,
    file_stem: []const u8,
    file_ext: []const u8,
    clean_dest: bool,
    no_hash: bool,
    injection_kind: []const u8,
) *std.Build.Step.Run {
    const run = cliRun(b, zx_exe, opts);
    run.addArgs(&.{ "app", "asset" });
    run.addFileArg(src);
    run.addArg("--outdir");
    const asset_output_dir = run.addOutputDirectoryArg("asset");
    run.addArgs(&.{ "--file-stem", file_stem, "--ext", file_ext });
    if (clean_dest) run.addArg("--clean");
    if (no_hash) run.addArg("--no-hash");
    run.expectExitCode(0);

    const install_static_assets = b.addInstallDirectory(.{
        .source_dir = asset_output_dir,
        .install_dir = .{ .custom = "static/assets/" },
        .install_subdir = "_",
    });
    install_static_assets.step.name = if (std.mem.eql(u8, injection_kind, "wasmlink"))
        "install client wasm assets"
    else if (std.mem.eql(u8, injection_kind, "script"))
        "install client js assets"
    else
        b.fmt("install client {s} assets", .{injection_kind});
    install_static_assets.step.dependOn(&run.step);
    b.getInstallStep().dependOn(&install_static_assets.step);

    return run;
}

fn addStaticAssetRun(
    b: *std.Build,
    zx_exe: *std.Build.Step.Compile,
    opts: Resolved,
    manifest_in: LazyPath,
    src: LazyPath,
    href_stem: []const u8,
    file_stem: []const u8,
    file_ext: []const u8,
    injection_kind: []const u8,
    clean_dest: bool,
    no_hash: bool,
) struct {
    run: *std.Build.Step.Run,
    manifest_out: LazyPath,
} {
    const run = cliRun(b, zx_exe, opts);
    run.addArgs(&.{ "app", "asset" });
    run.addFileArg(src);
    run.addArg("--outdir");
    const asset_output_dir = run.addOutputDirectoryArg("asset");
    run.addArg("--href-stem");
    run.addArg(href_stem);
    run.addArg("--manifest");
    run.addFileArg(manifest_in);
    run.addArg("--manifest-out");
    const manifest_out = run.addOutputFileArg("app.zon");
    run.addArgs(&.{ "--file-stem", file_stem, "--ext", file_ext, "--kind", injection_kind });
    if (clean_dest) run.addArg("--clean");
    if (no_hash) run.addArg("--no-hash");
    run.expectExitCode(0);

    // Install the static assets directory
    const install_static_assets = b.addInstallDirectory(.{
        .source_dir = asset_output_dir,
        .install_dir = .{ .custom = "static/assets/" },
        .install_subdir = "_",
    });
    install_static_assets.step.name = if (std.mem.eql(u8, injection_kind, "wasmlink"))
        "install client wasm assets"
    else if (std.mem.eql(u8, injection_kind, "script"))
        "install client js assets"
    else
        b.fmt("install client {s} assets", .{injection_kind});
    install_static_assets.step.dependOn(&run.step);
    b.getInstallStep().dependOn(&install_static_assets.step);

    return .{ .run = run, .manifest_out = manifest_out };
}

const Injections = struct {
    items: std.ArrayList(AddElementOptions) = .empty,
    wf: ?*std.Build.Step.WriteFile = null,

    pub fn add(self: *Injections, b: *std.Build, options: AddElementOptions) void {
        self.items.append(b.allocator, options) catch @panic("OOM");
        if (self.wf != null) _ = self.rewriteSeed(b);
    }

    pub fn seedBuildInjections(self: *Injections, b: *std.Build) !std.Build.LazyPath {
        self.wf = b.addWriteFiles();
        return self.rewriteSeed(b);
    }

    fn rewriteSeed(self: *Injections, b: *std.Build) std.Build.LazyPath {
        const wf = self.wf.?;

        var aw = std.Io.Writer.Allocating.init(b.allocator);
        defer aw.deinit();
        std.zon.stringify.serializeArbitraryDepth(self.items.items, .{ .whitespace = true }, &aw.writer) catch @panic("OOM");

        wf.embeds.clearRetainingCapacity();
        return wf.add("build-injections.zon", aw.written());
    }
};

// TODO: move to src/Build.zig
pub const Build = struct {
    pub const BuildZiex = struct {
        exe: *std.Build.Step.Compile,
    };

    pub const BuildCommand = struct {
        transpile: *std.Build.Step.Run,
    };

    pub const App = struct {
        exe: *std.Build.Step.Compile,
        module: *std.Build.Module,
    };

    /// Output transformer: injects elements into the generated output
    pub const Transformer = struct {
        b: *std.Build,
        userdata: *anyopaque,

        pub fn addElement(self: Transformer, options: AddElementOptions) void {
            const injections: *Injections = @ptrCast(@alignCast(self.userdata));
            injections.add(self.b, options);
        }
    };

    build: *std.Build,

    /// The app's canonical `zx` module. Component modules created via
    /// `addComponent` are bound to this so the whole app shares one zx graph.
    zx_module: *std.Build.Module,

    /// The app's root executable and generated `app` module.
    app: App,

    cmd: BuildCommand,

    outdir: LazyPath,
    assetsdir: LazyPath,

    cli: BuildZiex,

    transformer: Transformer,

    clients: ?*Clients,

    /// Transpile a `.zx` component file and return a Zig module wired to this
    /// app's canonical `zx` module.
    pub fn addComponent(self: Build, opts: build_zig.TranslatedZx.Options) *std.Build.Module {
        var component_opts = opts;
        // Inherit the app's target/optimize unless the caller overrode them.
        if (component_opts.target == null) component_opts.target = self.zx_module.resolved_target;
        if (component_opts.optimize == null) component_opts.optimize = self.zx_module.optimize;

        const mod = build_zig.addTranslateZx(self.build, component_opts).createModule();
        mod.addImport("zx", self.zx_module);
        if (self.clients) |c| c.add(mod);
        return mod;
    }

    /// Like `addComponent`, but also imports the resulting module onto the app's
    /// root module and generated `app` module under `name`.
    pub fn addComponentImport(self: Build, name: []const u8, opts: build_zig.TranslatedZx.Options) void {
        const mod = self.addComponent(opts);
        self.addImport(name, mod);
    }

    /// Add an import to app's root module and generated `app` module under `name`.
    pub fn addImport(self: Build, name: []const u8, mod: *std.Build.Module) void {
        self.app.exe.root_module.addImport(name, mod);
        self.app.module.addImport(name, mod);
        if (self.clients) |c| c.add(mod);
    }
};

const ServerOnlyStubMode = enum {
    lazy,
    strict,
};
