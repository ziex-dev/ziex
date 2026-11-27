// All of this are copied from ZLS/Zig codebase

const std = @import("std");
const manifest = @import("../../build.zig.zon");

/// Must match the `version` in `build.zig.zon`.
/// Keep as `MAJOR.MINOR.PATCH-dev` during development; drop `.pre` only when tagging a stable release.
const ziex_version = std.SemanticVersion.parse(manifest.version) catch unreachable;

/// Resolve the version embedded in the binary.
///
/// Tags look like `v0.1.0-dev.1389`. `git describe` then yields either that tag
/// exactly, or `v0.1.0-dev.1389-3-gc36f2aa1` (tag + commits since + hash), which
/// becomes `0.1.0-dev.1392+c36f2aa1`. Falls back to `MAJOR.MINOR.PATCH-dev` when
/// git is unavailable. Override with `-Dversion=`.
pub fn getVersion(b: *std.Build) std.SemanticVersion {
    if (b.option([]const u8, "version", "Version to embed in the binary. Must be a semantic version.")) |semver_string| {
        return std.SemanticVersion.parse(semver_string) catch |err| {
            std.debug.panic("Expected -Dversion={s} to be a semantic version: {}", .{ semver_string, err });
        };
    }

    // TODO: for now always return the version from the manifest
    // until behavior with this new versioning scheme is tested
    if (true) return ziex_version;
    if (ziex_version.pre == null and ziex_version.build == null) return ziex_version;

    // Ensure git version changes get picked up
    // https://codeberg.org/ziglang/zig/issues/35473
    b.graph.poisonCache();

    const argv: []const []const u8 = &.{
        "git", "-C", b.fmt("{f}", .{b.root}), "--git-dir", ".git", "describe", "--match", "v*.*.*", "--tags",
    };
    const git_describe_untrimmed = switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| stdout,
        else => |res| {
            const argv_joined = std.mem.join(b.allocator, " ", argv) catch @panic("OOM");
            std.log.warn(
                \\Failed to run git describe to resolve Ziex version: {t}
                \\command: {s}
                \\
                \\Consider passing the -Dversion flag to specify the version.
            , .{ res, argv_joined });
            return ziex_version;
        },
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");
    const desc = if (std.mem.startsWith(u8, git_describe, "v")) git_describe[1..] else git_describe;

    // Untagged development build: <tag>-<height>-g<hash>
    // e.g. v0.1.0-dev.1389-3-gc36f2aa1 → 0.1.0-dev.1392+c36f2aa1
    if (std.mem.findScalarLast(u8, desc, '-')) |hash_sep| {
        const commit_id = desc[hash_sep + 1 ..];
        if (commit_id.len > 1 and commit_id[0] == 'g') {
            if (std.mem.findScalarLast(u8, desc[0..hash_sep], '-')) |height_sep| {
                const commit_height = desc[height_sep + 1 .. hash_sep];
                if (isAllDigits(commit_height)) {
                    const tagged_ancestor = desc[0..height_sep];
                    const ancestor_ver = std.SemanticVersion.parse(tagged_ancestor) catch {
                        std.debug.print("Unexpected 'git describe' tag: '{s}'\n", .{git_describe});
                        std.process.exit(1);
                    };
                    const height = std.fmt.parseUnsigned(u64, commit_height, 10) catch unreachable;

                    return .{
                        .major = ancestor_ver.major,
                        .minor = ancestor_ver.minor,
                        .patch = ancestor_ver.patch,
                        .pre = bumpDevPre(b, ancestor_ver.pre orelse "dev", height),
                        .build = commit_id[1..],
                    };
                }
            }
        }
    }

    // Exact tag (e.g. v0.1.0-dev.1389 or v0.1.0).
    return std.SemanticVersion.parse(desc) catch {
        std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
        std.process.exit(1);
    };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// `dev` + height → `dev.<height>`; `dev.1389` + 3 → `dev.1392`.
fn bumpDevPre(b: *std.Build, pre: []const u8, height: u64) []const u8 {
    if (std.mem.findScalarLast(u8, pre, '.')) |dot| {
        const base = pre[0..dot];
        const n_str = pre[dot + 1 ..];
        if (std.fmt.parseUnsigned(u64, n_str, 10)) |n| {
            return b.fmt("{s}.{d}", .{ base, n + height });
        } else |_| {}
    }
    return b.fmt("{s}.{d}", .{ pre, height });
}
