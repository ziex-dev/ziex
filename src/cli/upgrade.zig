const std = @import("std");
const builtin = @import("builtin");
const zx_info = @import("zx_info");

const context = @import("shared/context.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.upgrade;

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const version = args.version;

    var maybe_cmd_str: ?[:0]u8 = null;
    defer if (maybe_cmd_str) |s| ctx.allocator.free(s);

    const install_cmd = switch (builtin.os.tag) {
        .windows => blk: {
            if (std.mem.eql(u8, version, "latest")) {
                break :blk [_][:0]const u8{ "powershell", "-c", "irm " ++ zx_info.homepage["https://".len..] ++ "/install.ps1 | iex" };
            } else {
                const prefix = if (std.mem.startsWith(u8, version, "v")) "" else "v";
                maybe_cmd_str = try ctx.allocator.printSentinel("& ([scriptblock]::Create((irm {s}/install.ps1))) -Version '{s}{s}'", .{ zx_info.homepage["https://".len..], prefix, version }, 0);
                break :blk [_][:0]const u8{ "powershell", "-c", maybe_cmd_str.? };
            }
        },
        .linux, .macos => blk: {
            if (std.mem.eql(u8, version, "latest")) {
                break :blk [_][:0]const u8{ "bash", "-c", "curl -fsSL " ++ zx_info.homepage ++ "/install | bash" };
            } else {
                const prefix = if (std.mem.startsWith(u8, version, "v")) "" else "v";
                maybe_cmd_str = try ctx.allocator.printSentinel("curl -fsSL {s}/install | bash -s -- {s}{s}", .{ zx_info.homepage, prefix, version }, 0);
                break :blk [_][:0]const u8{ "bash", "-c", maybe_cmd_str.? };
            }
        },
        else => return error.UnsupportedOS,
    };

    var system = try std.process.spawn(app.io, .{ .argv = &install_cmd });
    const term = try system.wait(app.io);
    _ = term;

    // try ctx.writer.print("Upgraded to: ", .{});
    // var zx_version = std.process.Child.init(&.{ "zx", "version" }, ctx.allocator);
    // try zx_version.spawn();
    // _ = try zx_version.wait();
}
