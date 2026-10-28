const cli = @import("std_cli");

pub const bin_path = cli.Argument.init(.@"bin-path", []const u8, .{
    .default_value = "",
    .short = 'b',
    .help = "Path to the app executable (default: from <install-prefix>/manifest/app.zon)",
});

pub const build_args = cli.Argument.init(.@"build-args", []const u8, .{
    .default_value = "",
    .short = 'a',
    .help = "Additional arguments appended to zig build",
});

pub const zig_path = cli.Argument.init(.@"zig-path", []const u8, .{
    .default_value = "zig",
    .help = "Path to the zig executable (falls back to ZIEX_ZIG_PATH, then PATH)",
});

pub const verbose = cli.Argument.init(.verbose, bool, .{
    .default_value = false,
    .short = 'v',
    .help = "Show verbose output",
});

pub const install_prefix = cli.Argument.init(.@"install-prefix", []const u8, .{
    .default_value = "zig-out",
    .short = 'i',
    .help = "Install prefix for the app (default: zig-out)",
});

/// `--release`; the default differs per command, so each passes its own.
pub fn release(comptime default: []const u8, comptime help: [:0]const u8) cli.Argument {
    return cli.Argument.init(.release, []const u8, .{
        .default_value = default,
        .help = help,
    });
}
