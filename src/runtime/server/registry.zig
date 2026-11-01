const std = @import("std");
const zx = @import("../../root.zig");

pub const ActionFn = *const fn (*zx.server.Action) void;
pub const ServerEventFn = *const fn (*zx.server.Event) void;

// TODO: Make this allocator global and configurable by the user
const allocator = std.heap.page_allocator;

/// A dynamic linear registry that avoids HashMap (and its Wyhash 128-bit
/// multiply) so the module compiles on the native WASM backend without
/// requiring the `__multi3` compiler-rt intrinsic.
fn LinearMap(comptime V: type) type {
    const Entry = struct { key: []const u8, val: V };
    return struct {
        entries: std.ArrayList(Entry) = .empty,

        pub fn put(self: *@This(), key: []const u8, val: V) void {
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.key, key)) {
                    e.val = val;
                    return;
                }
            }
            self.entries.append(allocator, .{ .key = key, .val = val }) catch {};
        }

        pub fn get(self: *const @This(), key: []const u8) ?V {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.val;
            }
            return null;
        }
    };
}

var mu: std.Io.Mutex = .init;
var event_map: LinearMap(ServerEventFn) = .{};

const ActionEntry = struct {
    route_path: []const u8,
    action_id: u32,
    action_fn: ActionFn,
};

var action_entries: std.ArrayList(ActionEntry) = .empty;

/// Register an action handler for a route and return its stable action ID.
pub fn register(route_path: []const u8, preferred_action_id: u32, action_fn: ActionFn) u32 {
    mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (preferred_action_id != 0) {
        for (action_entries.items) |*entry| {
            if (entry.action_id == preferred_action_id and std.mem.eql(u8, entry.route_path, route_path)) {
                entry.action_fn = action_fn;
                return preferred_action_id;
            }
        }

        action_entries.append(allocator, .{
            .route_path = route_path,
            .action_id = preferred_action_id,
            .action_fn = action_fn,
        }) catch return preferred_action_id;
        return preferred_action_id;
    }

    var max_action_id: u32 = 0;
    for (action_entries.items) |entry| {
        if (!std.mem.eql(u8, entry.route_path, route_path)) continue;
        if (entry.action_fn == action_fn) return entry.action_id;
        max_action_id = @max(max_action_id, entry.action_id);
    }

    const action_id = max_action_id + 1;
    action_entries.append(allocator, .{
        .route_path = route_path,
        .action_id = action_id,
        .action_fn = action_fn,
    }) catch return action_id;
    return action_id;
}

pub fn registerEvent(route_path: []const u8, handler_id: u32, event_fn: ServerEventFn) void {
    mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer mu.unlock(std.Io.Threaded.global_single_threaded.io());

    // Composite key: "route_path:handler_id"
    var buf: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ route_path, handler_id }) catch return;

    for (event_map.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            e.val = event_fn;
            return;
        }
    }

    const key_dupe = allocator.dupe(u8, key) catch return;
    event_map.entries.append(allocator, .{ .key = key_dupe, .val = event_fn }) catch {
        allocator.free(key_dupe);
    };
}

pub fn getEvent(route_path: []const u8, handler_id: u32) ?ServerEventFn {
    mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer mu.unlock(std.Io.Threaded.global_single_threaded.io());

    var buf: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ route_path, handler_id }) catch return null;

    return event_map.get(key);
}

/// Look up a registered action handler by route path and action ID.
pub fn get(route_path: []const u8, action_id: u32) ?ActionFn {
    mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer mu.unlock(std.Io.Threaded.global_single_threaded.io());

    for (action_entries.items) |entry| {
        if (entry.action_id == action_id and std.mem.eql(u8, entry.route_path, route_path)) {
            return entry.action_fn;
        }
    }
    return null;
}
