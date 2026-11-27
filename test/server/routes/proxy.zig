const std = @import("std");
const zx = @import("zx");

// Each proxy and handler appends a tag to `x-trace`, so tests can read the run order.
fn trace(res: anytype, arena: std.mem.Allocator, tag: []const u8) void {
    const prev = res.headers.get("x-trace") orelse return res.headers.set("x-trace", tag);
    res.headers.set("x-trace", std.mem.concat(arena, u8, &.{ prev, ",", tag }) catch return);
}

pub const State = struct { user: []const u8 };

// /proxy: wraps everything below it.
pub const root = struct {
    pub fn Proxy(ctx: *zx.ProxyContext) !void {
        trace(ctx.response, ctx.arena, "root>");
        if (ctx.request.headers.get("x-fail-before") != null) return error.ProxyFailed;
        ctx.next();
        trace(ctx.response, ctx.arena, "<root");
        // The handler's status is visible after next().
        ctx.response.headers.set("x-seen-status", try ctx.arena.print("{d}", .{ctx.response.status()}));
    }

    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("root");
    }
};

// /proxy/inner: a proxy without next() still continues, and state reaches the handler.
pub const inner = struct {
    pub fn Proxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "inner");
    }

    pub fn RouteProxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "route-proxy");
        ctx.state(State{ .user = "ada" });
    }

    pub fn PageProxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "page-proxy");
    }

    pub fn GET(ctx: zx.RouteContext, _: void, state: ?*const State) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text(if (state) |s| s.user else "none");
    }
};

// /proxy/inner/page: PageProxy of its own route only; ancestors' RouteProxy/PageProxy don't cascade.
pub const page = struct {
    pub fn PageProxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "page-proxy");
        ctx.next();
        ctx.response.headers.set("x-after-page", "1");
    }

    pub fn RouteProxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "route-proxy");
    }

    pub fn Page(ctx: zx.PageContext) zx.Component {
        trace(ctx.response, ctx.arena, "page");
        var _zx = zx.x.allocInit(ctx.arena, .{ .src = @src() });
        return _zx.ele(.p, .{ .allocator = ctx.arena, .children = _zx.chs(.{_zx.txt("proxied page")}) });
    }
};

// /proxy/guard: aborts before the handler unless authorized; the outer proxy still unwinds.
pub const guard = struct {
    pub fn RouteProxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "guard");
        if (ctx.request.headers.get("authorization") == null) {
            ctx.response.setStatus(.forbidden);
            ctx.response.text("blocked");
            return ctx.abort();
        }
    }

    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("allowed");
    }
};

// /proxy/after: rewrites the response after the handler, or replaces it with abort().
pub const after = struct {
    pub fn RouteProxy(ctx: *zx.ProxyContext) void {
        ctx.next();
        ctx.next(); // a second call does nothing
        ctx.response.setStatus(.created);
        ctx.response.headers.set("x-after", "1");
        if (ctx.request.headers.get("x-replace") != null) {
            ctx.response.text("replaced");
            ctx.abort();
        }
    }

    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("original");
    }
};

// /proxy/fail: a failing proxy stops the chain and answers 500.
pub const fail = struct {
    pub fn RouteProxy(_: *zx.ProxyContext) !void {
        return error.ProxyFailed;
    }

    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("unreachable");
    }
};

// /proxy/items/:id and /proxy/items/:id/detail: Proxy in a dynamic segment cascades.
pub const item = struct {
    pub fn Proxy(ctx: *zx.ProxyContext) void {
        trace(ctx.response, ctx.arena, "item");
    }

    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("item");
    }
};

pub const item_detail = struct {
    pub fn GET(ctx: zx.RouteContext) void {
        trace(ctx.response, ctx.arena, "handler");
        ctx.response.text("detail");
    }
};
