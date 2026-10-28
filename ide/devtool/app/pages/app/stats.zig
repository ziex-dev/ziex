const std = @import("std");
const zx = @import("zx");
const api = @import("../api.zig");
const data = @import("../data.zig");
const connection = @import("../connection.zig");

pub var component_count: usize = 0;
pub var route_count: usize = 0;

pub var outer_port: u16 = 0;
pub var inner_port: u16 = 0;
pub var install_prefix: []const u8 = "";
pub var exe_path: []const u8 = "";
pub var injection_count: usize = 0;
pub var injections_label: []const u8 = "";
pub var app_version: []const u8 = "";

var install_prefix_owned: ?[]const u8 = null;
var exe_path_owned: ?[]const u8 = null;
var injections_label_owned: ?[]const u8 = null;
var app_version_owned: ?[]const u8 = null;

var components_fetch_started = false;
var app_info_fetch_started = false;
var runtime_info_fetch_started = false;
var data_allocator: ?std.mem.Allocator = null;

const DevAppInfo = struct {
    outer_port: u16 = 0,
    inner_port: u16 = 0,
    install_prefix: []const u8 = "",
    exe_path: ?[]const u8 = null,
    route_count: usize = 0,
    injection_count: usize = 0,
    injections: []const []const u8 = &.{},
};

const RuntimeInfo = struct {
    version: []const u8 = "",
    route_count: usize = 0,
    address: ?[]const u8 = null,
    port: ?u16 = null,
    workers: ?u16 = null,
    thread_pool: ?u16 = null,
};

pub fn invalidate() void {
    components_fetch_started = false;
    app_info_fetch_started = false;
    runtime_info_fetch_started = false;
    component_count = 0;
    route_count = 0;
    outer_port = 0;
    inner_port = 0;
    injection_count = 0;
    adopt(&install_prefix_owned, &install_prefix, null);
    adopt(&exe_path_owned, &exe_path, null);
    adopt(&injections_label_owned, &injections_label, null);
    adopt(&app_version_owned, &app_version, null);
}

fn adopt(owned: *?[]const u8, view: *[]const u8, value: ?[]const u8) void {
    if (owned.*) |prev| zx.allocator.free(prev);
    owned.* = null;
    view.* = "";
    if (value) |v| {
        if (v.len == 0) return;
        const dup = zx.allocator.dupe(u8, v) catch return;
        owned.* = dup;
        view.* = dup;
    }
}

pub fn ensureCountsFetch(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (!data.loadSettings()) return;
    _ = connection.applyUrlConfig(allocator);
    data_allocator = allocator;
    fetchComponentsCount(allocator);
    fetchAppInfo(allocator);
    fetchRuntimeInfo(allocator);
}

fn fetchComponentsCount(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (components_fetch_started) return;
    const url = api.componentsUrl(allocator, .{ .include_native = false }) orelse return;
    components_fetch_started = true;
    connection.markLoading();
    var client: zx.http.Client = .{ .io = zx.Io.default(), .allocator = allocator };
    client.fetchThen(.{ .url = url }, {}, onFetchComponentsCount);
}

fn fetchAppInfo(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (app_info_fetch_started) return;
    const url = api.appInfoUrl(allocator) orelse return;
    app_info_fetch_started = true;
    var client: zx.http.Client = .{ .io = zx.Io.default(), .allocator = allocator };
    client.fetchThen(.{ .url = url }, {}, onFetchAppInfo);
}

fn fetchRuntimeInfo(allocator: std.mem.Allocator) void {
    if (comptime zx.platform.isServer()) return;
    if (runtime_info_fetch_started) return;
    const url = api.runtimeInfoUrl(allocator) orelse return;
    runtime_info_fetch_started = true;
    var client: zx.http.Client = .{ .io = zx.Io.default(), .allocator = allocator };
    client.fetchThen(.{ .url = url }, {}, onFetchRuntimeInfo);
}

fn onFetchComponentsCount(_: void, result: zx.http.Client.Error!zx.http.Client.Result) void {
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
        "App returned an error while loading components.");
    if (r.body.len == 0) return connection.markUnavailable("Empty response from the app.");

    const parsed = zx.util.zxon.parse(zx.util.devtool.ComponentSerializable, allocator, r.body, .{}) catch
        return connection.markUnavailable("App responded, but the component payload was invalid.");
    component_count = api.countSerializable(&parsed, 0);
    connection.markConnected();
}

fn onFetchAppInfo(_: void, result: zx.http.Client.Error!zx.http.Client.Result) void {
    defer zx.client.rerender();
    const r = result catch return;
    if (@backingInt(r.status) >= 400) return;

    const parsed = r.json(DevAppInfo, zx.allocator) catch return;
    defer parsed.deinit();
    const info = parsed.value;
    outer_port = info.outer_port;
    inner_port = info.inner_port;
    route_count = info.route_count;
    injection_count = info.injection_count;
    adopt(&install_prefix_owned, &install_prefix, info.install_prefix);
    adopt(&exe_path_owned, &exe_path, info.exe_path);
    if (info.injections.len > 0) {
        const joined = std.mem.join(zx.allocator, ", ", info.injections) catch null;
        if (joined) |label| {
            if (injections_label_owned) |prev| zx.allocator.free(prev);
            injections_label_owned = label;
            injections_label = label;
        }
    } else {
        adopt(&injections_label_owned, &injections_label, null);
    }
}

fn onFetchRuntimeInfo(_: void, result: zx.http.Client.Error!zx.http.Client.Result) void {
    defer zx.client.rerender();
    const allocator = data_allocator orelse return;
    const r = result catch return;
    if (@backingInt(r.status) >= 400) return;

    const parsed = zx.util.zxon.parse(RuntimeInfo, allocator, r.body, .{}) catch return;
    adopt(&app_version_owned, &app_version, parsed.version);
    if (parsed.route_count > 0) route_count = parsed.route_count;
    if (!connection.isUnavailable()) connection.markConnected();
}

pub fn componentCountLabel(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{component_count}) catch "0";
}

pub fn routeCountLabel(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{route_count}) catch "0";
}

pub fn injectionCountLabel(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{injection_count}) catch "0";
}

pub fn portLabel(allocator: std.mem.Allocator, port: u16) []const u8 {
    if (port == 0) return "—";
    return std.fmt.allocPrint(allocator, "{d}", .{port}) catch "—";
}

pub fn displayOrDash(value: []const u8) []const u8 {
    return if (value.len == 0) "—" else value;
}
