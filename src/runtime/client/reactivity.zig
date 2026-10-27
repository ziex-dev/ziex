const std = @import("std");
const builtin = @import("builtin");

const Client = @import("Client.zig");
const zx = @import("../../root.zig");

const js = zx.client.js;
const is_wasm = zx.platform.role == .client;

fn getGlobalAllocator() std.mem.Allocator {
    return zx.allocator;
}

const ComponentSubKey = struct {
    component_id: []const u8,

    const Context = struct {
        pub fn hash(_: Context, k: ComponentSubKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            return h.final();
        }
        pub fn eql(_: Context, a: ComponentSubKey, b: ComponentSubKey) bool {
            return std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

var component_subscriptions = std.HashMapUnmanaged(
    ComponentSubKey,
    void,
    ComponentSubKey.Context,
    std.hash_map.default_max_load_percentage,
){};

pub var active_component_id: ?[]const u8 = null;

/// Key for the per-component per-slot state store.
const StateKey = struct {
    component_id: []const u8,
    slot: u32,

    const Context = struct {
        pub fn hash(_: Context, k: StateKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            h.update(std.mem.asBytes(&k.slot));
            return h.final();
        }
        pub fn eql(_: Context, a: StateKey, b: StateKey) bool {
            return a.slot == b.slot and std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

/// Opaque blob of state with a serialization vtable for server event round-trips.
const StateEntry = struct {
    ptr: *anyopaque,
    /// Serialize current value to positional JSON. Only populated on WASM.
    getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8 = &noopGetJson,
    /// Apply a positional JSON value back to the state (triggers re-render).
    applyJson: *const fn (ptr: *anyopaque, json: []const u8) void = &noopApplyJson,

    fn noopGetJson(_: std.mem.Allocator, _: *anyopaque) []const u8 {
        return "null";
    }
    fn noopApplyJson(_: *anyopaque, _: []const u8) void {}
};

var state_store = std.HashMapUnmanaged(
    StateKey,
    StateEntry,
    StateKey.Context,
    std.hash_map.default_max_load_percentage,
){};

/// Slot base for `ctx.action` pending flags. Kept out of the normal
/// `(1 << 20) + state_idx` range so pending is never round-tripped to the server.
pub const action_pending_slot_base: u32 = 3 << 20;

pub fn actionPendingState(
    alloc: std.mem.Allocator,
    component_id: []const u8,
    action_idx: u32,
) *State(bool) {
    return State(bool).getOrCreate(alloc, component_id, action_pending_slot_base + action_idx, false) catch
        @panic("actionPendingState");
}

pub fn State(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        /// The owning component ID - used to call scheduleRender on mutation.
        component_id: []const u8,

        pub fn init(value: T, component_id: []const u8) Self {
            return .{ .value = value, .component_id = component_id };
        }

        /// Get the current value.
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Set a new value and trigger a component re-render.
        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            scheduleRender(self.component_id);
        }

        /// Update the value using a transform function `fn(T) T` and trigger a re-render.
        /// Example: `count.update(struct { fn f(x: i32) i32 { return x + 1; } }.f)`
        pub fn update(self: *Self, transform: *const fn (T) T) void {
            self.value = transform(self.value);
            scheduleRender(self.component_id);
        }

        /// Create an event handler that updates the state using a transform function.
        pub fn bind(self: *Self, comptime transform: *const fn (T) T) zx.EventHandler {
            return .{
                .callback = &struct {
                    fn handler(ctx: *anyopaque, _: zx.client.Event) void {
                        const s: *Self = @ptrCast(@alignCast(ctx));
                        s.set(transform(s.get()));
                    }
                }.handler,
                .context = self,
            };
        }

        pub fn getOrCreate(alloc: std.mem.Allocator, component_id: []const u8, slot: u32, initial: T) !*Self {
            if (is_wasm) {
                const key = StateKey{ .component_id = component_id, .slot = slot };

                if (state_store.get(key)) |entry| {
                    return @ptrCast(@alignCast(entry.ptr));
                }

                const state_ptr = try getGlobalAllocator().create(Self);
                state_ptr.* = Self.init(initial, component_id);
                const id_copy = try getGlobalAllocator().dupe(u8, component_id);
                const stored_key = StateKey{ .component_id = id_copy, .slot = slot };
                try state_store.put(getGlobalAllocator(), stored_key, .{
                    .ptr = @ptrCast(state_ptr),
                    .getJson = &struct {
                        fn f(a: std.mem.Allocator, ptr: *anyopaque) []const u8 {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            var aw = std.Io.Writer.Allocating.init(a);
                            zx.util.zxon.serialize(s.get(), &aw.writer, .{}) catch return "null";
                            return aw.written();
                        }
                    }.f,
                    .applyJson = &struct {
                        fn f(ptr: *anyopaque, json: []const u8) void {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            s.set(zx.util.zxon.parse(T, getGlobalAllocator(), json, .{}) catch return);
                        }
                    }.f,
                });
                return state_ptr;
            } else {
                // Server SSR: return default state
                const state_ptr = try alloc.create(Self);
                state_ptr.* = Self.init(initial, component_id);
                return state_ptr;
            }
        }

        /// Look up an existing state by (component_id, slot). Used by StateContext in event handlers
        /// where the state was already created during render.
        pub fn getExisting(component_id: []const u8, slot: u32) *Self {
            const key = StateKey{ .component_id = component_id, .slot = slot };
            if (state_store.get(key)) |entry| {
                return @ptrCast(@alignCast(entry.ptr));
            }
            @panic("State not found - ensure sc.state() is called in the same order as ctx.state()");
        }
    };
}

/// Top-level alias for State(T) pointer to improve IDE/ZLS type resolution.
pub fn StateInstance(comptime T: type) type {
    return *State(T);
}

/// Collect a BoundStateEntry for every state belonging to `component_id`, in slot order.
/// Used by ctx.bind(serverFn) to auto-bind all component states for server event round-trips.
/// Returns an empty slice on SSR (state_store is not populated server-side).
pub fn collectStateBoundEntries(
    alloc: std.mem.Allocator,
    component_id: []const u8,
    state_count: u32,
) []EventHandler.Bound {
    if (!is_wasm) return &.{};

    var list = std.ArrayList(EventHandler.Bound).empty;
    for (0..state_count) |i| {
        const slot = (1 << 20) + @as(u32, @intCast(i));
        const key = StateKey{ .component_id = component_id, .slot = slot };
        if (state_store.get(key)) |entry| {
            list.append(alloc, .{
                .state_ptr = entry.ptr,
                .getJson = entry.getJson,
                .applyJson = entry.applyJson,
            }) catch {};
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Re-render the whole page using VDOM diffing algorithm like react
pub fn rerender() void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        client.renderAll();
    }
}

/// Request a re-render of a specific component by ID.
/// If the component_id is not found in the registry (e.g. a nested ComponentCtx
/// component without @client), falls back to re-rendering all components.
pub fn scheduleRender(component_id: []const u8) void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        const instance = Client.parseInstanceKey(component_id);
        for (client.components) |cmp| {
            if (std.mem.eql(u8, cmp.id, instance.id)) {
                client.renderInstance(cmp, instance.occurrence) catch {};
                return;
            }
        }
        // component_id not registered - nested component inside a CSR parent.
        // Re-render all so the parent picks up the state change.
        client.renderAll();
    }
}

pub const EventHandler = zx.EventHandler;
