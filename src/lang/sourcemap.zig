const std = @import("std");

/// A single position mapping from generated (.zig) to source (.zx).
/// All coordinates are 0-based.
pub const Mapping = struct {
    generated_line: i32,
    generated_column: i32,
    source_line: i32,
    source_column: i32,
};

pub const MAP_PREFIX = "//# ziex-map ";
pub const MAP_DATA_PREFIX = "//# ziex-map-data ";

/// Canonical position map: owned Mapping list + optional source path.
pub const PositionMap = struct {
    entries: []Mapping,
    /// Relative .zx source path (owned when set via `dupe`).
    source: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PositionMap) void {
        self.allocator.free(self.entries);
        if (self.source.len > 0) self.allocator.free(self.source);
        self.* = undefined;
    }

    /// Borrowing view for lookups (does not free entries).
    pub fn asDecoded(self: PositionMap) DecodedMap {
        return .{
            .entries = self.entries,
            .allocator = self.allocator,
            .owned = false,
        };
    }

    pub fn sourceToGenerated(self: PositionMap, line: i32, column: i32) ?Mapping {
        return self.asDecoded().sourceToGenerated(line, column);
    }

    pub fn generatedToSource(self: PositionMap, line: i32, column: i32) ?Mapping {
        return self.asDecoded().generatedToSource(line, column);
    }

    /// Pack entries as little-endian i32 quads and base64-encode.
    pub fn serializeData(self: PositionMap, allocator: std.mem.Allocator) ![]u8 {
        const bytes_len = self.entries.len * 16;
        const raw = try allocator.alloc(u8, bytes_len);
        defer allocator.free(raw);

        for (self.entries, 0..) |m, i| {
            const off = i * 16;
            writeI32(raw[off..][0..4], m.generated_line);
            writeI32(raw[off + 4 ..][0..4], m.generated_column);
            writeI32(raw[off + 8 ..][0..4], m.source_line);
            writeI32(raw[off + 12 ..][0..4], m.source_column);
        }

        const b64_len = std.base64.standard.Encoder.calcSize(raw.len);
        const b64 = try allocator.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64, raw);
        return b64;
    }

    /// Decode base64-packed i32 quads into a PositionMap (source path empty).
    pub fn deserializeData(allocator: std.mem.Allocator, b64: []const u8) !PositionMap {
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        if (decoded_len % 16 != 0) return error.InvalidMapData;
        const raw = try allocator.alloc(u8, decoded_len);
        defer allocator.free(raw);
        try std.base64.standard.Decoder.decode(raw, b64);

        const count = decoded_len / 16;
        const entries = try allocator.alloc(Mapping, count);
        errdefer allocator.free(entries);

        for (0..count) |i| {
            const off = i * 16;
            entries[i] = .{
                .generated_line = readI32(raw[off..][0..4]),
                .generated_column = readI32(raw[off + 4 ..][0..4]),
                .source_line = readI32(raw[off + 8 ..][0..4]),
                .source_column = readI32(raw[off + 12 ..][0..4]),
            };
        }

        return .{
            .entries = entries,
            .source = "",
            .allocator = allocator,
        };
    }

    /// Emit the two trailing comment lines for a generated .zig file.
    pub fn formatEmbed(self: PositionMap, allocator: std.mem.Allocator) ![]u8 {
        const data = try self.serializeData(allocator);
        defer allocator.free(data);
        return allocator.print("{s}{s}\n{s}{s}\n", .{
            MAP_PREFIX,
            self.source,
            MAP_DATA_PREFIX,
            data,
        });
    }

    /// Parse embed comments from generated Zig source. Returns null if absent.
    pub fn parseEmbed(allocator: std.mem.Allocator, zig_source: []const u8) !?PositionMap {
        const data_pos = std.mem.lastIndexOf(u8, zig_source, MAP_DATA_PREFIX) orelse return null;
        const data_start = data_pos + MAP_DATA_PREFIX.len;
        const data_end = std.mem.indexOfScalarPos(u8, zig_source, data_start, '\n') orelse zig_source.len;
        const b64 = std.mem.trim(u8, zig_source[data_start..data_end], " \t\r");

        var map = try deserializeData(allocator, b64);
        errdefer map.deinit();

        // Find source path from the preceding //# ziex-map line.
        if (std.mem.lastIndexOf(u8, zig_source[0..data_pos], MAP_PREFIX)) |src_pos| {
            const src_start = src_pos + MAP_PREFIX.len;
            const src_end = std.mem.indexOfScalarPos(u8, zig_source, src_start, '\n') orelse data_pos;
            const src = std.mem.trim(u8, zig_source[src_start..src_end], " \t\r");
            if (src.len > 0) {
                map.source = try allocator.dupe(u8, src);
            }
        }

        return map;
    }

    /// Human-readable golden format: `src:col -> gen:col | "src" => "gen"`
    pub fn formatHuman(
        self: PositionMap,
        allocator: std.mem.Allocator,
        zx_source: []const u8,
        zig_source: []const u8,
    ) ![]u8 {
        return formatHumanEntries(allocator, self.entries, zx_source, zig_source);
    }

    /// Deep copy for transferring ownership to another allocator.
    pub fn dupe(self: PositionMap, allocator: std.mem.Allocator) !PositionMap {
        const entries = try allocator.dupe(Mapping, self.entries);
        errdefer allocator.free(entries);
        const source = if (self.source.len > 0) try allocator.dupe(u8, self.source) else "";
        return .{
            .entries = entries,
            .source = source,
            .allocator = allocator,
        };
    }
};

/// Alias kept for existing call sites.
pub const SourceMap = PositionMap;

