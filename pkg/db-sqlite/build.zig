const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("sqlite", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = upstream.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });

    const c = translate_c.createModule();
    c.addIncludePath(upstream.path("."));

    // Browser: no libc or OS layer. Headers are stubs; zx supplies the VFS and `errno`.
    const browser = target.result.cpu.arch.isWasm() and target.result.os.tag == .freestanding;
    if (browser) {
        c.addIncludePath(b.path("wasm/include"));
        // Zig's own libc for malloc and the string functions. Built for WASI because that
        // gates its string exports; nothing linked from it uses WASI imports.
        // As a file: `addObject` would make every exe linking sqlite also link libc.
        c.addObjectFile(b.addObject(.{ .name = "zigc", .root_module = b.createModule(.{
            .root_source_file = b.graph.path(.zig_lib, "c.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
            .optimize = optimize,
            .link_libc = true,
        }) }).getEmittedBin());
    }

    c.addCSourceFile(.{
        .file = upstream.path("sqlite3.c"),
        .flags = if (browser) &[_][]const u8{
            "-std=c99",
            // No OS layer: the VFS is zx's (Db/Sqlite/web.zig), registered from `sqlite3_os_init`.
            "-DSQLITE_OS_OTHER=1",
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOCALTIME=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DQS=0",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_ENABLE_API_ARMOR=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_UTF16=1",
        } else &[_][]const u8{
            "-std=c99",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_ENABLE_API_ARMOR=1",
            "-DSQLITE_ENABLE_UNLOCK_NOTIFY",
            "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_UTF16=1",
            "-DHAVE_USLEEP=0",
        },
    });

    const sqlite = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "c", .module = c }},
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sqlite })).step);
}
