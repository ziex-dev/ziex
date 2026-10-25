const std = @import("std");

const pltfm = @import("../platform.zig");
const zxon_mod = @import("zxon.zig");

const platform = pltfm.platform;

/// Fill in defaults / required fields for a component props struct.
pub fn coerce(comptime T: type, props: anytype) T {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Target type must be a struct");
    }

    const s = info.@"struct";
    var result: T = undefined;

    inline for (s.field_names, s.field_types, s.field_attrs) |field_name, field_type, field_attr| {
        if (@hasField(@TypeOf(props), field_name)) {
            @field(result, field_name) = @field(props, field_name);
        } else if (field_attr.defaultValue(field_type)) |default_value| {
            @field(result, field_name) = default_value;
        } else {
            @compileError(std.fmt.comptimePrint("Missing required attribute `{s}` in Component `{s}`", .{ field_name, @typeName(T) }));
        }
    }

    return result;
}

/// Serialize props to ZXON for client-island hydration markers.
/// Returns null when empty, non-serializable, or on the client platform.
pub fn zxon(allocator: std.mem.Allocator, props: anytype) ?[]const u8 {
    if (platform.role == .client) return null;
    const T = @TypeOf(props);
    const info = @typeInfo(T);

    if (info != .@"struct") return null;
    if (info.@"struct".field_types.len == 0) return null;
    if (!comptime serializable(T)) return null;

    var aw = std.Io.Writer.Allocating.init(allocator);
    zxon_mod.serialize(props, &aw.writer, .{}) catch {
        aw.deinit();
        return null;
    };
    return aw.toOwnedSlice() catch null;
}

/// Serialize props to a JSON object (named fields). Used by DevTools via
pub fn json(allocator: std.mem.Allocator, props: anytype) ?[]const u8 {
    const T = @TypeOf(props);
    const info = @typeInfo(T);

    if (info != .@"struct") return null;
    if (info.@"struct".field_types.len == 0) return null;
    if (!comptime serializable(T)) return null;

    return std.json.Stringify.valueAlloc(allocator, props, .{}) catch null;
}

pub fn jsonDevtool(allocator: std.mem.Allocator, props: anytype) ?[]const u8 {
    const T = @TypeOf(props);
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    if (info.@"struct".field_types.len == 0) return null;

    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    aw.writer.writeByte('{') catch return null;

    var first = true;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        const value = @field(props, field_name);
        if (comptime isActionType(field_type)) {
            if (!first) aw.writer.writeByte(',') catch return null;
            first = false;
            writeJsonValue(&aw.writer, field_name) catch return null;
            aw.writer.writeAll(":\"fn()\"") catch return null;
        } else if (comptime serializable(field_type)) {
            if (!first) aw.writer.writeByte(',') catch return null;
            first = false;
            writeJsonValue(&aw.writer, field_name) catch return null;
            aw.writer.writeByte(':') catch return null;
            writeJsonValue(&aw.writer, value) catch return null;
        }
    }

    aw.writer.writeByte('}') catch return null;
    return aw.toOwnedSlice() catch null;
}

// zxon in the client, which ships without std.json.
fn writeJsonValue(w: *std.Io.Writer, value: anytype) !void {
    if (comptime platform.role == .client) return zxon_mod.serialize(value, w, .{});
    return std.json.Stringify.value(value, .{}, w);
}

fn isActionType(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti == .@"fn") return true;
    if (ti == .pointer and ti.pointer.size == .one and @typeInfo(ti.pointer.child) == .@"fn") return true;
    if (ti == .@"struct") {
        // zx.EventHandler shape
        return @hasField(T, "callback") and @hasField(T, "context") and @hasField(T, "handler_id");
    }
    return false;
}

/// Merged type of two props structs (for spreading). Override fields win.
pub fn Merged(comptime Base: type, comptime Override: type) type {
    const base_info = @typeInfo(Base);
    const override_info = @typeInfo(Override);

    if (base_info != .@"struct" or override_info != .@"struct") {
        @compileError("Merged expects struct types");
    }

    const base = base_info.@"struct";
    const override = override_info.@"struct";

    comptime var field_count = base.field_names.len;
    inline for (override.field_names) |of_name| {
        comptime var found = false;
        inline for (base.field_names) |bf_name| {
            if (std.mem.eql(u8, bf_name, of_name)) {
                found = true;
                break;
            }
        }
        if (!found) field_count += 1;
    }

    comptime var field_names: [field_count][:0]const u8 = undefined;
    comptime var field_types: [field_count]type = undefined;
    comptime var field_attrs: [field_count]std.builtin.Type.Struct.FieldAttributes = undefined;
    comptime var idx: usize = 0;

    inline for (base.field_names, base.field_types, base.field_attrs) |bf_name, bf_type, bf_attr| {
        comptime var found = false;
        inline for (override.field_names, override.field_types, override.field_attrs) |of_name, of_type, of_attr| {
            if (std.mem.eql(u8, bf_name, of_name)) {
                field_names[idx] = bf_name;
                field_types[idx] = of_type;
                field_attrs[idx] = of_attr;
                found = true;
                break;
            }
        }
        if (!found) {
            field_names[idx] = bf_name;
            field_types[idx] = bf_type;
            field_attrs[idx] = bf_attr;
        }
        idx += 1;
    }

    inline for (override.field_names, override.field_types, override.field_attrs) |of_name, of_type, of_attr| {
        comptime var found = false;
        inline for (base.field_names) |bf_name| {
            if (std.mem.eql(u8, bf_name, of_name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            field_names[idx] = of_name;
            field_types[idx] = of_type;
            field_attrs[idx] = of_attr;
            idx += 1;
        }
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn serializable(comptime T: type) bool {
    return serializableImpl(T, &.{});
}

fn serializableImpl(comptime T: type, comptime visited: []const type) bool {
    for (visited) |v| {
        if (v == T) return true;
    }

    const new_visited = visited ++ [_]type{T};

    return switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float, .bool => true,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) break :blk true;
                if (serializableImpl(ptr.child, new_visited)) break :blk true;
            }
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) break :blk true;
            }
            break :blk false;
        },
        .array => |arr| serializableImpl(arr.child, new_visited),
        .optional => |opt| serializableImpl(opt.child, new_visited),
        .@"struct" => |s| blk: {
            for (s.field_types) |field_type| {
                if (!serializableImpl(field_type, new_visited)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => true,
        else => false,
    };
}
