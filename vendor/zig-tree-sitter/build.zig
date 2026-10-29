const std = @import("std");
const ts = @import("tree_sitter");

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

    if (wasmtime) |dep| {
        if (target.result.os.tag == .windows) {
            if (target.result.abi != .msvc) {
                const copy_wasmtime = b.addInstallLibFile(dep.path("lib/libwasmtime.a"), "wasmtime.lib");
                lib.step.dependOn(&copy_wasmtime.step);
                module.addLibraryPath(b.path("zig-out/lib"));
            } else {
                lib.step.dependOn(&b.addFail("FIXME: cannot build with enable-wasm for MSVC").step);
            }
        } else {
            module.addLibraryPath(dep.path("lib"));
        }

        module.linkSystemLibrary("wasmtime", .{
            .use_pkg_config = .no,
            .search_strategy = .no_fallback,
            .preferred_link_mode = .static,
        });
    }
}
