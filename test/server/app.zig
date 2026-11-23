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
    .{ .path = "/slow", .route = @import("routes/slow.zig") },
    .{ .path = "/ai/openai/chat/completions", .route = @import("routes/ai/openai_chat.zig") },
    .{ .path = "/ai/openai/images/generations", .route = @import("routes/ai/openai_images.zig") },
    .{ .path = "/ai/anthropic/messages", .route = @import("routes/ai/anthropic_messages.zig") },
    .{ .path = "/ai/limited/chat/completions", .route = @import("routes/ai/limited.zig") },
    .{ .path = "/flag/ofrep/ofrep/v1/evaluate/flags/:key", .route = @import("routes/flag/ofrep.zig") },
    .{ .path = "/flag/flagship/accounts/:account/flagship/apps/:app/evaluate", .route = @import("routes/flag/flagship.zig") },
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
    @"/slow",
    @"/ai/openai/chat/completions",
    @"/ai/openai/images/generations",
    @"/ai/anthropic/messages",
    @"/ai/limited/chat/completions",
    @"/flag/ofrep/ofrep/v1/evaluate/flags/:key",
    @"/flag/flagship/accounts/:account/flagship/apps/:app/evaluate",
    @"/events",
    @"/events/other",
    @"/actions",
};

pub const components = [_]zx.client.ComponentMeta{};
