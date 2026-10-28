const zx = @import("zx");

pub const pages = struct {
    pub const events = @import("pages/events.zig");
    pub const actions = @import("pages/actions.zig");
};

pub const routes = [_]zx.App.Route{
    .{ .path = "/", .route = @import("routes/root.zig") },
    .{ .path = "/echo", .route = @import("routes/echo.zig") },
    .{ .path = "/headers", .route = @import("routes/headers.zig") },
    .{ .path = "/json", .route = @import("routes/json.zig") },
    .{ .path = "/redirect", .route = @import("routes/redirect.zig") },
    .{ .path = "/events", .page = pages.events },
    .{ .path = "/events/other", .page = pages.events },
    .{ .path = "/actions", .page = pages.actions },
};

pub const RoutePaths = enum {
    @"/",
    @"/echo",
    @"/headers",
    @"/json",
    @"/redirect",
    @"/events",
    @"/events/other",
    @"/actions",
};

pub const components = [_]zx.client.ComponentMeta{};
