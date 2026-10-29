const std = @import("std");
const lang = @import("lang");

const Builder = @import("Builder.zig");
const tui = @import("../../tui/main.zig");
const CliConstant = @import("../shared/constant.zig");

const Colors = tui.Colors;
const log = std.log.scoped(.diagnostics);
const sourcemap = lang.sourcemap;

pub fn dedupe(allocator: std.mem.Allocator, diagnostics: []Builder.Diagnostic) []Builder.Diagnostic {
    var write: usize = 0;
    for (0..diagnostics.len) |read| {
        var is_dup = false;
        for (0..write) |prev| {
            if (diagnostics[read].line == diagnostics[prev].line and
                diagnostics[read].col == diagnostics[prev].col and
                diagnostics[read].kind == diagnostics[prev].kind and
                std.mem.eql(u8, diagnostics[read].file, diagnostics[prev].file) and
                std.mem.eql(u8, diagnostics[read].message, diagnostics[prev].message))
            {
                is_dup = true;
                break;
            }
        }
        if (is_dup) {
            allocator.free(diagnostics[read].file);
            allocator.free(diagnostics[read].message);
            if (diagnostics[read].source_line) |sl| allocator.free(sl);
            if (diagnostics[read].caret_line) |cl| allocator.free(cl);
            diagnostics[read] = .{
                .file = &.{},
                .line = 0,
                .col = 0,
                .kind = .note,
                .message = &.{},
                .source_line = null,
                .caret_line = null,
            };
        } else {
            if (write != read) {
                diagnostics[write] = diagnostics[read];
                diagnostics[read] = .{
                    .file = &.{},
                    .line = 0,
                    .col = 0,
                    .kind = .note,
                    .message = &.{},
                    .source_line = null,
                    .caret_line = null,
                };
            }
            write += 1;
        }
    }
    return diagnostics[0..write];
}

/// Remap diagnostics from generated .zig files back to original .zx source files
/// using inlined position maps. Modifies diagnostics in-place (replaces file/line/col).
pub fn remap(allocator: std.mem.Allocator, diagnostics: []Builder.Diagnostic, options: RemapOptions) void {
    for (diagnostics) |*d| {
        remapSingle(allocator, d, options) catch |err| {
            log.debug("position map remap failed for {s}: {s}", .{ d.file, @errorName(err) });
        };

        // Normalize path if it's a generated file in the zig-cache
        normalizePath(allocator, d) catch |err| {
            log.debug("path normalization failed for {s}: {s}", .{ d.file, @errorName(err) });
        };
    }
}

fn normalizePath(allocator: std.mem.Allocator, d: *Builder.Diagnostic) !void {
    const cache_pattern = ".zig-cache";
    const app_pattern = "/app/";

    const cache_pos = std.mem.indexOf(u8, d.file, cache_pattern) orelse return;
    const app_pos = std.mem.indexOfPos(u8, d.file, cache_pos + cache_pattern.len, app_pattern) orelse return;

    const relative_path = d.file[app_pos + 1 ..]; // "app/..."
    const new_file = try allocator.dupe(u8, relative_path);
    allocator.free(d.file);
    d.file = new_file;
}

fn remapSingle(allocator: std.mem.Allocator, d: *Builder.Diagnostic, options: RemapOptions) !void {
    const remapped = (try remapLocation(allocator, d.file, d.line, d.col, options)) orelse return;
    allocator.free(d.file);
    d.file = remapped.file;
    d.line = remapped.line;
    d.col = remapped.col;

    // Clear pinpoint info as they refer to the generated file context
    if (d.source_line) |sl| {
        allocator.free(sl);
        d.source_line = null;
    }
    if (d.caret_line) |cl| {
        allocator.free(cl);
        d.caret_line = null;
    }
}

pub const RemappedLocation = struct {
    file: []u8,
    line: u32,
    col: u32,
};

