const std = @import("std");
const zx = @import("zx");
const data = @import("data.zig");

pub const RouteOpts = struct {
    rendering: ?[]const u8 = null,
    caching_ttl_s: ?i64 = null,
    caching_key: ?[]const u8 = null,
    prerender: bool = false,
    dynamic: bool = false,
    stream: bool = false,
    has_static: bool = false,
};

pub const AppRoute = struct {
    path: []const u8,
    kind: []const u8 = "Page",
    methods: []const []const u8 = &.{},
    has_page: bool = false,
    has_route: bool = false,
    has_layout: bool = false,
    has_notfound: bool = false,
    has_error: bool = false,
    has_proxy: bool = false,
    is_dynamic: bool = false,
    page_opts: ?RouteOpts = null,
    route_opts: ?RouteOpts = null,
    layout_opts: ?RouteOpts = null,
    rendering: RouteOpts = .{},
};

pub const ComponentsQuery = struct {
    include_native: bool = true,
    include_props: bool = true,
    include_attributes: bool = true,
};

pub fn hostBaseUrl(allocator: std.mem.Allocator) ?[]const u8 {
    _ = data.loadSettings();
    const host = data.host;
    if (std.mem.startsWith(u8, host, "http://") or std.mem.startsWith(u8, host, "https://")) {
        return host;
    }
    return allocator.print("http://{s}", .{host}) catch null;
}

pub fn componentsUrl(allocator: std.mem.Allocator, query: ComponentsQuery) ?[]const u8 {
    const base = hostBaseUrl(allocator) orelse return null;
    const path = data.current_path;
    return allocator.print(
        "{s}/.well-known/_zx/devtool?path={s}&include_native={d}&include_props={d}&include_attributes={d}",
        .{
            base,
            path,
            @as(u8, if (query.include_native) 1 else 0),
            @as(u8, if (query.include_props) 1 else 0),
            @as(u8, if (query.include_attributes) 1 else 0),
        },
    ) catch null;
}

pub fn routesMetaUrl(allocator: std.mem.Allocator) ?[]const u8 {
    const base = hostBaseUrl(allocator) orelse return null;
    return allocator.print("{s}/.well-known/_zx/devtool?meta=true", .{base}) catch null;
}

pub fn appInfoUrl(allocator: std.mem.Allocator) ?[]const u8 {
    const base = hostBaseUrl(allocator) orelse return null;
    return allocator.print("{s}/.well-known/_zx/app", .{base}) catch null;
}

pub fn runtimeInfoUrl(allocator: std.mem.Allocator) ?[]const u8 {
    const base = hostBaseUrl(allocator) orelse return null;
    return allocator.print("{s}/.well-known/_zx/devtool?info=true", .{base}) catch null;
}

pub fn openInEditorUrl(allocator: std.mem.Allocator, file: []const u8, line: u32) ?[]const u8 {
    const base = hostBaseUrl(allocator) orelse return null;
    return allocator.print(
        "{s}/.well-known/_zx/open-in-editor?file={s}&line={d}&col=1",
        .{ base, file, line },
    ) catch null;
}

pub fn routeHref(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const base = hostBaseUrl(allocator) orelse return "#";
    return allocator.print("{s}{s}", .{ base, path }) catch "#";
}

pub fn countSerializable(node: *const zx.util.devtool.ComponentSerializable, acc: usize) usize {
    var total = acc + 1;
    if (node.children) |kids| {
        for (kids) |*kid| {
            total = countSerializable(kid, total);
        }
    }
    return total;
}
