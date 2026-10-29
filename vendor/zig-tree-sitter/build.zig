const std = @import("std");
const ts = @import("tree_sitter");

const wasm_url = "https://github.com/tree-sitter/tree-sitter-c/releases/download/v0.24.1/tree-sitter-c.wasm";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const enable_wasm = b.option(bool, "enable-wasm", "Enable Wasm support") orelse false;
    options.addOption(bool, "enable_wasm", enable_wasm);

    const core = b.dependencyFromBuildZig(ts, .{
        .target = target,
        .optimize = optimize,
        .amalgamated = true,
        .@"build-shared" = false,
        .@"enable-wasm" = enable_wasm,
    });
    const core_lib = core.artifact("tree-sitter");
    b.addNamedLazyPath("wasi-include", core.namedLazyPath("wasi-include"));
    const wasmtime = if (enable_wasm) core.builder.lazyDependency(ts.wasmtimeDep(target.result), .{}) else null;

    const module = b.addModule("tree_sitter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(core_lib);
    module.addOptions("build", options);

    const lib = b.addLibrary(.{
        .name = "zig-tree-sitter",
        .root_module = module,
        .linkage = .static,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install generated docs");
    docs_step.dependOn(&install_docs.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.linkLibrary(lib);
    test_mod.addOptions("build", options);

    const run_tests = b.addRunArtifact(b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    if (wasmtime) |dep| {
        if (target.result.os.tag == .windows) {
            if (target.result.abi != .msvc) {
                const copy_wasmtime = b.addInstallLibFile(dep.path("lib/libwasmtime.a"), "wasmtime.lib");
                lib.step.dependOn(&copy_wasmtime.step);
                module.addLibraryPath(b.path("zig-out/lib"));
                test_mod.addLibraryPath(b.path("zig-out/lib"));
            } else {
                const fail = b.addFail("FIXME: cannot build with enable-wasm for MSVC");
                test_step.dependOn(&fail.step);
            }

            test_mod.linkSystemLibrary("advapi32", .{});
            test_mod.linkSystemLibrary("bcrypt", .{});
            test_mod.linkSystemLibrary("ntdll", .{});
            test_mod.linkSystemLibrary("ole32", .{});
            test_mod.linkSystemLibrary("shell32", .{});
            test_mod.linkSystemLibrary("userenv", .{});
            test_mod.linkSystemLibrary("ws2_32", .{});
        } else {
            module.addLibraryPath(dep.path("lib"));
            test_mod.addLibraryPath(dep.path("lib"));
        }

        module.linkSystemLibrary("wasmtime", .{
            .use_pkg_config = .no,
            .search_strategy = .no_fallback,
            .preferred_link_mode = .static,
        });
        test_mod.linkSystemLibrary("unwind", .{
            .use_pkg_config = .no,
        });
    }

    // HACK: fetch tree-sitter-c only for tests (ziglang/zig#19914)
    if (b.pkg_hash.len > 0) return;
    if (b.option(bool, "test", "Fetch test dependencies") orelse false) {
        const ts_c_dep = b.lazyDependency("tree-sitter-c", .{
            .target = target,
            .optimize = optimize,
        });
        if (ts_c_dep) |dep| {
            const depmod = dep.module("tree-sitter-c");
            depmod.addImport("tree-sitter", module);
            test_mod.addImport("tree-sitter-c", depmod);

            if (enable_wasm) {
                const run_curl = b.addSystemCommand(&.{ "curl", "-LSsf", wasm_url, "-o" });
                const wasm_file = run_curl.addOutputFileArg("tree-sitter-c.wasm");
                run_curl.expectExitCode(0);
                run_curl.expectStdErrEqual("");
                test_step.dependOn(&run_curl.step);
                test_mod.addAnonymousImport("tree-sitter-c.wasm", .{
                    .root_source_file = wasm_file,
                });
            }
        }
    }
}
