const std = @import("std");
const zx_info = @import("zx_info");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.update;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const version = args.version;
    const canary = args.canary;

    const ref = if (!std.mem.eql(u8, version, "latest"))
        try ctx.allocator.print("#v{s}", .{version})
    else if (canary)
        try ctx.allocator.dupe(u8, "")
    else blk: {
        const tag = try fetchLatestReleaseTag(app.io, ctx.allocator, app.environ_map);
        defer ctx.allocator.free(tag);
        break :blk try ctx.allocator.print("#{s}", .{tag});
    };
    defer ctx.allocator.free(ref);

    const fetch_uri = try ctx.allocator.print("git+{s}{s}", .{ zx_info.repository, ref });
    defer ctx.allocator.free(fetch_uri);

    var system = util.spawnZig(app.io, .{
        .argv = &.{ args.@"zig-path", "fetch", "--save", fetch_uri },
        .environ_map = app.environ_map,
    }) catch |err| util.exitZigSpawnFailed(args.@"zig-path", err);
    const term = try system.wait(app.io);
    _ = term;
}

fn fetchLatestReleaseTag(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth_header: ?std.http.Header = if (environ_map.get("GITHUB_TOKEN")) |token| blk: {
        if (token.len == 0) break :blk null;
        break :blk .{
            .name = "authorization",
            .value = try allocator.print("Bearer {s}", .{token}),
        };
    } else null;
    defer if (auth_header) |h| allocator.free(h.value);

    const slug = std.mem.trimEnd(u8, zx_info.repository, "/");
    const owner_repo = if (std.mem.lastIndexOfScalar(u8, slug, '/')) |i|
        if (std.mem.lastIndexOfScalar(u8, slug[0..i], '/')) |j| slug[j + 1 ..] else slug
    else
        slug;

    const url = try allocator.print(
        "https://api.github.com/repos/{s}/releases/latest",
        .{owner_repo},
    );
    defer allocator.free(url);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, &.{
        .{ .name = "user-agent", .value = "ziex-cli" },
        .{ .name = "accept", .value = "application/vnd.github+json" },
    });
    if (auth_header) |h| try headers.append(allocator, h);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = @fromBackingInt(@intCast(5)),
        .response_writer = &aw.writer,
        .extra_headers = headers.items,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.NoReleaseFound;

    const parsed = std.json.parseFromSlice(struct {
        tag_name: []const u8,
    }, allocator, aw.written(), .{ .ignore_unknown_fields = true }) catch return error.NoReleaseFound;
    defer parsed.deinit();

    return allocator.dupe(u8, parsed.value.tag_name);
}
