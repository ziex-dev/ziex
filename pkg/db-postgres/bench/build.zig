const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // benchmarks default to -Doptimize=fast
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default fast)") orelse .fast;
    // e.g. -Dlibpq=$(brew --prefix libpq); omitted => libpq driver is skipped
    const libpq_prefix = b.option([]const u8, "libpq", "libpq install prefix containing include/ and lib/");
    // e.g. -Dopenssl=$(brew --prefix openssl@3); needed for pg.zig over TLS (it uses OpenSSL)
    const openssl_prefix = b.option([]const u8, "openssl", "OpenSSL install prefix, enables TLS in pg.zig");

    // one stand-in module for the optional C imports (a file may belong to only one module)
    const empty = b.createModule(.{ .root_source_file = b.path("src/empty.zig") });
    const ours = b.dependency("db_postgres", .{ .target = target, .optimize = optimize }).module("postgres");
    // the real zx.Db front end (src/runtime/core/Db.zig) on top of this package; staged so its
    // sibling imports (../../wasm) stay inside the module path. Copied fresh on every build.
    const runtime = b.addWriteFiles();
    _ = runtime.addCopyDirectory(b.path("../../../src/runtime/core"), "core", .{});
    _ = runtime.addCopyDirectory(b.path("../../../src/runtime/wasm"), "wasm", .{});
    const zx_db = b.createModule(.{
        .root_source_file = runtime.add("zx_db.zig", "pub const Db = @import(\"core/Db.zig\");\n"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "db_postgres", .module = ours },
            // Db.Sqlite is never used here
            .{ .name = "sqlite", .module = empty },
        },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ours", .module = ours },
            .{ .name = "zx_db", .module = zx_db },
            .{ .name = "pg", .module = pgModule(b, target, optimize, openssl_prefix) },
        },
    });

    const options = b.addOptions();
    options.addOption(bool, "libpq", libpq_prefix != null);
    options.addOption(bool, "pg_tls", openssl_prefix != null);
    mod.addOptions("config", options);

    if (libpq_prefix) |prefix| {
        const include = b.pathJoin(&.{ prefix, "include" });
        const lib = b.pathJoin(&.{ prefix, "lib" });
        const translate = b.addTranslateC(.{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ include, "libpq-fe.h" }) },
            .target = target,
            .optimize = optimize,
        });
        translate.addIncludePath(.{ .cwd_relative = include });
        mod.addImport("libpq", translate.createModule());
        mod.addLibraryPath(.{ .cwd_relative = lib });
        mod.addRPath(.{ .cwd_relative = lib });
        mod.linkSystemLibrary("pq", .{});
        mod.link_libc = true;
    } else {
        mod.addImport("libpq", empty);
    }

    const exe = b.addExecutable(.{ .name = "pg-bench", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the benchmark (pass the URL after --)").dependOn(&run.step);
}

fn pgModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, openssl_prefix: ?[]const u8) *std.Build.Module {
    const prefix = openssl_prefix orelse return b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg");
    return b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
        .openssl_lib_name = @as([]const u8, "ssl"),
        .openssl_lib_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) },
        .openssl_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) },
    }).module("pg");
}
