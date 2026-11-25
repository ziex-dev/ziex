const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    app_opts.addOption(bool, "feat_kv_server", false);
    app_opts.addOption(bool, "feat_kv_client", false);
    app_opts.addOption(bool, "feat_cache_server", false);
    app_opts.addOption(bool, "feat_ai_server", false);
    app_opts.addOption([]const u8, "ai_provider", "openai");
    app_opts.addOption(?[]const u8, "ai_model", null);
    app_opts.addOption(?[]const u8, "ai_image_model", null);
    app_opts.addOption(?[]const u8, "ai_base_url", null);
    app_opts.addOption(bool, "feat_flag_server", false);
    app_opts.addOption([]const u8, "flag_provider", "ofrep");
    app_opts.addOption(?[]const u8, "flag_base_url", null);
    app_opts.addOption(?[]const u8, "flag_app_id", null);
    app_opts.addOption(?[]const u8, "flag_binding", null);
    app_opts.addOption(bool, "feat_email_server", false);
    app_opts.addOption([]const u8, "email_provider", "resend");
    app_opts.addOption(?[]const u8, "email_from", null);
    app_opts.addOption(?[]const u8, "email_base_url", null);
    app_opts.addOption(?[]const u8, "email_binding", null);
    app_opts.addOption(bool, "feat_bucket_server", false);
    app_opts.addOption(?[]const u8, "bucket_provider", null);
    app_opts.addOption(?[]const u8, "bucket_binding", null);
    app_opts.addOption(?[]const u8, "bucket_name", null);
    app_opts.addOption(?[]const u8, "bucket_endpoint", null);
    app_opts.addOption(?[]const u8, "bucket_region", null);
    zx_mod.addOptions("app_opts", app_opts);

    if (opts.enable_httpz) {
        if (b.lazyDependency("httpz", .{ .target = opts.target, .optimize = opts.optimize })) |httpz_dep| {
            zx_mod.addImport("httpz", httpz_dep.module("httpz"));
        }
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
