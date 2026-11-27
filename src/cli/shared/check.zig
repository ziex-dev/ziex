//! Type-checks a Ziex app (`zx build --check`, `zx lsp` on save): runs its build in
//! check mode, which skips binaries, and maps compile errors onto `.zx`/`.zig` source.
const std = @import("std");
const BuildConfig = @import("../../build/init/BuildConfig.zig");
pub const Builder = @import("../dev/Builder.zig");
const Diagnostics = @import("../dev/Diagnostics.zig");
const util = @import("util.zig");

pub const Options = struct {
    /// Absolute build root.
    root: []const u8,
    zig_path: []const u8 = "zig",
    environ_map: ?*std.process.Environ.Map = null,
    /// Extra `zig build` arguments, e.g. `-Dtarget=...`.
    build_args: []const []const u8 = &.{},
};

pub const Result = struct {
    /// Errors and their notes; files under the build root are relative to it.
    diagnostics: []Builder.Diagnostic,
    build: ?Builder.BuildResult,

    pub fn failed(self: Result) bool {
        return self.build != null;
    }

    pub fn deinit(self: *Result) void {
        if (self.build) |*b| b.deinit();
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !Result {
    const config = try (BuildConfig{ .command = .check }).arg(allocator);
    defer allocator.free(config);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    // A deep reference trace lets `Diagnostics.relocate` reach the user's call site.
    try argv.appendSlice(allocator, &.{ util.resolveZigExe(options.environ_map, options.zig_path), "build", config, "-freference-trace=64" });
    try argv.appendSlice(allocator, options.build_args);

    var bsp: Builder.Bsp = undefined;
    try bsp.init(io, .{
        .allocator = allocator,
        .argv = argv.items,
        .environ_map = options.environ_map,
        .watch = false,
        .cwd = options.root,
    });
    var builder = bsp.builder();
    defer builder.deinit(io);

    while (try builder.next(io)) |event| switch (event) {
        .errors => |result| {
            const build = result;
            // `remap` reads generated files, which may not be under the current directory.
            rebase(allocator, build.diagnostics, options.root, .absolute);
            Diagnostics.relocate(io, allocator, options.root, build.diagnostics);
            Diagnostics.remap(allocator, build.diagnostics, .{ .io = io });
            rebase(allocator, build.diagnostics, options.root, .absolute);
            rebase(allocator, build.diagnostics, options.root, .relative);
            return .{ .diagnostics = Diagnostics.dedupe(allocator, build.diagnostics), .build = build };
        },
        .assets_installed => |result| {
            var assets = result;
            assets.deinit();
            break;
        },
        .should_restart, .build_complete_no_change, .resolved => break,
        .step_progress, .change_detected => {},
    };
    return .{ .diagnostics = &.{}, .build = null };
}

fn rebase(allocator: std.mem.Allocator, diagnostics: []Builder.Diagnostic, root: []const u8, to: enum { absolute, relative }) void {
    for (diagnostics) |*d| {
        if (d.file.len == 0) continue;
        const new: []u8 = switch (to) {
            .absolute => if (std.Io.Dir.path.isAbsolute(d.file))
                continue
            else
                std.Io.Dir.path.resolveAlloc(allocator, &.{ root, d.file }) catch continue,
            .relative => blk: {
                if (!std.mem.startsWith(u8, d.file, root) or d.file.len <= root.len + 1) continue;
                if (!std.Io.Dir.path.isSep(d.file[root.len])) continue;
                break :blk allocator.dupe(u8, d.file[root.len + 1 ..]) catch continue;
            },
        };
        allocator.free(d.file);
        d.file = new;
    }
}