pub const RemapOptions = struct {
    require_mapping: bool = true,
    transpile_dir: []const u8 = CliConstant.default_transpile_dir,
};

/// Remap a generated `.zig` path/line/col to the original `.zx` using the inlined
/// position map
pub fn remapLocation(
    allocator: std.mem.Allocator,
    file: []const u8,
    line: u32,
    col: u32,
    options: RemapOptions,
) !?RemappedLocation {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Compiler diagnostics already carry a readable cache path; `@src().file`
    // from DevTools is often a short module path (e.g. `pages/foo.zig`).
    const candidates = try zigPathCandidates(allocator, file, options.transpile_dir);
    defer {
        for (candidates) |c| allocator.free(c);
        allocator.free(candidates);
    }

    var file_content: ?[]u8 = null;
    defer if (file_content) |c| allocator.free(c);

    for (candidates) |candidate| {
        if (std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .unlimited)) |content| {
            file_content = content;
            break;
        } else |_| {}
    }

    const content = file_content orelse return null;

    var map = (try sourcemap.PositionMap.parseEmbed(allocator, content)) orelse return null;
    defer map.deinit();

    if (map.source.len == 0) return null;

    const gen_line: i32 = @as(i32, @intCast(line)) - 1;
    const gen_col: i32 = @as(i32, @intCast(col)) - 1;
    if (map.generatedToSource(gen_line, gen_col)) |mapping| {
        const new_file = try allocator.dupe(u8, map.source);
        const col_val: u32 = if (mapping.source_column >= 0) @intCast(mapping.source_column + 1) else 1;
        return .{
            .file = new_file,
            .line = @intCast(mapping.source_line + 1),
            .col = col_val,
        };
    }

    if (options.require_mapping) return null;

    return .{
        .file = try allocator.dupe(u8, map.source),
        .line = line,
        .col = col,
    };
}

/// Resolve `@src()` / diagnostic paths to a readable generated `.zig` on disk.
fn zigPathCandidates(allocator: std.mem.Allocator, file: []const u8, transpile_dir: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }

    try list.append(allocator, try allocator.dupe(u8, file));

    const trimmed = std.mem.trimStart(u8, file, "./");
    if (transpile_dir.len > 0 and
        std.mem.indexOf(u8, trimmed, ".zig-cache") == null and
        std.mem.endsWith(u8, trimmed, ".zig"))
    {
        try list.append(allocator, try std.fs.path.join(allocator, &.{ transpile_dir, trimmed }));
        if (std.mem.startsWith(u8, trimmed, "app/")) {
            try list.append(allocator, try std.fs.path.join(allocator, &.{ transpile_dir, trimmed["app/".len..] }));
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Read a few lines of source context around a given line number.
pub fn readSourceContext(allocator: std.mem.Allocator, file_path: []const u8, target_line: u32, context_lines: u32) ?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024)) catch return null;
    defer allocator.free(source);

    const start_line = if (target_line > context_lines) target_line - context_lines else 1;
    const end_line = target_line + context_lines;

    var buf = std.ArrayList(u8).empty;
    var line_num: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line_num >= start_line and line_num <= end_line) {
            // Line number prefix
            const prefix = allocator.print("{d: >4} | ", .{line_num}) catch return null;
            defer allocator.free(prefix);
            buf.appendSlice(allocator, prefix) catch return null;
            buf.appendSlice(allocator, line) catch return null;
            buf.append(allocator, '\n') catch return null;

            // Add caret line for the error line
            if (line_num == target_line) {
                buf.appendSlice(allocator, "     | ") catch return null;
                // We don't have exact col info here so skip caret
            }
        }
        if (line_num > end_line) break;
        line_num += 1;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

