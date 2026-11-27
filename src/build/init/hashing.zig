const std = @import("std");

const magic: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6d };
const version: u32 = 1;

/// esbuild-style 8-character content hash length in output filenames.
pub const tag_len = 8;

/// Content hash tag for asset filenames (first 4 bytes of BLAKE3 as 8 hex chars).
pub fn contentTag(content: []const u8) [tag_len]u8 {
    var hash: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(content);
    hasher.final(&hash);

    var out: [tag_len]u8 = undefined;
    _ = std.mem.print(&out, "{x:0>8}", .{std.mem.readInt(u32, hash[0..4], .little)}) catch unreachable;
    return out;
}

/// Returns wasm bytes suitable for content hashing: same as the input module
/// but with custom sections removed. Debug builds embed unstable `.zig-cache/o/`
/// paths in custom sections (name, DWARF, etc.); executable sections are stable.
pub fn hashInput(allocator: std.mem.Allocator, wasm: []const u8) ![]u8 {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], &magic) or std.mem.readInt(u32, wasm[4..8], .little) != version) {
        return try allocator.dupe(u8, wasm);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &magic);
    try writeU32(allocator, &out, version);

    var offset: usize = 8;
    while (offset < wasm.len) {
        const section_id = try readVarUint7(wasm, &offset);
        const section_size = try readVarUint32(wasm, &offset);
        const section_end = offset + section_size;
        if (section_end > wasm.len) return error.InvalidWasm;

        if (section_id != 0) {
            try writeVarUint7(allocator, &out, section_id);
            try writeVarUint32(allocator, &out, @intCast(section_size));
            try out.appendSlice(allocator, wasm[offset..section_end]);
        }

        offset = section_end;
    }

    return out.toOwnedSlice(allocator);
}

fn readVarUint7(wasm: []const u8, offset: *usize) !u8 {
    const value = try readVarUint32(wasm, offset);
    if (value > std.math.maxInt(u8)) return error.InvalidWasm;
    return @intCast(value);
}

fn readVarUint32(wasm: []const u8, offset: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (offset.* >= wasm.len) return error.InvalidWasm;
        const byte = wasm[offset.*];
        offset.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 35) return error.InvalidWasm;
    }
}

fn writeVarUint7(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u8) !void {
    try writeVarUint32(allocator, out, value);
}

fn writeVarUint32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var remaining = value;
    while (true) {
        var byte: u8 = @truncate(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte |= 0x80;
        try out.append(allocator, byte);
        if (remaining == 0) break;
    }
}

fn writeU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}
