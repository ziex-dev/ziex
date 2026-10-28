const std = @import("std");
const std_cli = @import("std_cli");

const asset = @import("app/asset.zig");
const context = @import("shared/context.zig");
const cli_args = @import("root.zig");
const help = @import("shared/help.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.app;

pub fn run(ctx: CommandContext, parsed: anytype) !void {
    const sub = parsed.subcommand orelse {
        help.write(command, parsed, ctx.writer, .{ .prefix = "zx app", .color = help.useColor(ctx.app) }) catch {};
        return;
    };
    switch (sub) {
        .asset => |s| switch (s.kind) {
            .help => unreachable,
            .args => |args| try asset.run(ctx, args),
        },
    }
}
