const std = @import("std");
const zx = @import("zx");

pub const src = struct {
    pub const profile = profileSrc();
    pub const greet = greetSrc();
    pub const add = addSrc();
    pub const direct = directSrc();

    fn profileSrc() std.lang.SourceLocation {
        return @src();
    }
    fn greetSrc() std.lang.SourceLocation {
        return @src();
    }
    fn addSrc() std.lang.SourceLocation {
        return @src();
    }
    fn directSrc() std.lang.SourceLocation {
        return @src();
    }
};

pub const ProfileInput = struct {
    name: []const u8,
    age: i32,
    subscribe: bool,
    nickname: ?[]const u8,
};

pub const GreetInput = struct { name: []const u8 };
pub const AmountInput = struct { amount: i32 };

/// Observed handler invocations, reset by tests between cases.
pub const calls = struct {
    pub var profile: u32 = 0;
    pub var greet: u32 = 0;
    pub var add: u32 = 0;
    pub var direct: u32 = 0;

    pub var name_buf: [128]u8 = undefined;
    pub var name_len: usize = 0;
    pub var nickname_buf: [128]u8 = undefined;
    pub var nickname_len: ?usize = null;
    pub var age: i32 = 0;
    pub var subscribe: bool = false;

    pub fn reset() void {
        profile = 0;
        greet = 0;
        add = 0;
        direct = 0;
        name_len = 0;
        nickname_len = null;
        age = 0;
        subscribe = false;
    }

    pub fn name() []const u8 {
        return name_buf[0..name_len];
    }

    pub fn nickname() ?[]const u8 {
        const len = nickname_len orelse return null;
        return nickname_buf[0..len];
    }

    fn record(input: ProfileInput) void {
        name_len = @min(input.name.len, name_buf.len);
        @memcpy(name_buf[0..name_len], input.name[0..name_len]);
        age = input.age;
        subscribe = input.subscribe;
        if (input.nickname) |n| {
            const len = @min(n.len, nickname_buf.len);
            @memcpy(nickname_buf[0..len], n[0..len]);
            nickname_len = len;
        } else nickname_len = null;
    }
};

pub fn Page(ctx: zx.PageContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.arena, .{ .src = @src() });
    return _zx.ele(.main, .{
        .allocator = ctx.arena,
        .children = _zx.chs(.{
            _zx.cmp(ProfileForm, .{ .src = @src() }, .{ .name = "ProfileForm" }, .{}),
            _zx.cmp(GreetForm, .{ .src = @src() }, .{ .name = "GreetForm" }, .{}),
            _zx.cmp(AddForm, .{ .src = @src() }, .{ .name = "AddForm" }, .{}),
            _zx.cmp(DirectForm, .{ .src = @src() }, .{ .name = "DirectForm" }, .{}),
        }),
    });
}

pub fn ProfileForm(ctx: *zx.ComponentContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.form, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(src.profile, "action", ctx.bind(onProfile)),
        }),
        .children = _zx.chs(.{
            _zx.ele(.input, .{ .attributes = _zx.attrs(.{_zx.attr(@src(), "name", "name")}) }),
            _zx.ele(.button, .{ .children = _zx.chs(.{_zx.txt("Save")}) }),
        }),
    });
}

pub fn GreetForm(ctx: *zx.ComponentContext) zx.Component {
    const greeting = ctx.state([]const u8, "Please log in");
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.form, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(src.greet, "action", ctx.bind(onGreet)),
        }),
        .children = _zx.chs(.{
            _zx.ele(.p, .{ .children = _zx.chs(.{_zx.expr(greeting)}) }),
            _zx.ele(.input, .{ .attributes = _zx.attrs(.{_zx.attr(@src(), "name", "name")}) }),
        }),
    });
}

pub fn AddForm(ctx: *zx.ComponentContext) zx.Component {
    const total = ctx.state(i32, 0);
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.form, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(src.add, "action", ctx.bind(onAdd)),
        }),
        .children = _zx.chs(.{
            _zx.ele(.output, .{ .children = _zx.chs(.{_zx.expr(total)}) }),
            _zx.ele(.input, .{ .attributes = _zx.attrs(.{_zx.attr(@src(), "name", "amount")}) }),
        }),
    });
}

pub fn DirectForm(ctx: *zx.ComponentContext) zx.Component {
    var _zx = zx.x.allocInit(ctx.allocator, .{ .src = @src() });
    return _zx.ele(.form, .{
        .allocator = ctx.allocator,
        .attributes = _zx.attrs(.{
            _zx.attr(src.direct, "action", onDirect),
        }),
        .children = _zx.chs(.{
            _zx.ele(.input, .{ .attributes = _zx.attrs(.{_zx.attr(@src(), "name", "name")}) }),
        }),
    });
}

pub fn onProfile(ctx: *zx.server.Action) void {
    calls.profile += 1;
    calls.record(ctx.data(ProfileInput));
}

pub fn onGreet(data: GreetInput, sc: *zx.StateContext) void {
    calls.greet += 1;
    sc.state([]const u8).set(sc.fmt("Hello, {s}!", .{data.name}) catch "Err");
}

pub fn onAdd(ctx: *zx.server.Action.Stateful) void {
    calls.add += 1;
    const total = ctx.state(i32);
    total.set(total.get() + ctx.data(AmountInput).amount);
}

pub fn onDirect(data: ProfileInput) void {
    calls.direct += 1;
    calls.record(data);
}

pub const options: zx.PageOptions = .{
    .methods = &.{ .GET, .POST },
};
