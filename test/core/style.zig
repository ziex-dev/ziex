const std = @import("std");
const zx = @import("zx");

const S = zx.Style;

test "formatting" {
    const style: S = .{
        .display = .flex,
        .flex_direction = .column,
        .background_color = .hex(0xff0000),
        .padding_top = .px(10),
        .width = .px(100),
    };

    const result = try std.testing.allocator.print("{f}", .{style});
    defer std.testing.allocator.free(result);

    // std.debug.print("\nGenerated CSS: {s}\n", .{result});

    try std.testing.expect(std.mem.indexOf(u8, result, "display: flex;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "flex-direction: column;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "background-color: #ff0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "padding-top: 10px;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "width: 100px;") != null);
}

test "in component" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var ctx = zx.x.allocInit(arena_allocator, .{});

    const style: S = .{
        .color = .hex(0x0000ff),
        .margin_top = .px(20),
    };

    const comp = ctx.ele(.div, .{
        .attributes = ctx.attrs(.{
            ctx.attr(@src(), "style", style).?,
            ctx.attr(@src(), "class", "my-div").?,
        }),
        .children = ctx.chs(.{
            ctx.txt("Hello with style"),
        }),
    });
    defer comp.deinit(arena_allocator);

    try std.testing.expectEqual(zx.ElementTag.div, comp.element.tag);

    var found_style = false;
    for (comp.element.attributes.?) |attr| {
        if (std.mem.eql(u8, attr.name, "style")) {
            const expected_style = "color: #0000ff; margin-top: 20px; ";
            try std.testing.expectEqualStrings(expected_style, attr.value.?);
            found_style = true;
        }
    }
    try std.testing.expect(found_style);
}

test "pseudo-states" {
    const style: S = .{
        .background_color = .hex(0x0000ff),
        .hover = &S{
            .background_color = .hex(0xff0000),
        },
    };

    const result = try std.testing.allocator.print("{f}", .{style});
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "background-color: #0000ff;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "hover { background-color: #ff0000; }") != null);
}

test "shorthands" {
    const style: S = .{
        .padding = .px2(10, 20),
        .margin = .px4(5, 10, 15, 20),
    };

    const result = try std.testing.allocator.print("{f}", .{style});
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "padding: 10px 20px;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "margin: 5px 10px 15px 20px;") != null);
}

test "viewport units and calc" {
    const Calc = zx.style.Calc;
    const style: S = .{
        .min_height = .vh(60),
        .width = .vw(100),
        .max_width = .calc(Calc.px(960).sub(Calc.px(48))),
    };

    const result = try std.testing.allocator.print("{f}", .{style});
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "min-height: 60vh;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "width: 100vw;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "max-width: calc((960px - 48px));") != null);
}
