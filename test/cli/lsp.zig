const std = @import("std");
const testing = std.testing;
const lang = @import("lang");
const html = @import("html_hover");
const html_hover = html.hover;
const html_complete = html.complete;

fn offsetOf(src: []const u8, needle: []const u8, into: u32) u32 {
    const idx = std.mem.indexOf(u8, src, needle).?;
    return @intCast(idx + into);
}

test "hover > element tag name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div class="x">hi</div>);
        \\}
    ;
    // Point at the "div" in the start tag.
    const off = offsetOf(src, "<div", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "<div>") != null);
    try testing.expect(std.mem.indexOf(u8, md, "no special meaning") != null);
    try testing.expect(std.mem.indexOf(u8, md, "MDN Reference") != null);
}

test "hover > global attribute name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div class="x">hi</div>);
        \\}
    ;
    const off = offsetOf(src, "class=", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "class") != null);
    try testing.expect(std.mem.indexOf(u8, md, "space-separated list of the classes") != null);
}

test "hover > element-specific attribute name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<a href="/x">link</a>);
        \\}
    ;
    const off = offsetOf(src, "href=", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "href") != null);
    try testing.expect(std.mem.indexOf(u8, md, "hyperlink points to") != null);
    // The enclosing tag should be reflected.
    try testing.expect(std.mem.indexOf(u8, md, "<a>") != null);
}

test "hover > unknown element returns null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<Foo />);
        \\}
    ;
    const off = offsetOf(src, "<Foo", 1);
    try testing.expect((try html_hover.hoverMarkdown(arena, src, off)) == null);
}

test "hover > cursor outside tag returns null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div>hi</div>);
        \\}
    ;
    const off = offsetOf(src, "Page", 1);
    try testing.expect((try html_hover.hoverMarkdown(arena, src, off)) == null);
}

test "hover > void element self-closing tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><br /></div>);
        \\}
    ;
    const off = offsetOf(src, "<br", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "<br>") != null);
}

test "hover > builtin attribute @allocator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a}>hi</div>);
        \\}
    ;
    const off = offsetOf(src, "@allocator", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "@allocator") != null);
    try testing.expect(std.mem.indexOf(u8, md, "builtin") != null);
}

test "hover > builtin shorthand @{allocator}" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<div @{allocator}>hi</div>);
        \\}
    ;
    const off = offsetOf(src, "@{allocator}", 2);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "@allocator") != null);
}

test "hover > attribute shorthand {class}" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div {class}>hi</div>);
        \\}
    ;
    const off = offsetOf(src, "{class}", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "class") != null);
}

test "completion > tag name after <" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<di
    ;
    const off: u32 = @intCast(src.len);
    const result = (try html_complete.complete(arena, src, off)) orelse return error.NoCompletion;
    const items = switch (result) {
        .completion_list => |list| list.items,
        .completion_items => |items| items,
    };
    var found_div = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "div")) found_div = true;
    }
    try testing.expect(found_div);
}

test "completion > builtin attribute after @" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @
    ;
    const off: u32 = @intCast(src.len);
    const result = (try html_complete.complete(arena, src, off)) orelse return error.NoCompletion;
    const items = switch (result) {
        .completion_list => |list| list.items,
        .completion_items => |items| items,
    };
    var found_allocator = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "@allocator")) found_allocator = true;
    }
    try testing.expect(found_allocator);
}

test "completion > outside zx block returns null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    const x = a < b;
    ;
    const off = offsetOf(src, "a < b", 2);
    try testing.expect((try html_complete.complete(arena, src, off)) == null);
}

test "completion > tag snippet wraps with end tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<di
    ;
    const off: u32 = @intCast(src.len);
    const result = (try html_complete.complete(arena, src, off)) orelse return error.NoCompletion;
    const items = switch (result) {
        .completion_list => |list| list.items,
        .completion_items => |items| items,
    };
    var found = false;
    for (items) |item| {
        if (!std.mem.eql(u8, item.label, "div")) continue;
        try testing.expect(item.insertTextFormat == .Snippet);
        try testing.expectEqualStrings("div>$0</div>", item.insertText.?);
        found = true;
    }
    try testing.expect(found);
}

test "completion > void tag completes without end tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<br
    ;
    const off: u32 = @intCast(src.len);
    const result = (try html_complete.complete(arena, src, off)) orelse return error.NoCompletion;
    const items = switch (result) {
        .completion_list => |list| list.items,
        .completion_items => |items| items,
    };
    var found = false;
    for (items) |item| {
        if (!std.mem.eql(u8, item.label, "br")) continue;
        try testing.expectEqualStrings("br />", item.insertText.?);
        found = true;
    }
    try testing.expect(found);
}

