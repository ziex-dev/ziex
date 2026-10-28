const std = @import("std");

const zx = @import("../../../../root.zig");
const AppConfig = @import("../Config.zig");
const server_meta = @import("../../../server/Server.zig");

pub const header_mode = "x-zx-devtool";
pub const header_include_native = "x-zx-devtool-include-native";
pub const header_include_props = "x-zx-devtool-include-props";
pub const header_include_attributes = "x-zx-devtool-include-attributes";

pub const cors = .{
    .{ "Access-Control-Allow-Origin", "*" },
    .{ "Access-Control-Allow-Methods", "GET, POST, OPTIONS" },
    .{ "Access-Control-Allow-Headers", "Content-Type, x-zx-devtool, x-zx-devtool-include-native, x-zx-devtool-include-props, x-zx-devtool-include-attributes" },
    .{ "Access-Control-Allow-Private-Network", "true" },
};

/// Result of the early probe (before / instead of normal routing).
pub const Early = enum {
    /// No `x-zx-devtool` header.
    none,
    /// CORS applied; respond empty 200 (OPTIONS).
    empty,
    /// CORS applied; write routes JSON.
    meta,
    /// CORS applied; write info JSON.
    info,
    /// CORS applied; continue page render (e.g. components).
    continue_render,
};

pub fn early(mode: ?[]const u8, is_options: bool) Early {
    if (mode == null) return .none;
    if (is_options) return .empty;
    if (std.mem.eql(u8, mode.?, "meta")) return .meta;
    if (std.mem.eql(u8, mode.?, "info")) return .info;
    return .continue_render;
}

pub fn isComponentsMode(mode: ?[]const u8) bool {
    return mode != null and std.mem.eql(u8, mode.?, "components");
}

pub fn applyCors(http: zx.http.Transport) void {
    inline for (cors) |pair| {
        http.resHeaderSet(pair[0], pair[1]);
    }
}

pub fn componentOptions(http: zx.http.Transport) zx.util.devtool.SerializeOptions {
    const include_native = !std.mem.eql(u8, http.reqHeaderGet(header_include_native) orelse "1", "0");
    const include_props = !std.mem.eql(u8, http.reqHeaderGet(header_include_props) orelse "1", "0");
    const include_attributes = !std.mem.eql(u8, http.reqHeaderGet(header_include_attributes) orelse "1", "0");
    return .{
        .only_components = !include_native,
        .include_props = include_props,
        .include_attributes = include_attributes,
    };
}

pub fn writeMeta(
    allocator: std.mem.Allocator,
    app: *server_meta.ServerApp,
    config: AppConfig.ServerConfig,
    writer: *std.Io.Writer,
) !void {
    const meta_data = try server_meta.SerilizableAppMeta.init(allocator, app, config);
    try meta_data.serializeRoutes(writer);
}

pub fn writeInfo(
    allocator: std.mem.Allocator,
    app: *server_meta.ServerApp,
    config: AppConfig.ServerConfig,
    writer: *std.Io.Writer,
) !void {
    const meta_data = try server_meta.SerilizableAppMeta.init(allocator, app, config);
    try meta_data.serializeInfo(writer);
}

pub fn writeComponents(
    component: zx.Component,
    options: zx.util.devtool.SerializeOptions,
    writer: *std.Io.Writer,
) !void {
    try zx.util.devtool.formatWithOptions(component, writer, options);
}
