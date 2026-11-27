const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    app: std.Build.LazyPath,
    manifest: std.Build.LazyPath,
    enable_httpz: bool = true,
    cli_command: []const u8 = "serve",
    base_path: ?[]const u8 = null,
    server_port: ?u16 = null,
    server_address: ?[]const u8 = null,
};

pub fn configure(b: *std.Build, zx_mod: *std.Build.Module, opts: Options) *std.Build.Module {
    const app_opts = b.addOptions();
    app_opts.addOption(?[]const u8, "app_base_path", opts.base_path);
    app_opts.addOption(?u16, "server_port", opts.server_port);
    app_opts.addOption(?[]const u8, "server_address", opts.server_address);
    app_opts.addOption([]const u8, "cli_command", opts.cli_command);
    app_opts.addOption(bool, "enable_httpz", opts.enable_httpz);
    app_opts.addOption(bool, "omit_prerendered", false);
    app_opts.addOption(bool, "feat_sqlite_server", false);
    app_opts.addOption(bool, "feat_sqlite_client", false);
    app_opts.addOption(bool, "feat_pg_server", false);
    app_opts.addOption(bool, "feat_mysql_server", false);
    app_opts.addOption(bool, "feat_kv_server", false);
    app_opts.addOption(bool, "feat_kv_client", false);
    app_opts.addOption(bool, "feat_cache_server", false);
    app_opts.addOption(bool, "feat_ai_server", false);
    app_opts.addOption([]const u8, "ai_provider", "openai");
    app_opts.addOption(bool, "feat_flag_server", false);
    app_opts.addOption([]const u8, "flag_provider", "ofrep");
    app_opts.addOption(bool, "feat_email_server", false);
    app_opts.addOption([]const u8, "email_provider", "resend");
    app_opts.addOption(bool, "feat_bucket_server", false);
    app_opts.addOption(?[]const u8, "bucket_provider", null);
    zx_mod.addOptions("app_opts", app_opts);

    if (opts.enable_httpz) {
        zx_mod.addImport("httpz", b.dependency("httpz", .{ .target = opts.target, .optimize = opts.optimize }).module("httpz"));
    }

    const app_mod = b.createModule(.{
        .root_source_file = opts.app,
        .imports = &.{
            .{ .name = "zx", .module = zx_mod },
        },
    });
    app_mod.addImport("app", app_mod);
    zx_mod.addImport("app", app_mod);

    zx_mod.addImport("manifest", b.createModule(.{
        .root_source_file = opts.manifest,
    }));

    return app_mod;
}
