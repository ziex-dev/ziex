const zx = @import("../../root.zig");
const core = @import("../core/Event.zig");

const Allocator = zx.Allocator;
const StateContext = core.StateContext;

const Event = @This();

allocator: Allocator = undefined,
arena: Allocator = undefined,
io: @import("std").Io = undefined,

_internal: Internal = .{},

pub const Internal = struct {
    action_ref: u64 = 0,
    payload: zx.EventHandler.Payload = .{},
    state_ctx: ?*StateContext = null,
};

pub fn init(action_ref: u64) Event {
    return .{ ._internal = .{ .action_ref = action_ref } };
}

pub fn value(self: Event) ?[]const u8 {
    return self._internal.payload.value;
}

/// Stateful server event - provides `state()` access to bound component state.
pub const Stateful = struct {
    inner: *Event,

    /// Access the component's state (server-side).
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *Stateful, comptime T: type) core.StateHandle(T) {
        return self.inner._internal.state_ctx.?.state(T);
    }

    pub fn value(self: Stateful) ?[]const u8 {
        return self.inner.value();
    }
};
