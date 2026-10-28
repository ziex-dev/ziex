/// Extract specific line ranges from content (1-indexed, inclusive)
/// Similar to cli/init.zig's line extraction for templates
pub fn extractLines(allocator: zx.Allocator, content: []const u8, line_ranges: []const struct { u32, u32 }) []const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_n: u32 = 1;
    var first_line = true;

    while (line_iter.next()) |line| {
        for (line_ranges) |line_range| {
            const start, const end = line_range;
            if (line_n >= start and line_n <= end) {
                if (!first_line) {
                    result.append('\n') catch unreachable;
                }
                result.appendSlice(line) catch unreachable;
                first_line = false;
                break;
            }
        }
        line_n += 1;
    }

    return allocator.dupe(u8, result.items) catch unreachable;
}

/// Helper function to find minimum indentation in non-empty lines
pub fn findMinIndent(lines: []const []const u8, first_non_empty: usize, last_non_empty: usize) usize {
    var min_indent: usize = std.math.maxInt(usize);
    for (lines[first_non_empty .. last_non_empty + 1]) |line| {
        if (std.mem.trim(u8, line, " \t").len > 0) {
            var indent: usize = 0;
            for (line) |char| {
                if (char == ' ' or char == '\t') {
                    indent += 1;
                } else {
                    break;
                }
            }
            if (indent < min_indent) {
                min_indent = indent;
            }
        }
    }
    return if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
}

/// Helper function to remove common leading indentation
pub fn removeCommonIndentation(allocator: zx.Allocator, content: []const u8) []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines.append(line) catch unreachable;
    }

    if (lines.items.len == 0) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    // Find first and last non-empty lines
    var first_non_empty: ?usize = null;
    var last_non_empty: ?usize = null;
    for (lines.items, 0..) |line, i| {
        if (std.mem.trim(u8, line, " \t").len > 0) {
            if (first_non_empty == null) {
                first_non_empty = i;
            }
            last_non_empty = i;
        }
    }

    if (first_non_empty == null) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    const first = first_non_empty.?;
    const last = last_non_empty.?;

    // Find minimum indentation
    const min_indent = findMinIndent(lines.items, first, last);

    // Build result with indentation removed
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (lines.items[first .. last + 1], 0..) |line, i| {
        if (i > 0) {
            result.append('\n') catch unreachable;
        }
        if (std.mem.trim(u8, line, " \t").len > 0) {
            const start = @min(min_indent, line.len);
            result.appendSlice(line[start..]) catch unreachable;
        } else {
            result.appendSlice(line) catch unreachable;
        }
    }

    return allocator.dupe(u8, result.items) catch unreachable;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn shouldStripDedupePrefix(token: []const u8, sep: usize) bool {
    if (sep == 0 or sep + 2 >= token.len) return false;

    const prefix = token[0..sep];
    const rest = token[sep + 2 ..];
    if (prefix.len == 0 or rest.len == 0) return false;

    // Keep this conservative to avoid rewriting random snake_case names.
    return std.ascii.isUpper(prefix[0]) and isIdentStart(rest[0]);
}

/// Strip dedupe prefixes in identifiers, e.g. `Learn__Page` -> `Page`.
pub fn stripDedupePrefixes(allocator: zx.Allocator, content: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < content.len) {
        const ch = content[i];
        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < content.len and isIdentContinue(content[i])) : (i += 1) {}

            const token = content[start..i];
            if (std.mem.indexOf(u8, token, "__")) |sep| {
                if (shouldStripDedupePrefix(token, sep)) {
                    out.appendSlice(token[sep + 2 ..]) catch unreachable;
                    continue;
                }
            }

            out.appendSlice(token) catch unreachable;
            continue;
        }

        out.append(ch) catch unreachable;
        i += 1;
    }

    return allocator.dupe(u8, out.items) catch unreachable;
}

pub fn renderComponentToHtml(allocator: zx.Allocator, component: zx.Component) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    component.render(&aw.writer, .{}) catch unreachable;
    return allocator.dupe(u8, aw.written()) catch unreachable;
}

