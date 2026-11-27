const std = @import("std");
const testing = std.testing;

const lang = @import("lang");
const Markdown = @import("lang").Markdown;
const ts = @import("tree_sitter");
const mdzx = @import("tree_sitter_mdzx");

fn transpile(source: []const u8) ![]const u8 {
    return Markdown.transpile(testing.allocator, source);
}

test "heading transpiles to h1" {
    const out = try transpile("# Hello\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<h1") != null);
    try testing.expect(std.mem.find(u8, out, "Hello") != null);
}

test "paragraph with emphasis" {
    const out = try transpile("This is *italic* text.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<em>") != null);
    try testing.expect(std.mem.find(u8, out, "italic") != null);
    try testing.expect(std.mem.find(u8, out, "</em>") != null);
}

test "strong emphasis" {
    const out = try transpile("Say **bold** please.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<strong>") != null);
    try testing.expect(std.mem.find(u8, out, "bold") != null);
}

test "strikethrough" {
    const out = try transpile("Not ~~gone~~ yet.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<s>") != null);
    try testing.expect(std.mem.find(u8, out, "gone") != null);
}

test "inline code" {
    const out = try transpile("Use `code` here.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<code>") != null);
    try testing.expect(std.mem.find(u8, out, "code") != null);
}

test "inline link" {
    const out = try transpile("Go [home](https://example.com).\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<a href=\"https://example.com\">") != null);
    try testing.expect(std.mem.find(u8, out, "home") != null);
}

test "image" {
    const out = try transpile("![alt](https://example.com/a.png)\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<img") != null);
    try testing.expect(std.mem.find(u8, out, "src=\"https://example.com/a.png\"") != null);
    try testing.expect(std.mem.find(u8, out, "alt=\"alt\"") != null);
}

test "thematic break" {
    const out = try transpile("***\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<hr") != null);
}

