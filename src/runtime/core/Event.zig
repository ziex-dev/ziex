const std = @import("std");
const zx = @import("../../root.zig");

/// A handle to a single state value.
/// Returned by `e.state(T)` or `sc.state(T)` - call `.get()` to read, `.set(val)` to write back.
pub fn StateHandle(comptime T: type) type {
    return struct {
        _internal: Internal,

        pub const Internal = struct {
            ctx: *StateContext,
            index: usize,
            value: T,
        };

        pub fn get(self: @This()) T {
            return self._internal.value;
        }

        pub fn set(self: @This(), val: T) void {
            if (self._internal.index >= self._internal.ctx._internal.outputs.len) return;
            var aw = std.Io.Writer.Allocating.init(self._internal.ctx.arena);
            zx.util.zxon.serialize(val, &aw.writer, .{}) catch return;
            self._internal.ctx._internal.outputs[self._internal.index] = aw.written();
        }
    };
}

/// Server-side accessor for component states round-tripped through a server event.
///
/// Call `sc.state(T)` in the same order as `ctx.state(T)` in the render function
/// to access each bound state - no index needed.
pub const StateContext = struct {
    arena: std.mem.Allocator,
    _internal: Internal = .{},

    pub const Internal = struct {
        /// Positional JSON values received from the client, one per bound state.
        inputs: []const []const u8 = &.{},
        /// Positional JSON values to return to the client (pre-seeded from inputs).
        outputs: [][]u8 = &.{},
        /// Auto-incremented by each call to state().
        index: usize = 0,
    };

    /// Create a StateContext from raw state slices (e.g. from a server event payload or form data).
    /// Duplicates each input into `outputs` so unmodified states are preserved in the response.
    pub fn init(arena: std.mem.Allocator, inputs: []const []const u8) ?*StateContext {
        const outputs = arena.alloc([]u8, inputs.len) catch return null;
        for (inputs, 0..) |s, i| {
            outputs[i] = arena.dupe(u8, s) catch "";
        }
        const sc = arena.create(StateContext) catch return null;
        sc.* = .{
            .arena = arena,
            ._internal = .{
                .inputs = inputs,
                .outputs = outputs,
            },
        };
        return sc;
    }

    /// Access the next bound state in call order, deserializing it to type `T`.
    /// Returns a StateHandle with `.get()` / `.set()` - same ergonomics as Event.Stateful.state().
    pub fn state(self: *StateContext, comptime T: type) StateHandle(T) {
        const i = self._internal.index;
        self._internal.index += 1;
        const val: T = if (i < self._internal.inputs.len)
            zx.util.zxon.parse(T, self.arena, self._internal.inputs[i], .{}) catch std.mem.zeroes(T)
        else
            std.mem.zeroes(T);
        return .{ ._internal = .{ .ctx = self, .index = i, .value = val } };
    }

    pub fn fmt(self: StateContext, comptime format: []const u8, args: anytype) ![]u8 {
        return self.arena.print(format, args);
    }
};