/// Lookup view over Mapping entries.
pub const DecodedMap = struct {
    entries: []const Mapping,
    allocator: std.mem.Allocator,
    /// When true, `deinit` frees `entries`.
    owned: bool = true,

    pub fn deinit(self: *DecodedMap) void {
        if (self.owned) self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Map a source (original .zx) position to the generated (.zig) position.
    pub fn sourceToGenerated(self: DecodedMap, line: i32, column: i32) ?Mapping {
        var best: ?Mapping = null;

        for (self.entries) |m| {
            if (m.source_line > line) continue;
            if (m.source_line == line and m.source_column > column) continue;

            if (best) |b| {
                const better = m.source_line > b.source_line or
                    (m.source_line == b.source_line and m.source_column > b.source_column);
                const tie = m.source_line == b.source_line and m.source_column == b.source_column;
                if (better) {
                    best = m;
                } else if (tie) {
                    if (m.generated_line < b.generated_line or
                        (m.generated_line == b.generated_line and m.generated_column < b.generated_column))
                    {
                        best = m;
                    }
                }
            } else {
                best = m;
            }
        }

        const b = best orelse return null;

        var boundary: ?i32 = null;
        for (self.entries) |m| {
            if (m.source_line != line) continue;
            if (m.source_column <= b.source_column) continue;
            if (boundary == null or m.source_column < boundary.?) boundary = m.source_column;
        }

        var clamped_col = column;
        if (b.source_line == line) {
            if (boundary) |bnd| {
                if (clamped_col >= bnd) clamped_col = bnd - 1;
            }
        }

        const col_offset = if (b.source_line == line) clamped_col - b.source_column else 0;
        return .{
            .generated_line = b.generated_line,
            .generated_column = b.generated_column + col_offset,
            .source_line = line,
            .source_column = column,
        };
    }

    /// Map a generated (.zig) position back to the source (original .zx).
    pub fn generatedToSource(self: DecodedMap, line: i32, column: i32) ?Mapping {
        const entries = self.entries;
        if (entries.len == 0) return null;

        var low: usize = 0;
        var high: usize = entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const m = entries[mid];
            if (m.generated_line < line or (m.generated_line == line and m.generated_column <= column)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) return null;
        const idx = low - 1;
        const b = entries[idx];

        var clamped_col = column;
        if (b.generated_line == line) {
            var j = idx + 1;
            while (j < entries.len and
                entries[j].generated_line == line and
                entries[j].generated_column == b.generated_column) : (j += 1)
            {}
            if (j < entries.len and entries[j].generated_line == line and column >= entries[j].generated_column) {
                clamped_col = entries[j].generated_column - 1;
            }
        }

        const col_offset = if (b.generated_line == line) clamped_col - b.generated_column else 0;
        return .{
            .generated_line = line,
            .generated_column = column,
            .source_line = b.source_line,
            .source_column = b.source_column + col_offset,
        };
    }
};

/// Builder for creating position maps from mappings.
pub const Builder = struct {
    mappings: std.array_list.Managed(Mapping),
    allocator: std.mem.Allocator,
    source: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .mappings = std.array_list.Managed(Mapping).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.mappings.deinit();
    }

    pub fn addMapping(self: *Builder, mapping: Mapping) !void {
        try self.mappings.append(mapping);
    }

    /// Finalize into an owned PositionMap. Entries are already in generated order.
    pub fn build(self: *Builder) !PositionMap {
        const entries = try self.mappings.toOwnedSlice();
        errdefer self.allocator.free(entries);
        const source = if (self.source.len > 0) try self.allocator.dupe(u8, self.source) else "";
        return .{
            .entries = entries,
            .source = source,
            .allocator = self.allocator,
        };
    }
};

pub fn formatHumanEntries(
    allocator: std.mem.Allocator,
    entries: []const Mapping,
    zx_source: []const u8,
    zig_source: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (entries) |m| {
        const src_snippet = getSnippet(zx_source, m.source_line, m.source_column);
        const gen_snippet = getSnippet(zig_source, m.generated_line, m.generated_column);
        try aw.writer.print("{d}:{d} -> {d}:{d} | \"{s}\" => \"{s}\"\n", .{
            m.source_line,
            m.source_column,
            m.generated_line,
            m.generated_column,
            src_snippet,
            gen_snippet,
        });
    }

    return aw.toOwnedSlice();
}

fn getSnippet(source: []const u8, line: i32, col: i32) []const u8 {
    const offset = lineColToOffset(source, line, col) orelse return "<out-of-bounds>";
    const remaining = source[offset..];
    const max_len: usize = 20;
    var end: usize = 0;
    while (end < remaining.len and end < max_len and remaining[end] != '\n') {
        end += 1;
    }
    return remaining[0..end];
}

pub fn lineColToOffset(source: []const u8, line: i32, col: i32) ?usize {
    if (line < 0 or col < 0) return null;
    var current_line: i32 = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (current_line == line) {
            const line_start = i;
            var line_end = i;
            while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
            const col_usize: usize = @intCast(col);
            if (col_usize > line_end - line_start) return null;
            return line_start + col_usize;
        }
        if (source[i] == '\n') current_line += 1;
        i += 1;
    }
    if (current_line == line and col == 0) return source.len;
    return null;
}

fn writeI32(buf: *[4]u8, value: i32) void {
    const u: u32 = @bitCast(value);
    buf[0] = @truncate(u);
    buf[1] = @truncate(u >> 8);
    buf[2] = @truncate(u >> 16);
    buf[3] = @truncate(u >> 24);
}

fn readI32(buf: *const [4]u8) i32 {
    const u: u32 = @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
    return @bitCast(u);
}
