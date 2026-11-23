const Flag = @This();

const std = @import("std");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const Memory = @import("Flag/Memory.zig");
pub const Kv = @import("Flag/Kv.zig");
pub const Ofrep = @import("Flag/Ofrep.zig");
pub const Flagship = @import("Flag/Flagship.zig");

pub const Provider = enum {
    ofrep,
    flagship,
    kv,

    pub fn Type(comptime provider: Provider) type {
        return switch (provider) {
            .ofrep => Ofrep,
            .flagship => Flagship,
            .kv => Kv,
        };
    }
};

// OpenFeature error codes.
pub const Error = error{
    ProviderNotReady,
    FlagNotFound,
    ParseError,
    TypeMismatch,
    TargetingKeyMissing,
    InvalidContext,
    ProviderFatal,
    General,
};

pub const Reason = enum {
    static,
    default,
    targeting_match,
    split,
    cached,
    disabled,
    unknown,
    stale,
    @"error",
};

pub const Kind = enum { boolean, string, int, float, object };

pub const Value = union(Kind) {
    boolean: bool,
    string: []const u8,
    int: i64,
    float: f64,
    object: std.json.Value,

    pub fn fromJson(json: std.json.Value) Error!Value {
        return switch (json) {
            .bool => |b| .{ .boolean = b },
            .string => |s| .{ .string = s },
            .integer => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .number_string => |s| if (std.fmt.parseInt(i64, s, 10)) |i| .{ .int = i } else |_| .{ .float = std.fmt.parseFloat(f64, s) catch return error.ParseError },
            .object, .array => .{ .object = json },
            .null => error.ParseError,
        };
    }

    pub fn jsonStringify(v: Value, jw: anytype) !void {
        switch (v) {
            inline else => |inner| try jw.write(inner),
        }
    }
};

// The evaluation context; serializes as `{"targetingKey":…, <attributes>…}`.
pub const Context = struct {
    targeting_key: ?[]const u8 = null,
    attributes: []const Attribute = &.{},

    pub const Attribute = struct {
        name: []const u8,
        value: Value,
    };

    pub fn get(c: Context, name: []const u8) ?Value {
        for (c.attributes) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn jsonStringify(c: Context, jw: anytype) !void {
        try jw.beginObject();
        if (c.targeting_key) |k| {
            try jw.objectField("targetingKey");
            try jw.write(k);
        }
        for (c.attributes) |a| {
            try jw.objectField(a.name);
            try jw.write(a.value);
        }
        try jw.endObject();
    }
};

// A null `value` means the caller's default, e.g. for a disabled flag.
pub const Resolution = struct {
    value: ?Value = null,
    variant: ?[]const u8 = null,
    reason: Reason = .unknown,
    metadata: ?std.json.Value = null,
};

pub const VTable = struct {
    resolve: *const fn (userdata: ?*anyopaque, arena: std.mem.Allocator, key: []const u8, kind: Kind, context: Context) Error!Resolution,
};

pub fn Details(comptime T: type) type {
    return struct {
        value: T,
        variant: ?[]const u8 = null,
        reason: Reason = .default,
        err: ?Error = null,
        metadata: ?std.json.Value = null,
    };
}

// Never fails: on any error the result holds `default` with reason `.@"error"`.
// Slices in the result borrow from `arena`.
pub fn details(f: Flag, comptime T: type, arena: std.mem.Allocator, key: []const u8, default: T, context: Context) Details(T) {
    const res = f.vtable.resolve(f.userdata, arena, key, comptime kindOf(T), context) catch |err|
        return .{ .value = default, .reason = .@"error", .err = err };
    const raw = res.value orelse
        return .{ .value = default, .variant = res.variant, .reason = res.reason, .metadata = res.metadata };
    const val = coerce(T, arena, raw) catch |err|
        return .{ .value = default, .reason = .@"error", .err = err, .metadata = res.metadata };
    return .{ .value = val, .variant = res.variant, .reason = res.reason, .metadata = res.metadata };
}

pub fn value(f: Flag, comptime T: type, arena: std.mem.Allocator, key: []const u8, default: T, context: Context) T {
    return f.details(T, arena, key, default, context).value;
}

pub const failing: Flag = .{ .vtable = &.{ .resolve = &failingResolve } };

fn failingResolve(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: Kind, _: Context) Error!Resolution {
    return error.ProviderNotReady;
}

fn kindOf(comptime T: type) Kind {
    if (T == []const u8) return .string;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => .int,
        .float => .float,
        else => .object,
    };
}

fn coerce(comptime T: type, arena: std.mem.Allocator, v: Value) Error!T {
    switch (comptime kindOf(T)) {
        .boolean => if (v == .boolean) return v.boolean,
        .string => if (v == .string) return v.string,
        .int => if (v == .int) return std.math.cast(T, v.int) orelse error.TypeMismatch,
        .float => switch (v) {
            .float => |x| return @floatCast(x),
            .int => |x| return @floatFromInt(x),
            else => {},
        },
        .object => if (v == .object) return std.json.parseFromValueLeaky(T, arena, v.object, .{ .ignore_unknown_fields = true }) catch error.TypeMismatch,
    }
    return error.TypeMismatch;
}
