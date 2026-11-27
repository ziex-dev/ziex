const std = @import("std");

/// Read `package.json` from an npm package dependency (root or `package/` prefix).
pub fn readNpmPackageJson(b: *std.Build, dep: *std.Build.Dependency) []const u8 {
    const dir = dep.builder.root.root_dir.handle;
    const io = b.graph.io;
    const arena = b.graph.arena;
    return dir.readFileAlloc(io, "package.json", arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => dir.readFileAlloc(io, "package/package.json", arena, .unlimited) catch |e| {
            std.debug.panic("failed to read package.json: {s}", .{@errorName(e)});
        },
        else => std.debug.panic("failed to read package.json: {s}", .{@errorName(err)}),
    };
}

/// Parallel `zig fetch` for each npm `optionalDependencies` entry, then sequential
/// `zig fetch --save=` so `build.zig.zon` updates do not race.
pub fn addOptionalDependencyFetches(
    b: *std.Build,
    parent: *std.Build.Step,
    package_json: []const u8,
) void {
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, package_json, .{}) catch |err| {
        std.debug.panic("failed to parse package.json: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    const optional = parsed.value.object.get("optionalDependencies") orelse {
        std.log.warn("package.json has no optionalDependencies; nothing to fetch", .{});
        return;
    };
    if (optional != .object) std.debug.panic("optionalDependencies must be an object", .{});

    const Item = struct { dep_name: []const u8, url: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    var it = optional.object.iterator();
    while (it.next()) |entry| {
        const pkg_name = entry.key_ptr.*;
        const version = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => std.debug.panic("optionalDependencies[{s}] must be a string version", .{pkg_name}),
        };
        items.append(b.allocator, .{
            .dep_name = depNameForNpmPackage(b, pkg_name),
            .url = npmTarballUrl(b, pkg_name, version),
        }) catch @panic("OOM");
    }

    var fetch_steps: std.ArrayList(*std.Build.Step) = .empty;
    fetch_steps.ensureTotalCapacity(b.allocator, items.items.len) catch @panic("OOM");
    for (items.items) |item| {
        const fetch = b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", item.url });
        fetch.setName(b.fmt("fetch {s}", .{item.dep_name}));
        fetch.setCwd(b.path(""));
        fetch.has_side_effects = true;
        fetch.expectExitCode(0);
        _ = fetch.captureStdErr(.{});
        fetch_steps.appendAssumeCapacity(&fetch.step);
    }

    var prev_save: ?*std.Build.Step = null;
    for (items.items) |item| {
        const save = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "fetch",
            b.fmt("--save={s}", .{item.dep_name}),
            item.url,
        });
        save.setName(b.fmt("save {s}", .{item.dep_name}));
        save.setCwd(b.path(""));
        save.has_side_effects = true;
        save.expectExitCode(0);
        _ = save.captureStdErr(.{});

        if (prev_save) |prev| {
            save.step.dependOn(prev);
        } else {
            for (fetch_steps.items) |fetch_step| save.step.dependOn(fetch_step);
        }
        parent.dependOn(&save.step);
        prev_save = &save.step;
    }
}

fn depNameForNpmPackage(b: *std.Build, npm_name: []const u8) []const u8 {
    const raw = blk: {
        if (std.mem.startsWith(u8, npm_name, "@")) {
            if (std.mem.findScalar(u8, npm_name, '/')) |slash| {
                const scope = npm_name[1..slash];
                const pkg = npm_name[slash + 1 ..];
                const scope_dash = b.fmt("{s}-", .{scope});
                break :blk if (std.mem.startsWith(u8, pkg, scope_dash))
                    pkg
                else
                    b.fmt("{s}-{s}", .{ scope, pkg });
            }
        }
        break :blk npm_name;
    };

    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(b.allocator, raw.len) catch @panic("OOM");
    for (raw) |c| {
        out.append(b.allocator, switch (c) {
            '-', '.', '/' => '_',
            else => c,
        }) catch @panic("OOM");
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn npmTarballUrl(b: *std.Build, npm_name: []const u8, version: []const u8) []const u8 {
    const basename = if (std.mem.findScalarLast(u8, npm_name, '/')) |i|
        npm_name[i + 1 ..]
    else
        npm_name;
    return b.fmt("https://registry.npmjs.org/{s}/-/{s}-{s}.tgz", .{ npm_name, basename, version });
}