pub fn readHighlightedSourceContext(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    target_line: u32,
    context_lines: u32,
    highlightFn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024)) catch return null;
    defer allocator.free(source);

    const start_line = if (target_line > context_lines) target_line - context_lines else 1;
    const end_line = target_line + context_lines;

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| : (line_num += 1) {
        if (line_num >= start_line and line_num <= end_line) {
            try lines.append(allocator, line);
        }
        if (line_num > end_line) break;
    }

    if (lines.items.len == 0) return null;

    var snippet = std.ArrayList(u8).empty;
    defer snippet.deinit(allocator);
    for (lines.items, 0..) |line, idx| {
        if (idx > 0) try snippet.append(allocator, '\n');
        try snippet.appendSlice(allocator, line);
    }

    const highlighted = highlightFn(allocator, snippet.items) catch try escapeHtmlAlloc(allocator, snippet.items);
    defer allocator.free(highlighted);

    return try wrapHighlightedLines(allocator, highlighted, start_line, target_line);
}

fn wrapHighlightedLines(
    allocator: std.mem.Allocator,
    highlighted: []const u8,
    start_line: u32,
    target_line: u32,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var current_line = start_line;
    var line_start: usize = 0;
    while (line_start <= highlighted.len) : (current_line += 1) {
        const rel_end = std.mem.indexOfScalarPos(u8, highlighted, line_start, '\n');
        const line_end = rel_end orelse highlighted.len;
        const line_html = highlighted[line_start..line_end];
        const is_error_line = current_line == target_line;
        try out.appendSlice(allocator, "<span class=\"zx-code-line");
        if (is_error_line) try out.appendSlice(allocator, " zx-code-line-error");
        try out.appendSlice(allocator, "\"><span class=\"zx-code-line-no\">");

        var number_buf: [16]u8 = undefined;
        const line_no = try std.fmt.bufPrint(&number_buf, "{d}", .{current_line});
        try out.appendSlice(allocator, line_no);
        try out.appendSlice(allocator, "</span><span class=\"zx-code-line-text\">");
        if (line_html.len > 0) {
            try out.appendSlice(allocator, line_html);
        } else {
            try out.appendSlice(allocator, " ");
        }
        try out.appendSlice(allocator, "</span></span>");
        if (rel_end == null) break;
        try out.append(allocator, '\n');
        line_start = line_end + 1;
    }

    return out.toOwnedSlice(allocator);
}

fn escapeHtmlAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a structured JSON payload for the error overlay.
pub fn toJson(allocator: std.mem.Allocator, diagnostics: []const Builder.Diagnostic) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"type\":\"error\",\"diagnostics\":[");
    for (diagnostics, 0..) |d, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"file\":\"");
        try jsonEscapeAppend(allocator, &buf, d.file);
        try buf.appendSlice(allocator, "\",\"line\":");
        const line_str = try allocator.print("{d}", .{d.line});
        defer allocator.free(line_str);
        try buf.appendSlice(allocator, line_str);
        try buf.appendSlice(allocator, ",\"col\":");
        const col_str = try allocator.print("{d}", .{d.col});
        defer allocator.free(col_str);
        try buf.appendSlice(allocator, col_str);
        try buf.appendSlice(allocator, ",\"kind\":\"");
        const kind_str: []const u8 = switch (d.kind) {
            .@"error" => "error",
            .warning => "warning",
            .note => "note",
        };
        try buf.appendSlice(allocator, kind_str);
        try buf.appendSlice(allocator, "\",\"message\":\"");
        try jsonEscapeAppend(allocator, &buf, d.message);
        try buf.appendSlice(allocator, "\"");

        // Add source context for error diagnostics
        if (d.kind == .@"error") {
            if (readSourceContext(allocator, d.file, d.line, 3)) |ctx| {
                defer allocator.free(ctx);
                try buf.appendSlice(allocator, ",\"source\":\"");
                try jsonEscapeAppend(allocator, &buf, ctx);
                try buf.appendSlice(allocator, "\"");
            }
        }

        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn jsonEscapeAppend(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const encoded = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                try list.appendSlice(allocator, encoded);
            },
            else => try list.append(allocator, c),
        }
    }
}

