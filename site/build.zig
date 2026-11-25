const std = @import("std");
const ziex = @import("ziex");

const build_zon = @import("build.zig.zon");

const ServerBackend = enum {
    std,
    auto,
    dusty,
};

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const id = assetId(b, optimize);
    const log_level = b.option(std.log.Level, "log-level", "Log level: debug, info, warn, error") orelse .info;
    const server_backend = b.option(ServerBackend, "server", "Server backend: std, auto, dusty") orelse .auto;
    const build_zig = b.option(bool, "build-zig", "Build zig/compiler_rt wasm from source") orelse false;

    const jsbinding_name = b.fmt("app.{s}.js", .{id});

    const app_features: ziex.InitOptions.AppOptions.FeatureOptions = .{
        .sqlite = .enabled,
        // .postgres = .enabled,
        .kv = .enabled,
        .cache = .enabled,
        .flag = .{ .server = .{ .provider = .kv } },
        .ai = .{ .server = .{ .provider = .openai, .model = "gpt-4o-mini", .image_model = "gpt-image-2.6-flare" } },
    };
    const app_client: ziex.InitOptions.ClientOptions = .{
        .bindings = .{
            .href = b.fmt("/assets/{s}", .{jsbinding_name}),
            .install_subdir = "pkg/ziex",
            .build = .enabled,
        },
        .wasm = .{
            .optimize = if (optimize == .debug) null else .small,
        },
    };

    // --- Deps --- //
    const ziex_dep = b.dependency("ziex", .{ .optimize = optimize, .target = target });
    const tree_sitter_dep = ziex_dep.builder.dependency("tree_sitter", .{ .optimize = optimize, .target = target });
    const tree_sitter_zx_dep = ziex_dep.builder.dependency("tree_sitter_zx", .{ .optimize = optimize, .target = target, .@"build-shared" = false });
    // const tree_sitter_mdzx_dep = ziex_dep.builder.dependency("tree_sitter_mdzx", .{ .optimize = optimize, .target = target, .@"build-shared" = false });
    const ziex_js_dep = b.dependency("ziex_js", .{
        .optimize = optimize,
        .target = target,
        .@"from-source" = true,
        .@"type-decl" = false,
        .@"feature-kv-client" = if (app_features.kv) |k| k.client != null else false,
        .@"feature-kv-server" = if (app_features.kv) |k| k.server != null else false,
        .@"feature-sqlite" = if (app_features.sqlite) |s| s.server != null else false,
        .@"feature-wasm-client" = app_client.wasm.link,
    });

    const pg_step = b.step("pg", "Install playground assets");
    const playground_zig_version = "0.17.0";

    // --- Playground Assets --- //
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
        const wasm_optimize: std.builtin.Optimize = .small;

        const zx_wasm_dep = b.dependency("ziex", .{ .target = wasm_target, .optimize = wasm_optimize, .lsp = true });
        const zx_exe = zx_wasm_dep.artifact("zx");

        // -- zx.tar.gz (only include files needed for playground compilation)
        const run_zx_tar = b.addSystemCommand(&.{ "tar", "-czf" });
        run_zx_tar.setName("pack zx sources (playground)");
        run_zx_tar.has_side_effects = true;
        const zx_tar_gz = run_zx_tar.addOutputFileArg("zx.tar.gz");
        run_zx_tar.addArgs(&.{
            "--exclude",
            "src/cli",
            "--exclude",
            "src/cli.zig",
            "--exclude",
            "src/lsp",
            "--exclude",
            "src/tui",
            "--exclude",
            "src/main.zig",
        });
        run_zx_tar.addArg("-C");
        run_zx_tar.addDirectoryArg(zx_wasm_dep.path("."));
        run_zx_tar.addArg("src");

        const ziex_js_files = ziex_js_dep.namedWriteFiles("ziex_js");
        const pg_init_js = ziex_js_files.getDirectory().path(b, "wasm/init.js");

        const playground_assets = b.addNamedWriteFiles("playground_assets");
        _ = playground_assets.addCopyFile(zx_exe.getEmittedBin(), b.fmt("zx-{s}-{s}.wasm", .{ ziex.info.version, id }));
        _ = playground_assets.addCopyFile(zx_tar_gz, b.fmt("zx-{s}-{s}.tar.gz", .{ ziex.info.version, id }));
        _ = playground_assets.addCopyFile(pg_init_js, "init.js");

        if (build_zig) {
            const zig_dep = b.dependency("zig", .{
                .target = wasm_target,
                .optimize = wasm_optimize,
                .@"version-string" = @as([]const u8, playground_zig_version),
                .@"no-lib" = true,
                .dev = "wasm",
            });

            const lib_compiler_rt = b.addLibrary(.{
                .linkage = .static,
                .name = "compiler_rt",
                .root_module = b.createModule(.{
                    .root_source_file = zig_dep.path("lib/compiler_rt.zig"),
                    .target = wasm_target,
                    .optimize = wasm_optimize,
                }),
            });
            const zig_exe = zig_dep.artifact("zig");

            // -- zig.tar.gz
            const run_tar = b.addSystemCommand(&.{ "tar", "-czf" });
            run_tar.setName("pack zig stdlib (playground)");
            const zig_tar_gz = run_tar.addOutputFileArg("zig.tar.gz");
            run_tar.addArg("-C");
            run_tar.addDirectoryArg(zig_dep.path("."));
            run_tar.addArgs(&.{ "lib/std", "lib/ubsan_rt.zig", "lib/compiler_rt.zig", "lib/compiler_rt", "lib/c.zig", "lib/fuzzer.zig", "lib/zig.h", "lib/compiler/test_runner.zig" });

            _ = playground_assets.addCopyFile(zig_exe.getEmittedBin(), b.fmt("zig-{s}.wasm", .{playground_zig_version}));
            _ = playground_assets.addCopyFile(lib_compiler_rt.getEmittedBin(), b.fmt("libcompiler_rt-{s}.a", .{playground_zig_version}));
            _ = playground_assets.addCopyFile(zig_tar_gz, b.fmt("zig-{s}.tar.gz", .{playground_zig_version}));
        } else {
            const zigc_wasm = try b.dependencyLazy("zigc_wasm", .{});
            const zigc_lib = try b.dependencyLazy("zigc_lib", .{});

            const lib_compiler_rt = b.addLibrary(.{
                .linkage = .static,
                .name = "compiler_rt",
                .root_module = b.createModule(.{
                    .root_source_file = zigc_lib.path("compiler_rt.zig"),
                    .target = wasm_target,
                    .optimize = wasm_optimize,
                }),
            });

            const lib_stage = b.addWriteFiles();
            _ = lib_stage.addCopyDirectory(zigc_lib.path("std"), "lib/std", .{});
            _ = lib_stage.addCopyDirectory(zigc_lib.path("compiler_rt"), "lib/compiler_rt", .{});
            _ = lib_stage.addCopyFile(zigc_lib.path("ubsan_rt.zig"), "lib/ubsan_rt.zig");
            _ = lib_stage.addCopyFile(zigc_lib.path("compiler_rt.zig"), "lib/compiler_rt.zig");
            _ = lib_stage.addCopyFile(zigc_lib.path("c.zig"), "lib/c.zig");
            _ = lib_stage.addCopyFile(zigc_lib.path("fuzzer.zig"), "lib/fuzzer.zig");
            _ = lib_stage.addCopyFile(zigc_lib.path("zig.h"), "lib/zig.h");
            _ = lib_stage.addCopyFile(zigc_lib.path("compiler/test_runner.zig"), "lib/compiler/test_runner.zig");

            const run_tar = b.addSystemCommand(&.{ "tar", "-czf" });
            run_tar.setName("pack zig stdlib (playground)");
            const zig_tar_gz = run_tar.addOutputFileArg("zig.tar.gz");
            run_tar.addArg("-C");
            run_tar.addDirectoryArg(lib_stage.getDirectory());
            run_tar.addArg("lib");

            _ = playground_assets.addCopyFile(
                zigc_wasm.path("bin/zig.wasm"),
                b.fmt("zig-{s}.wasm", .{playground_zig_version}),
            );
            _ = playground_assets.addCopyFile(
                lib_compiler_rt.getEmittedBin(),
                b.fmt("libcompiler_rt-{s}.a", .{playground_zig_version}),
            );
            _ = playground_assets.addCopyFile(
                zig_tar_gz,
                b.fmt("zig-{s}.tar.gz", .{playground_zig_version}),
            );
        }

        const install_pg = b.addInstallDirectory(.{
            .source_dir = playground_assets.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "static/assets/playground",
        });
        install_pg.step.name = "install playground wasm assets";

        // -- Steps: pg - installs playground assets --- //
        pg_step.dependOn(&install_pg.step);
    }

    // --- Ziex App Executable --- //
    const app_exe = b.addExecutable(.{
        .name = "ziex_dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app_exe.root_module.addImport("initoptions", b.createModule(.{
        .root_source_file = b.path("../src/build/init/InitOptions.zig"),
        .target = target,
        .optimize = optimize,
    }));
    app_exe.root_module.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));
    app_exe.root_module.addImport("tree_sitter_zx", tree_sitter_zx_dep.module("tree_sitter_zx"));
    if (!target.result.cpu.arch.isWasm())
        if (b.lazyDependency("lunasvg", .{ .optimize = optimize, .target = target })) |lunasvg|
            app_exe.root_module.addImport("lunasvg", lunasvg.module("lunasvg"));
    app_exe.root_module.addImport("geist_fonts", addGeistFontsModule(b));
    app_exe.root_module.addImport("branding", addBrandingModule(b));

    app_exe.step.dependOn(pg_step);

    const site_opts = b.addOptions();
    site_opts.addOption(bool, "use_dusty", server_backend == .dusty);
    app_exe.root_module.addOptions("site_opts", site_opts);

    // --- Ziex setup: wires dependencies and adds `zx`/`dev` build steps --- //
    var zx = try ziex.init(b, app_exe, .{
        .app = .{
            // .path = b.path("app"),
            // .base_path = "/test",
            .features = app_features,
            .client = app_client,
            .server = .{
                .backend = switch (server_backend) {
                    .std => .std,
                    .auto, .dusty => .auto,
                },
            },
        },
        .cli = .{ .optimize = optimize, .log_level = log_level },
    });
    zx.addImport("cli_args", ziex_dep.module("cli_args"));
    if (!target.result.cpu.arch.isWasm() and server_backend == .dusty) {
        if (b.lazyDependency("dusty", .{ .target = target, .optimize = optimize, .use_tls = false })) |dusty_dep| {
            zx.addImport("dusty", dusty_dep.module("dusty"));
        }
    }

    // --- ZX Components --- //
    if (true) {
        // Single File
        const icons_mod = zx.addComponent(.{ .root_source_file = b.path("component/icon.zx") });
        zx.app.module.addImport("icon", icons_mod);
        // multifile
        zx.addComponentImport("component", .{ .root_source_file = b.path("component/main.zx") });
        // from deps
        const ui_dep = b.dependency("ui", .{});
        const ui_mod = ui_dep.module("ui");
        ui_mod.addImport("zx", zx.zx_module);
        zx.addImport("ui", ui_mod);

        // templates/_base pages, mounted under /template
        const template_path = b.path("../templates/_base/app/pages");
        const template_pages = [_]struct { []const u8, []const u8 }{
            .{ "tmpl_layout", "layout.zx" },
            .{ "tmpl_home", "page.zx" },
            .{ "tmpl_form", "form/page.zx" },
            .{ "tmpl_actions", "actions/page.zx" },
            .{ "tmpl_events", "events/page.zx" },
            .{ "tmpl_db", "db/page.zx" },
            .{ "tmpl_kv", "kv/page.zx" },
        };
        for (template_pages) |page| {
            const mod = zx.addComponent(.{ .root_source_file = template_path.path(b, page[1]) });
            zx.addImport(page[0], mod);
        }
        // Template stylesheet, at the /assets/style.css path its layout links to
        const template_css = b.addInstallFile(b.path("../templates/_base/app/assets/style.css"), "static/assets/style.css");
        b.default_step.dependOn(&template_css.step);

        // /bench: CSR js-framework-benchmark from bench/ziex
        const bench_csr_mod = zx.addComponent(.{
            .root_source_file = b.path("../bench/ziex/app/pages/js-framework-benchmark/csr/page.zx"),
        });
        zx.addImport("bench_csr", bench_csr_mod);
    }

    if (true) {
        const tailwindcss_b = tailwindcss.addBuild(b, .{
            .config = .{
                .input = b.path("app/styles/tailwind.css"),
                // .minify = true,
                // .optimize = true,
                // .map = false,
            },
        });
        const css_install = b.addInstallFile(tailwindcss_b.file, "static/assets/_/tailwind.css");
        css_install.step.name = "install tailwind.css";
        b.default_step.dependOn(&css_install.step);
    }

    if (true) {
        const css_builds = tailwindcss.addBuilds(b, &.{
            .{
                .name = "docs",
                .config = .{
                    .input = b.path("app/assets/docs.css"),
                    // .minify = true,
                    .optimize = true,
                    // .map = false,
                },
            },
            .{
                .name = "home",
                .config = .{
                    .input = b.path("app/assets/home.css"),
                    // .minify = true,
                    .optimize = true,
                    // .map = false,
                },
            },
        });

        for (css_builds) |css_build| {
            const css_fn = css_build.name orelse return error.MissingName;
            const css_install = b.addInstallFile(css_build.file, b.fmt("static/assets/_/{s}.css", .{css_fn}));
            css_install.step.name = b.fmt("install {s}.css", .{css_fn});
            b.default_step.dependOn(&css_install.step);
        }
    }

    if (true) {
        const is_release = optimize != .debug;
        const build_client_wasm = app_client.wasm.link;
        if (build_client_wasm and app_client.bindings.link) {
            const ziex_js_files = ziex_js_dep.namedWriteFiles("ziex_js");
            const init_name = if (is_release) "init.js" else "init.dev.js";
            const init_js = ziex_js_files.getDirectory().path(b, b.fmt("wasm/{s}", .{init_name}));
            const install_main_js = b.addInstallFile(init_js, b.fmt("static/assets/{s}", .{jsbinding_name}));
            install_main_js.step.name = "install app.js bindings";
            b.default_step.dependOn(&install_main_js.step);
        }
    }

    if (true) {
        const playground_scripts = esbuild.addBuild(b, .{
            .name = "playground_scripts",
            .config = .{
                .entrypoints = &.{
                    b.path("app/pages/playground/scripts/editor.ts"),
                    b.path("app/pages/playground/scripts/workers/runner.ts"),
                    b.path("app/pages/playground/scripts/workers/zig.ts"),
                    b.path("app/pages/playground/scripts/workers/zx.ts"),
                    b.path("app/pages/playground/scripts/workers/zls.ts"),
                    b.path("app/pages/playground/scripts/shell.ts"),
                },
                // just-bash's browser build still imports node:zlib for gzip
                .alias = &.{
                    .{ .key = "node:zlib", .path = b.path("app/pages/playground/scripts/stubs/zlib.ts") },
                },
                .format = .esm,
                .splitting = false,
                .platform = .browser,
                .minify = optimize != .debug,
                .define = &.{
                    .{
                        .key = "VERSION",
                        .value = b.fmt("\"{s}-{s}\"", .{ ziex.info.version, id }),
                    },
                    .{
                        .key = "ZIG_VERSION",
                        .value = b.fmt("\"{s}\"", .{playground_zig_version}),
                    },
                },
            },
        });

        const install_playground_scripts = b.addInstallDirectory(.{
            .source_dir = playground_scripts.dir,
            .install_dir = .prefix,
            .install_subdir = "static/assets/playground",
        });
        install_playground_scripts.step.name = "install playground scripts";
        b.default_step.dependOn(&install_playground_scripts.step);
    }

    if (true) {
        const branding_dep = b.dependency("branding", .{});
        const install_branding = b.addInstallDirectory(.{
            .source_dir = branding_dep.path("."),
            .install_dir = .prefix,
            .install_subdir = "static/assets/branding",
            .include_extensions = &.{ "webp", "svg", "png", "gif" },
        });
        install_branding.step.name = "install branding";
        b.default_step.dependOn(&install_branding.step);
    }
}