/// Extract a section by marker comment, e.g. "Control Flow: if"
/// The marker format is: // --- <section> ---
pub fn extractSection(allocator: zx.Allocator, content: []const u8, section: []const u8) []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines.append(line) catch unreachable;
    }

    if (lines.items.len == 0) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    const prefix = "// --- ";
    const suffix = " ---";
    var start_index: ?usize = null;

    for (lines.items, 0..) |line, i| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, prefix) and std.mem.endsWith(u8, trimmed, suffix)) {
            const inner = trimmed[prefix.len .. trimmed.len - suffix.len];
            if (std.mem.eql(u8, inner, section)) {
                start_index = i + 1;
                break;
            }
        }
    }

    if (start_index == null or start_index.? >= lines.items.len) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    var end_index: usize = lines.items.len;
    for (lines.items[start_index.?..], 0..) |line, j| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, prefix) and std.mem.endsWith(u8, trimmed, suffix)) {
            end_index = start_index.? + j;
            break;
        }
    }

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (lines.items[start_index.?..end_index], 0..) |line, i| {
        if (i > 0) {
            result.append('\n') catch unreachable;
        }
        result.appendSlice(line) catch unreachable;
    }

    const dedented = removeCommonIndentation(allocator, result.items);
    return stripDedupePrefixes(allocator, dedented);
}

// Extract only the top-level `fn` declarations and `pub const options` lines of a section,
// so docs show signatures taken from code that compiles.
pub fn extractSignatures(allocator: zx.Allocator, content: []const u8, section: []const u8) []const u8 {
    const body = extractSection(allocator, content, section);
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const is_fn = std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn ");
        const is_options = std.mem.startsWith(u8, line, "pub const options");
        if (!is_fn and !is_options) continue;

        var sig = std.mem.trimEnd(u8, line, " \t");
        if (is_fn and std.mem.endsWith(u8, sig, " {")) sig = sig[0 .. sig.len - 2];
        if (result.items.len > 0) result.append('\n') catch unreachable;
        result.appendSlice(sig) catch unreachable;
    }

    return allocator.dupe(u8, result.items) catch unreachable;
}

/// Extract a section that is wrapped in a helper function body (e.g. unwrap__...)
/// and return only the function body content with normalized indentation.
pub fn extractUnwrapSection(allocator: zx.Allocator, content: []const u8, section: []const u8) []const u8 {
    const wrapped = extractSection(allocator, content, section);
    const open = std.mem.indexOfScalar(u8, wrapped, '{') orelse return wrapped;

    var depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var i = open;

    while (i < wrapped.len) : (i += 1) {
        const ch = wrapped[i];

        if (!in_string and ch == '/' and i + 1 < wrapped.len and wrapped[i + 1] == '/') {
            // Skip line comments so apostrophes/braces in comments don't affect parsing.
            i += 2;
            while (i < wrapped.len and wrapped[i] != '\n') : (i += 1) {}
            continue;
        }

        if (ch == '"') {
            var escaped = false;
            if (i > 0) {
                var backslashes: usize = 0;
                var j = i - 1;
                while (wrapped[j] == '\\') {
                    backslashes += 1;
                    if (j == 0) break;
                    j -= 1;
                }
                escaped = (backslashes % 2) == 1;
            }

            if (!escaped) {
                if (!in_string) {
                    in_string = true;
                    string_char = ch;
                } else if (string_char == ch) {
                    in_string = false;
                    string_char = null;
                }
            }
        }

        if (in_string) continue;

        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            if (depth == 0) break;
            depth -= 1;
            if (depth == 0 and i > open + 1) {
                const body = removeCommonIndentation(allocator, wrapped[open + 1 .. i]);
                const uncommented = uncommentIfCommentOnly(allocator, body);
                return stripDiscardPrefixLines(allocator, uncommented);
            }
        }
    }

    return wrapped;
}

fn uncommentIfCommentOnly(allocator: zx.Allocator, content: []const u8) []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines.append(line) catch unreachable;
    }

    var has_non_empty = false;
    for (lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        has_non_empty = true;
        if (!std.mem.startsWith(u8, trimmed, "//")) return content;
    }

    if (!has_non_empty) return content;

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    for (lines.items, 0..) |line, i| {
        if (i > 0) out.append('\n') catch unreachable;

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        var uncommented = trimmed[2..];
        if (uncommented.len > 0 and uncommented[0] == ' ') {
            uncommented = uncommented[1..];
        }
        out.appendSlice(uncommented) catch unreachable;
    }

    return removeCommonIndentation(allocator, out.items);
}

