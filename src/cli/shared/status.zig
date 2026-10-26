const std = @import("std");
const Builder = @import("../dev/Builder.zig");
const tui = @import("../../tui/main.zig");

const Colors = tui.Colors;

const max_step_name_len = 60;

/// Status line for an in-flight build step (`Building foo [3/10]`).
pub fn formatStepProgress(buf: []u8, label: []const u8, progress: Builder.StepProgress) []const u8 {
    const step = progress.step orelse return std.fmt.bufPrint(buf, "{s}{s}{s}...{s} {s}[{d}/{d}]{s}", .{
        Colors.cyan, Colors.bold, label, Colors.reset, Colors.dim, progress.completed, progress.total, Colors.reset,
    }) catch label;
    const shown = truncateStepName(step);
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s} {s}({s}{s}) [{d}/{d}]{s}", .{
        Colors.cyan, Colors.bold, label, Colors.reset, Colors.dim, shown.text, shown.ellipsis, progress.completed, progress.total, Colors.reset,
    }) catch label;
}

/// Keeps the status on one line; a wrapped line breaks the `\r` redraw.
pub fn truncateStepName(name: []const u8) struct { text: []const u8, ellipsis: []const u8 } {
    if (name.len <= max_step_name_len) return .{ .text = name, .ellipsis = "" };
    var end: usize = max_step_name_len;
    while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1;
    return .{ .text = name[0..end], .ellipsis = "…" };
}
