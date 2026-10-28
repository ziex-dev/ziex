const Wasm = @This();

const std = @import("std");
const Kv = @import("../Kv.zig");
const Wire = @import("../Wire.zig");

fn get(_: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    var ptr: [*]u8 = undefined;
    const n = ext.get(ns.ptr, ns.len, key.ptr, key.len, &ptr);
    if (n < 0) return null;
    if (n == 0) return try allocator.dupe(u8, "");
    defer std.heap.wasm_allocator.free(ptr[0..@intCast(n)]);
    return try allocator.dupe(u8, ptr[0..@intCast(n)]);
}

fn put(_: ?*anyopaque, ns: []const u8, key: []const u8, value: []const u8, opts: Kv.PutOptions) !void {
    const ttl: u32 = if (opts.ttl) |d| blk: {
        const secs = d.toSeconds();
        break :blk if (secs <= 0) 0 else @intCast(secs);
    } else 0;
    if (ext.put(ns.ptr, ns.len, key.ptr, key.len, value.ptr, value.len, ttl) < 0) return error.PutFailed;
}

fn delete(_: ?*anyopaque, ns: []const u8, key: []const u8) !void {
    if (ext.delete(ns.ptr, ns.len, key.ptr, key.len) < 0) return error.DeleteFailed;
}

fn list(_: ?*anyopaque, ns: []const u8, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
    var ptr: [*]u8 = undefined;
    const n = ext.list(ns.ptr, ns.len, prefix.ptr, prefix.len, &ptr);
    if (n < 0) return error.InvalidResponse;
    if (n == 0) return &[_][]u8{};
    defer std.heap.wasm_allocator.free(ptr[0..@intCast(n)]);

    return Wire.decodeStrings(allocator, ptr[0..@intCast(n)]) catch return error.InvalidResponse;
}

const ext = struct {
    pub extern "__zx_kv" fn get(
        ns_ptr: [*]const u8,
        ns_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
        out_ptr: *[*]u8,
    ) i32;

    pub extern "__zx_kv" fn put(
        ns_ptr: [*]const u8,
        ns_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
        val_ptr: [*]const u8,
        val_len: usize,
        ttl_seconds: u32,
    ) i32;

    pub extern "__zx_kv" fn delete(
        ns_ptr: [*]const u8,
        ns_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
    ) i32;

    pub extern "__zx_kv" fn list(
        ns_ptr: [*]const u8,
        ns_len: usize,
        prefix_ptr: [*]const u8,
        prefix_len: usize,
        out_ptr: *[*]u8,
    ) i32;
};

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
