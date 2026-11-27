const std = @import("std");
const lsp = @import("lsp");

pub const Encoding = lsp.offsets.Encoding;
pub const Position = lsp.types.flat.Position;
pub const Range = lsp.types.flat.Range;

/// Byte offset of `pos` in `source`. Positions past the end of their line (or
/// past the end of the document) are clamped.
pub fn positionToOffset(source: []const u8, pos: Position, encoding: Encoding) usize {
    return lsp.offsets.positionToIndex(source, pos, encoding);
}

/// Position of the byte at `offset` in `source`.
pub fn offsetToPosition(source: []const u8, offset: usize, encoding: Encoding) Position {
    return lsp.offsets.indexToPosition(source, @min(offset, source.len), encoding);
}

/// Position of a `line`/`byte_column` pair, such as a tree-sitter point.
pub fn byteColumnToPosition(source: []const u8, line: u32, byte_column: u32, encoding: Encoding) Position {
    return lsp.offsets.convertPositionEncoding(
        source,
        .{ .line = line, .character = byte_column },
        .@"utf-8",
        encoding,
    );
}

/// Apply one `textDocument/didChange` incremental edit and return the new
/// document. Caller owns the returned memory.
pub fn applyIncrementalChange(
    allocator: std.mem.Allocator,
    source: []const u8,
    range: Range,
    new_text: []const u8,
    encoding: Encoding,
) ![]const u8 {
    const start_offset = positionToOffset(source, range.start, encoding);
    const end_offset = positionToOffset(source, range.end, encoding);
    if (start_offset > end_offset) return error.InvalidRange;

    const new_len = start_offset + new_text.len + (source.len - end_offset);
    const result = try allocator.alloc(u8, new_len);
    @memcpy(result[0..start_offset], source[0..start_offset]);
    @memcpy(result[start_offset..][0..new_text.len], new_text);
    @memcpy(result[start_offset + new_text.len ..], source[end_offset..]);
    return result;
}

/// The `.zx` source as ZLS should see it. ZLS parses `.zx` files as Zig and relies on
/// error recovery to step over the markup, but a backtick template attribute
/// (`` id=`c{c}` ``) inside an `if`/`for`/`switch` branch defeats that recovery, and
/// everything after it loses highlighting, hover and completion. Each single-line
/// template becomes a same-length `"..."` literal (quotes and backslashes inside blanked),
/// so every byte offset stays the same. Comments, strings and char literals are skipped.
pub fn zlsView(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, source);
    var i: usize = 0;
    while (i < out.len) {
        switch (out[i]) {
            '/' => if (i + 1 < out.len and out[i + 1] == '/') {
                i = std.mem.findScalarPos(u8, out, i, '\n') orelse out.len;
                continue;
            },
            '"' => {
                i = skipQuoted(out, i, '"');
                continue;
            },
            '\'' => {
                // Only a real char literal ('a', '\n', '\x41'); a lone apostrophe in text stays.
                const end = std.mem.findScalarPos(u8, out, i + 1, '\'') orelse out.len;
                if (end < out.len and end - i <= 10 and std.mem.findScalar(u8, out[i..end], '\n') == null) {
                    i = end + 1;
                    continue;
                }
            },
            '`' => {
                const end = std.mem.findScalarPos(u8, out, i + 1, '`') orelse break;
                if (std.mem.findScalar(u8, out[i..end], '\n') == null) {
                    out[i] = '"';
                    out[end] = '"';
                    for (out[i + 1 .. end]) |*c| if (c.* == '"' or c.* == '\\') {
                        c.* = ' ';
                    };
                }
                i = end + 1;
                continue;
            },
            else => {},
        }
        i += 1;
    }
    return out;
}

// Past the closing `quote` (or the end of the line, for an unterminated one).
fn skipQuoted(s: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '\n' => return i,
        else => if (s[i] == quote) return i + 1,
    };
    return s.len;
}
