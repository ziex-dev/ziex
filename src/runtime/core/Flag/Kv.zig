const Kv = @This();

const std = @import("std");
const Flag = @import("../Flag.zig");
const Store = @import("../Kv.zig");
const Memory = @import("Memory.zig");
const wire = @import("wire.zig");

// Definitions are stored as flagd JSON under `prefix ++ key`.
store: Store,
prefix: []const u8 = "flag:",

pub fn flag(k: *Kv) Flag {
    return .{ .userdata = k, .vtable = &.{ .resolve = &resolve } };
}

pub fn put(k: Kv, gpa: std.mem.Allocator, definition: Memory.Definition) !void {
    const key = try std.mem.concat(gpa, u8, &.{ k.prefix, definition.key });
    defer gpa.free(key);
    const body = try std.json.Stringify.valueAlloc(gpa, definition, .{});
    defer gpa.free(body);
    try k.store.put(key, body, .{});
}

pub fn delete(k: Kv, gpa: std.mem.Allocator, key: []const u8) !void {
    const full = try std.mem.concat(gpa, u8, &.{ k.prefix, key });
    defer gpa.free(full);
    try k.store.delete(full);
}

fn resolve(userdata: ?*anyopaque, arena: std.mem.Allocator, key: []const u8, _: Flag.Kind, context: Flag.Context) Flag.Error!Flag.Resolution {
    const k: *Kv = @ptrCast(@alignCast(userdata));
    const full = std.mem.concat(arena, u8, &.{ k.prefix, key }) catch return error.General;
    const found = k.store.get(arena, full) catch return error.General;
    const raw = found orelse return error.FlagNotFound;

    const Stored = struct {
        state: []const u8 = "ENABLED",
        variants: std.json.ArrayHashMap(std.json.Value),
        defaultVariant: []const u8,
    };
    const stored = try wire.parse(Stored, arena, raw);

    const variants = arena.alloc(Memory.Variant, stored.variants.map.count()) catch return error.General;
    for (variants, stored.variants.map.keys(), stored.variants.map.values()) |*v, name, json|
        v.* = .{ .name = name, .value = try Flag.Value.fromJson(json) };

    const definition: Memory.Definition = .{
        .key = key,
        .variants = variants,
        .default_variant = stored.defaultVariant,
        .disabled = std.mem.eql(u8, stored.state, "DISABLED"),
    };
    return definition.resolve(context);
}
