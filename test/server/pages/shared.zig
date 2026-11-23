//! Handlers declared outside any listed module; `events.zig` re-exports one.
const zx = @import("zx");

pub var calls: u32 = 0;

pub fn onShared(_: *zx.server.Event) void {
    calls += 1;
}