fn stripDiscardPrefixLines(allocator: zx.Allocator, content: []const u8) []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines.append(line) catch unreachable;
    }

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    for (lines.items, 0..) |line, i| {
        if (i > 0) out.append('\n') catch unreachable;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}

        const rest = line[indent..];
        if (std.mem.startsWith(u8, rest, "_ = ")) {
            out.appendSlice(line[0..indent]) catch unreachable;
            out.appendSlice(rest[4..]) catch unreachable;
        } else {
            out.appendSlice(line) catch unreachable;
        }
    }

    return allocator.dupe(u8, out.items) catch unreachable;
}

/// Extract content inside return (...) for ZX code
pub fn extractZxReturnContent(allocator: zx.Allocator, content: []const u8) []const u8 {
    const return_pattern = "return (";
    if (std.mem.indexOf(u8, content, return_pattern)) |start_idx| {
        var depth: usize = 1;
        var i = start_idx + return_pattern.len;
        while (i < content.len and depth > 0) {
            if (content[i] == '(') {
                depth += 1;
            } else if (content[i] == ')') {
                depth -= 1;
                if (depth == 0) {
                    return allocator.dupe(u8, content[start_idx + return_pattern.len .. i]) catch unreachable;
                }
            }
            i += 1;
        }
    }
    return allocator.dupe(u8, content) catch unreachable;
}

/// Extract content after return statement for Zig code (until semicolon)
pub fn extractZigReturnContent(allocator: zx.Allocator, content: []const u8) []const u8 {
    const return_pattern = "return ";
    if (std.mem.indexOf(u8, content, return_pattern)) |start_idx| {
        var depth: usize = 0;
        var in_string = false;
        var string_char: ?u8 = null;
        var i = start_idx + return_pattern.len;

        while (i < content.len) {
            const char = content[i];

            // Handle string literals
            if (char == '"' or char == '\'') {
                // Check if previous character is not a backslash (or if backslash is escaped)
                var is_escaped = false;
                if (i > start_idx + return_pattern.len) {
                    var backslash_count: usize = 0;
                    var j = i - 1;
                    while (j >= start_idx + return_pattern.len and content[j] == '\\') {
                        backslash_count += 1;
                        j -= 1;
                    }
                    is_escaped = (backslash_count % 2) == 1;
                }

                if (!is_escaped) {
                    if (!in_string) {
                        in_string = true;
                        string_char = char;
                    } else if (char == string_char) {
                        in_string = false;
                        string_char = null;
                    }
                }
            }

            // Only process brackets/braces/parentheses outside of strings
            if (!in_string) {
                if (char == '(' or char == '{' or char == '[') {
                    depth += 1;
                } else if (char == ')' or char == '}' or char == ']') {
                    depth -= 1;
                } else if (char == ';' and depth == 0) {
                    return allocator.dupe(u8, content[start_idx + return_pattern.len .. i]) catch unreachable;
                }
            }

            i += 1;
        }
    }
    return allocator.dupe(u8, content) catch unreachable;
}

const zx = @import("zx");
const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree_sitter");
const hl_query = @embedFile("./highlights.scm");
const ts_zx = @import("tree_sitter_zx");

// Cache for tree-sitter objects to avoid recreating them on every call
const HighlightCache = struct {
    parser: *ts.Parser,
    language: *const ts.Language,
    query: *ts.Query,
    mutex: std.Io.Mutex = .init,

    var instance: ?*HighlightCache = null;

    fn getOrInit(allocator: std.mem.Allocator) !*HighlightCache {
        if (instance) |cache| return cache;

        const parser = ts.Parser.create();
        const lang: *const ts.Language = @ptrCast(ts_zx.language());

        var error_offset: u32 = 0;
        const query = ts.Query.create(@ptrCast(lang), hl_query, &error_offset) catch |err| {
            std.debug.print("Query error at offset {d}: {}\n", .{ error_offset, err });
            parser.destroy();
            lang.destroy();
            return err;
        };

        try parser.setLanguage(lang);

        const cache = try allocator.create(HighlightCache);
        cache.* = .{
            .parser = parser,
            .language = lang,
            .query = query,
        };

        instance = cache;
        // std.log.info("\x1b[1;32m[HL CACHE] Initialized (this should only happen once)\x1b[0m", .{});
        return cache;
    }
};

