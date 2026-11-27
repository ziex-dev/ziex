const std = @import("std");
const initlib = @import("src/build/init.zig");
const build_zon = @import("build.zig.zon");
const util = @import("src/build/util.zig");

/// Options for initializing
pub const InitOptions = initlib.InitOptions;

/// Transpiled ZX module
pub const TranslatedZx = @import("src/build/TranslatedZx.zig");

/// Initialize a Ziex project (sets up Ziex, dependencies, executables, wasm executable and `serve` step)
pub const init = initlib.init;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_lsp = b.option(bool, "lsp", "Enable zx lsp (backed by ZLS)") orelse true;
    const enable_sqlite = b.option(bool, "feature-sqlite", "Enabled sqlite support") orelse false;
    const enable_postgres = b.option(bool, "feature-postgres", "Enabled postgres support") orelse false;
    const enable_mysql = b.option(bool, "feature-mysql", "Enabled mysql support") orelse false;
    const log_level = b.option(std.log.Level, "cli-log-level", "Log level for the CLI") orelse .info;
    const is_client = b.option(bool, "is-client", "Building for the browser (client)") orelse false;
    const enable_httpz = b.option(bool, "enable-httpz", "Enable httpz backend for server") orelse false;
    const version = util.getVersion(b);

    // Options
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.fmt("{f}", .{version}));
    options.addOption([]const u8, "description", build_zon.description);
    options.addOption([]const u8, "repository", build_zon.repository);
    options.addOption([]const u8, "homepage", build_zon.homepage);
    options.addOption([]const u8, "minimum_zig_version", build_zon.minimum_zig_version);

    // Dependencies
    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const tree_sitter_zx_dep = b.dependency("tree_sitter_zx", .{ .target = target, .optimize = optimize, .@"build-shared" = false });
    const tree_sitter_mdzx_dep = b.dependency("tree_sitter_mdzx", .{ .target = target, .optimize = optimize, .@"build-shared" = false });

    // --- Features Module --- //
    const lang_mod = b.addModule("lang", .{ .root_source_file = b.path("src/lang.zig"), .target = target, .optimize = optimize });
    lang_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));
    lang_mod.addImport("tree_sitter_zx", tree_sitter_zx_dep.module("tree_sitter_zx"));
    lang_mod.addImport("tree_sitter_mdzx", tree_sitter_mdzx_dep.module("tree_sitter_mdzx"));

    // --- Main `zx` Module --- //
    const mod = b.addModule("zx", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    // Imports (zx)
    {
        if (enable_sqlite) {
            const db_sqlite_dep = b.lazyDependency("db_sqlite", .{ .target = target, .optimize = optimize });
            if (db_sqlite_dep) |a| mod.addImport("sqlite", a.module("sqlite"));
        }
        if (!is_client) {
            if (enable_postgres) {
                const db_postgres_dp = b.lazyDependency("db_postgres", .{ .target = target, .optimize = optimize });
                if (db_postgres_dp) |a| mod.addImport("db_postgres", a.module("postgres"));
            }

            if (enable_mysql) {
                const db_mysql_dp = b.lazyDependency("db_mysql", .{ .target = target, .optimize = optimize });
                if (db_mysql_dp) |a| mod.addImport("db_mysql", a.module("mysql"));
            }

            if (enable_httpz) {
                if (b.lazyDependency("httpz", .{ .target = target, .optimize = optimize })) |httpz_dep| {
                    mod.addImport("httpz", httpz_dep.module("httpz"));
                }
            }
        }

        mod.addOptions("zx_info", options);
    }

    // --- Ziex CLI (Transpiler, Exporter, Dev Server) --- //
    // Vendored from https://codeberg.org/ziglang/zig/pulls/31620 until it is merged.
    const std_cli_mod = b.createModule(.{
        .root_source_file = b.path("vendor/std/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_args_mod = b.addModule("cli_args", .{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_args_mod.addImport("std_cli", std_cli_mod);

    const exe_build_options = b.addOptions();
    exe_build_options.addOption(bool, "enable_lsp", enable_lsp);
    exe_build_options.addOption(bool, "enable_zls", enable_lsp);
    exe_build_options.addOption(u2, "log_level", @backingInt(log_level));

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("std_cli", std_cli_mod);
    cli_mod.addImport("lang", lang_mod);
    cli_mod.addImport("zx_info", options.createModule());
    cli_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));
    cli_mod.addImport("tree_sitter_zx", tree_sitter_zx_dep.module("tree_sitter_zx"));
    cli_mod.addOptions("build_options", exe_build_options);
    cli_mod.addAnonymousImport("app_template", .{ .root_source_file = b.path("templates/Template.zig") });

    if (enable_lsp) {
        if (b.lazyDependency("lsp_kit", .{ .target = target, .optimize = optimize })) |lsp_kit| {
            cli_mod.addImport("lsp", lsp_kit.module("lsp"));
        }

        if (b.lazyDependency("zls", .{ .target = target, .optimize = optimize })) |zls| {
            cli_mod.addImport("zls", zls.module("zls"));
        }
    }

    const exe = b.addExecutable(.{ .name = "zx", .root_module = cli_mod });
    if (enable_lsp and target.result.cpu.arch.isWasm()) exe.rdynamic = true;
    b.installArtifact(exe);

    // --- Steps: Run --- //
    if (b.isRoot()) {
        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
    }

    // --- Steps: Test --- //
    if (b.isRoot()) {
        const mode_test = b.createModule(.{ .root_source_file = b.path("src/root.zig") });
        if (b.lazyDependency("db_sqlite", .{})) |ad| mode_test.addImport("sqlite", ad.module("sqlite"));
        if (b.lazyDependency("db_postgres", .{})) |ad| mode_test.addImport("db_postgres", ad.module("postgres"));
        if (b.lazyDependency("db_mysql", .{})) |ad| mode_test.addImport("db_mysql", ad.module("mysql"));
        mode_test.addOptions("zx_info", options);
        mode_test.addImport("lang", lang_mod);

        const test_app_mod = @import("src/Build.zig").Testing.configure(b, mode_test, .{
            .target = target,
            .optimize = optimize,
            .app = b.path("test/server/app.zig"),
            .manifest = b.path("test/server/manifest.zon"),
        });

        const testing_mod = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = mode_test },
                .{ .name = "app", .module = test_app_mod },
                .{ .name = "lang", .module = lang_mod },
                .{ .name = "tree_sitter", .module = tree_sitter_dep.module("tree_sitter") },
                .{ .name = "tree_sitter_mdzx", .module = tree_sitter_mdzx_dep.module("tree_sitter_mdzx") },
                .{ .name = "builder", .module = b.createModule(.{
                    .root_source_file = b.path("src/cli/dev/Builder.zig"),
                }) },
            },
        });
        const html_hover_mod = b.createModule(.{
            .root_source_file = b.path("src/lsp/root.zig"),
            .imports = &.{
                .{ .name = "lang", .module = lang_mod },
            },
        });

        if (enable_lsp)
            if (b.lazyDependency("lsp_kit", .{ .target = target, .optimize = optimize })) |lsp_kit| {
                html_hover_mod.addImport("lsp", lsp_kit.module("lsp"));
            };

        testing_mod.addImport("html_hover", html_hover_mod);

        const testing_mod_tests = b.addTest(.{
            .root_module = testing_mod,
            .test_runner = .{ .path = b.path("test/runner.zig"), .mode = .simple },
        });
        const test_run = b.addRunArtifact(testing_mod_tests);
        test_run.step.dependOn(b.getInstallStep());

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&test_run.step);

        // protocol/auth/url unit tests for the postgres package; no server needed
        const pg_unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("pkg/db-postgres/src/postgres.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(pg_unit).step);

        // protocol/auth/url unit tests for the mysql package; no server needed
        const mysql_unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("pkg/db-mysql/src/mysql.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(mysql_unit).step);
    }

    // --- Steps: e2e (Runs e2e step for site/) --- //
    if (b.isRoot()) {
        const e2e_step = b.step("e2e", "Run the site in development mode");
        const e2e_cmd = b.addSystemCommand(&.{ "npx", "playwright", "test" });
        e2e_cmd.setCwd(b.path("test/e2e"));
        e2e_step.dependOn(&e2e_cmd.step);
        e2e_cmd.addPassthruArgs();
    }

    // --- Steps: Dev (Runs dev step for site/) --- //
    if (b.isRoot()) {
        const dev_step = b.step("dev", "Run the site in development mode");
        const dev_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "dev" });
        dev_cmd.setCwd(b.path("site"));
        dev_step.dependOn(&dev_cmd.step);
        dev_cmd.addPassthruArgs();
    }

    // --- Steps: Site (Runs build step for site/) --- //
    if (b.isRoot()) {
        const site_step = b.step("site", "Build the site");
        const site_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        site_cmd.setCwd(b.path("site"));
        site_step.dependOn(&site_cmd.step);
        site_cmd.addPassthruArgs();
    }

    // --- Steps: Gen (Runs steps of tools/codegen) --- //
    if (b.isRoot()) {
        const gen_step = b.step("gen", "Run generators/dev tasks: zig build gen -- <css|events|web|html|tags|mcp|all|transpile-only|syncbench>...");
        const gen_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        gen_cmd.setCwd(b.path("tools/codegen"));
        gen_cmd.addPassthruArgs();
        gen_step.dependOn(&gen_cmd.step);
    }
}

/// Transpile a single `.zx` / `.mdzx` file into a `TranslatedZx`, mirroring
/// `std.Build.addTranslateC` (one root source → one cached translate step →
/// `createModule()` / `addModule()`).
///
///     const tzx = ziex.addTranslateZx(b, .{ .root_source_file = b.path("icons.zx") });
///     const icons = tzx.createModule();
///     icons.addImport("zx", zx.module);   // `zx` from `ziex.init`
///
/// Prefer this over directory transpile when you want per-file rebuilds under
/// `zig build --watch`. The host transpiler CLI is resolved for the host
/// target so it can execute during the build; it never enters the runtime
/// module graph.
pub fn addTranslateZx(b: *std.Build, opts: TranslatedZx.Options) *TranslatedZx {
    const zx_host_dep = b.dependencyFromBuildZig(@This(), .{});
    return TranslatedZx.create(b, zx_host_dep.artifact("zx"), opts);
}

pub const info = .{
    .version = build_zon.version,
    .description = build_zon.description,
    .repository = build_zon.repository,
    .homepage = build_zon.homepage,
    .minimum_zig_version = build_zon.minimum_zig_version,
};
