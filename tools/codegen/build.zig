//! Generators and dev tasks for the ziex repo. Every step works on the repo
//! root (two levels up), so run them from the root via `zig build gen -- <step>...`.

const std = @import("std");

const usage = "usage: zig build gen -- <css|events|web|html|tags|mcp|all|transpile-only|syncbench>...";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.path("../..");
    const all = b.step("all", "Run every generator");

    const webref = b.dependency("webref", .{});
    inline for (.{
        .{ "css", "css.zig", "CSS types from webref", .debug },
        .{ "events", "events.zig", "DOM event types from webref", .debug },
        .{ "web", "web.zig", "Typed browser bindings from webref", .fast },
    }) |g| {
        const run = addGenerator(b, g[0], g[1], g[2], g[3], root, all);
        run.addDirectoryArg2(webref.path(""), .{});
    }

    _ = addGenerator(b, "html", "html_docs.zig", "HTML element/attribute docs for the LSP (network)", .debug, root, all);

    {
        const step = b.step("tags", "pkg/ziex TAG_NAMES + DELEGATED_EVENTS");
        inline for (.{ "tagsgen", "delegatedeventsgen" }) |name| {
            const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", name });
            cmd.setCwd(root.path(b, "pkg/ziex"));
            step.dependOn(&cmd.step);
        }
        all.dependOn(step);
    }

    {
        const step = b.step("mcp", "src/runtime/core/mcp/gen from the MCP spec");
        const spec = b.dependency("mcp_spec", .{});
        // Newest first; a dual-era server speaks all of them.
        const spec_versions = .{ "2026-07-28", "2025-11-25" };
        const exe = b.addExecutable(.{
            .name = "mcp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("mcp.zig"),
                .target = b.graph.host,
            }),
        });
        const update = b.addUpdateSourceFiles();
        inline for (.{ "version", "methods", "error_codes", "defs_index" }) |kind| {
            const run = b.addRunArtifact(exe);
            run.addArg(kind);
            inline for (spec_versions) |v| {
                run.addArg(v);
                run.addFileArg(spec.path("schema/" ++ v ++ "/schema.json"));
            }
            update.addCopyFileToSource(run.captureStdOut(.{}), "../../src/runtime/core/mcp/gen/" ++ kind ++ ".zig");
        }
        step.dependOn(&update.step);
        all.dependOn(step);
    }

    {
        const ziex = b.dependency("ziex", .{ .target = target, .optimize = optimize });
        const exe = b.addExecutable(.{
            .name = "transpile-only",
            .root_module = b.createModule(.{
                .root_source_file = root.path(b, "test/transpile_only.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zx", .module = ziex.module("zx") },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        run.setCwd(root);
        b.step("transpile-only", "Update snapshots without running full tests").dependOn(&run.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "syncbench",
            .root_module = b.createModule(.{
                .root_source_file = root.path(b, "site/app/pages/bench.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run = b.addRunArtifact(exe);
        run.setCwd(root);
        run.addPassthruArgs();
        b.step("syncbench", "Run synchronization benchmark from GH actions").dependOn(&run.step);
    }

    b.default_step = b.step("usage", "Print usage");
    b.default_step.dependOn(&b.addFail(usage).step);
}

fn addGenerator(
    b: *std.Build,
    comptime name: []const u8,
    comptime source: []const u8,
    comptime description: []const u8,
    comptime optimize: std.lang.Optimize,
    root: std.Build.LazyPath,
    all: *std.Build.Step,
) *std.Build.Step.Run {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run = b.addRunArtifact(exe);
    run.setCwd(root);
    run.has_side_effects = true;
    const step = b.step(name, description);
    step.dependOn(&run.step);
    all.dependOn(step);
    return run;
}