/// Enhance error output with colors if not already present
pub fn enhanceGeneric(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    // Check if output already has ANSI color codes
    if (std.mem.indexOf(u8, output, "\x1b[") != null) {
        // Already has colors, return as-is
        return try allocator.dupe(u8, output);
    }

    // Output doesn't have colors, let's add them
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try result.append(allocator, '\n');
            continue;
        }

        // Colorize based on content
        if (std.mem.indexOf(u8, line, "error:") != null or
            std.mem.indexOf(u8, line, "Error:") != null or
            std.mem.indexOf(u8, line, "ERROR:") != null)
        {
            // Red for error lines, try to colorize file paths separately
            try colorizeErrorLine(allocator, &result, line);
        } else if (std.mem.indexOf(u8, line, "warning:") != null or
            std.mem.indexOf(u8, line, "Warning:") != null)
        {
            // Yellow for warnings
            try result.appendSlice(allocator, Colors.yellow);
            try result.appendSlice(allocator, line);
            try result.appendSlice(allocator, Colors.reset);
        } else if (std.mem.indexOf(u8, line, "note:") != null or
            std.mem.indexOf(u8, line, "Note:") != null)
        {
            // Cyan for notes
            try result.appendSlice(allocator, Colors.cyan);
            try result.appendSlice(allocator, line);
            try result.appendSlice(allocator, Colors.reset);
        } else if (std.mem.indexOf(u8, line, "stderr") != null) {
            // Gray for stderr notices
            try result.appendSlice(allocator, Colors.gray);
            try result.appendSlice(allocator, line);
            try result.appendSlice(allocator, Colors.reset);
        } else if (std.mem.startsWith(u8, line, "   ") or
            std.mem.startsWith(u8, line, "  ") or
            std.mem.indexOf(u8, line, "^") != null)
        {
            // Dim for indented context lines and caret lines
            try result.appendSlice(allocator, Colors.gray);
            try result.appendSlice(allocator, line);
            try result.appendSlice(allocator, Colors.reset);
        } else if (std.mem.indexOf(u8, line, "+- ") != null) {
            // Cyan for build tree structure
            try result.appendSlice(allocator, Colors.cyan);
            try result.appendSlice(allocator, line);
            try result.appendSlice(allocator, Colors.reset);
        } else {
            // Normal output
            try result.appendSlice(allocator, line);
        }
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

/// Colorize an error line, highlighting file paths in cyan and errors in red
fn colorizeErrorLine(allocator: std.mem.Allocator, result: *std.ArrayList(u8), line: []const u8) !void {
    // Look for pattern: "filepath:line:col: error: message"
    if (std.mem.indexOf(u8, line, ":")) |first_colon| {
        // Check if this looks like a file path (before error:)
        if (std.mem.indexOf(u8, line, " error:")) |error_pos| {
            if (first_colon < error_pos) {
                // File path part (cyan)
                try result.*.appendSlice(allocator, Colors.cyan);
                try result.*.appendSlice(allocator, line[0..error_pos]);
                try result.*.appendSlice(allocator, Colors.reset);

                // Error part (red)
                try result.*.appendSlice(allocator, Colors.red);
                try result.*.appendSlice(allocator, line[error_pos..]);
                try result.*.appendSlice(allocator, Colors.reset);
                return;
            }
        }
    }

    // Fallback: just make the whole line red
    try result.*.appendSlice(allocator, Colors.red);
    try result.*.appendSlice(allocator, line);
    try result.*.appendSlice(allocator, Colors.reset);
}

/// Helper to get a single line from a file without loading the whole file every time
pub fn getLineFromFile(allocator: std.mem.Allocator, file_path: []const u8, line_num: u32) !?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch return null;
    defer allocator.free(source);

    var it = std.mem.splitScalar(u8, source, '\n');
    var current: u32 = 1;
    while (it.next()) |line| {
        if (current == line_num) return allocator.dupe(u8, line) catch null;
        current += 1;
    }
    return null;
}

