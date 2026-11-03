// Tailwind Plugin Example (lines 1-22)
const std = @import("std");
const tailwindcss = @import("tailwindcss");

pub fn build(b: *std.Build) !void {
    const css = tailwindcss.addBuild(b, .{
        .config = .{
            .input = b.path("app/styles/tailwind.css"),
            // .minify = true,
            // .optimize = true,
            // .map = false,
        },
    });
    const install = b.addInstallFile(css.file, "static/assets/tailwind.css");
    b.default_step.dependOn(&install.step);
}

// Esbuild Plugin Example (lines 24-45)
const std = @import("std");
const esbuild = @import("esbuild");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const out = esbuild.addBuild(b, .{
        .config = .{
            .entrypoints = &.{b.path("app/main.ts")},
            .platform = .browser,
            .minify = optimize != .debug,
            .sourcemap = if (optimize == .debug) .@"inline" else .none,
        },
    });
    const install = b.addInstallDirectory(.{
        .source_dir = out.dir,
        .install_dir = .prefix,
        .install_subdir = "static/assets",
    });
    b.default_step.dependOn(&install.step);
}

// TypeScript Plugin Example (lines 47-60)
const std = @import("std");
const typescript = @import("typescript");

pub fn build(b: *std.Build) !void {
    const dts = typescript.addBuild(b, .{
        .name = "app.d.ts",
        .config = .{
            .project = b.path("tsconfig.json"),
        },
    });
    _ = dts;
}

// Combined Plugins Example (lines 62-83)
const std = @import("std");
const esbuild = @import("esbuild");
const tailwindcss = @import("tailwindcss");

pub fn build(b: *std.Build) !void {
    const css = tailwindcss.addBuild(b, .{
        .config = .{ .input = b.path("app/styles/tailwind.css") },
    });
    b.default_step.dependOn(&b.addInstallFile(css.file, "static/assets/tailwind.css").step);

    const js = esbuild.addBuild(b, .{
        .config = .{
            .entrypoints = &.{b.path("app/main.ts")},
            .platform = .browser,
        },
    });
    b.default_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = js.dir,
        .install_dir = .prefix,
        .install_subdir = "static/assets",
    }).step);
}
