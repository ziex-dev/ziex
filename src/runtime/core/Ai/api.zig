const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");

pub fn model(explicit: ?[]const u8, default: ?[]const u8) Ai.Error![]const u8 {
    return explicit orelse default orelse error.MissingModel;
}

pub fn endpoint(arena: std.mem.Allocator, base: []const u8, path: []const u8) Ai.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}

pub fn json(gpa: std.mem.Allocator, payload: anytype) Ai.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, payload, .{ .emit_null_optional_fields = false });
}

// Returns the 2xx response body, owned by `gpa`.
pub fn post(io: std.Io, gpa: std.mem.Allocator, url: []const u8, headers: []const http.Header, payload: anytype) Ai.Error![]u8 {
    const body = try json(gpa, payload);
    defer gpa.free(body);

    var client: http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    const res = try client.fetch(.{ .url = url, .method = .POST, .headers = headers, .payload = body });
    defer res.deinit(gpa);

    try check(res.status, url, res.body);
    return gpa.dupe(u8, res.body);
}

pub fn get(io: std.Io, gpa: std.mem.Allocator, url: []const u8) Ai.Error![]u8 {
    var client: http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    const res = try client.fetch(.{ .url = url });
    defer res.deinit(gpa);

    try check(res.status, url, res.body);
    return gpa.dupe(u8, res.body);
}

pub fn check(status: http.Status, url: []const u8, body: []const u8) Ai.Error!void {
    if (status.class() == .success) return;

    std.log.scoped(.zx_ai).warn("{d} {s}: {s}", .{ @backingInt(status), url, body });
    return switch (status) {
        .unauthorized, .forbidden => error.Unauthorized,
        .too_many_requests => error.RateLimited,
        else => error.ApiError,
    };
}

// The result borrows from `arena` and `body`.
pub fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) Ai.Error!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}
