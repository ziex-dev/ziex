const Ofrep = @This();

const std = @import("std");
const Flag = @import("../Flag.zig");
const http = @import("../http.zig");
const wire = @import("wire.zig");

// OpenFeature Remote Evaluation Protocol: flagd, GO Feature Flag, Flipt and others.
io: std.Io,
base_url: []const u8,
api_key: ?[]const u8 = null,

pub const env_url = "OFREP_URL";
pub const env_api_key = "OFREP_API_KEY";

pub fn flag(o: *Ofrep) Flag {
    return .{ .userdata = o, .vtable = &.{ .resolve = &resolve } };
}

fn resolve(userdata: ?*anyopaque, arena: std.mem.Allocator, key: []const u8, _: Flag.Kind, context: Flag.Context) Flag.Error!Flag.Resolution {
    const o: *Ofrep = @ptrCast(@alignCast(userdata));
    const url = std.fmt.allocPrint(arena, "{s}/ofrep/v1/evaluate/flags/{f}", .{
        std.mem.trimEnd(u8, o.base_url, "/"),
        std.fmt.alt(std.Uri.Component{ .raw = key }, .formatPath),
    }) catch return error.General;

    var headers: [2]http.Header = .{ .{ .name = "content-type", .value = "application/json" }, undefined };
    var n: usize = 1;
    if (o.api_key) |k| {
        headers[1] = .{ .name = "authorization", .value = std.fmt.allocPrint(arena, "Bearer {s}", .{k}) catch return error.General };
        n = 2;
    }

    const res = try wire.post(o.io, arena, url, headers[0..n], .{ .context = context });
    return switch (res.status) {
        .ok => (try wire.parse(wire.Reply, arena, res.body)).resolution(),
        .not_found => error.FlagNotFound,
        .bad_request => wire.errorCode((wire.parse(wire.Reply, arena, res.body) catch wire.Reply{}).errorCode orelse ""),
        else => error.General,
    };
}
