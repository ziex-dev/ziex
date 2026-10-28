const std = @import("std");
const zx = @import("zx");
const api = @import("../api.zig");
const data = @import("../data.zig");
const string = @import("../string.zig");
const connection = @import("../connection.zig");

pub const AppRoute = api.AppRoute;
pub const RouteOpts = api.RouteOpts;

pub var routes: []const AppRoute = &[_]AppRoute{};
pub var inputvalue: []const u8 = "";
pub var inputvalue_owned: ?[]const u8 = null;
pub var selected_path: []const u8 = "";
pub var selected_path_owned: ?[]const u8 = null;

var fetched = false;
var data_allocator: ?std.mem.Allocator = null;

pub fn invalidate() void {
    fetched = false;
    routes = &.{};
    selected_path = "";
}

pub fn ensureFetched(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (fetched) return;
    if (!data.loadSettings()) return;
    _ = connection.applyUrlConfig(allocator);
    data_allocator = allocator;
    const url = api.routesMetaUrl(allocator) orelse return;
    fetched = true;
    connection.markLoading();
    var client: zx.http.Client = .{ .io = zx.Io.default(), .allocator = allocator };
    client.fetchThen(.{ .url = url }, {}, onFetchText);
}

fn onFetchText(_: void, result: zx.http.Client.Error!zx.http.Client.Result) void {
    defer zx.client.rerender();
    const allocator = data_allocator orelse return;
    const r = result catch {
        connection.markUnavailable(connection.defaultUnavailableReason(allocator));
        return;
    };
    const status: u16 = @backingInt(r.status);
    if (status >= 400) return connection.markUnavailable(if (status == 502)
        "No app is running on this host (dev server returned 502)."
    else
        "App returned an error while loading routes.");
    if (r.body.len == 0) return connection.markUnavailable("Empty response from the app.");

    routes = zx.util.zxon.parse([]const AppRoute, allocator, r.body, .{}) catch
        return connection.markUnavailable("App responded, but the routes payload was invalid.");
    if (selected_path.len == 0 and routes.len > 0) {
        selected_path = routes[0].path;
    }
    connection.markConnected();
}

pub fn setSearch(value: ?[]const u8) void {
    data.adopt(&inputvalue_owned, &inputvalue, value, "");
}

pub fn setSelected(value: ?[]const u8) void {
    data.adopt(&selected_path_owned, &selected_path, value, "");
}

pub fn findSelected() ?AppRoute {
    if (selected_path.len == 0) return null;
    for (routes) |route| {
        if (std.mem.eql(u8, route.path, selected_path)) return route;
    }
    return null;
}

pub fn getMethodTokenClass(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "GET")) return "route-method-token method-get";
    if (std.mem.eql(u8, method, "POST")) return "route-method-token method-post";
    if (std.mem.eql(u8, method, "PUT")) return "route-method-token method-put";
    if (std.mem.eql(u8, method, "DELETE")) return "route-method-token method-delete";
    if (std.mem.eql(u8, method, "PATCH")) return "route-method-token method-patch";
    if (std.mem.eql(u8, method, "HEAD")) return "route-method-token method-head";
    if (std.mem.eql(u8, method, "OPTIONS")) return "route-method-token method-options";
    if (std.mem.eql(u8, method, "ANY")) return "route-method-token method-any";
    return "route-method-token";
}

pub fn routeMatchesSearch(route: AppRoute) bool {
    if (inputvalue.len == 0) return true;
    if (string.containsIgnoreCase(route.path, inputvalue)) return true;
    if (string.containsIgnoreCase(route.kind, inputvalue)) return true;
    for (route.methods) |method| {
        if (string.containsIgnoreCase(method, inputvalue)) return true;
    }
    return false;
}

pub fn getRouteItemClass(route: AppRoute) []const u8 {
    if (!routeMatchesSearch(route)) return "route-item route-item-hidden";
    if (std.mem.eql(u8, route.path, selected_path)) return "route-item route-item-selected";
    return "route-item";
}

pub fn getRouteHref(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    return api.routeHref(allocator, path);
}

pub fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}
