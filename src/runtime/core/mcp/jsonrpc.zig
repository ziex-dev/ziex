const std = @import("std");
const error_codes = @import("gen/error_codes.zig");
const types = @import("types.zig");

pub const codes = error_codes;

pub const Id = union(enum) {
    string: []const u8,
    number: i64,
    null,

    pub fn fromJson(value: ?std.json.Value) Id {
        const v = value orelse return .null;
        return switch (v) {
            .string => |s| .{ .string = s },
            .integer => |n| .{ .number = n },
            // Ids outside i64 range would trap in @intFromFloat.
            .float => |f| if (std.math.isFinite(f) and @abs(f) < 0x1p63) .{ .number = @intFromFloat(f) } else .null,
            .null => .null,
            else => .null,
        };
    }

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
    }
};

pub const Incoming = struct {
    id: ?Id = null,
    method: []const u8 = "",
    params: ?std.json.Value = null,
    is_notification: bool = false,
    is_response: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Incoming {
    const tree = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
    if (tree != .object) return error.InvalidRequest;
    const obj = tree.object;

    const ver = obj.get("jsonrpc") orelse return error.InvalidRequest;
    if (ver != .string or !std.mem.eql(u8, ver.string, "2.0")) return error.InvalidRequest;

    var out: Incoming = .{};
    if (obj.get("id")) |id_v| out.id = Id.fromJson(id_v);

    if (obj.get("method")) |m| {
        if (m != .string) return error.InvalidRequest;
        out.method = m.string;
        out.params = obj.get("params");
        out.is_notification = out.id == null;
        return out;
    }
    out.is_response = true;
    return out;
}

pub fn writeResult(allocator: std.mem.Allocator, id: Id, result: anytype) ![]u8 {
    return types.stringify(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = result,
    });
}

pub fn writeError(allocator: std.mem.Allocator, id: Id, code: i64, message: []const u8) ![]u8 {
    return types.stringify(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    });
}

pub fn writeErrorData(allocator: std.mem.Allocator, id: Id, code: i64, message: []const u8, data: anytype) ![]u8 {
    return types.stringify(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message, .data = data },
    });
}

pub fn writeErrorParse(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return writeError(allocator, .null, error_codes.parse_error, message);
}