// Cache-busting id: hash of the sources packed into / compiled for the playground and client assets
fn assetId(b: *std.Build, _: std.builtin.Optimize) []const u8 {
    const io = b.graph.io;
    const dirs = [_][]const u8{ "../src", "../pkg/ziex/src" };
    var hasher = std.hash.Wyhash.init(0);
    for (dirs) |sub| {
        var dir = b.root.openDir(io, sub, .{ .iterate = true }) catch |err|
            std.debug.panic("unable to open {s}: {t}", .{ sub, err });
        defer dir.close(io);
        b.dependOnDirectoryContents(b.path(sub));

        var files: std.ArrayList([]const u8) = .empty;
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch |err| std.debug.panic("unable to walk {s}: {t}", .{ sub, err })) |entry| switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(b.path(b.pathJoin(&.{ sub, entry.path }))),
            .file => files.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM"),
            else => {},
        };
        // Walk order is fs-dependent
        std.mem.sort([]const u8, files.items, {}, struct {
            fn less(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.order(u8, a, c) == .lt;
            }
        }.less);

        for (files.items) |rel| {
            const data = dir.readFileAlloc(io, rel, b.allocator, .unlimited) catch |err|
                std.debug.panic("unable to read {s}/{s}: {t}", .{ sub, rel, err });
            b.dependOnFileContents(b.path(b.pathJoin(&.{ sub, rel })));
            hasher.update(rel);
            hasher.update(&.{0});
            hasher.update(data);
            b.allocator.free(data);
        }
    }
    return b.fmt("{x:0>8}", .{@as(u32, @truncate(hasher.final()))});
}

fn addGeistFontsModule(b: *std.Build) *std.Build.Module {
    const geist = b.dependency("geist_font", .{});
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(geist.path("Geist/ttf/Geist-Regular.ttf"), "Geist-Regular.ttf");
    _ = wf.addCopyFile(geist.path("Geist/ttf/Geist-Bold.ttf"), "Geist-Bold.ttf");
    const root = wf.add("root.zig",
        \\pub const regular = @embedFile("Geist-Regular.ttf");
        \\pub const bold = @embedFile("Geist-Bold.ttf");
        \\
    );
    return b.createModule(.{
        .root_source_file = root,
    });
}

fn addBrandingModule(b: *std.Build) *std.Build.Module {
    const branding = b.dependency("branding", .{});
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(branding.path("banner-animated.svg"), "banner-animated.svg");
    const root = wf.add("root.zig",
        \\pub const banner_animated = @embedFile("banner-animated.svg");
        \\
    );
    return b.createModule(.{
        .root_source_file = root,
    });
}

const esbuild = @import("esbuild");
const tailwindcss = @import("tailwindcss");
