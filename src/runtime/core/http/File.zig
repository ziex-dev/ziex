// TODO: get rid of File interface and probably just have reader in file field of MFD.
pub const File = @This();

const std = @import("std");

/// Original filename as reported by the browser (empty string when absent).
name: []const u8 = "",

/// MIME type of the file, e.g. `"image/png"` (empty string when unknown).
content_type: []const u8 = "",

/// File size in bytes.
/// For future streaming readers this may be 0 if the size is not yet known.
size: usize = 0,

/// Reader interface for the file content.
data: std.Io.Reader = emptyReader(),

/// Build a File backed by an in-memory byte slice.
pub fn fromBytes(
    bytes: []const u8,
    name: []const u8,
    content_type: []const u8,
    fbs_alloc: std.mem.Allocator,
) File {
    const fbs = fbs_alloc.create(std.Io.FixedBufferStream([]const u8)) catch return .{
        .name = name,
        .content_type = content_type,
        .size = bytes.len,
    };
    fbs.* = std.Io.fixedBufferStream(bytes);
    return .{
        .name = name,
        .content_type = content_type,
        .size = bytes.len,
        .data = fbs.reader().any(),
    };
}

var empty_ctx: u8 = 0;

fn emptyReadFn(_: *const anyopaque, _: []u8) anyerror!usize {
    return 0;
}

fn emptyReader() std.Io.Reader {
    return .{ .context = &empty_ctx, .readFn = &emptyReadFn };
}
