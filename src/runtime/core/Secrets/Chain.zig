// Tries each store in order and returns the first hit.
const Chain = @This();

const std = @import("std");
const Secrets = @import("../Secrets.zig");

stores: []const Secrets,

pub fn secrets(c: *const Chain) Secrets {
    return .{ .userdata = @constCast(c), .vtable = &.{ .get = &get } };
}

fn get(userdata: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
    const c: *const Chain = @ptrCast(@alignCast(userdata));
    for (c.stores) |store| {
        if (try store.get(allocator, name)) |value| return value;
    }
    return null;
}
