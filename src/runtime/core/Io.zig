//! `std.Io` implementations for Ziex, and the default one for each platform.
const std = @import("std");
const builtin = @import("builtin");

pub const Web = @import("Io/Web.zig");

const is_browser = builtin.os.tag == .freestanding;
const Threaded = if (is_browser) void else std.Io.Threaded;

var threaded: Threaded = if (is_browser) {} else undefined;
var threaded_initialized = false;

/// `Web` in the browser, a shared `std.Io.Threaded` everywhere else (including the edge).
pub fn default() std.Io {
    if (comptime is_browser) return Web.io();

    if (!threaded_initialized) {
        threaded = .init(allocator(), .{});
        threaded_initialized = true;
    }
    return threaded.io();
}

/// Tears down the shared `std.Io.Threaded`; `default()` creates a new one afterwards.
pub fn deinitDefault() void {
    if (comptime is_browser) return;
    if (!threaded_initialized) return;
    threaded.deinit();
    threaded_initialized = false;
}

fn allocator() std.mem.Allocator {
    return @import("App.zig").allocator;
}
