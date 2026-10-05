const std = @import("std");
const zx = @import("zx");

const Request = zx.server.Request;
const Response = zx.server.Response;
const PageContext = zx.PageContext;
const LayoutContext = zx.LayoutContext;
const NotFoundContext = zx.NotFoundContext;
const ErrorContext = zx.ErrorContext;
const ServerApp = zx.server.App;
const tryExtractParams = zx.Router.tryExtractParams;
const patternMatchScore = zx.Router.patternMatchScore;
const RouteMatch = zx.Router.RouteMatch;

const AppCtx = struct { port: u16 };
const StateCtx = struct { count: i32 };

var seen_page_app_port: u16 = 0;
var seen_page_state_count: i32 = 0;

var seen_layout_app_port: u16 = 0;
var seen_layout_state_count: i32 = 0;

const PageModule = struct {
    pub fn Page(ctx: zx.PageContext, app: AppCtx, state: StateCtx) zx.Component {
        _ = ctx;
        seen_page_app_port = app.port;
        seen_page_state_count = state.count;
        return .{ .text = "ok" };
    }
};

const LayoutModule = struct {
    pub fn Layout(ctx: zx.LayoutContext, child: zx.Component, app: AppCtx, state: StateCtx) zx.Component {
        _ = ctx;
        seen_layout_app_port = app.port;
        seen_layout_state_count = state.count;
        return child;
    }
};

const OptionalPageModule = struct {
    pub var saw_null: bool = false;

    pub fn Page(ctx: zx.PageContext, app: ?*const AppCtx) zx.Component {
        _ = ctx;
        saw_null = (app == null);
        return .{ .text = "ok" };
    }
};

fn makeReqRes(alloc: std.mem.Allocator) struct { req: Request, res: Response } {
    const req = Request.init(.{ .url = "/", .arena = alloc });
    const res = Response.init(.{ .arena = alloc });
    return .{ .req = req, .res = res };
}

// --- Context Type Aliases --- //

test "PageContext: is same as LayoutContext" {
    try std.testing.expect(PageContext == LayoutContext);
}

test "PageContext: is same as NotFoundContext" {
    try std.testing.expect(PageContext == NotFoundContext);
}

// --- PageContext --- //

test "PageContext: has request field" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{
        .url = "/test",
        .method = .POST,
        .arena = alloc,
    });

    const res = Response.init(.{
        .status = 200,
        .arena = alloc,
    });

    const ctx = PageContext.init(req, res, alloc, std.testing.io);

    try std.testing.expectEqualStrings("/test", ctx.request.url);
    try std.testing.expectEqual(Request.Method.POST, ctx.request.method);
}

test "PageContext: has response field" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{ .arena = alloc });
    const res = Response.init(.{
        .status = 201,
        .arena = alloc,
    });

    const ctx = PageContext.init(req, res, alloc, std.testing.io);

    try std.testing.expectEqual(@as(u16, 201), ctx.response.status);
    try std.testing.expect(ctx.response.ok);
    try std.testing.expectEqualStrings("Created", ctx.response.statusText);
}

test "PageContext: has allocator and arena fields" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{ .arena = alloc });
    const res = Response.init(.{ .arena = alloc });
    const ctx = PageContext.init(req, res, alloc, std.testing.io);

    // Verify fields are accessible
    _ = ctx.allocator;
    _ = ctx.arena;
    _ = ctx.io;
    _ = ctx.data;
}

test "PageData: get returns null when unset" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const data = zx.PageData.init(alloc);
    try std.testing.expect(data.get("title") == null);
}

test "PageData: set then get round-trips and overwrites" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const data = zx.PageData.init(alloc);
    data.set("title", "Hello");
    try std.testing.expectEqualStrings("Hello", data.get("title").?);

    data.set("title", "World");
    try std.testing.expectEqualStrings("World", data.get("title").?);
}

test "PageData: shared store visible across page and layout contexts" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const rr = makeReqRes(alloc);
    const page_ctx = PageContext.init(rr.req, rr.res, alloc, std.testing.io);
    const layout_ctx: LayoutContext = page_ctx;

    page_ctx.data.set("title", "From page");
    page_ctx.data.set("description", "Meta");

    try std.testing.expectEqualStrings("From page", layout_ctx.data.get("title").?);
    try std.testing.expectEqualStrings("Meta", layout_ctx.data.get("description").?);
}