pub fn formatFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, options: RemapOptions) !?[]u8 {
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

    while (reader.streamDelimiter(&line_writer.writer, '\n')) |_| {
        const line = line_writer.written();
        _ = reader.takeByte() catch {};

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

    if (diagnostics.items.len == 0) return null;

    remap(allocator, diagnostics.items, options);
    const deduped = dedupe(allocator, diagnostics.items);
    diagnostics.shrinkRetainingCapacity(deduped.len);

    return try formatOxlint(allocator, deduped);
}

pub fn formatOxlint(allocator: std.mem.Allocator, diagnostics: []const Builder.Diagnostic) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    const w = &buf.writer;

    for (diagnostics) |d| {
        const kind_symbol = switch (d.kind) {
            // .@"error" => Colors.red ++ "✖" ++ Colors.reset,
            .@"error" => Colors.red ++ "" ++ Colors.reset,
            // .warning => Colors.yellow ++ "⚠" ++ Colors.reset,
            .warning => Colors.yellow ++ "" ++ Colors.reset,
            // .note => Colors.cyan ++ "ℹ" ++ Colors.reset,
            .note => Colors.cyan ++ "" ++ Colors.reset,
        };
        const kind_text = switch (d.kind) {
            .@"error" => Colors.red ++ Colors.bold ++ "error" ++ Colors.reset,
            .warning => Colors.yellow ++ Colors.bold ++ "warning" ++ Colors.reset,
            .note => Colors.cyan ++ Colors.bold ++ "note" ++ Colors.reset,
        };

        // Header: Icon kind: message
        try w.print("  {s} {s}: {s}\n", .{ kind_symbol, kind_text, d.message });

        // File path line: ╭─[path:line:col]
        try w.print("     {s}╭─{s}[{s}{s}:{d}:{d}{s}]\n", .{
            Colors.gray,
            Colors.reset,
            Colors.cyan,
            d.file,
            d.line,
            d.col,
            Colors.reset,
        });

        // Try to get source lines
        var source_line: ?[]const u8 = d.source_line;
        var caret_line: ?[]const u8 = d.caret_line;

        var owned_source = false;
        var owned_caret = false;

        if (source_line == null) {
            source_line = getLineFromFile(allocator, d.file, d.line) catch null;
            if (source_line != null) owned_source = true;
        }

        if (caret_line == null and d.col > 0) {
            // Generate basic caret if col is available
            var cl = std.ArrayList(u8).empty;
            for (0..d.col - 1) |_| try cl.append(allocator, ' ');
            try cl.append(allocator, '^');
            caret_line = cl.toOwnedSlice(allocator) catch null;
            if (caret_line != null) owned_caret = true;
        }

        defer {
            if (owned_source) if (source_line) |sl| allocator.free(sl);
            if (owned_caret) if (caret_line) |cl| allocator.free(cl);
        }

        if (source_line) |sl| {
            // Show line content
            const trimmed_sl = std.mem.trimStart(u8, sl, " \t");
            const leading_spaces = sl.len - trimmed_sl.len;

            // Use faint (DIM) for line numbers to simulate smaller font
            try w.print(" \x1b[2m{s}{d: >3} │{s} {s}\n", .{ Colors.gray, d.line, Colors.reset, trimmed_sl });

            if (caret_line) |cl| {
                const trimmed_cl = if (cl.len > leading_spaces) cl[leading_spaces..] else cl;
                // Dot should be exactly the same color and weight as the vertical line separator
                try w.print("     \x1b[2m{s}·{s} {s}{s}{s}\n", .{ Colors.gray, Colors.reset, Colors.purple, trimmed_cl, Colors.reset });
            }
        }

        // Footer: ╰────
        try w.print("     {s}╰────{s}\n\n", .{ Colors.gray, Colors.reset });
    }

    return try allocator.dupe(u8, buf.written());
}
