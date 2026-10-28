const std = @import("std");
const Colors = @import("Colors.zig");

pub const Box = @This();

/// Unicode rounded box drawing characters
pub const Chars = struct {
    pub const top_left = "╭";
    pub const top_right = "╮";
    pub const bottom_left = "╰";
    pub const bottom_right = "╯";
    pub const horizontal = "─";
    pub const vertical = "│";
};

/// Box configuration options
pub const Options = struct {
    /// Border color (ANSI escape code)
    border_color: []const u8 = Colors.gray,
    /// Title color (ANSI escape code)
    title_color: []const u8 = Colors.reset,
    /// Content width (excluding borders and padding)
    width: usize = 66,
};

/// Preset styles for common use cases
pub const Style = struct {
    pub const default = Options{};
    pub const err = Options{ .border_color = Colors.red, .title_color = Colors.red };
    pub const warning = Options{ .border_color = Colors.yellow, .title_color = Colors.yellow };
    pub const success = Options{ .border_color = Colors.green, .title_color = Colors.green };
    pub const info = Options{ .border_color = Colors.cyan, .title_color = Colors.cyan };
};

/// Print a complete box with title and content lines
pub fn print(options: Options, title: []const u8, lines: []const []const u8) void {
    const border = options.border_color;
    const title_color = options.title_color;
    const width = options.width;

    // Top border
    std.debug.print("{s}{s}", .{ border, Chars.top_left });
    printHorizontalLine(width + 2);
    std.debug.print("{s}{s}\n", .{ Chars.top_right, Colors.reset });

    // Title line
    std.debug.print("{s}{s}{s} {s}{s}{s}", .{ border, Chars.vertical, Colors.reset, title_color, title, Colors.reset });
    printPadding(width, title.len);
    std.debug.print(" {s}{s}{s}\n", .{ border, Chars.vertical, Colors.reset });

    // Content lines
    for (lines) |line| {
        std.debug.print("{s}{s}{s} {s}", .{ border, Chars.vertical, Colors.reset, line });
        printPadding(width, line.len);
        std.debug.print(" {s}{s}{s}\n", .{ border, Chars.vertical, Colors.reset });
    }

    // Bottom border
    std.debug.print("{s}{s}", .{ border, Chars.bottom_left });
    printHorizontalLine(width + 2);
    std.debug.print("{s}{s}\n", .{ Chars.bottom_right, Colors.reset });
}

/// Print horizontal line characters
fn printHorizontalLine(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        std.debug.print("{s}", .{Chars.horizontal});
    }
}

/// Print padding spaces
fn printPadding(width: usize, content_len: usize) void {
    if (content_len < width) {
        const padding = width - content_len;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            std.debug.print(" ", .{});
        }
    }
}

/// Print a CLI error box (convenience function)
pub fn printCliError(comptime issue_url: []const u8, err_name: []const u8) void {
    const title = "Error: An unexpected problem occurred while running Ziex CLI.";

    // Build the lines with runtime values
    var report_buf: [256]u8 = undefined;
    const report_line = std.fmt.bufPrint(&report_buf, "Please report it at {s}", .{issue_url}) catch "Please report it at the repository";

    var details_buf: [256]u8 = undefined;
    const details_line = std.fmt.bufPrint(&details_buf, "Details: {s}", .{err_name}) catch "Details: unknown";

    print(Style.err, title, &.{ report_line, details_line });
}