test "hover > custom component does not use HTML element docs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<Button>hi</Button>);
        \\}
    ;
    const off = offsetOf(src, "<Button", 1);
    try testing.expect((try html_hover.hoverMarkdown(arena, src, off)) == null);
}

test "completion > custom component does not suggest HTML attributes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<Button 
    ;
    const off: u32 = @intCast(src.len);
    const result = try html_complete.complete(arena, src, off);
    if (result) |r| {
        const items = switch (r) {
            .completion_list => |list| list.items,
            .completion_items => |items| items,
        };
        for (items) |item| {
            // Builtins (@…) are fine; plain HTML attrs are not.
            try testing.expect(item.label.len > 0 and item.label[0] == '@');
        }
    }
}

test "hover > lowercase button still shows HTML docs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<button>hi</button>);
        \\}
    ;
    const off = offsetOf(src, "<button", 1);
    const md = (try html_hover.hoverMarkdown(arena, src, off)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, md, "<button>") != null);
}

fn completionLabels(arena: std.mem.Allocator, src: []const u8, offset: u32) ![]const []const u8 {
    const result = (try html_complete.complete(arena, src, offset)) orelse return &.{};
    const items = switch (result) {
        .completion_list => |list| list.items,
        .completion_items => |items| items,
    };
    const labels = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, i| labels[i] = item.label;
    return labels;
}

fn hasLabel(labels: []const []const u8, want: []const u8) bool {
    for (labels) |label| {
        if (std.mem.eql(u8, label, want)) return true;
    }
    return false;
}

test "completion > tag name after element text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hello <b
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "b"));
    try testing.expect(hasLabel(labels, "br"));
}

test "completion > tag name after expression block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>{name} <str
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "strong"));
}

test "completion > bare < after element text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hello <
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "span"));
}

test "completion > attribute after element text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hello <a hr
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "href"));
    try testing.expect(hasLabel(labels, "hreflang"));
}

test "completion > builtin attribute after element text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hello <Counter @rend
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "@rendering"));
}

test "completion > closing tag after element text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hello </
    ;
    const labels = try completionLabels(arena, src, @intCast(src.len));
    try testing.expect(hasLabel(labels, "p"));
}

test "completion > zig less-than after markup stays null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A `<` used as a comparison must not be mistaken for a tag, even in a file
    // that also contains ZX markup.
    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>hi</p>);
        \\}
        \\
        \\fn lt(x: usize, y: usize) bool {
        \\    return x <y
    ;
    try testing.expect((try html_complete.complete(arena, src, @intCast(src.len))) == null);
}

test "completion > zig less-than inside expression block stays null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>{if (x <y
    ;
    try testing.expect((try html_complete.complete(arena, src, @intCast(src.len))) == null);
}

const lsp_text = html.text;

test "text > positionToOffset counts utf-16 code units" {
    // `é` is two bytes but one utf-16 code unit, so the byte offset of the
    // character after "Café" is 5 while its utf-16 column is 4.
    const src = "Café x\nsecond\n";

    try testing.expectEqual(
        @as(usize, 5),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 4 }, .@"utf-16"),
    );
    try testing.expectEqual(
        @as(usize, 4),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 4 }, .@"utf-8"),
    );
    try testing.expectEqual(
        @as(usize, 5),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 4 }, .@"utf-32"),
    );
}

test "text > positionToOffset handles surrogate pairs" {
    // `🠁` is four bytes and two utf-16 code units.
    const src = "a🠁b\n";

    try testing.expectEqual(
        @as(usize, 5),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 3 }, .@"utf-16"),
    );
    try testing.expectEqual(
        @as(usize, 5),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 2 }, .@"utf-32"),
    );
}

test "text > positionToOffset clamps to the end of the line" {
    const src = "ab\ncdef\n";

    // A column past the end of line 0 must not spill into line 1.
    try testing.expectEqual(
        @as(usize, 2),
        lsp_text.positionToOffset(src, .{ .line = 0, .character = 40 }, .@"utf-16"),
    );
    try testing.expectEqual(
        @as(usize, 3),
        lsp_text.positionToOffset(src, .{ .line = 1, .character = 0 }, .@"utf-16"),
    );
}

