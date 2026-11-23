const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree_sitter");
const ts_zx = @import("tree_sitter_zx");
const platform_mod = @import("../../platform.zig");

const hl_query = @embedFile("highlights.scm");

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
        return cache;
    }
};

pub fn highlightZx(io: std.Io, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (platform_mod.platform.role == .client) return try allocator.dupe(u8, source);

    const cache = try HighlightCache.getOrInit(std.heap.page_allocator);
    try cache.mutex.lock(io);
    defer cache.mutex.unlock(io);

    const tree = cache.parser.parseString(source, null) orelse return error.ParseError;
    defer tree.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(cache.query, tree.rootNode());

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var last: usize = 0;
    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const start = cap.node.startByte();
            const end = cap.node.endByte();
            if (start < last) continue;

            const capture_name = cache.query.captureNameForId(cap.index) orelse continue;
            try appendHtmlEscapedPreserveWhitespace(allocator, &out, source[last..start]);
            try out.appendSlice(allocator, "<span class='");
            for (capture_name) |char| {
                try out.append(allocator, if (char == '.') ' ' else char);
            }
            try out.appendSlice(allocator, "'>");
            try appendHtmlEscapedPreserveWhitespace(allocator, &out, source[start..end]);
            try out.appendSlice(allocator, "</span>");
            last = end;
        }
    }

    try appendHtmlEscapedPreserveWhitespace(allocator, &out, source[last..]);
    return out.toOwnedSlice(allocator);
}

pub fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendHtmlEscapedPreserveWhitespace(allocator, &out, text);
    return out.toOwnedSlice(allocator);
}

fn appendHtmlEscapedPreserveWhitespace(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, char),
        }
    }
}
