const std = @import("std");
const options = @import("build_options");

pub const MenuItem = struct {
    href: []const u8,
    label: []const u8,
    active_match: []const u8,
};

pub const menu = [_]MenuItem{
    .{ .href = "/", .label = "Components", .active_match = "/" },
    .{ .href = "routes", .label = "Routes", .active_match = "routes" },
    .{ .href = "app", .label = "App", .active_match = "app" },
    .{ .href = "settings", .label = "Settings", .active_match = "settings" },
};

pub fn isActive(url: []const u8, match: []const u8) bool {
    if (std.mem.eql(u8, match, "/")) {
        return std.mem.eql(u8, url, "/") or std.mem.endsWith(u8, url, "index.html");
    }
    return std.mem.indexOf(u8, url, match) != null;
}

pub fn buildUrl(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    if (options.platform == .chromium) {
        if (std.mem.eql(u8, path, "/")) {
            return "index.html";
        }
        return allocator.print("{s}.html", .{path}) catch unreachable;
    }
    return path;
}
