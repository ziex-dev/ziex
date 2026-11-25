const Event = @This();

const std = @import("std");
const builtin = @import("builtin");

const zx = @import("../../root.zig");
const client = @import("window.zig");
const generated_events = @import("events/generated.zig");

const js = zx.client.js;
const reactivity = client.reactivity;
const Allocator = zx.Allocator;
pub const Kind = generated_events.Kind;
const platform_role = zx.platform.role;

_internal: Internal = .{},

pub const Internal = struct {
    event_ref: u32 = 0,
    component_id: []const u8 = "",
    state_idx: u32 = 0,
};

pub fn init(event_ref: u32) Event {
    return .{ ._internal = .{ .event_ref = event_ref } };
}

/// Get the underlying js.Object for the event
pub fn getEvent(self: Event) client.Event {
    return client.Event.fromRef(self._internal.event_ref);
}

pub fn preventDefault(self: Event) void {
    if (platform_role != .client) return;

    self.getEvent().preventDefault();
}

pub fn stopPropagation(self: Event) void {
    if (platform_role != .client) return;

    self.getEvent().stopPropagation();
}

pub fn stopImmediatePropagation(self: Event) void {
    if (platform_role != .client) return;

    self.getEvent().stopImmediatePropagation();
}

/// The live DOM event as a `zx.client.web` interface, e.g. `ctx.native(web.DragEvent)`.
/// Valid during the handler; `.h.dup()` to keep it longer.
pub fn native(self: Event, comptime T: type) T {
    return .{ .h = @fromBackingInt(self._internal.event_ref) };
}

/// Get the input/button value for the element that owns the handler.
pub fn value(self: Event) ?[]const u8 {
    if (platform_role != .client) return null;
    const event = self.getEvent();
    if (event.ref.get(js.Object, "currentTarget") catch null) |current| {
        defer current.deinit();
        if (current.getAlloc(js.String, zx.allocator, "value") catch null) |v| return v;
    }
    const target = event.ref.get(js.Object, "target") catch return null;
    defer target.deinit();
    return target.getAlloc(js.String, zx.allocator, "value") catch null;
}

/// Get the key from keyboard event
pub fn key(self: Event) ?[]const u8 {
    if (platform_role != .client) return null;
    const event = self.getEvent();
    return event.ref.getAlloc(js.String, zx.allocator, "key") catch null;
}

/// Get the event data by providing zx.client.events.<Type>.
pub fn as(self: Event, comptime T: type, allocator: Allocator) T {
    _ = allocator;
    if (platform_role != .client) return std.mem.zeroInit(T, .{});
    const event = self.getEvent();
    if (comptime (builtin.optimize == .debug)) assertType(T, event);
    return readStruct(T, scratchAllocator(), event.ref);
}

var scratch_arena: std.heap.ArenaAllocator = undefined;
var scratch_ready: bool = false;

fn scratchAllocator() Allocator {
    if (!scratch_ready) {
        scratch_arena = .init(zx.allocator);
        scratch_ready = true;
    } else {
        _ = scratch_arena.reset(.retain_capacity);
    }
    return scratch_arena.allocator();
}

/// Debug-only guard: validates that requested struct `T` matches the live event.
inline fn assertType(comptime T: type, event: client.Event) void {
    if (comptime T == generated_events.Event) return;

    const type_str = event.getType(zx.allocator) orelse return;
    defer zx.allocator.free(type_str);

    const kind = generated_events.kindForType(type_str) orelse return; // custom event
    switch (kind) {
        inline else => |k| {
            if (generated_events.Data(k) != T) {
                std.log.err(
                    \\Event.as, incorrect type requested for '{s}' event
                    \\
                    \\  Requested: {s}
                    \\  Expected: {s}
                    \\
                ,
                    .{ type_str, @typeName(T), @typeName(generated_events.Data(k)) },
                );
            }
        },
    }
}

fn readStruct(comptime T: type, allocator: Allocator, obj: js.Object) T {
    const info = @typeInfo(T).@"struct";
    var result: T = std.mem.zeroInit(T, .{});
    inline for (info.field_types, info.field_names) |field_type, field_name| {
        if (readField(field_type, allocator, obj, field_name)) |v| {
            @field(result, field_name) = v;
        }
    }
    return result;
}

// One boundary crossing per field; type mismatches read as null.
fn readField(comptime F: type, allocator: Allocator, obj: js.Object, comptime name: []const u8) ?F {
    const finfo = @typeInfo(F);
    const Child = if (finfo == .optional) finfo.optional.child else F;
    const js_name = comptime generated_events.jsName(name);

    switch (@typeInfo(Child)) {
        .@"struct" => {
            const sub = (obj.get(?js.Object, js_name) catch return null) orelse return null;
            defer sub.deinit();
            return readStruct(Child, allocator, sub);
        },
        .pointer => |p| {
            if (p.size != .slice or p.child != u8) @compileError("unsupported pointer field type in Event.as: " ++ @typeName(F));
            return obj.getAlloc(?js.String, allocator, js_name) catch null;
        },
        .int => {
            const v = (obj.get(?f64, js_name) catch return null) orelse return null;
            return std.math.lossyCast(Child, v);
        },
        .float => {
            const v = (obj.get(?f64, js_name) catch return null) orelse return null;
            return @floatCast(v);
        },
        .bool => return obj.get(?bool, js_name) catch null,
        else => @compileError("unsupported field type in Event.as: " ++ @typeName(F)),
    }
}

/// Stateful client event, provides `state()` access to bound component's state.
pub const Stateful = struct {
    inner: *Event,

    /// Access the component's state.
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *Stateful, comptime T: type) *reactivity.State(T) {
        const slot = (1 << 20) + self.inner._internal.state_idx;
        self.inner._internal.state_idx += 1;
        return reactivity.State(T).getExisting(self.inner._internal.component_id, slot);
    }

    pub fn getEvent(self: Stateful) client.Event {
        return self.inner.getEvent();
    }

    pub fn preventDefault(self: Stateful) void {
        self.inner.preventDefault();
    }

    pub fn stopPropagation(self: Stateful) void {
        self.inner.stopPropagation();
    }

    pub fn stopImmediatePropagation(self: Stateful) void {
        self.inner.stopImmediatePropagation();
    }

    pub fn value(self: Stateful) ?[]const u8 {
        return self.inner.value();
    }

    pub fn native(self: Stateful, comptime T: type) T {
        return self.inner.native(T);
    }

    pub fn key(self: Stateful) ?[]const u8 {
        return self.inner.key();
    }

    pub fn as(self: Stateful, comptime T: type, allocator: Allocator) T {
        return self.inner.as(T, allocator);
    }
};
