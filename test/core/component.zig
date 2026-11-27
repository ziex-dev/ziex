const std = @import("std");
const zx = @import("zx");

const testing = std.testing;
const Component = zx.Component;

const LabelProps = struct {
    label: []const u8 = "Count",
    initial: i32 = 0,
};

fn Alone(allocator: std.mem.Allocator) Component {
    _ = allocator;
    return .{ .text = "alone" };
}

fn WithProps(allocator: std.mem.Allocator, p: LabelProps) Component {
    _ = allocator;
    return .{ .text = p.label };
}

fn WithCtx(ctx: *zx.ComponentCtx(LabelProps)) Component {
    return .{ .text = ctx.props.label };
}

test "fn > allocator-only call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fn_comp = Component.ComponentFn.init(Alone, "Alone", a, .{});
    try testing.expect(!fn_comp.isIsland());
    const out = try fn_comp.call();
    try testing.expectEqualStrings("alone", out.text);
}

test "fn > props call uses coerced defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fn_comp = Component.ComponentFn.init(WithProps, "WithProps", a, .{ .initial = 9 });
    const out = try fn_comp.call();
    try testing.expectEqualStrings("Count", out.text);
}

test "fn > contexted call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fn_comp = Component.ComponentFn.init(WithCtx, "WithCtx", a, .{ .label = "ctx-label" });
    const out = try fn_comp.callOwned("owner-1");
    try testing.expectEqualStrings("ctx-label", out.text);

    // Owner id is stamped onto the ctx before invoke.
    const ctx: *zx.ComponentCtx(LabelProps) = @ptrCast(@alignCast(@constCast(fn_comp.data.?)));
    try testing.expectEqualStrings("owner-1", ctx._internal.component_id);
}

test "island > cmp builds hydrate_id + zxon props, ssr runs at render" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var zx_ctx = zx.x.allocInit(a, .{});
    const island = zx_ctx.cmp(
        WithCtx,
        .{},
        .{ .name = "WithCtx", .client = .{ .name = "WithCtx", .id = "hid123" } },
        .{ .label = "Main Counter", .initial = 5 },
    );

    try testing.expect(island == .component_fn);
    const cf = island.component_fn;
    try testing.expect(cf.isIsland());
    try testing.expectEqualStrings("hid123", cf.island.?.id);
    try testing.expectEqualStrings("WithCtx", cf.name);
    try testing.expectEqualStrings("[\"Main Counter\",5]", cf.island.?.props.?);

    var aw = std.Io.Writer.Allocating.init(a);
    try Component.render(island, &aw.writer, .{ .io = std.testing.io });
    try testing.expectEqualStrings("<!--$hid123 [\"Main Counter\",5]-->Main Counter<!--/$hid123-->", aw.written());
}

test "island > render emits comment markers and ssr body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var zx_ctx = zx.x.allocInit(a, .{});
    const island = zx_ctx.cmp(
        WithProps,
        .{},
        .{ .name = "WithProps", .client = .{ .name = "WithProps", .id = "abc" } },
        .{ .label = "Hi", .initial = 2 },
    );

    var aw = std.Io.Writer.Allocating.init(a);
    try Component.render(island, &aw.writer, .{});
    try testing.expectEqualStrings("<!--$abc [\"Hi\",2]-->Hi<!--/$abc-->", aw.written());
}

test "island > empty props omits zxon payload in marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var zx_ctx = zx.x.allocInit(a, .{});
    const island = zx_ctx.cmp(
        Alone,
        .{},
        .{ .name = "Alone", .client = .{ .name = "Alone", .id = "z" } },
        .{},
    );

    try testing.expect(island.component_fn.island.?.props == null);

    var aw = std.Io.Writer.Allocating.init(a);
    try Component.render(island, &aw.writer, .{});
    try testing.expectEqualStrings("<!--$z-->alone<!--/$z-->", aw.written());
}

test "plain > not an island" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var zx_ctx = zx.x.allocInit(a, .{});
    const comp = zx_ctx.cmp(Alone, .{}, .{ .name = "Alone" }, .{});
    try testing.expect(comp == .component_fn);
    try testing.expect(!comp.component_fn.isIsland());
}

test "devtool > serialize includes props via dump_props" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var zx_ctx = zx.x.allocInit(a, .{});
    const comp = zx_ctx.cmp(
        WithCtx,
        .{},
        .{ .name = "WithCtx" },
        .{ .label = "Hello", .initial = 42 },
    );

    var aw = std.Io.Writer.Allocating.init(a);
    try zx.util.devtool.formatWithOptions(comp, &aw.writer, .{});
    const out = aw.written();
    try testing.expect(std.mem.find(u8, out, "WithCtx") != null);
    try testing.expect(std.mem.find(u8, out, "Hello") != null);
    try testing.expect(std.mem.find(u8, out, "42") != null);
    try testing.expect(std.mem.find(u8, out, "label") != null);
}

test "fn > dump_props returns json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fn_comp = Component.ComponentFn.init(WithCtx, "WithCtx", a, .{ .label = "Hello", .initial = 42 });
    const json = fn_comp.dev.dump_props(a, fn_comp.data).?;
    try testing.expect(std.mem.find(u8, json, "Hello") != null);
    try testing.expect(std.mem.find(u8, json, "42") != null);
    try testing.expect(std.mem.find(u8, json, "label") != null);
}