pub fn highlightZx(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (builtin.os.tag == .freestanding) return try allocator.dupe(u8, source);

    var total_timer = Timer.start();

    // Get cached objects (first call initializes, subsequent calls reuse)
    var timer = Timer.start();
    const cache = try HighlightCache.getOrInit(std.heap.page_allocator);
    logTiming("Cache lookup/init", timer.lap());

    // Lock for thread safety (important in concurrent requests)
    cache.mutex.lock(zx.Io.default()) catch return error.Cancelled;
    defer cache.mutex.unlock(zx.Io.default());

    timer.reset();
    const tree = cache.parser.parseString(source, null) orelse return error.ParseError;
    defer tree.destroy();
    logTimingFmt("Parse source ({d} bytes)", .{source.len}, timer.lap());

    timer.reset();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(cache.query, tree.rootNode());
    logTiming("Query execution", timer.lap());
    timer.reset();
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var last: usize = 0;
    var match_count: usize = 0;

    while (cursor.nextMatch()) |match| {
        match_count += 1;
        for (match.captures) |cap| {
            const start = cap.node.startByte();
            const end = cap.node.endByte();

            // Skip if this capture overlaps with already processed text
            if (start < last) continue;

            const capture_name = cache.query.captureNameForId(cap.index) orelse continue;

            // Copy text before this token (HTML escaped, preserving newlines)
            try appendHtmlEscapedPreserveWhitespace(&out, source[last..start]);

            // Convert dots to spaces for space-separated CSS classes
            try out.appendSlice("<span class='");
            for (capture_name) |c| {
                if (c == '.') {
                    try out.append(' ');
                } else {
                    try out.append(c);
                }
            }
            try out.appendSlice("'>");
            try appendHtmlEscapedPreserveWhitespace(&out, source[start..end]);
            try out.appendSlice("</span>");

            last = end;
        }
    }

    // Append remaining text (HTML escaped, preserving newlines)
    try appendHtmlEscapedPreserveWhitespace(&out, source[last..]);

    const result = try out.toOwnedSlice();
    logTimingFmt("HTML generation ({d} matches, {d} -> {d} bytes)", .{ match_count, source.len, result.len }, timer.lap());

    const total_elapsed = total_timer.read();
    logTiming("TOTAL highlightZx", total_elapsed);

    // var aw = std.Io.Writer.Allocating.init(allocator);
    // try tree.rootNode().format(&aw.writer);
    // return aw.written();
    //
    // var walker = tree.walk();
    // while (true) {
    //     const node = walker.node();
    //     std.log.info("{s}", .{node.kind()});
    //     if (node.desce() == null) break;
    // }
    return result;
}

fn appendHtmlEscapedPreserveWhitespace(out: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            '&' => try out.appendSlice("&amp;"),
            '"' => try out.appendSlice("&quot;"),
            '\'' => try out.appendSlice("&#39;"),
            // Preserve newlines, spaces, and tabs
            '\n', '\r', '\t', ' ' => try out.append(c),
            else => try out.append(c),
        }
    }
}

const Timer = struct {
    start_ts: std.Io.Timestamp,

    fn start() Timer {
        return .{ .start_ts = .now(zx.Io.default(), .awake) };
    }

    fn lap(self: *Timer) u64 {
        const now = std.Io.Timestamp.now(zx.Io.default(), .awake);
        const elapsed: u64 = @intCast(now.nanoseconds - self.start_ts.nanoseconds);
        self.start_ts = now;
        return elapsed;
    }

    fn read(self: Timer) u64 {
        const now = std.Io.Timestamp.now(zx.Io.default(), .awake);
        return @intCast(now.nanoseconds - self.start_ts.nanoseconds);
    }

    fn reset(self: *Timer) void {
        self.start_ts = .now(zx.Io.default(), .awake);
    }
};

