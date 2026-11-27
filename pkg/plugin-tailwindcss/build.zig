const std = @import("std");
const plugin_system = @import("plugin_system");
const util = @import("src/util.zig");

pub const BuildConfig = @import("src/TailwindBuildConfig.zig");

pub const Build = struct {
    name: ?[]const u8 = null,
    config: BuildConfig,
};

pub const Output = struct {
    name: ?[]const u8 = null,
    file: std.Build.LazyPath,
    run: *std.Build.Step.Run,
};

pub var node_path: ?std.Build.LazyPath = null;

pub fn setNodePath(path: std.Build.LazyPath) void {
    node_path = path;
}

pub fn setBunPath(path: std.Build.LazyPath) void {
    node_path = path;
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
    const plugin_exe = dep.artifact("tailwindcss");

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const alloc = arena.allocator();

    const json_buf = try std.json.Stringify.valueAlloc(alloc, util.options(build_item.config), .{});

    const run = b.addRunArtifact(plugin_exe);

    const step_name = b.fmt("build {s} {s}", .{ deriveName(b, build_item, &run.step), "tailwindcss" });
    run.setName(step_name);
    run.setStdIn(.{ .bytes = json_buf });

    run.addArg("--name");
    run.addArg(build_item.name orelse "tailwindcss");
    run.addArg("--output");
    const output = run.addOutputFileArg2("output.css", .{});
    run.addArg("--dep-file");
    _ = run.addDepFileOutputArg2("output.d", .{});

    if (node_path) |np| {
        run.addArg("--node-path");
        run.addFileArg(np);
    }

    run.addArg("--input");
    run.addFileArg(build_item.config.input);

    if (build_item.config.base) |base| {
        run.addArg("--base");
        run.addFileArg(base);
    }

    for (build_item.config.sources) |source| {
        run.addArg("--source");
        run.addFileArg(source);
    }

    return .{ .name = build_item.name, .file = output, .run = run };
}

fn deriveName(b: *std.Build, self: Build, step: *std.Build.Step) []const u8 {
    if (self.name) |n| return n;
    // TODO: LazyPath.basename has been removed zig 0.17, figoure out alternative
    // const input_name = self.config.input.basename(b, step);
    const input_name = self.config.input.src_path.sub_path;
    _ = step;
    _ = b;
    return input_name;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin_system_dep = b.dependency("plugin_system", .{ .target = target, .optimize = optimize });
    const plugin_system_mod = plugin_system_dep.module("plugin_system");

    const exe = b.addExecutable(.{
        .name = "tailwindcss",
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

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the plugin");
    run_step.dependOn(&run_cmd.step);
}
