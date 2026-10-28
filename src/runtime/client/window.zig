const std = @import("std");
const builtin = @import("builtin");

const zx = @import("../../root.zig");
pub const ext = @import("window/extern.zig");
pub const reactivity = @import("reactivity.zig");
pub const WebSocket = @import("../core/WebSocket.zig");
pub const Document = @import("window/document.zig");

pub const is_wasm = zx.platform.role == .client;

/// JS bindings - only available in WASM builds
pub const js = if (is_wasm) @import("js") else struct {
    pub const Object = void;
    pub const Value = void;
    pub const String = []const u8;
    pub const global = struct {
        pub fn get(_: type, _: []const u8) !void {}
        pub fn call(_: type, _: []const u8, _: anytype) !void {}
    };
    pub fn string(_: []const u8) void {}
};

pub const Console = struct {
    ref: js.Object,

    pub fn init() Console {
        return .{
            .ref = js.global.get(js.Object, "console") catch @panic("JS_ERR"),
        };
    }

    pub fn deinit(self: Console) void {
        self.ref.deinit();
    }

    pub fn log(self: Console, args: anytype) void {
        self.ref.call(void, "log", args) catch @panic("JS");
    }

    pub fn str(self: Console, data: []const u8) void {
        self.ref.call(void, "log", .{js.string(data)}) catch @panic("JS_ERR");
    }

    pub fn strLevel(self: Console, message_level: std.log.Level, data: []const u8) void {
        switch (message_level) {
            .debug => self.ref.call(void, "debug", .{js.string(data)}) catch @panic("JS_ERR"),
            .info => self.ref.call(void, "info", .{js.string(data)}) catch @panic("JS_ERR"),
            .warn => self.ref.call(void, "warn", .{js.string(data)}) catch @panic("JS_ERR"),
            .err => self.ref.call(void, "error", .{js.string(data)}) catch @panic("JS_ERR"),
        }
    }
};

pub const Event = struct {
    pub const EventTarget = struct {
        value: ?[]const u8 = null,
    };

    /// The js.Object reference to the event
    ref: js.Object,

    target: ?EventTarget = null,
    data: ?[]const u8 = null,

    /// Create an Event from a u64 NaN-boxed reference (passed from JS via jsz)
    pub fn fromRef(event_ref: u64) Event {
        const event_value: js.Value = @enumFromInt(event_ref);
        const event_obj = js.Object{ .value = event_value };

        return .{
            .ref = event_obj,
            .target = null,
            .data = null,
        };
    }

    pub fn preventDefault(self: Event) void {
        self.ref.call(void, "preventDefault", .{}) catch @panic("JS_ERR");
    }

    pub fn stopPropagation(self: Event) void {
        self.ref.call(void, "stopPropagation", .{}) catch @panic("JS_ERR");
    }

    pub fn stopImmediatePropagation(self: Event) void {
        self.ref.call(void, "stopImmediatePropagation", .{}) catch @panic("JS_ERR");
    }

    pub fn getType(self: Event, allocator: std.mem.Allocator) ?[]const u8 {
        return self.ref.getAlloc(js.String, allocator, "type") catch null;
    }

    pub fn getTarget(self: Event) ?js.Object {
        return self.ref.get(js.Object, "target") catch null;
    }

    pub fn deinit(self: Event) void {
        self.ref.deinit();
    }
};

pub fn eval(T: type, code: []const u8) !T {
    _ = @as([]const u8, code);
    return try js.global.call(T, "eval", .{js.string(code)});
}

/// Callback types for async operations (must match bridge.ts CallbackType)
pub const CallbackType = enum(u8) {
    event = 0,
    fetch_success = 1,
    fetch_error = 2,
    timeout = 3,
    interval = 4,
    ws_open = 5,
    ws_message = 6,
    ws_error = 7,
    ws_close = 8,
};

/// Callback function types
pub const TimeoutCallback = *const fn () void;
pub const IntervalCallback = *const fn () void;

/// Maximum number of concurrent callbacks
const MAX_CALLBACKS = 64;

const TimerApi = struct {
    pub fn setTimeout(callback: TimeoutCallback, delay: std.Io.Duration) ?u64 {
        const id = registerCallback(.{
            .callback_type = .timeout,
            .timeout_fn = callback,
            .active = true,
        }) orelse return null;

        ext._setTimeout(id, millis(delay));
        return id;
    }

    pub fn setInterval(callback: IntervalCallback, interval: std.Io.Duration) ?u64 {
        const id = registerCallback(.{
            .callback_type = .interval,
            .interval_fn = callback,
            .active = true,
        }) orelse return null;

        ext._setInterval(id, millis(interval));
        return id;
    }

    pub fn clearInterval(callback_id: u64) void {
        const index: usize = @intCast(callback_id % MAX_CALLBACKS);
        if (callbacks[index].active and callbacks[index].callback_type == .interval) {
            callbacks[index].active = false;
            ext._clearInterval(callback_id);
        }
    }
};

/// Callback registry entry
const CallbackEntry = struct {
    callback_type: CallbackType,
    timeout_fn: ?TimeoutCallback = null,
    interval_fn: ?IntervalCallback = null,
    active: bool = false,
};

/// Global callback registry
var callbacks: [MAX_CALLBACKS]CallbackEntry = @splat(CallbackEntry{
    .callback_type = .event,
    .active = false,
});
var next_callback_id: u64 = 1;

/// Register a callback and get its ID
fn registerCallback(entry: CallbackEntry) ?u64 {
    const id = next_callback_id;
    const index: usize = @intCast(id % MAX_CALLBACKS);

    if (callbacks[index].active) {
        // Slot is occupied, find another
        for (&callbacks, 0..) |*slot, i| {
            if (!slot.active) {
                slot.* = entry;
                slot.active = true;
                next_callback_id = i + 1;
                return @intCast(i);
            }
        }
        return null; // No free slots
    }

    callbacks[index] = entry;
    callbacks[index].active = true;
    next_callback_id += 1;
    return id;
}

/// Calls `callback` once after `delay`.
pub fn setTimeout(callback: TimeoutCallback, delay: std.Io.Duration) ?u64 {
    if (!is_wasm) return null;
    return TimerApi.setTimeout(callback, delay);
}

/// Calls `callback` every `interval`.
pub fn setInterval(callback: IntervalCallback, interval: std.Io.Duration) ?u64 {
    if (!is_wasm) return null;
    return TimerApi.setInterval(callback, interval);
}

/// JS timers take whole milliseconds.
fn millis(duration: std.Io.Duration) u32 {
    return std.math.lossyCast(u32, @max(0, duration.toMilliseconds()));
}

/// Clear an interval by its ID
pub fn clearInterval(callback_id: u64) void {
    if (!is_wasm) return;
    TimerApi.clearInterval(callback_id);
}

/// Dispatch a callback from JS (called by __zx_cb export)
/// Returns true if a callback was found and invoked
pub fn dispatchCallback(callback_type: CallbackType, callback_id: u64, data_ref: u64, allocator: std.mem.Allocator) bool {
    _ = data_ref;
    _ = allocator;

    const index: usize = @intCast(callback_id % MAX_CALLBACKS);
    const entry = &callbacks[index];

    if (!entry.active) return false;

    switch (callback_type) {
        .timeout => {
            if (entry.timeout_fn) |cb| {
                cb();
                entry.active = false;
                return true;
            }
        },
        .interval => {
            if (entry.interval_fn) |cb| {
                cb();
                // Keep active for next tick
                return true;
            }
        },
        .fetch_success, .fetch_error, .event, .ws_open, .ws_message, .ws_error, .ws_close => return false,
    }

    return false;
}