test "PageData: separate init contexts do not share" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const rr = makeReqRes(alloc);
    const a = PageContext.init(rr.req, rr.res, alloc, std.testing.io);
    const b = PageContext.init(rr.req, rr.res, alloc, std.testing.io);

    a.data.set("title", "only-a");
    try std.testing.expect(b.data.get("title") == null);
}

// --- ErrorContext --- //

test "ErrorContext: has error field" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{ .arena = alloc });
    const res = Response.init(.{ .arena = alloc });
    const err = error.OutOfMemory;

    const ctx = ErrorContext.init(req, res, alloc, std.testing.io, err);

    try std.testing.expectEqual(error.OutOfMemory, ctx.err);
}

test "ErrorContext: has request and response fields" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{
        .url = "/error-page",
        .arena = alloc,
    });

    const res = Response.init(.{
        .status = 500,
        .arena = alloc,
    });

    const ctx = ErrorContext.init(req, res, alloc, std.testing.io, error.Unexpected);

    try std.testing.expectEqualStrings("/error-page", ctx.request.url);
    try std.testing.expectEqual(@as(u16, 500), ctx.response.status);
}

test "ErrorContext: has allocator and arena fields" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const req = Request.init(.{ .arena = alloc });
    const res = Response.init(.{ .arena = alloc });
    const ctx = ErrorContext.init(req, res, alloc, std.testing.io, error.Unexpected);

    _ = ctx.allocator;
    _ = ctx.arena;
    _ = ctx.io;
}

test "ServerMeta.page injects app/state positional values" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const rr = makeReqRes(alloc);
    const page_fn = ServerApp.page(PageModule);
    const ctx = zx.PageContext.init(rr.req, rr.res, alloc, std.testing.io);

    var app = AppCtx{ .port = 5588 };
    var state = StateCtx{ .count = 42 };

    _ = try page_fn(ctx, @ptrCast(&app), @ptrCast(&state));

    try std.testing.expectEqual(@as(u16, 5588), seen_page_app_port);
    try std.testing.expectEqual(@as(i32, 42), seen_page_state_count);
}

test "ServerMeta.layout injects app/state positional values" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const rr = makeReqRes(alloc);
    const layout_fn = ServerApp.layout(LayoutModule);
    const ctx = zx.LayoutContext.init(rr.req, rr.res, alloc, std.testing.io);

    var app = AppCtx{ .port = 9000 };
    var state = StateCtx{ .count = 7 };
    const child = zx.Component{ .text = "child" };

    const out = layout_fn(ctx, child, @ptrCast(&app), @ptrCast(&state));
    _ = out;

    try std.testing.expectEqual(@as(u16, 9000), seen_layout_app_port);
    try std.testing.expectEqual(@as(i32, 7), seen_layout_state_count);
}

test "ServerMeta.page injects null for optional app parameter" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    OptionalPageModule.saw_null = false;

    const rr = makeReqRes(alloc);
    const page_fn = ServerApp.page(OptionalPageModule);
    const ctx = zx.PageContext.init(rr.req, rr.res, alloc, std.testing.io);

    _ = try page_fn(ctx, null, null);

    try std.testing.expect(OptionalPageModule.saw_null);
}

test "tryExtractParams: glob_all catch-all matches nested paths" {
    var m = RouteMatch{ .route = undefined };
    try std.testing.expect(tryExtractParams("/:*", "/anything/everything", &m));
    try std.testing.expectEqual(@as(usize, 1), m.param_count);
    try std.testing.expectEqualStrings("anything", m.getParam("*").?);
}

test "tryExtractParams: glob_all catch-all matches single segment" {
    var m = RouteMatch{ .route = undefined };
    try std.testing.expect(tryExtractParams("/:*", "/anything", &m));
    try std.testing.expectEqualStrings("anything", m.getParam("*").?);
}

test "tryExtractParams: static route does not match extra segments" {
    var m = RouteMatch{ .route = undefined };
    try std.testing.expect(!tryExtractParams("/search.json", "/search.json/extra", &m));
}

test "tryExtractParams: static route matches exactly" {
    var m = RouteMatch{ .route = undefined };
    try std.testing.expect(tryExtractParams("/search.json", "/search.json", &m));
}

test "patternMatchScore: static routes outrank catch-all params" {
    try std.testing.expect(patternMatchScore("/search.json") > patternMatchScore("/:*"));
}

test "patternMatchScore: root route is specific" {
    try std.testing.expect(patternMatchScore("/") > patternMatchScore("/:*"));
}