fn logTiming(comptime label: []const u8, elapsed_ns: u64) void {
    if (true) return;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const color_reset = "\x1b[0m";
    const color_label = "\x1b[1;35m"; // magenta
    const color_time = if (elapsed_ms < 1) "\x1b[1;32m" else if (elapsed_ms < 10) "\x1b[1;33m" else "\x1b[1;31m";
    std.log.info("  {s}[HL]{s} {s}: {s}{d:.3}ms{s}", .{
        color_label, color_reset,
        label,       color_time,
        elapsed_ms,  color_reset,
    });
}

fn logTimingFmt(comptime label: []const u8, args: anytype, elapsed_ns: u64) void {
    if (true) return;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const color_reset = "\x1b[0m";
    const color_label = "\x1b[1;35m"; // magenta
    const color_time = if (elapsed_ms < 1) "\x1b[1;32m" else if (elapsed_ms < 10) "\x1b[1;33m" else "\x1b[1;31m";
    var buf: [256]u8 = undefined;
    const formatted_label = std.fmt.bufPrint(&buf, label, args) catch label;
    std.log.info("  {s}[HL]{s} {s}: {s}{d:.3}ms{s}", .{
        color_label,     color_reset,
        formatted_label, color_time,
        elapsed_ms,      color_reset,
    });
}

pub fn formatLargeNumber(n: f64) []const u8 {
    if (n >= 1000) {
        const k = n / 1000;
        if (k >= 10) {
            return std.fmt.comptimePrint("{d}k", .{@as(u32, @intFromFloat(k))});
        } else {
            return std.fmt.comptimePrint("{d:.1}k", .{k});
        }
    }
    return std.fmt.comptimePrint("{d}", .{@as(u32, @intFromFloat(n))});
}

pub fn formatMemory(mb: f64) []const u8 {
    return std.fmt.comptimePrint("{d:.1} MB", .{mb});
}

pub fn formatRequests(n: f64) []const u8 {
    const int_val = @as(u32, @intFromFloat(n));
    if (int_val >= 10000) {
        const thousands = int_val / 1000;
        const remainder = int_val % 1000;
        return std.fmt.comptimePrint("{d},{d:0>3}", .{ thousands, remainder });
    }
    if (int_val >= 1000) {
        const thousands = int_val / 1000;
        const remainder = int_val % 1000;
        return std.fmt.comptimePrint("{d},{d}", .{ thousands, remainder });
    }
    return std.fmt.comptimePrint("{d}", .{int_val});
}

pub fn formatLatency(ms: f64) []const u8 {
    return std.fmt.comptimePrint("{d:.2} ms", .{ms});
}

pub fn formatBuildTime(s: f64) []const u8 {
    const int_s = @as(u32, @intFromFloat(s));
    if (int_s >= 60) {
        const mins = int_s / 60;
        const secs = int_s % 60;
        return std.fmt.comptimePrint("{d}m {d}s", .{ mins, secs });
    }
    return std.fmt.comptimePrint("{d}s", .{int_s});
}

pub fn formatImageSize(mb: f64) []const u8 {
    if (mb >= 1000) {
        const gb = mb / 1000;
        return std.fmt.comptimePrint("{d:.1} GB", .{gb});
    }
    return std.fmt.comptimePrint("{d} MB", .{@as(u32, @intFromFloat(mb))});
}

pub fn formatColdStart(ms: f64) []const u8 {
    return std.fmt.comptimePrint("{d} ms", .{@as(u32, @intFromFloat(ms))});
}

pub fn formatCpuPeak(pct: f64) []const u8 {
    return std.fmt.comptimePrint("{d:.1}%", .{pct});
}

pub fn formatBinarySize(mb: f64) []const u8 {
    if (mb == 0) return "N/A";
    return std.fmt.comptimePrint("{d:.1} MB", .{mb});
}

pub fn randInt(io: std.Io, comptime T: type) T {
    var x: T = undefined;
    io.random(@ptrCast(&x));
    return x;
}

pub fn buildId(io: std.Io, allocator: std.mem.Allocator) []const u8 {
    return allocator.print("{x}", .{randInt(io, u32)}) catch @panic("failed to print build id");
}
