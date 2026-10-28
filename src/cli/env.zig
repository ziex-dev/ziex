const std = @import("std");
const builtin = @import("builtin");
const zx_info = @import("zx_info");

const context = @import("shared/context.zig");
const zx_module = @import("shared/zx_module.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.env;

const Format = cli_args.EnvFormat;

// Internal, set by `zx dev` and wasm hosts; not user config:
// ZIEX_INNER_PORT, ZIEX_OUTER_PORT, ZIEX_STOP_ON_EOF,
// ZIEX_DEV_EVENT, ZIEX_DEV_BUILD_MS, ZIEX_DEV_FIRST, ZIEX_DEV_RESOLVED, ZIEX_DEV_URL.
const EnvVars = struct {
    ZIEX_MODULE_PATH: ?[]const u8 = null,
    ZIEX_ZIG_PATH: ?[]const u8 = null,
    ZIEX_ROOT_DIR: ?[]const u8 = null,
    ZIEX_DATA_DIR: ?[]const u8 = null,
    ZIEX_STATIC_DIR: ?[]const u8 = null,
    ZIEX_EDITOR: ?[]const u8 = null,
};

const Info = struct {
    zx_exe: ?[]const u8 = null,
    version: []const u8,
    zx_module_path: ?[]const u8 = null,
    env: EnvVars = .{},
};

pub fn run(ctx: CommandContext, args: anytype) !void {
    const environ_map = ctx.app.environ_map;

    const zx_exe: ?[:0]u8 = if (builtin.os.tag == .wasi)
        null
    else
        std.process.executablePathAlloc(ctx.app.io, ctx.allocator) catch null;
    defer if (zx_exe) |p| ctx.allocator.free(p);

    const resolved_module_path: ?[]u8 = if (environ_map.get("ZIEX_MODULE_PATH") != null)
        null
    else
        zx_module.resolve(ctx.app.io, ctx.allocator, environ_map, ".");
    defer if (resolved_module_path) |p| ctx.allocator.free(p);

    const info: Info = .{
        .zx_exe = zx_exe,
        .version = zx_info.version,
        .zx_module_path = environ_map.get("ZIEX_MODULE_PATH") orelse resolved_module_path,
        .env = .{
            .ZIEX_MODULE_PATH = environ_map.get("ZIEX_MODULE_PATH"),
            .ZIEX_ZIG_PATH = environ_map.get("ZIEX_ZIG_PATH"),
            .ZIEX_ROOT_DIR = environ_map.get("ZIEX_ROOT_DIR"),
            .ZIEX_DATA_DIR = environ_map.get("ZIEX_DATA_DIR"),
            .ZIEX_STATIC_DIR = environ_map.get("ZIEX_STATIC_DIR"),
            .ZIEX_EDITOR = environ_map.get("ZIEX_EDITOR"),
        },
    };

    const fmt: Format = args.format;
    switch (fmt) {
        .zon => {
            try std.zon.stringify.serialize(info, .{ .whitespace = true }, ctx.writer);
            try ctx.writer.writeByte('\n');
        },
        .json => {
            try std.json.Stringify.value(info, .{
                .whitespace = .indent_4,
                .emit_null_optional_fields = true,
            }, ctx.writer);
            try ctx.writer.writeByte('\n');
        },
    }
}