test "fenced code block" {
    const out = try transpile(
        \\```zig
        \\const x = 1;
        \\```
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<pre") != null);
    try testing.expect(std.mem.find(u8, out, "language-zig") != null);
    try testing.expect(std.mem.find(u8, out, "const x = 1;") != null);
    // Closing fence must not appear inside the code element
    try testing.expect(std.mem.find(u8, out, "1;```") == null);
    try testing.expect(std.mem.find(u8, out, "1;\n```") == null);
}

test "emits render and default page" {
    const out = try transpile("# Hi\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "pub fn render(allocator:") != null);
    try testing.expect(std.mem.find(u8, out, "mdzx.page(@This()") != null);
    try testing.expect(std.mem.find(u8, out, "pub fn Page(") != null);
}

test "author page suppresses default page" {
    const out = try transpile(
        \\---
        \\const zx = @import("zx");
        \\pub fn Page(c: zx.PageContext) zx.Component {
        \\    return zx.mdzx.page(@This(), c);
        \\}
        \\---
        \\
        \\# Hi
        \\
    );
    defer testing.allocator.free(out);
    var count: usize = 0;
    var rest: []const u8 = out;
    while (std.mem.find(u8, rest, "pub fn Page(")) |idx| {
        count += 1;
        rest = rest[idx + 1 ..];
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.find(u8, out, "pub fn render(allocator:") != null);
}

test "user-declared render is an error" {
    const result = transpile(
        \\---
        \\pub fn render(allocator: @import("zx").Allocator) @import("zx").Component {
        \\    _ = allocator;
        \\    return undefined;
        \\}
        \\---
        \\
        \\# Hi
        \\
    );
    try testing.expectError(error.UserDeclaredRender, result);
}

test "props emits component ctx render and skips default page" {
    const out = try transpile(
        \\---
        \\pub const Props = struct { name: []const u8 };
        \\var props: Props = undefined;
        \\---
        \\
        \\# Hi
        \\
        \\{props.name}
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "pub fn render(ctx: *@import(\"zx\").ComponentCtx(Props))") != null);
    try testing.expect(std.mem.find(u8, out, "props = ctx.props;") != null);
    try testing.expect(std.mem.find(u8, out, "pub fn Page(") == null);
}

test "pure md rejects zx embeds" {
    const result = Markdown.transpileWithOptions(testing.allocator,
        \\# Hi
        \\
        \\<Button />
        \\
    , .{ .pure_md = true, .emit_default_page = true });
    try testing.expectError(error.PureMdEmbed, result);
}

test "pure md allows markdown-only" {
    const out = try Markdown.transpileWithOptions(testing.allocator, "# Pure\n", .{
        .pure_md = true,
        .emit_default_page = true,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "pub fn render(allocator:") != null);
    try testing.expect(std.mem.find(u8, out, "pub fn Page(") != null);
}

test "non-page path skips default page" {
    const out = try Markdown.transpileWithOptions(testing.allocator, "# Hi\n", .{
        .emit_default_page = false,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "pub fn render(allocator:") != null);
    try testing.expect(std.mem.find(u8, out, "pub fn Page(") == null);
}

test "unordered list" {
    const out = try transpile(
        \\- one
        \\- two
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<ul") != null);
    try testing.expect(std.mem.find(u8, out, "<li") != null);
    try testing.expect(std.mem.find(u8, out, "one") != null);
}

test "ordered list" {
    const out = try transpile(
        \\1. first
        \\2. second
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<ol") != null);
    try testing.expect(std.mem.find(u8, out, "first") != null);
}

test "block quote" {
    const out = try transpile(
        \\> quoted
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<blockquote") != null);
    try testing.expect(std.mem.find(u8, out, "quoted") != null);
}

test "multiple headings" {
    const out = try transpile("# A\n\n## B\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<h1") != null);
    try testing.expect(std.mem.find(u8, out, "<h2") != null);
}

test "zx component block" {
    const out = try transpile("<Button label=\"Go\" />\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<Button") != null);
    try testing.expect(std.mem.find(u8, out, "label=\"Go\"") != null);
}

test "frontmatter zig decls preserved" {
    const src =
        \\---
        \\pub const title = "Hi";
        \\---
        \\
        \\# Body
        \\
    ;
    const out = try transpile(src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "pub const title = \"Hi\";") != null);
    try testing.expect(std.mem.find(u8, out, "<h1") != null);
    try testing.expect(std.mem.find(u8, out, "Body") != null);
}

test "dual grammar, block leaves opaque inline, inline parses emphasis" {
    const source = "Hello *world*.\n";
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(ts.Language.fromRaw(mdzx.language())) catch unreachable;
    const block = parser.parseString(source, null) orelse unreachable;
    defer block.destroy();

    const root = block.rootNode();
    try testing.expectEqualStrings("source_file", root.kind());

    var found_inline: ?ts.Node = null;
    var i: u32 = 0;
    while (i < root.childCount()) : (i += 1) {
        const child = root.child(i) orelse continue;
        if (std.mem.eql(u8, child.kind(), "paragraph")) {
            var j: u32 = 0;
            while (j < child.childCount()) : (j += 1) {
                const gc = child.child(j) orelse continue;
                if (std.mem.eql(u8, gc.kind(), "inline")) {
                    found_inline = gc;
                    break;
                }
            }
        }
    }
    const inline_node = found_inline orelse return error.NoInlineNode;

    var has_emphasis_in_block = false;
    var k: u32 = 0;
    while (k < inline_node.childCount()) : (k += 1) {
        const c = inline_node.child(k) orelse continue;
        if (std.mem.eql(u8, c.kind(), "emphasis")) has_emphasis_in_block = true;
    }
    try testing.expect(!has_emphasis_in_block);

    parser.setLanguage(ts.Language.fromRaw(mdzx.inlineLanguage())) catch unreachable;
    const range = inline_node.range();
    try parser.setIncludedRanges(&.{range});
    const inline_tree = parser.parseString(source, null) orelse unreachable;
    defer inline_tree.destroy();

    const inline_root = inline_tree.rootNode();
    var saw_emphasis = false;
    var n: u32 = 0;
    while (n < inline_root.childCount()) : (n += 1) {
        const c = inline_root.child(n) orelse continue;
        if (std.mem.eql(u8, c.kind(), "emphasis")) saw_emphasis = true;
    }
    try testing.expect(saw_emphasis);
}

test "fixture basic.mdzx" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/data/mdzx/basic.mdzx",
        testing.allocator,
        .limited(64 * 1024),
    );
    defer testing.allocator.free(source);
    const out = try transpile(source);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<h1") != null);
}

