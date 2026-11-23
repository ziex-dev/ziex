const std = @import("std");
const zx = @import("zx");
pub const shared = @import("shared.zig");

// Registers a handler declared in a plain .zig file.
pub const onShared = shared.onShared;

pub const src = struct {
    pub const ping = pingSrc();
    pub const inc = incSrc();
    pub const dec = decSrc();
    pub const label = labelSrc();

    fn pingSrc() std.builtin.SourceLocation {
        return @src();
    }
    fn incSrc() std.builtin.SourceLocation {
        return @src();
    }
    fn decSrc() std.builtin.SourceLocation {
        return @src();
    }
    fn labelSrc() std.builtin.SourceLocation {
        return @src();
    }
};

/// Observed handler invocations, reset by tests between cases.
pub const calls = struct {
    pub var ping: u32 = 0;
    pub var inc: u32 = 0;
    pub var dec: u32 = 0;
    pub var label: u32 = 0;
    pub var last_value_buf: [256]u8 = undefined;
    pub var last_value_len: ?usize = null;

    pub fn reset() void {
        ping = 0;
        inc = 0;
        dec = 0;
        label = 0;
        last_value_len = null;
    }

    pub fn lastValue() ?[]const u8 {
        const len = last_value_len orelse return null;
        return last_value_buf[0..len];
    }

    fn recordValue(value: ?[]const u8) void {
        const v = value orelse {
            last_value_len = null;
            return;
        };
        const len = @min(v.len, last_value_buf.len);
        @memcpy(last_value_buf[0..len], v[0..len]);
        last_value_len = len;
    }
};

pub fn Page(ctx: zx.PageContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.arena, .{ .src = @src() });
    return _zx.ele(.main, .{
        .allocator = ctx.arena,
        .children = _zx.chs(.{
            _zx.cmp(Ping, .{ .src = @src() }, .{ .name = "Ping" }, .{}),
            _zx.cmp(Counter, .{ .src = @src() }, .{ .name = "Counter" }, .{}),
            _zx.cmp(Shared, .{ .src = @src() }, .{ .name = "Shared" }, .{}),
        }),
    });
}

pub fn Ping(ctx: *zx.ComponentContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.button, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(src.ping, "onclick", ctx.bind(onPing)),
        }),
        .children = _zx.chs(.{_zx.txt("Ping")}),
    });
}

pub fn Shared(ctx: *zx.ComponentContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.button, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(@src(), "onclick", ctx.bind(shared.onShared)),
        }),
        .children = _zx.chs(.{_zx.txt("Shared")}),
    });
}

pub fn Counter(ctx: *zx.ComponentContext) zx.Component {
    const count = ctx.state(i32, 0);
    const text = ctx.state([]const u8, "initial");
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.div, .{
        .allocator = ctx.allocator,
        .children = _zx.chs(.{
            _zx.ele(.button, .{
                .attributes = _zx.attrs(.{
                    _zx.attr(src.inc, "onclick", ctx.bind(onInc)),
                }),
                .children = _zx.chs(.{ _zx.txt("+ "), _zx.expr(count) }),
            }),
            _zx.ele(.button, .{
                .attributes = _zx.attrs(.{
                    _zx.attr(src.dec, "onclick", ctx.bind(onDec)),
                }),
                .children = _zx.chs(.{_zx.txt("-")}),
            }),
            _zx.ele(.input, .{
                .attributes = _zx.attrs(.{
                    _zx.attr(src.label, "oninput", ctx.bind(onLabel)),
                }),
            }),
            _zx.ele(.span, .{
                .children = _zx.chs(.{_zx.expr(text)}),
            }),
        }),
    });
}

pub fn onPing(e: *zx.server.Event) void {
    calls.ping += 1;
    calls.recordValue(e.value());
}

pub fn onInc(e: *zx.server.Event.Stateful) void {
    calls.inc += 1;
    const c = e.state(i32);
    c.set(c.get() + 1);
}

pub fn onDec(e: *zx.server.Event.Stateful) void {
    calls.dec += 1;
    const c = e.state(i32);
    c.set(c.get() - 1);
}

/// Leaves the first state untouched and writes the event value into the second.
pub fn onLabel(e: *zx.server.Event.Stateful) void {
    calls.label += 1;
    calls.recordValue(e.value());
    _ = e.state(i32);
    e.state([]const u8).set(e.value() orelse "");
}

pub const options: zx.PageOptions = .{
    .methods = &.{ .GET, .POST },
};
