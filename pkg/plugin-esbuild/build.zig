const std = @import("std");
const plugin_system = @import("plugin_system");
const util = @import("src/util.zig");
const host_esbuild = @import("src/host_esbuild.zig");

pub const BuildConfig = @import("src/EsbuildBuildConfig.zig");

pub const Build = struct {
    name: ?[]const u8 = null,
    config: BuildConfig,
};

pub const Output = struct {
    dir: std.Build.LazyPath,
    run: *std.Build.Step.Run,
};

pub var esbuild_path: ?std.Build.LazyPath = null;

/// Override the Zig-managed host esbuild binary (e.g. `node_modules/.bin/esbuild`).
pub fn setEsbuildPath(path: std.Build.LazyPath) void {
    esbuild_path = path;
}

pub fn addBuild(b: *std.Build, build_item: Build) Output {
    return innerInitSingle(b, build_item) catch @panic("addBuild");
}

pub fn addBuilds(b: *std.Build, builds: []const Build) []const Output {
    const outputs = b.allocator.alloc(Output, builds.len) catch @panic("OOM");
    for (builds, 0..) |build_item, i| {
        outputs[i] = innerInitSingle(b, build_item) catch @panic("addBuilds");
    }
    return outputs;
}

fn innerInitSingle(b: *std.Build, build_item: Build) !Output {
    const dep = b.dependencyFromBuildZig(@This(), .{});
    const plugin_exe = dep.artifact("esbuild");

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const alloc = arena.allocator();

    const json_buf = try std.json.Stringify.valueAlloc(alloc, util.options(build_item.config), .{});

    const run = b.addRunArtifact(plugin_exe);

    const step_name = b.fmt("build {s} {s}", .{ deriveName(b, build_item, &run.step), "esbuild" });
    run.setName(step_name);
    run.setStdIn(.{ .bytes = json_buf });

    run.addArg("--name");
    run.addArg(build_item.name orelse "esbuild");

    // Zig-managed output directory (enables build caching)
    run.addArg("--outdir");
    const outdir = run.addOutputDirectoryArg2("dist", .{});

    // Dep file for transitive dependency tracking (rebuilds when imported files change)
    run.addArg("--dep-file");
    _ = run.addDepFileOutputArg2("dist.d", .{});

    // Prefer an explicit path; otherwise the host @esbuild/* binary from this package's lazy deps.
    if (esbuild_path orelse resolveHostEsbuild(dep)) |bin| {
        run.addArg("--esbuild-path");
        run.addFileArg(bin);
    }
    for (build_item.config.entrypoints) |ep| {
        run.addArg("--entry");
        run.addFileArg(ep);
    }
    for (build_item.config.alias) |a| {
        run.addArg("--alias");
        run.addArg(a.key);
        run.addFileArg(a.path);
    }

    return .{ .dir = outdir, .run = run };
}

fn resolveHostEsbuild(plugin_dep: *std.Build.Dependency) ?std.Build.LazyPath {
    const host_dep = plugin_dep.builder.dependencyLazy(host_esbuild.depName(), .{}) catch return null;
    // zig fetch strips the npm tarball's top-level `package/` directory.
    return host_dep.path(plugin_dep.builder.fmt("{s}", .{host_esbuild.exeName()}));
}

fn deriveName(b: *std.Build, self: Build, step: *std.Build.Step) []const u8 {
    if (self.name) |n| return n;
    if (self.config.entrypoints.len > 0) {
        const ep = self.config.entrypoints[0];
        // TODO: LazyPath.basename has been removed zig 0.17, figoure out alternative
        // const ep_name = ep.basename(b, step);
        const ep_name = ep.src_path.sub_path;
        _ = step;
        _ = b;
        return ep_name;
    } else {
        return "";
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sync_deps_step = b.option(bool, "sync-deps", "Sync optionalDependencies via zig fetch") orelse false;

    const plugin_system_dep = b.dependency("plugin_system", .{ .target = target, .optimize = optimize });
    const plugin_system_mod = plugin_system_dep.module("plugin_system");

    const exe = b.addExecutable(.{
        .name = "esbuild",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plugin_system", .module = plugin_system_mod },
            },
        }),
    });
    b.installArtifact(exe);

    {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Run the plugin");
        run_step.dependOn(&run_cmd.step);
    }

    if (sync_deps_step) {
        const default_step = b.getInstallStep();
        const esbuild_dep = b.dependency("esbuild", .{});
        plugin_system.addOptionalDependencyFetches(b, default_step, plugin_system.readNpmPackageJson(b, esbuild_dep));
    }
}
