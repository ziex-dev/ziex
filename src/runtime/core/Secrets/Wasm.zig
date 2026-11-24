// Host secret bindings, read as `await env[name].get()`.
// Plain string secrets arrive as WASI environ and are served by `Env`.
const Wasm = @This();

const std = @import("std");
const Secrets = @import("../Secrets.zig");
const host = @import("../../wasm/imports.zig");

pub fn secrets(_: *const Wasm) Secrets {
    return .{ .vtable = &.{ .get = &get } };
}

fn get(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
    var out: [*]u8 = undefined;
    const n = host.wait(.env_call, .{ name, "get", "[]", &out });
    if (n == host.missing or n == host.unsupported) return null;
    if (n <= 0) return error.Unavailable;

    const owned = host.owned(out, n);
    defer host.free(owned);
    const value = std.json.parseFromSlice(?[]const u8, allocator, owned, .{}) catch return error.Unavailable;
    defer value.deinit();
    return try allocator.dupe(u8, value.value orelse return null);
}
