const std = @import("std");
const zx = @import("zx");
const api = @import("api.zig");
const data = @import("data.zig");
const connection = @import("connection.zig");

pub var components: []const data.Component = &.{};
pub var inputvalue: []const u8 = "";
pub var inputvalue_owned: ?[]const u8 = null;
pub var stateFilter: []const u8 = "";
pub var stateFilter_owned: ?[]const u8 = null;
pub var selected_component: []const u8 = "";
pub var selected_component_owned: ?[]const u8 = null;

var fetched = false;
var data_allocator: ?std.mem.Allocator = null;

pub fn invalidate() void {
    fetched = false;
    components = &.{};
}

pub fn ensureFetched(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (fetched) return;
    if (!data.loadSettings()) return;
    _ = connection.applyUrlConfig(allocator);
    data_allocator = allocator;
    const url = api.componentsUrl(allocator, .{
        .include_native = data.show_native_elements,
        .include_props = data.include_props,
        .include_attributes = data.include_attributes,
    }) orelse return;
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
    if (status >= 400) return connection.markUnavailable(unavailableReason(allocator, status));
    if (r.body.len == 0) return connection.markUnavailable("Empty response from the app.");

    const parsed = zx.util.zxon.parse(zx.util.devtool.ComponentSerializable, allocator, r.body, .{}) catch
        return connection.markUnavailable("App responded, but the component payload was invalid.");
    const mapped = data.fromSerializableRoot(allocator, parsed) catch
        return connection.markUnavailable("Failed to map component tree.");
    std.log.info("Fetched {d} root components", .{mapped.len});
    components = mapped;
    connection.markConnected();
}

fn unavailableReason(allocator: std.mem.Allocator, status_code: u16) []const u8 {
    _ = allocator;
    return switch (status_code) {
        502 => "No app is running on this host (dev server returned 502).",
        else => "App returned an error while loading components.",
    };
}

pub fn setSearch(value: ?[]const u8) void {
    data.adopt(&inputvalue_owned, &inputvalue, value, "");
}

pub fn setStateFilter(value: ?[]const u8) void {
    data.adopt(&stateFilter_owned, &stateFilter, value, "");
}

pub fn setSelected(value: ?[]const u8) void {
    data.adopt(&selected_component_owned, &selected_component, value, "");
}

pub fn toggleTreeCollapsed() void {
    data.tree_collapsed = !data.tree_collapsed;
    data.saveSettings();
}
