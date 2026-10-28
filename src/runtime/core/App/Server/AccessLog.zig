//! Shared dev-mode access logging for Std andd Httpz badckendds.
const std = @import("std");

const PageCache = @import("../../../server/PageCache.zig");

/// Paths to ignore in dev logging (browser probes, internal routes).
pub fn isNoisyPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/.well-known/")) return true;
    if (std.mem.startsWith(u8, path, "/assets/_/")) return true;
    if (std.mem.eql(u8, path, "/favicon.ico")) return true;
    return false;
}

/// Tracks proxy execution for the current request (thread-local).
pub const ProxyStatus = struct {
    threadlocal var executed: bool = false;
    threadlocal var aborted: bool = false;

    pub fn reset() void {
        executed = false;
        aborted = false;
    }

    pub fn markExecuted() void {
        executed = true;
    }

    pub fn markAborted() void {
        executed = true;
        aborted = true;
    }
};

/// Unified status indicator combining proxy and cache status.
/// Format: [XY] where X=proxy status, Y=cache status
/// Position 1 (proxy): ⇥=ran, !=aborted, -=none
/// Position 2 (cache): >=hit, o=miss, -=skip
const StatusIndicator = struct {
    const dim = "\x1b[2m";
    const red = "\x1b[91m";
    const green = "\x1b[92m";
    const yellow = "\x1b[93m";
    const magenta = "\x1b[95m";
    const reset = "\x1b[0m";

    fn get(cache_status: PageCache.Status, http_status: u16) []const u8 {
        const proxy_ran = ProxyStatus.executed;
        const proxy_aborted = ProxyStatus.aborted;

        if (cache_status == .disabled) {
            return if (proxy_aborted)
                dim ++ "[" ++ reset ++ red ++ "!" ++ reset ++ dim ++ "-]" ++ reset ++ " "
            else if (proxy_ran)
                dim ++ "[" ++ reset ++ magenta ++ "⇥" ++ reset ++ dim ++ "-]" ++ reset ++ " "
            else
                dim ++ "[--]" ++ reset ++ " ";
        }

        const effective_cache = PageCache.effectiveStatus(cache_status, http_status);

        if (proxy_aborted) {
            return switch (effective_cache) {
                .hit => dim ++ "[" ++ reset ++ red ++ "!" ++ green ++ ">" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .miss => dim ++ "[" ++ reset ++ red ++ "!" ++ yellow ++ "o" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .skip => dim ++ "[" ++ reset ++ red ++ "!" ++ reset ++ dim ++ "-]" ++ reset ++ " ",
                .disabled => dim ++ "[" ++ reset ++ red ++ "!" ++ reset ++ dim ++ "-]" ++ reset ++ " ",
            };
        } else if (proxy_ran) {
            return switch (effective_cache) {
                .hit => dim ++ "[" ++ reset ++ magenta ++ "⇥" ++ green ++ ">" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .miss => dim ++ "[" ++ reset ++ magenta ++ "⇥" ++ yellow ++ "o" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .skip => dim ++ "[" ++ reset ++ magenta ++ "⇥" ++ reset ++ dim ++ "-]" ++ reset ++ " ",
                .disabled => dim ++ "[" ++ reset ++ magenta ++ "⇥" ++ reset ++ dim ++ "-]" ++ reset ++ " ",
            };
        } else {
            return switch (effective_cache) {
                .hit => dim ++ "[-" ++ reset ++ green ++ ">" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .miss => dim ++ "[-" ++ reset ++ yellow ++ "o" ++ reset ++ dim ++ "]" ++ reset ++ " ",
                .skip => dim ++ "[--]" ++ reset ++ " ",
                .disabled => dim ++ "[--]" ++ reset ++ " ",
            };
        }
    }
};

pub const Args = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    start_time: std.Io.Timestamp,
    cache_status: PageCache.Status = .disabled,
};

/// Emit one colored access-log line. Caller should gate on comptime `is_dev`
/// and skip via `isNoisyPath` before calling.
pub fn log(allocator: std.mem.Allocator, io: std.Io, args: Args) void {
    const end_time = std.Io.Timestamp.now(io, .awake);
    const elapsed_ns = args.start_time.durationTo(end_time).nanoseconds;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const c = struct {
        const reset_c = "\x1b[0m";
        const method_c = "\x1b[1;34m";
        const path_color = "\x1b[36m";
        fn time(ms: f64) []const u8 {
            return if (ms < 10) "\x1b[92m" else if (ms < 100) "\x1b[93m" else "\x1b[91m";
        }
        fn status(code: u16) []const u8 {
            return if (code < 300) "\x1b[92m" else if (code < 400) "\x1b[93m" else "\x1b[91m";
        }
    };

    const msg = allocator.print("{s}{s}{s}{s} {s}{s}{s} {s}{d}{s} {s}{d:.3}ms{s}\x1b[K", .{
        StatusIndicator.get(args.cache_status, args.status),
        c.method_c,
        args.method,
        c.reset_c,
        c.path_color,
        args.path,
        c.reset_c,
        c.status(args.status),
        args.status,
        c.reset_c,
        c.time(elapsed_ms),
        elapsed_ms,
        c.reset_c,
    }) catch "[log line too long]";
    std.log.info("{s}", .{msg});
}
