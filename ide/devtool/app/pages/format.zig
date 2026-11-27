const std = @import("std");

pub fn getValueColor(value: []const u8) []const u8 {
    if (std.mem.find(u8, value, "fn") != null) return "value-function";
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return "value-boolean";
    if (std.mem.startsWith(u8, value, "\"")) return "value-string";
    return "value-default";
}

pub fn isMultilineStringValue(value: []const u8) bool {
    if (std.mem.findScalar(u8, value, '\n') != null) return true;
    if (!std.mem.startsWith(u8, value, "\"")) return false;
    return std.mem.find(u8, value, "\\n") != null or
        std.mem.find(u8, value, "\\r") != null;
}

pub fn decodeJsonString(allocator: std.mem.Allocator, value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch {
            return unescapeCommon(allocator, value) catch value;
        };
        return switch (parsed.value) {
            .string => |s| s,
            else => unescapeCommon(allocator, value) catch value,
        };
    }
    return unescapeCommon(allocator, value) catch value;
}

fn unescapeCommon(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var slice = value;
    if (slice.len >= 2 and slice[0] == '"' and slice[slice.len - 1] == '"') {
        slice = slice[1 .. slice.len - 1];
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < slice.len) {
        if (slice[i] == '\\' and i + 1 < slice.len) {
            switch (slice[i + 1]) {
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                '\\' => try out.append(allocator, '\\'),
                '"' => try out.append(allocator, '"'),
                else => {
                    try out.append(allocator, '\\');
                    try out.append(allocator, slice[i + 1]);
                },
            }
            i += 2;
        } else {
            try out.append(allocator, slice[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn countLines(value: []const u8) usize {
    var lines: usize = 1;
    for (value) |c| {
        if (c == '\n') lines += 1;
    }
    return @min(@max(lines, 4), 24);
}
