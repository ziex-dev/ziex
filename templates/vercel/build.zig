const std = @import("std");
const ziex = @import("ziex");

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Ziex App Executable ---
    const app_exe = b.addExecutable(.{
        .name = "ziex_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // --- Ziex setup: wires dependencies and adds `zx`/`dev` build steps ---
    _ = try ziex.init(b, app_exe, .{
        .app = .{
            .client = .{
                .bindings = .{ .install_subdir = "bindings/ziex" },
            },
        },
    });
}
