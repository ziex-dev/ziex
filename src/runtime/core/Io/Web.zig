//! `std.Io` for the browser. Clocks, entropy and sleep go to the page's JS;
//! everything else fails like `std.Io.failing`.
//!
//! `sleep` suspends the calling handler through JSPI, like a blocking `Client.fetch`.
//! Without JSPI it busy-waits.
const Web = @This();

const std = @import("std");
const Io = std.Io;

pub fn io() Io {
    return .{ .userdata = null, .vtable = &vtable };
}

const vtable: Io.VTable = blk: {
    var vt = Io.failing.vtable.*;
    vt.swapCancelProtection = &swapCancelProtection;
    vt.checkCancel = &checkCancel;
    vt.now = &now;
    vt.clockResolution = &clockResolution;
    vt.sleep = &sleep;
    vt.random = &random;
    vt.randomSecure = &randomSecure;
    break :blk vt;
};

/// Which JS clock backs an `Io.Clock`.
const Source = enum(u32) {
    /// `performance.timeOrigin + performance.now()`: Unix time with sub-millisecond precision.
    unix = 0,
    /// `performance.now()`: monotonic since page load.
    monotonic = 1,
};

fn source(clock: Io.Clock) ?Source {
    return switch (clock) {
        .real => .unix,
        .awake, .boot => .monotonic,
        // The page can't measure CPU time.
        .cpu_process, .cpu_thread => null,
    };
}

// Nothing cancels on the web, but std code still saves and restores the protection.
var cancel_protection: Io.CancelProtection = .unblocked;

fn swapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    defer cancel_protection = new;
    return cancel_protection;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

fn now(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const src = source(clock) orelse return .zero;
    return .{ .nanoseconds = ext.now(@backingInt(src)) };
}

fn clockResolution(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    _ = source(clock) orelse return error.ClockUnavailable;
    return .{ .nanoseconds = ext.resolution() };
}

fn sleep(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const duration = timeout.toDurationFromNow(io()) orelse return ext.sleep(-1);
    const ns = duration.raw.nanoseconds;
    if (ns <= 0) return;
    ext.sleep(@as(f64, @floatFromInt(ns)) / std.time.ns_per_ms);
}

fn random(_: ?*anyopaque, buffer: []u8) void {
    _ = ext.random(buffer.ptr, buffer.len);
}

fn randomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    if (!ext.random(buffer.ptr, buffer.len)) return error.EntropyUnavailable;
}

const ext = struct {
    extern "__zx_io" fn now(source: u32) i64;
    /// Timer granularity in nanoseconds (browsers coarsen `performance.now()`).
    extern "__zx_io" fn resolution() i64;
    /// Milliseconds; negative waits forever.
    extern "__zx_io" fn sleep(ms: f64) void;
    /// True when the bytes came from `crypto.getRandomValues`.
    extern "__zx_io" fn random(ptr: [*]u8, len: usize) bool;
};
