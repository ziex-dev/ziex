const Memory = @This();

const std = @import("std");
const Flag = @import("../Flag.zig");

flags: []const Definition,

pub const Variant = struct {
    name: []const u8,
    value: Flag.Value,
};

// A flag with fixed variants, as in flagd and the OpenFeature in-memory provider.
pub const Definition = struct {
    key: []const u8,
    variants: []const Variant,
    default_variant: []const u8,
    disabled: bool = false,
    // Picks a variant by name; null falls back to `default_variant`.
    evaluator: ?*const fn (context: Flag.Context) ?[]const u8 = null,

    pub fn resolve(d: Definition, context: Flag.Context) Flag.Error!Flag.Resolution {
        if (d.disabled) return .{ .reason = .disabled };
        if (d.evaluator) |evaluate| if (evaluate(context)) |name| {
            return .{ .value = try d.variant(name), .variant = name, .reason = .targeting_match };
        };
        return .{ .value = try d.variant(d.default_variant), .variant = d.default_variant, .reason = .static };
    }

    fn variant(d: Definition, name: []const u8) Flag.Error!Flag.Value {
        for (d.variants) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
        return error.General;
    }

    // flagd's flag definition format.
    pub fn jsonStringify(d: Definition, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("state");
        try jw.write(if (d.disabled) "DISABLED" else "ENABLED");
        try jw.objectField("variants");
        try jw.beginObject();
        for (d.variants) |v| {
            try jw.objectField(v.name);
            try jw.write(v.value);
        }
        try jw.endObject();
        try jw.objectField("defaultVariant");
        try jw.write(d.default_variant);
        try jw.endObject();
    }
};

pub fn flag(m: *Memory) Flag {
    return .{ .userdata = m, .vtable = &.{ .resolve = &resolve } };
}

fn resolve(userdata: ?*anyopaque, _: std.mem.Allocator, key: []const u8, _: Flag.Kind, context: Flag.Context) Flag.Error!Flag.Resolution {
    const m: *Memory = @ptrCast(@alignCast(userdata));
    for (m.flags) |d| if (std.mem.eql(u8, d.key, key)) return d.resolve(context);
    return error.FlagNotFound;
}
