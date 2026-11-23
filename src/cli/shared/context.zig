const std = @import("std");
const builtin = @import("builtin");

const tui = @import("../../tui/main.zig");

/// Shared per-process context threaded through CLI commands.
pub const AppContext = struct {
    io: std.Io,
    environ_map: *std.process.Environ.Map,
};

/// Per-command execution context passed to each command's `run` function.
pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    spinner: if (builtin.cpu.arch.isWasm()) void else *tui.Spinner,
    app: *AppContext,
};
