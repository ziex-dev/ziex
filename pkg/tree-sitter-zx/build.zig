const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "build-shared", "Build a shared library") orelse true;
    const reuse_alloc = b.option(bool, "reuse-allocator", "Reuse the library allocator") orelse false;

    const library_name = "tree_sitter_zx";

    const lib: *std.Build.Step.Compile = b.addLibrary(.{
        .name = library_name,
        .linkage = if (shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .wasi,
            .pic = if (shared) true else null,
        }),
    });
    // Zig no longer bundles a libc for wasi; tree-sitter provides the headers.
    if (target.result.os.tag == .wasi) {
        if (b.lazyDependency("tree_sitter", .{})) |ts_dep| {
            lib.root_module.addSystemIncludePath(ts_dep.namedLazyPath("wasi-include"));
        }
    }

    lib.root_module.addCSourceFile(.{
        .file = b.path("src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    if (fileExists(b, "src/scanner.c")) {
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/scanner.c"),
            .flags = &.{"-std=c11"},
        });
    }

    if (reuse_alloc) {
        lib.root_module.addCMacro("TREE_SITTER_REUSE_ALLOCATOR", "");
    }
    if (optimize == .debug) {
        lib.root_module.addCMacro("TREE_SITTER_DEBUG", "");
    }

    lib.root_module.addIncludePath(b.path("src"));

    b.installArtifact(lib);
    b.installFile("src/node-types.json", "node-types.json");

    if (fileExists(b, "queries")) {
        b.installDirectory(.{
            .source_dir = b.path("queries"),
            .install_dir = .prefix,
            .install_subdir = "queries",
            .include_extensions = &.{"scm"},
        });
    }

    const module = b.addModule(library_name, .{
        .root_source_file = b.path("bindings/zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(lib);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bindings/zig/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport(library_name, module);

    // Fetch tree-sitter lazily when available so tests work across build API versions.
    if (b.lazyDependency("tree_sitter", .{})) |ts_dep| {
        tests.root_module.addImport("tree_sitter", ts_dep.module("tree_sitter"));
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

inline fn fileExists(b: *std.Build, filename: []const u8) bool {
    const dir = b.root.root_dir.handle;
    dir.access(b.graph.io, filename, .{}) catch return false;
    return true;
}
