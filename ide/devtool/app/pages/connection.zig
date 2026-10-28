const std = @import("std");
const zx = @import("zx");
const data = @import("data.zig");

pub const Status = enum {
    /// No fetch attempted yet this session.
    idle,
    /// At least one fetch in flight.
    loading,
    /// Last fetch succeeded.
    connected,
    /// Last fetch failed (app down, CORS, mixed content, etc.).
    unavailable,
};

pub var status: Status = .idle;

/// Human-readable reason shown in the fallback UI (static string, not owned).
pub var detail: []const u8 = "";

pub fn markLoading() void {
    if (status != .connected) status = .loading;
}

pub fn markConnected() void {
    status = .connected;
    detail = "";
}

pub fn markUnavailable(reason: []const u8) void {
    status = .unavailable;
    detail = reason;
}

pub const unreachable_app =
    "Cannot reach the app. Check the host/port, or start it with `zx dev` / `zig build dev`.";

pub fn defaultUnavailableReason(allocator: std.mem.Allocator) []const u8 {
    if (mixedContentHint(allocator)) |hint| return hint;
    return unreachable_app;
}

pub fn isUnavailable() bool {
    return status == .unavailable;
}

pub fn isLoading() bool {
    return status == .loading;
}

pub fn reset() void {
    status = .idle;
    detail = "";
}

/// Apply `?port=` / `?host=` from the page URL into `data.host` (and localStorage).
/// Returns true when a query override was applied.
pub fn applyUrlConfig(allocator: std.mem.Allocator) bool {
    if (comptime zx.platform.isServer()) return false;
    const search = readLocationSearch(allocator) orelse return false;
    defer allocator.free(search);

    var host_override: ?[]const u8 = null;
    var port_override: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, search, '&');
    while (iter.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.first();
        const value = kv.rest();
        if (std.mem.eql(u8, key, "host") and value.len > 0) {
            host_override = value;
        } else if (std.mem.eql(u8, key, "port") and value.len > 0) {
            port_override = value;
        }
    }

    if (host_override) |h| {
        const decoded = percentDecodeAlloc(allocator, h) catch return false;
        data.setHost(decoded);
        return true;
    }
    if (port_override) |p| {
        const port = std.fmt.parseInt(u16, p, 10) catch return false;
        if (port == 0) return false;
        const host = allocator.print("localhost:{d}", .{port}) catch return false;
        data.setHost(host);
        return true;
    }
    return false;
}

fn readLocationSearch(allocator: std.mem.Allocator) ?[]u8 {
    const js = zx.client.js;
    const loc = js.global.get(js.Object, "location") catch return null;
    defer loc.deinit();
    const raw = loc.getAlloc(js.String, allocator, "search") catch return null;
    defer allocator.free(raw);
    if (raw.len == 0) return null;
    const trimmed = if (raw[0] == '?') raw[1..] else raw;
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.parseInt(u8, input[i + 1 .. i + 2], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.parseInt(u8, input[i + 2 .. i + 3], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Suggest a helpful message when the page is HTTPS but the target is HTTP localhost.
pub fn mixedContentHint(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime zx.platform.isServer()) return null;
    const js = zx.client.js;
    const loc = js.global.get(js.Object, "location") catch return null;
    defer loc.deinit();
    const protocol = loc.getAlloc(js.String, allocator, "protocol") catch return null;
    defer allocator.free(protocol);
    if (!std.mem.eql(u8, protocol, "https:")) return null;

    const host = data.host;
    const is_local = std.mem.indexOf(u8, host, "localhost") != null or std.mem.indexOf(u8, host, "127.0.0.1") != null;
    const is_http = !std.mem.startsWith(u8, host, "https://");
    if (is_local and is_http) {
        return "Safari and some browsers block HTTPS pages from reaching http://localhost. Use the Chrome extension, or open this UI over HTTP.";
    }
    return null;
}
