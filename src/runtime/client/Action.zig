const Action = @This();

const std = @import("std");
const zx = @import("../../root.zig");
const ext = @import("window/extern.zig");
const reactivity = @import("reactivity.zig");

const Allocator = std.mem.Allocator;
const is_wasm = zx.platform.role == .client;

allocator: Allocator = undefined,

_internal: Internal = .{},

pub const Internal = struct {
    component_id: []const u8 = "",
    state_idx: u32 = 0,
    /// form entries from: `[k1, v1, k2, v2, ...]`.
    entries: []const []const u8 = &.{},
};

/// Build an Action from a submit event: preventDefault is caller's responsibility.
pub fn fromEvent(event: zx.client.Event, alloc: Allocator) Action {
    if (comptime !is_wasm) return .{ .allocator = alloc };

    return .{
        .allocator = alloc,
        ._internal = .{ .entries = readFormEntries(alloc, event._internal.event_ref) },
    };
}

fn readFormEntries(alloc: Allocator, event_ref: u32) []const []const u8 {
    var ptr: [*]u8 = undefined;
    const len = ext._getFormData(event_ref, &ptr);
    if (len == 0) return &.{};
    defer std.heap.wasm_allocator.free(ptr[0..len]);
    return zx.util.zxon.parse([]const []const u8, alloc, ptr[0..len], .{}) catch &.{};
}

/// Parse form fields into struct `T` (same field coercion as server Action).
pub fn data(self: Action, comptime T: type) T {
    comptime if (@typeInfo(T) != .@"struct") @compileError("ctx.data() requires a struct type, got: " ++ @typeName(T));

    var result: T = undefined;
    const type_struct = @typeInfo(T).@"struct";
    inline for (type_struct.field_names, type_struct.field_types) |field_name, field_type| {
        @field(result, field_name) = parseFormField(
            field_type,
            self.allocator,
            self._internal.entries,
            field_name,
        );
    }
    return result;
}

fn get(entries: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (std.mem.eql(u8, entries[i], name)) return entries[i + 1];
    }
    return null;
}

fn getAll(allocator: Allocator, entries: []const []const u8, name: []const u8) []const []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (std.mem.eql(u8, entries[i], name)) count += 1;
    }

    const values = allocator.alloc([]const u8, count) catch return &.{};
    i = 0;
    var out: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (!std.mem.eql(u8, entries[i], name)) continue;
        values[out] = entries[i + 1];
        out += 1;
    }
    return values;
}

/// Stateful client action - provides `state()` access to bound component state.
/// Use `fn(*zx.client.Action.Stateful) void` with `ctx.bind()` to get this type.
pub const Stateful = struct {
    inner: *Action,

    /// Access the component's state.
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *Stateful, comptime T: type) *reactivity.State(T) {
        const slot = (1 << 20) + self.inner._internal.state_idx;
        self.inner._internal.state_idx += 1;
        return reactivity.State(T).getExisting(self.inner._internal.component_id, slot);
    }

    pub fn data(self: *Stateful, comptime T: type) T {
        return self.inner.data(T);
    }
};

// TODO: this is duplicated logic that we can later re-use by isolating to it's own thing and adding tests for it.
fn parseFormField(
    comptime T: type,
    allocator: Allocator,
    entries: []const []const u8,
    name: []const u8,
) T {
    if (comptime T == []const []const u8) return getAll(allocator, entries, name);
    return parseScalar(T, get(entries, name));
}

fn parseScalar(comptime T: type, raw: ?[]const u8) T {
    switch (@typeInfo(T)) {
        .optional => |opt| return parseScalar(opt.child, raw orelse return null),
        .pointer => {
            comptime if (T != []const u8) @compileError("ctx.data(): unsupported pointer type: " ++ @typeName(T));
            return raw orelse "";
        },
        .bool => {
            const val = raw orelse return false;
            return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
        },
        .int => return std.fmt.parseInt(T, raw orelse return 0, 10) catch 0,
        .float => return std.fmt.parseFloat(T, raw orelse return 0) catch 0,
        else => @compileError("ctx.data(): unsupported field type '" ++ @typeName(T) ++ "'"),
    }
}
