const std = @import("std");
const plugin_system = @import("plugin_system");
const util = @import("src/util.zig");
const host_tsc = @import("src/host_tsc.zig");

pub const BuildConfig = @import("src/TypescriptBuildConfig.zig");

pub const Build = struct {
    name: ?[]const u8 = null,
    config: BuildConfig,
};

pub const Output = struct {
    dir: std.Build.LazyPath,
    run: *std.Build.Step.Run,
};

pub var tsc_path: ?std.Build.LazyPath = null;

/// Override the Zig-managed host tsc binary (e.g. `node_modules/.bin/tsc`).
pub fn setTscPath(path: std.Build.LazyPath) void {
    tsc_path = path;
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
    const plugin_exe = dep.artifact("typescript");

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const alloc = arena.allocator();

    const json_buf = try std.json.Stringify.valueAlloc(alloc, util.options(build_item.config), .{});

    const run = b.addRunArtifact(plugin_exe);

    const step_name = b.fmt("build {s} {s}", .{ deriveName(b, build_item, &run.step), "typescript" });
    run.setName(step_name);
    run.setStdIn(.{ .bytes = json_buf });

    run.addArg("--name");
    run.addArg(build_item.name orelse "typescript");

    // Zig-managed output directory (enables build caching)
    run.addArg("--outdir");
    const outdir = run.addOutputDirectoryArg2("dts", .{});

    // Dep file for rebuild tracking
    run.addArg("--dep-file");
    _ = run.addDepFileOutputArg2("dts.d", .{});

    // Prefer an explicit path; otherwise the host @typescript/typescript-* binary from lazy deps.
    if (tsc_path orelse resolveHostTsc(dep)) |bin| {
        run.addArg("--tsc-path");
        run.addFileArg(bin);
    }

    if (build_item.config.project) |project| {
        run.addArg("--project");
        run.addFileArg(project);
        run.addFileInput(project);
    }

    for (build_item.config.inputs) |input| {
        run.addArg("--input");
        run.addFileArg(input);
        run.addFileInput(input);
    }

    return .{ .dir = outdir, .run = run };
}

fn resolveHostTsc(plugin_dep: *std.Build.Dependency) ?std.Build.LazyPath {
    const host_dep = plugin_dep.builder.dependencyLazy(host_tsc.depName(), .{}) catch return null;
    // zig fetch strips the npm tarball's top-level `package/` directory.
    // Native packages ship the binary at lib/tsc (lib/tsc.exe on Windows).
    return host_dep.path(plugin_dep.builder.fmt("lib/{s}", .{host_tsc.exeName()}));
}

fn deriveName(b: *std.Build, self: Build, step: *std.Build.Step) []const u8 {
    if (self.name) |n| return n;
    if (self.config.project) |project| {
        const project_name = project.src_path.sub_path;
        _ = step;
        _ = b;
        return project_name;
    }
    _ = step;
    _ = b;
    return "";
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sync_deps = b.option(bool, "sync-deps", "Sync optionalDependencies via zig fetch") orelse false;

    const plugin_system_dep = b.dependency("plugin_system", .{ .target = target, .optimize = optimize });
    const plugin_system_mod = plugin_system_dep.module("plugin_system");

    const exe = b.addExecutable(.{
        .name = "typescript",
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

    if (sync_deps) {
        const default_step = b.getInstallStep();
        const typescript_dep = b.dependency("typescript", .{});
        plugin_system.addOptionalDependencyFetches(b, default_step, plugin_system.readNpmPackageJson(b, typescript_dep));
    }
}
