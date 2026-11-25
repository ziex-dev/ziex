// Worker asset names, shared by the build (from a path) and the runtime (from `@typeName`).
const std = @import("std");

// `pages/foo/[id]/worker.zig` -> `pages.foo.[id].worker`, the module's `@typeName`.
pub fn typeNameFromPath(buf: []u8, rel_path: []const u8) []const u8 {
    const stem = if (std.mem.endsWith(u8, rel_path, ".zig")) rel_path[0 .. rel_path.len - 4] else rel_path;
    for (stem, buf[0..stem.len]) |ch, *out| out.* = if (ch == '/' or ch == '\\') '.' else ch;
    return buf[0..stem.len];
}

// File-name-safe form of a worker's type name, used for `<name>.wasm`.
pub fn asset(buf: []u8, type_name: []const u8) []const u8 {
    for (type_name, buf[0..type_name.len]) |ch, *out| out.* = switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => ch,
        else => '_',
    };
    return buf[0..type_name.len];
}

test "path and type name map to the same asset" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const tn = typeNameFromPath(&a, "pages/foo/[id]/worker.zig");
    try std.testing.expectEqualStrings("pages.foo.[id].worker", tn);
    try std.testing.expectEqualStrings("pages.foo._id_.worker", asset(&b, tn));
}
