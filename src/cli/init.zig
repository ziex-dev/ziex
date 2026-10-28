const std = @import("std");
const app_template = @import("app_template");

const remote = @import("init/remote.zig");
const tui = @import("../tui/main.zig");
const context = @import("shared/context.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
const colors = tui.Colors;
const TemplateFile = app_template.TemplateFile;
const templates = app_template.files;
pub const command = cli_args.init;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const t_val = args.template;
    const force_init = args.force;
    const existing_init = args.existing;
    const init_path = std.mem.trim(u8, args.path orelse ".", " ");

    var printer = tui.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    // Validations
    const is_clean_dir = try isDirEmpty(io, init_path);
    const has_init_path_arg = init_path.len > 0 and !std.mem.eql(u8, init_path, ".");
    if (!is_clean_dir and !force_init and !existing_init) {
        printer.warning("Directory is not empty.", .{});
        try ctx.writer.print("\nYou may want either:\n\n", .{});
        if (!has_init_path_arg)
            try ctx.writer.print("  {s}zx init{s} {s}{s}{s}{s}  {s}# Create in a new directory{s}\n\n", .{
                colors.cyan,
                colors.reset,
                colors.bold,
                colors.gray,
                "my-app",
                colors.reset,
                colors.gray,
                colors.reset,
            });
        try ctx.writer.print("  {s}zx init{s} {s}{s}{s}{s}--force{s}  {s}# Create in current directory, overriding existing files{s}\n\n", .{
            colors.cyan,
            colors.reset,
            colors.bold,
            colors.gray,
            if (has_init_path_arg) init_path else "",
            if (has_init_path_arg) " " else "",
            colors.reset,
            colors.gray,
            colors.reset,
        });
        return;
    }

    if (force_init and !is_clean_dir) {
        std.debug.print("{s}Initializing with existing files, overriding if files already exist.{s}\n", .{ colors.yellow, colors.reset });
    }

    // Non-builtin templates are fetched from `github:ziex-dev/template-<name>`.
    const template_name = std.meta.stringToEnum(TemplateFile.Name, t_val) orelse {
        printer.header("{s} Initializing Ziex project!", .{tui.Printer.emoji("○")});
        printer.info("[{s}] (github:{s}/template-{s})", .{ t_val, "ziex-dev", t_val });

        remote.fetch(io, ctx.allocator, app.environ_map, t_val, init_path) catch |err| switch (err) {
            error.TemplateNotFound, error.NoReleaseFound => {
                printer.warning("Template '{s}' not found in the ziex-dev org (looked for github:ziex-dev/template-{s} with a published release).", .{ t_val, t_val });
                return;
            },
            error.NetworkError => {
                printer.warning("Failed to download template '{s}'. Check your network connection and try again.", .{t_val});
                return;
            },
            else => return err,
        };

        try printInitFooter(&printer, ctx.allocator, init_path, has_init_path_arg);
        return;
    };

    printer.header("{s} Initializing Ziex project!", .{tui.Printer.emoji("○")});
    printer.info("[{s}]", .{@tagName(template_name)});

    const bin_name = if (template_name == .docker)
        try detectExeName(io, ctx.allocator, init_path)
    else
        null;
    defer if (bin_name) |n| ctx.allocator.free(n);

    try std.Io.Dir.cwd().createDirPath(io, init_path);
    for (templates) |template| {
        if (template_name == .docker) {
            if (template.name != .docker) continue;
        } else {
            if (template.name != null and template.name.? != template_name) continue;
        }

        const output_path = try std.fs.path.join(ctx.allocator, &.{ init_path, template.path });
        defer ctx.allocator.free(output_path);

        // Skip if file exists and existing flag is set
        if (existing_init) {
            const file_exists = blk: {
                std.Io.Dir.cwd().access(io, output_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => continue,
                };
                break :blk true;
            };
            if (file_exists) continue;
        }

        if (std.fs.path.dirname(output_path)) |parent_dir| {
            try std.Io.Dir.cwd().createDirPath(io, parent_dir);
        }

        var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });

        printer.filepath(template.path);
        defer file.close(io);

        const content = if (bin_name) |name|
            try renderDockerTemplate(ctx.allocator, template.content, name)
        else
            template.content;
        defer if (bin_name != null) ctx.allocator.free(content);

        try file.writeStreamingAll(io, content);
    }

    try printInitFooter(&printer, ctx.allocator, init_path, has_init_path_arg);
}

fn printInitFooter(printer: *tui.Printer, allocator: std.mem.Allocator, init_path: []const u8, has_init_path_arg: bool) !void {
    if (has_init_path_arg) {
        const suggested_cmd = try std.fmt.allocPrint(allocator, "cd {s} && zig build dev", .{init_path});
        defer allocator.free(suggested_cmd);
        printer.footer("Now run {s}\n\n{s}{s}{s}", .{ tui.Printer.emoji("→"), colors.cyan, suggested_cmd, colors.reset });
    } else {
        printer.footer("Now run {s}\n\n{s}", .{ tui.Printer.emoji("→"), colors.Fns.cyan("zig build dev") });
    }
}

const default_exe_name = "ziex_app";
const default_port = 3000;

fn detectExeName(io: std.Io, allocator: std.mem.Allocator, init_path: []const u8) ![]const u8 {
    if (scanMetaExeName(io, allocator, init_path)) |name| return name else |_| {}
    if (parseZonName(io, allocator, init_path)) |name| return name else |_| {}
    return allocator.dupe(u8, default_exe_name);
}

fn scanMetaExeName(io: std.Io, allocator: std.mem.Allocator, init_path: []const u8) ![]const u8 {
    const bin_dir_path = try std.fs.path.join(allocator, &.{ init_path, "zig-out", "bin" });
    defer allocator.free(bin_dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, bin_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".meta.zon")) continue;
        const stem = entry.name[0 .. entry.name.len - ".meta.zon".len];
        if (stem.len == 0) continue;
        return allocator.dupe(u8, stem);
    }
    return error.ProgramNotFound;
}

fn parseZonName(io: std.Io, allocator: std.mem.Allocator, init_path: []const u8) ![]const u8 {
    const zon_path = try std.fs.path.join(allocator, &.{ init_path, "build.zig.zon" });
    defer allocator.free(zon_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(64 * 1024));
    defer allocator.free(data);

    const needle = ".name";
    var idx = std.mem.indexOf(u8, data, needle) orelse return error.NameNotFound;
    idx += needle.len;
    while (idx < data.len and (data[idx] == ' ' or data[idx] == '=')) idx += 1;
    if (idx >= data.len or data[idx] != '.') return error.NameNotFound;
    idx += 1; // skip the leading dot of the enum literal
    const start = idx;
    while (idx < data.len and (std.ascii.isAlphanumeric(data[idx]) or data[idx] == '_')) idx += 1;
    if (idx == start) return error.NameNotFound;
    return allocator.dupe(u8, data[start..idx]);
}

fn renderDockerTemplate(allocator: std.mem.Allocator, content: []const u8, bin_name: []const u8) ![]const u8 {
    const with_bin = try std.mem.replaceOwned(u8, allocator, content, "$BIN_NAME", bin_name);
    defer allocator.free(with_bin);

    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{default_port}) catch unreachable;
    return std.mem.replaceOwned(u8, allocator, with_bin, "$PORT", port_str);
}

pub fn isDirEmpty(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    return try iter.next(io) == null;
}
