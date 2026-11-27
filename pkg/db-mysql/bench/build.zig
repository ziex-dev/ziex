const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // benchmarks default to -Doptimize=fast
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default fast)") orelse .fast;
    // e.g. -Dmysql=$(brew --prefix mysql-client); omitted => libmysqlclient rows are skipped
    const mysql_prefix = b.option([]const u8, "mysql", "libmysqlclient install prefix containing include/ and lib/");

    // stand-in for the backends Db.zig imports but this benchmark never uses
    const empty = b.createModule(.{ .root_source_file = b.path("src/empty.zig") });
    const ours = b.dependency("db_mysql", .{ .target = target, .optimize = optimize }).module("mysql");
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
            .{ .name = "db_mysql", .module = ours },
            .{ .name = "db_postgres", .module = empty },
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
        },
    });

    const options = b.addOptions();
    options.addOption(bool, "mysql", mysql_prefix != null);
    mod.addOptions("config", options);

    if (mysql_prefix) |prefix| {
        // brew mysql-client ships headers under include/mysql/
        const include = b.pathJoin(&.{ prefix, "include", "mysql" });
        const lib = b.pathJoin(&.{ prefix, "lib" });
        const translate = b.addTranslateC(.{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ include, "mysql.h" }) },
            .target = target,
            .optimize = optimize,
        });
        translate.addIncludePath(.{ .cwd_relative = include });
        translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        mod.addImport("libmysql", translate.createModule());
        mod.addLibraryPath(.{ .cwd_relative = lib });
        mod.addRPath(.{ .cwd_relative = lib });
        mod.linkSystemLibrary("mysqlclient", .{});
        mod.link_libc = true;
    } else {
        mod.addImport("libmysql", empty);
    }

    const exe = b.addExecutable(.{ .name = "mysql-bench", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the benchmark (pass the URL after --)").dependOn(&run.step);
}
