//! Position/offset helpers for LSP text documents.
//!
//! `Position.character` counts code units of the encoding negotiated during
//! `initialize` (UTF-16 unless the client asks for something else), not bytes,
//! so every conversion has to go through that `Encoding`.

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
