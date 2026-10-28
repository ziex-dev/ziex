const std = @import("std");

const context = @import("shared/context.zig");
const Builder = @import("dev/Builder.zig");
const Diagnostics = @import("dev/Diagnostics.zig");
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
pub const command = cli_args.diagnose;

pub fn run(ctx: CommandContext, args: anytype) !void {
    _ = args;
    try formatErrorFromStdin(ctx.app.io, ctx.allocator, ctx.writer);
}

fn formatErrorFromStdin(io: std.Io, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var stdin_file = std.Io.File.stdin();
    var raw_buf: [8192]u8 = undefined;
    var streaming_reader = stdin_file.readerStreaming(io, &raw_buf);
    const io_reader = &streaming_reader.interface;
    var diagnostics = std.ArrayList(Builder.Diagnostic).empty;
    defer {
        for (diagnostics.items) |d| {
            allocator.free(d.file);
            allocator.free(d.message);
            if (d.source_line) |sl| allocator.free(sl);
            if (d.caret_line) |cl| allocator.free(cl);
        }
        diagnostics.deinit(allocator);
    }

    var line_writer = std.Io.Writer.Allocating.init(allocator);
    defer line_writer.deinit();

    while (io_reader.streamDelimiter(&line_writer.writer, '\n')) |_| {
        const line = line_writer.written();
        _ = io_reader.takeByte() catch {};

        if (Builder.parseDiagnostic(allocator, line)) |diag| {
            try diagnostics.append(allocator, diag);
        } else if (diagnostics.items.len > 0) {
            var last_diag = &diagnostics.items[diagnostics.items.len - 1];
            if (last_diag.source_line == null) {
                if (line.len > 0) {
                    last_diag.source_line = try allocator.dupe(u8, line);
                    line_writer.clearRetainingCapacity();
                    continue;
                }
            } else if (last_diag.caret_line == null) {
                if (std.mem.indexOfAny(u8, line, "^~") != null) {
                    last_diag.caret_line = try allocator.dupe(u8, line);
                    line_writer.clearRetainingCapacity();
                    continue;
                }
            }
        }

        line_writer.clearRetainingCapacity();
    } else |err| {
        if (err != error.EndOfStream) return err;
    }

    if (diagnostics.items.len == 0) return;

    Diagnostics.remap(allocator, diagnostics.items, .{});
    const deduped = Diagnostics.dedupe(allocator, diagnostics.items);
    diagnostics.shrinkRetainingCapacity(deduped.len);

    const formatted = try Diagnostics.formatOxlint(allocator, deduped);
    defer allocator.free(formatted);

    try writer.writeAll(formatted);
}