test "text > offsetToPosition counts utf-16 code units" {
    const src = "Café x\nsecond\n";

    const pos = lsp_text.offsetToPosition(src, 5, .@"utf-16");
    try testing.expectEqual(@as(u32, 0), pos.line);
    try testing.expectEqual(@as(u32, 4), pos.character);

    const bytes = lsp_text.offsetToPosition(src, 5, .@"utf-8");
    try testing.expectEqual(@as(u32, 5), bytes.character);

    // Byte 7 is the newline that ends line 0; line 1 starts at byte 8.
    const eol = lsp_text.offsetToPosition(src, 7, .@"utf-16");
    try testing.expectEqual(@as(u32, 0), eol.line);
    try testing.expectEqual(@as(u32, 6), eol.character);

    const second = lsp_text.offsetToPosition(src, 8, .@"utf-16");
    try testing.expectEqual(@as(u32, 1), second.line);
    try testing.expectEqual(@as(u32, 0), second.character);
}

test "text > offsetToPosition roundtrips through positionToOffset" {
    const src = "<p>Café ↉ x</p>\n<b>🠁</b>\n";

    var offset: usize = 0;
    while (offset <= src.len) : (offset += 1) {
        // Only round-trip codepoint boundaries.
        if (offset < src.len and src[offset] & 0xC0 == 0x80) continue;
        const pos = lsp_text.offsetToPosition(src, offset, .@"utf-16");
        try testing.expectEqual(offset, lsp_text.positionToOffset(src, pos, .@"utf-16"));
    }
}

test "text > byteColumnToPosition counts utf-16 code units" {
    const src = "a🠁b\nCafé x\n";

    const pos = lsp_text.byteColumnToPosition(src, 1, 5, .@"utf-16");
    try testing.expectEqual(@as(u32, 1), pos.line);
    try testing.expectEqual(@as(u32, 4), pos.character);

    try testing.expectEqual(@as(u32, 3), lsp_text.byteColumnToPosition(src, 0, 5, .@"utf-16").character);
    try testing.expectEqual(@as(u32, 2), lsp_text.byteColumnToPosition(src, 0, 5, .@"utf-32").character);
    try testing.expectEqual(@as(u32, 5), lsp_text.byteColumnToPosition(src, 0, 5, .@"utf-8").character);
}

test "text > diagnostic columns are re-encoded" {
    const allocator = testing.allocator;

    const src: [:0]const u8 =
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<p @allocator={a}>Café <blnk>x</blnk></p>);
        \\}
    ;
    var result = try lang.Ast.parse(allocator, src, .{});
    defer result.deinit(allocator);

    try testing.expect(result.diagnostics.items.len > 0);
    const d = result.diagnostics.items[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "blnk") != null);

    // tree-sitter columns count bytes; `é` makes them one ahead of utf-16.
    const tag_col: u32 = @intCast(std.mem.indexOf(u8, src, "blnk").? - (std.mem.indexOf(u8, src, "\n").? + 1));
    try testing.expectEqual(tag_col, d.start_column);

    const start = lsp_text.byteColumnToPosition(src, d.start_line, d.start_column, .@"utf-16");
    const end = lsp_text.byteColumnToPosition(src, d.end_line, d.end_column, .@"utf-16");
    try testing.expectEqual(@as(u32, 1), start.line);
    try testing.expectEqual(tag_col - 1, start.character);
    try testing.expectEqual(tag_col - 1 + 4, end.character);
}

test "text > applyIncrementalChange edits at the utf-16 position" {
    const allocator = testing.allocator;

    const src = "pub fn Page() zx.Component {\n    return (<p>Café </p>);\n}\n";
    // A client using utf-16 asks to insert "x" right before `</p>`. On line 1
    // that is column 20 in utf-16 code units, but byte 21 because of `é`.
    const edited = try lsp_text.applyIncrementalChange(
        allocator,
        src,
        .{
            .start = .{ .line = 1, .character = 20 },
            .end = .{ .line = 1, .character = 20 },
        },
        "x",
        .@"utf-16",
    );
    defer allocator.free(edited);

    try testing.expectEqualStrings(
        "pub fn Page() zx.Component {\n    return (<p>Café x</p>);\n}\n",
        edited,
    );
}

test "text > applyIncrementalChange replaces a range" {
    const allocator = testing.allocator;

    const src = "<p>Café</p>\n";
    const edited = try lsp_text.applyIncrementalChange(
        allocator,
        src,
        .{
            .start = .{ .line = 0, .character = 3 },
            .end = .{ .line = 0, .character = 7 },
        },
        "Tea",
        .@"utf-16",
    );
    defer allocator.free(edited);

    try testing.expectEqualStrings("<p>Tea</p>\n", edited);
}

test "text > applyIncrementalChange rejects an inverted range" {
    const allocator = testing.allocator;

    try testing.expectError(error.InvalidRange, lsp_text.applyIncrementalChange(
        allocator,
        "abcdef\n",
        .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 1 },
        },
        "x",
        .@"utf-16",
    ));
}