test "braces in fenced code stay literal" {
    const out = try transpile(
        \\```ts
        \\type Point = { x: number };
        \\```
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "type Point") != null);
    try testing.expect(std.mem.find(u8, out, "<pre") != null);
    try testing.expect(std.mem.find(u8, out, "language-ts") != null);
    // Whole fence content wrapped as a ZX string expression
    try testing.expect(std.mem.find(u8, out, "{\"type Point") != null);
}

test "braces in inline code are zx-escaped" {
    const out = try transpile("Use `{expressions}` here.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<code>") != null);
    try testing.expect(std.mem.find(u8, out,
        \\{"{expressions}"}
    ) != null);
    try testing.expect(std.mem.find(u8, out, "<code>{expressions}</code>") == null);
}

test "paragraph keeps plain text around markup" {
    const out = try transpile("Use **bold**, *italic*, and `code`.\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "Use ") != null);
    try testing.expect(std.mem.find(u8, out, "<strong>") != null);
    try testing.expect(std.mem.find(u8, out, ", ") != null);
    try testing.expect(std.mem.find(u8, out, "<em>") != null);
    try testing.expect(std.mem.find(u8, out, " and ") != null);
    try testing.expect(std.mem.find(u8, out, "<code>") != null);
}

test "backslash escapes preserve surrounding text" {
    const out = try transpile("Escaped: \\*not emphasis\\*\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "Escaped: ") != null);
    try testing.expect(std.mem.find(u8, out, "not emphasis") != null);
    try testing.expect(std.mem.find(u8, out, "<em>") == null);
}

test "ampersand in heading is not double-escaped" {
    const out = try transpile("## Quote & break\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<h2") != null);
    // Emitted as a ZX string expr with a raw `&` (runtime escapes once)
    try testing.expect(std.mem.find(u8, out, "Quote & break") != null);
    try testing.expect(std.mem.find(u8, out, "&amp;amp;") == null);
    try testing.expect(std.mem.find(u8, out, "{\"Quote & break\"}") != null);
}

test "block quote keeps nested lines without leaking markers" {
    const out = try transpile(
        \\> first line
        \\>
        \\> second line
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<blockquote") != null);
    try testing.expect(std.mem.find(u8, out, "first line") != null);
    try testing.expect(std.mem.find(u8, out, "second line") != null);
    try testing.expect(std.mem.find(u8, out, "&amp;gt;") == null);
    // Contiguous quote lines should not leave a marker glued to body text
    try testing.expect(std.mem.find(u8, out, "> second") == null);
}

test "inline link at line start is not a link-ref definition" {
    const out = try transpile("[Back to MDZX example](/examples/md)\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "<a href=\"/examples/md\">") != null);
    try testing.expect(std.mem.find(u8, out, "Back to MDZX example") != null);
}

test "task list markers become checkboxes" {
    const out = try transpile(
        \\- [x] Task done
        \\- [ ] Task open
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "type=\"checkbox\"") != null);
    try testing.expect(std.mem.find(u8, out, "checked=\"\"") != null);
    try testing.expect(std.mem.find(u8, out, "Task done") != null);
    try testing.expect(std.mem.find(u8, out, "Task open") != null);
    try testing.expect(std.mem.find(u8, out, "[x] Task") == null);
}

test "multiple fenced blocks" {
    const out = try transpile(
        \\```js
        \\console.log(1);
        \\```
        \\
        \\```ts
        \\type Point = { x: number };
        \\```
        \\
    );
    defer testing.allocator.free(out);
    var n: usize = 0;
    var rest: []const u8 = out;
    while (std.mem.find(u8, rest, "<pre")) |i| {
        n += 1;
        rest = rest[i + 4 ..];
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.find(u8, out, "language-js") != null);
    try testing.expect(std.mem.find(u8, out, "language-ts") != null);
    try testing.expect(std.mem.find(u8, out, "console.log(1);") != null);
    try testing.expect(std.mem.find(u8, out, "type Point") != null);
}

// Ensure lang module exports Markdown
comptime {
    _ = lang;
}
