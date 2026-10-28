const std = @import("std");

fn needsAttrEscape(value: []const u8) bool {
    for (value) |c| {
        switch (c) {
            '&', '<', '>', '"', '\'' => return true,
            else => {},
        }
    }
    return false;
}

fn needsTextEscape(value: []const u8) bool {
    for (value) |c| {
        switch (c) {
            '&', '<', '>' => return true,
            else => {},
        }
    }
    return false;
}

/// Escape a string for use inside an HTML attribute value.
/// Escapes: `& < > " '`
pub fn escapeAttr(writer: *std.Io.Writer, value: []const u8) !void {
    if (!needsAttrEscape(value)) {
        try writer.writeAll(value);
        return;
    }
    try escapeWithEntities(writer, value, true);
}

/// Escape a string for use inside an HTML text node.
/// Escapes: `& < >`
pub fn escapeText(writer: *std.Io.Writer, value: []const u8) !void {
    if (!needsTextEscape(value)) {
        try writer.writeAll(value);
        return;
    }
    try escapeWithEntities(writer, value, false);
}

/// Write `value` escaping specials, emitting contiguous safe runs as one writeAll.
fn escapeWithEntities(writer: *std.Io.Writer, value: []const u8, comptime attr: bool) !void {
    var start: usize = 0;
    for (value, 0..) |c, i| {
        const entity: ?[]const u8 = if (comptime attr) switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#x27;",
            else => null,
        } else switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (entity) |e| {
            if (i > start) try writer.writeAll(value[start..i]);
            try writer.writeAll(e);
            start = i + 1;
        }
    }
    if (start < value.len) try writer.writeAll(value[start..]);
}

/// Unescape HTML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#x27;`) back
/// to their literal characters, writing the result to `writer`.
pub fn unescape(writer: *std.Io.Writer, value: []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '&') {
            if (i + 4 <= value.len and std.mem.eql(u8, value[i .. i + 4], "&lt;")) {
                try writer.writeByte('<');
                i += 4;
            } else if (i + 4 <= value.len and std.mem.eql(u8, value[i .. i + 4], "&gt;")) {
                try writer.writeByte('>');
                i += 4;
            } else if (i + 5 <= value.len and std.mem.eql(u8, value[i .. i + 5], "&amp;")) {
                try writer.writeByte('&');
                i += 5;
            } else if (i + 6 <= value.len and std.mem.eql(u8, value[i .. i + 6], "&quot;")) {
                try writer.writeByte('"');
                i += 6;
            } else if (i + 6 <= value.len and std.mem.eql(u8, value[i .. i + 6], "&#x27;")) {
                try writer.writeByte('\'');
                i += 6;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        } else {
            try writer.writeByte(value[i]);
            i += 1;
        }
    }
}

pub fn normalizeBasePathForPrefixing(base_path: ?[]const u8) ?[]const u8 {
    const value = base_path orelse return null;
    if (value.len == 0 or std.mem.eql(u8, value, "/")) return null;
    if (value.len > 1 and value[value.len - 1] == '/') return value[0 .. value.len - 1];
    return value;
}

/// Returns true when `path` should be prefixed by `normalized_base_path`.
pub fn shouldPrefixPathWithBasePath(normalized_base_path: []const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.startsWith(u8, path, "//")) return false;
    if (!std.mem.startsWith(u8, path, normalized_base_path)) return true;
    if (path.len == normalized_base_path.len) return false;
    return path[normalized_base_path.len] != '/';
}

/// Prefix `path` with `base_path` when needed.
pub fn prefixPathWithBasePath(allocator: std.mem.Allocator, base_path: ?[]const u8, path: []const u8) []const u8 {
    const normalized_base = normalizeBasePathForPrefixing(base_path) orelse return path;
    if (!shouldPrefixPathWithBasePath(normalized_base, path)) return path;
    return allocator.print("{s}{s}", .{ normalized_base, path }) catch @panic("OOM");
}
