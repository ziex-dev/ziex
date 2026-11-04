const std = @import("std");
const typescript = @import("typescript");

pub fn build(b: *std.Build) !void {
    const builds = try b.allocator.alloc(typescript.Build, 2);
    builds[0] = .{
        .name = "check",
        .config = .{
            .project = b.path("tsconfig.json"),
            .no_emit = true,
        },
    };
    builds[1] = .{
        .name = "dts",
        .config = .{
            .project = b.path("tsconfig.json"),
            .declaration = true,
            .emit_declaration_only = true,
        },
    };
    const outputs = typescript.addBuilds(b, builds);
    for (outputs, 0..) |output, i| {
        const install = b.addInstallDirectory(.{
            .source_dir = output.dir,
            .install_dir = .prefix,
            .install_subdir = b.fmt("dist-{d}", .{i}),
        });
        b.default_step.dependOn(&install.step);
    }
}
