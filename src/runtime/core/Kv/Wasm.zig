const Wasm = @This();

const std = @import("std");
const Kv = @import("../Kv.zig");
const Wire = @import("../Wire.zig");
const host = @import("../../wasm/imports.zig");
const platform = @import("../../../platform.zig");

// Browser writes run in the background and must not suspend.
const write = if (platform.platform.role == .client) host.call else host.wait;

fn get(_: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    var ptr: [*]u8 = undefined;
    const n = host.wait(.kv_get, .{ ns, key, &ptr });
    if (n < 0) return null;
    if (n == 0) return try allocator.dupe(u8, "");
    defer std.heap.wasm_allocator.free(ptr[0..@intCast(n)]);
    return try allocator.dupe(u8, ptr[0..@intCast(n)]);
}

fn put(_: ?*anyopaque, ns: []const u8, key: []const u8, value: []const u8, opts: Kv.PutOptions) !void {
    const ttl: u32 = if (opts.ttl) |d| ttlSeconds(d) else 0;
    if (write(.kv_put, .{ ns, key, value, ttl }) < 0) return error.PutFailed;
}

// Rounded up: 0 means never expires.
pub fn ttlSeconds(d: std.Io.Duration) u32 {
    const ns = d.toNanoseconds();
    if (ns <= 0) return 0;
    const secs = std.math.divCeil(i96, ns, std.time.ns_per_s) catch unreachable;
    return std.math.cast(u32, secs) orelse std.math.maxInt(u32);
}

fn delete(_: ?*anyopaque, ns: []const u8, key: []const u8) !void {
    if (write(.kv_delete, .{ ns, key }) < 0) return error.DeleteFailed;
}

fn list(_: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
    var ptr: [*]u8 = undefined;
    const n = host.wait(.kv_list, .{ ns, prefix, &ptr });
    if (n < 0) return error.InvalidResponse;
    if (n == 0) return &[_][]u8{};
    defer std.heap.wasm_allocator.free(ptr[0..@intCast(n)]);

    return Wire.decodeStrings(allocator, ptr[0..@intCast(n)]) catch return error.InvalidResponse;
}

pub fn kv(wasm: *Wasm) Kv {
    return .{
        .userdata = wasm,
        .vtable = &.{
            .get = &get,
            .put = &put,
            .delete = &delete,
            .list = &list,
        },
    };
}
