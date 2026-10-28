const std = @import("std");

const context = @import("../shared/context.zig");
const Manifest = @import("../../build/Manifest.zig");
const hashing = @import("../../build/init/hashing.zig");
const AddElementOptions = @import("../../Build.zig").AddElementOptions;
const cli_args = @import("../root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.@"app.asset";

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src_path = args.src;
    const dest_dir = nonEmpty(args.outdir) orelse {
        try ctx.writer.print("Missing --outdir\n", .{});
        return error.MissingOutdir;
    };

    const file_stem = args.@"file-stem";
    const file_ext = args.ext;
    const injection_kind = args.kind;
    const clean_dest = args.clean;
    const no_hash = !args.hash;

    const manifest_in = nonEmpty(args.manifest);
    const manifest_out = nonEmpty(args.@"manifest-out");
    if ((manifest_in == null) != (manifest_out == null)) {
        try ctx.writer.print("--manifest and --manifest-out must be used together\n", .{});
        return error.MissingManifestPair;
    }
    const href_stem = nonEmpty(args.@"href-stem");
    if (manifest_in != null and href_stem == null) {
        try ctx.writer.print("Missing --href-stem (required when updating a manifest)\n", .{});
        return error.MissingHrefStem;
    }

    const dest_name, const href = if (no_hash) blk: {
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ file_stem, file_ext });
        const url = if (href_stem) |stem|
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, file_ext })
        else
            "";
        break :blk .{ name, url };
    } else blk: {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .unlimited);
        const hash_input = if (std.mem.eql(u8, file_ext, ".wasm"))
            try hashing.hashInput(allocator, content)
        else
            content;

        const hash_tag = hashing.contentTag(hash_input);
        const name = try std.fmt.allocPrint(allocator, "{s}.{s}{s}", .{ file_stem, &hash_tag, file_ext });
        const url = if (href_stem) |stem|
            try std.fmt.allocPrint(allocator, "{s}.{s}{s}", .{ stem, &hash_tag, file_ext })
        else
            "";
        break :blk .{ name, url };
    };

    if (std.fs.path.dirname(dest_dir)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    if (clean_dest) {
        std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};
    }
    try std.Io.Dir.cwd().createDirPath(io, dest_dir);

    const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, dest_name });
    try std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), dest_path, io, .{ .make_path = true });

    if (manifest_in) |min| {
        var manifest = try Manifest.init(io, allocator, min);

        if (std.mem.eql(u8, injection_kind, "script")) {
            try manifest.upsertJsglueInjection(.{
                .parent = .head,
                .position = .ending,
                .id = AddElementOptions.Id.jsglue,
                .element = .{
                    .tag = .script,
                    .attributes = &.{
                        .{ .name = "defer" },
                        .{ .name = "src", .value = href },
                    },
                },
            });
        } else if (std.mem.eql(u8, injection_kind, "wasmlink")) {
            try manifest.upsertWasmlinkInjection(.{
                .parent = .head,
                .position = .ending,
                .id = AddElementOptions.Id.wasmlink,
                .element = .{
                    .tag = .link,
                    .attributes = &.{
                        .{ .name = "id", .value = "__$wasmlink" },
                        .{ .name = "rel", .value = "preload" },
                        .{ .name = "as", .value = "fetch" },
                        .{ .name = "href", .value = href },
                        .{ .name = "crossorigin" },
                    },
                },
            });
        } else {
            try ctx.writer.print("Unknown --kind '{s}' (expected wasmlink or script)\n", .{injection_kind});
            return error.UnknownInjectionKind;
        }

        try manifest.commitTo(io, manifest_out.?);
    }
}

fn nonEmpty(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
