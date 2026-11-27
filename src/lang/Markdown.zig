/// MDZX / MD → ZX transpile.
///
/// Uses the official tree-sitter-markdown dual-grammar model:
/// 1. Parse blocks with `mdzx` (opaque `inline` leaves)
/// 2. Re-parse each `inline` range with `mdzx_inline` via included ranges
///
/// Always emits `pub fn render(...)`. Authors must not declare `render`.
/// Pages may declare `Page` (or get a default). Components may declare `Props`
/// (+ optional `var props`) for a `ComponentCtx` signature.
const Markdown = @This();

const std = @import("std");
const ts = @import("tree_sitter");
const mdzx = @import("tree_sitter_mdzx");

const Writer = std.ArrayList(u8);

/// Tree-sitter node kinds used by the MDZX block + inline grammars.
pub const NodeKind = enum {
    // Document / frontmatter
    source_file,
    frontmatter,
    frontmatter_delimiter,
    frontmatter_body,

    // Blocks
    atx_heading,
    paragraph,
    thematic_break,
    fenced_code_block,
    indented_code_block,
    block_quote,
    list,
    list_item,
    link_reference_definition,
    mdzx_component,
    zx_expression_block,
    @"inline",

    // Heading markers
    atx_h1_marker,
    atx_h2_marker,
    atx_h3_marker,
    atx_h4_marker,
    atx_h5_marker,
    atx_h6_marker,

    // Code fence
    info_string,
    language,
    code_fence_content,

    // Quotes / lists
    block_quote_marker,
    list_marker_dot,
    list_marker_parenthesis,
    list_marker_plus,
    list_marker_minus,
    list_marker_star,
    task_list_marker_checked,
    task_list_marker_unchecked,

    // Inline
    code_span,
    code_span_delimiter,
    code_span_content,
    emphasis,
    emphasis_content,
    strong_emphasis,
    strong_emphasis_content,
    bold_italic,
    bold_italic_content,
    strikethrough,
    strikethrough_content,
    inline_link,
    full_reference_link,
    image,
    autolink,
    backslash_escape,
    link_text,
    link_destination,
    uri,
    text,
    whitespace,
    soft_line_break,

    /// Anonymous / unrecognized node kind
    anon,

    fn fromString(s: []const u8) NodeKind {
        return std.meta.stringToEnum(NodeKind, s) orelse .anon;
    }

    pub fn fromNode(node: ?ts.Node) NodeKind {
        if (node == null) return .anon;
        return fromString(node.?.kind());
    }

    fn isBlock(self: NodeKind) bool {
        return switch (self) {
            .atx_heading,
            .paragraph,
            .thematic_break,
            .fenced_code_block,
            .indented_code_block,
            .block_quote,
            .list,
            .mdzx_component,
            .zx_expression_block,
            .link_reference_definition,
            => true,
            else => false,
        };
    }

    fn isZxEmbed(self: NodeKind) bool {
        return self == .mdzx_component or self == .zx_expression_block;
    }

    fn isListMarker(self: NodeKind) bool {
        return switch (self) {
            .list_marker_dot,
            .list_marker_parenthesis,
            .list_marker_plus,
            .list_marker_minus,
            .list_marker_star,
            => true,
            else => false,
        };
    }

    fn isOrderedListMarker(self: NodeKind) bool {
        return self == .list_marker_dot or self == .list_marker_parenthesis;
    }

    fn headingLevel(self: NodeKind) ?u8 {
        return switch (self) {
            .atx_h1_marker => 1,
            .atx_h2_marker => 2,
            .atx_h3_marker => 3,
            .atx_h4_marker => 4,
            .atx_h5_marker => 5,
            .atx_h6_marker => 6,
            else => null,
        };
    }
};

pub const TranspileOptions = struct {
    /// Emit a default `Page` unless the author already declared one.
    /// CLI sets this for `page.mdzx` / `page.md` only.
    emit_default_page: bool = true,
    /// Pure markdown (`.md`): ZX embeds are forbidden.
    pure_md: bool = false,
};

pub const TranspileError = error{
    UserDeclaredRender,
    PureMdEmbed,
    LoadingLang,
    ParseError,
    OutOfMemory,
};

const default_page =
    \\pub fn Page(c: @import("zx").PageContext) @import("zx").Component {
    \\    return @import("zx").mdzx.page(@This(), c);
    \\}
    \\
;

/// Combined MDZX parse: block tree + per-`inline` trees.
const Parsed = struct {
    allocator: std.mem.Allocator,
    block: *ts.Tree,
    inline_trees: std.ArrayList(*ts.Tree),
    inline_by_id: std.AutoHashMap(usize, usize),

    fn deinit(self: *Parsed) void {
        for (self.inline_trees.items) |t| t.destroy();
        self.inline_trees.deinit(self.allocator);
        self.inline_by_id.deinit();
        self.block.destroy();
    }

    fn inlineRoot(self: *const Parsed, block_inline: ts.Node) ?ts.Node {
        const idx = self.inline_by_id.get(@intFromPtr(block_inline.id)) orelse return null;
        return self.inline_trees.items[idx].rootNode();
    }
};

fn parseMdzx(allocator: std.mem.Allocator, source: []const u8) !Parsed {
    const block_parser = ts.Parser.create();
    defer block_parser.destroy();
    block_parser.setLanguage(ts.Language.fromRaw(mdzx.language())) catch return error.LoadingLang;
    const block = block_parser.parseString(source, null) orelse return error.ParseError;

    var parsed: Parsed = .{
        .allocator = allocator,
        .block = block,
        .inline_trees = .empty,
        .inline_by_id = .init(allocator),
    };
    errdefer parsed.deinit();

    const inline_parser = ts.Parser.create();
    defer inline_parser.destroy();
    inline_parser.setLanguage(ts.Language.fromRaw(mdzx.inlineLanguage())) catch return error.LoadingLang;

    var cursor = block.walk();
    defer cursor.destroy();

    outer: while (true) {
        const node = while (true) {
            const kind = NodeKind.fromNode(cursor.node());
            if (kind == .@"inline" or !cursor.gotoFirstChild()) {
                while (!cursor.gotoNextSibling()) {
                    if (!cursor.gotoParent()) break :outer;
                }
            }
            if (NodeKind.fromNode(cursor.node()) == .@"inline") break cursor.node();
        };

        var range = node.range();
        var ranges = std.ArrayList(ts.Range).empty;
        defer ranges.deinit(allocator);

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (child.isNamed()) {
                    const child_range = child.range();
                    try ranges.append(allocator, .{
                        .start_byte = range.start_byte,
                        .start_point = range.start_point,
                        .end_byte = child_range.start_byte,
                        .end_point = child_range.start_point,
                    });
                    range.start_byte = child_range.end_byte;
                    range.start_point = child_range.end_point;
                }
                if (!cursor.gotoNextSibling()) break;
            }
            _ = cursor.gotoParent();
        }
        try ranges.append(allocator, range);

        var filtered = std.ArrayList(ts.Range).empty;
        defer filtered.deinit(allocator);
        for (ranges.items) |r| {
            if (r.start_byte < r.end_byte) try filtered.append(allocator, r);
        }

        if (filtered.items.len > 0) {
            try inline_parser.setIncludedRanges(filtered.items);
            const inline_tree = inline_parser.parseString(source, null) orelse return error.ParseError;
            const idx = parsed.inline_trees.items.len;
            try parsed.inline_trees.append(allocator, inline_tree);
            try parsed.inline_by_id.put(@intFromPtr(node.id), idx);
        }

        while (!cursor.gotoNextSibling()) {
            if (!cursor.gotoParent()) break :outer;
        }
    }

    try inline_parser.setIncludedRanges(null);
    return parsed;
}

pub fn transpile(allocator: std.mem.Allocator, source: []const u8) anyerror![]const u8 {
    return transpileWithOptions(allocator, source, .{});
}

pub fn transpileWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: TranspileOptions,
) anyerror![]const u8 {
    const owned_source: ?[]u8 = if (source.len == 0 or source[source.len - 1] != '\n') blk: {
        const buf = try allocator.alloc(u8, source.len + 1);
        @memcpy(buf[0..source.len], source);
        buf[source.len] = '\n';
        break :blk buf;
    } else null;
    defer if (owned_source) |buf| allocator.free(buf);
    const effective_source = owned_source orelse source;

    var parsed = try parseMdzx(allocator, effective_source);
    defer parsed.deinit();

    const root = parsed.block.rootNode();
    var out: Writer = .empty;
    errdefer out.deinit(allocator);

    var blocks = std.ArrayList([]const u8).empty;
    defer {
        for (blocks.items) |b| allocator.free(b);
        blocks.deinit(allocator);
    }

    var has_author_page = false;
    var has_props = false;
    var has_props_var = false;

    const child_count = root.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = root.child(i) orelse continue;
        const kind = NodeKind.fromNode(child);

        switch (kind) {
            .frontmatter => {
                const fm_text = frontmatterSource(effective_source, child);
                if (frontmatterDeclaresRender(fm_text)) return error.UserDeclaredRender;
                if (std.mem.find(u8, fm_text, "pub fn Page") != null) has_author_page = true;
                has_props = frontmatterHasProps(fm_text);
                has_props_var = frontmatterHasPropsVar(fm_text);
                try writeFrontmatter(allocator, &out, fm_text);
            },
            else => {
                if (!kind.isBlock()) continue;
                if (options.pure_md and kind.isZxEmbed()) return error.PureMdEmbed;
                var buf: Writer = .empty;
                errdefer buf.deinit(allocator);
                try writeBlock(allocator, &buf, effective_source, child, &parsed);
                if (buf.items.len > 0) {
                    try blocks.append(allocator, try buf.toOwnedSlice(allocator));
                } else {
                    buf.deinit(allocator);
                }
            },
        }
    }

    if (blocks.items.len > 0) {
        try writeRenderFn(allocator, &out, blocks.items, has_props, has_props_var);
    }

    const should_emit_page = options.emit_default_page and !has_author_page and !has_props;
    if (should_emit_page) {
        try out.appendSlice(allocator, default_page);
    }

    return try out.toOwnedSlice(allocator);
}

fn writeRenderFn(
    allocator: std.mem.Allocator,
    out: *Writer,
    blocks: []const []const u8,
    has_props: bool,
    has_props_var: bool,
) !void {
    if (has_props) {
        try out.appendSlice(allocator,
            \\pub fn render(ctx: *@import("zx").ComponentCtx(Props)) @import("zx").Component {
            \\
        );
        if (has_props_var) {
            try out.appendSlice(allocator, "    props = ctx.props;\n");
        }
        try out.appendSlice(allocator, "    const allocator = ctx.allocator;\n");
    } else {
        try out.appendSlice(allocator,
            \\pub fn render(allocator: @import("zx").Allocator) @import("zx").Component {
            \\
        );
    }

    if (blocks.len == 1) {
        try out.appendSlice(allocator, "    return (");
        try appendWithAllocator(allocator, out, blocks[0]);
        try out.appendSlice(allocator, ");\n");
    } else {
        try out.appendSlice(allocator, "    return (<div @allocator={allocator}>\n");
        for (blocks) |block| {
            try out.appendSlice(allocator, "        ");
            try out.appendSlice(allocator, block);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "    </div>);\n");
    }
    try out.appendSlice(allocator, "}\n");
}

pub fn shouldEmitDefaultPage(path: ?[]const u8) bool {
    const p = path orelse return true;
    const base = std.Io.Dir.path.basename(p);
    return std.mem.eql(u8, base, "page.mdzx") or std.mem.eql(u8, base, "page.md");
}

fn frontmatterDeclaresRender(fm: []const u8) bool {
    return std.mem.find(u8, fm, "fn render(") != null;
}

fn frontmatterHasProps(fm: []const u8) bool {
    if (std.mem.find(u8, fm, "pub const Props") != null) return true;
    if (std.mem.find(u8, fm, "const Props") != null) return true;
    return false;
}

fn frontmatterHasPropsVar(fm: []const u8) bool {
    return std.mem.find(u8, fm, "var props") != null;
}

fn frontmatterSource(source: []const u8, node: ts.Node) []const u8 {
    if (node.childByFieldName("content")) |content| {
        return textOf(source, content);
    }
    return "";
}

fn writeFrontmatter(allocator: std.mem.Allocator, out: *Writer, content: []const u8) !void {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len > 0) {
        try out.appendSlice(allocator, trimmed);
        try out.appendSlice(allocator, "\n\n");
    }
}

fn writeBlock(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    switch (NodeKind.fromNode(node)) {
        .atx_heading => try writeHeading(allocator, buf, source, node, parsed),
        .paragraph => try writeParagraph(allocator, buf, source, node, parsed),
        .thematic_break => try buf.appendSlice(allocator, "<hr />"),
        .fenced_code_block => try writeFencedCodeBlock(allocator, buf, source, node),
        .indented_code_block => try writeIndentedCodeBlock(allocator, buf, source, node),
        .block_quote => try writeBlockQuote(allocator, buf, source, node, parsed),
        .list => try writeList(allocator, buf, source, node, parsed),
        .mdzx_component, .zx_expression_block => {
            try buf.appendSlice(allocator, std.mem.trim(u8, textOf(source, node), "\n \t"));
        },
        .link_reference_definition => {},
        else => {},
    }
}

fn writeHeading(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    const level = getHeadingLevel(node);
    const tag = switch (level) {
        1 => "h1",
        2 => "h2",
        3 => "h3",
        4 => "h4",
        5 => "h5",
        6 => "h6",
        else => "h1",
    };

    try buf.append(allocator, '<');
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');

    if (node.childByFieldName("heading_content")) |inline_node| {
        try writeInline(allocator, buf, source, inline_node, parsed);
    }

    try buf.appendSlice(allocator, "</");
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');
}

fn getHeadingLevel(node: ts.Node) u8 {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child).headingLevel()) |level| return level;
    }
    return 1;
}

fn writeParagraph(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    try buf.appendSlice(allocator, "<p>");
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .@"inline") {
            try writeInline(allocator, buf, source, child, parsed);
        }
    }
    try buf.appendSlice(allocator, "</p>");
}

fn writeFencedCodeBlock(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    var lang: ?[]const u8 = null;
    var content: ?[]const u8 = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .info_string, .language => {
                if (lang == null) {
                    lang = std.mem.trim(u8, textOf(source, child), " \t\n");
                }
            },
            .code_fence_content => content = textOf(source, child),
            else => {},
        }
    }

    try buf.appendSlice(allocator, "<pre><code");
    if (lang) |l| {
        if (l.len > 0) {
            try buf.appendSlice(allocator, " class=\"language-");
            try buf.appendSlice(allocator, l);
            try buf.append(allocator, '"');
        }
    }
    try buf.append(allocator, '>');
    if (content) |c| {
        try appendText(allocator, buf, std.mem.trimEnd(u8, c, "\n"));
    }
    try buf.appendSlice(allocator, "</code></pre>");
}

fn writeIndentedCodeBlock(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    try buf.appendSlice(allocator, "<pre><code>");
    var content: Writer = .empty;
    defer content.deinit(allocator);
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const line = textOf(source, child);
        const stripped = if (line.len >= 4 and std.mem.eql(u8, line[0..4], "    "))
            line[4..]
        else
            line;
        try content.appendSlice(allocator, std.mem.trimEnd(u8, stripped, "\n"));
        if (i + 1 < child_count) try content.append(allocator, '\n');
    }
    try appendText(allocator, buf, content.items);
    try buf.appendSlice(allocator, "</code></pre>");
}

fn writeBlockQuote(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    try buf.appendSlice(allocator, "<blockquote>");
    var first = true;
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) != .@"inline") continue;
        if (std.mem.trim(u8, textOf(source, child), " \t\n").len == 0) continue;
        if (!first) try buf.appendSlice(allocator, "<br />");
        first = false;
        try writeInline(allocator, buf, source, child, parsed);
    }
    try buf.appendSlice(allocator, "</blockquote>");
}

fn writeList(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    const is_ordered = isOrderedList(node);
    const tag = if (is_ordered) "ol" else "ul";

    try buf.append(allocator, '<');
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .list_item) {
            try writeListItem(allocator, buf, source, child, parsed);
        }
    }

    try buf.appendSlice(allocator, "</");
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');
}

fn isOrderedList(node: ts.Node) bool {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) != .list_item) continue;
        const item_children = child.childCount();
        var j: u32 = 0;
        while (j < item_children) : (j += 1) {
            const item_child = child.child(j) orelse continue;
            const kind = NodeKind.fromNode(item_child);
            if (kind.isOrderedListMarker()) return true;
            if (kind.isListMarker()) return false;
        }
    }
    return false;
}

fn writeListItem(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, parsed: *const Parsed) !void {
    try buf.appendSlice(allocator, "<li>");
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .task_list_marker_checked => try buf.appendSlice(allocator, "<input type=\"checkbox\" checked=\"\" disabled=\"\" /> "),
            .task_list_marker_unchecked => try buf.appendSlice(allocator, "<input type=\"checkbox\" disabled=\"\" /> "),
            .@"inline" => try writeInline(allocator, buf, source, child, parsed),
            else => {},
        }
    }
    try buf.appendSlice(allocator, "</li>");
}

fn writeInline(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, block_inline: ts.Node, parsed: *const Parsed) !void {
    const node = parsed.inlineRoot(block_inline) orelse block_inline;
    const child_count = node.childCount();
    if (child_count == 0) {
        try appendText(allocator, buf, textOf(source, block_inline));
        return;
    }
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try writeInlineElement(allocator, buf, source, child);
    }
}

fn writeInlineElement(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    switch (NodeKind.fromNode(node)) {
        .code_span => try writeCodeSpan(allocator, buf, source, node),
        .emphasis => try writeTaggedContent(allocator, buf, source, node, .emphasis_content, "<em>", "</em>"),
        .strong_emphasis => try writeTaggedContent(allocator, buf, source, node, .strong_emphasis_content, "<strong>", "</strong>"),
        .bold_italic => try writeTaggedContent(allocator, buf, source, node, .bold_italic_content, "<strong><em>", "</em></strong>"),
        .strikethrough => try writeTaggedContent(allocator, buf, source, node, .strikethrough_content, "<s>", "</s>"),
        .inline_link => try writeInlineLink(allocator, buf, source, node),
        .full_reference_link => try writeReferenceLink(allocator, buf, source, node),
        .image => try writeImage(allocator, buf, source, node),
        .autolink => try writeAutolink(allocator, buf, source, node),
        .backslash_escape => {
            const text = textOf(source, node);
            try appendText(allocator, buf, if (text.len >= 2) text[1..2] else text);
        },
        .soft_line_break => try buf.append(allocator, ' '),
        else => try appendText(allocator, buf, textOf(source, node)),
    }
}

fn writeCodeSpan(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    try buf.appendSlice(allocator, "<code>");
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .code_span_content) {
            try appendText(allocator, buf, textOf(source, child));
        }
    }
    try buf.appendSlice(allocator, "</code>");
}

fn writeTaggedContent(
    allocator: std.mem.Allocator,
    buf: *Writer,
    source: []const u8,
    node: ts.Node,
    content_kind: NodeKind,
    open: []const u8,
    close: []const u8,
) !void {
    try buf.appendSlice(allocator, open);
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == content_kind) try appendText(allocator, buf, textOf(source, child));
    }
    try buf.appendSlice(allocator, close);
}

fn writeInlineLink(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    var href: ?[]const u8 = null;
    var link_text_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .link_text => link_text_node = child,
            .link_destination, .uri => href = textOf(source, child),
            else => {},
        }
    }

    try buf.appendSlice(allocator, "<a");
    if (href) |h| {
        try buf.appendSlice(allocator, " href=\"");
        try buf.appendSlice(allocator, h);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '>');
    if (link_text_node) |lt| try writeLinkText(allocator, buf, source, lt, .body);
    try buf.appendSlice(allocator, "</a>");
}

fn writeReferenceLink(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    var link_text_node: ?ts.Node = null;
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .link_text) link_text_node = child;
    }

    try buf.appendSlice(allocator, "<a>");
    if (link_text_node) |lt| try writeLinkText(allocator, buf, source, lt, .body);
    try buf.appendSlice(allocator, "</a>");
}

const LinkTextMode = enum { body, attr };

fn writeLinkText(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node, mode: LinkTextMode) !void {
    const child_count = node.childCount();
    if (child_count == 0) {
        const raw = textOf(source, node);
        const inner = if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']')
            raw[1 .. raw.len - 1]
        else
            raw;
        try emitLinkText(allocator, buf, inner, mode);
        return;
    }
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (!child.isNamed()) {
            const text = textOf(source, child);
            if (std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "]")) continue;
            try emitLinkText(allocator, buf, text, mode);
        } else if (NodeKind.fromNode(child) == .backslash_escape) {
            const text = textOf(source, child);
            try emitLinkText(allocator, buf, if (text.len >= 2) text[1..2] else text, mode);
        } else {
            try emitLinkText(allocator, buf, textOf(source, child), mode);
        }
    }
}

fn emitLinkText(allocator: std.mem.Allocator, buf: *Writer, text: []const u8, mode: LinkTextMode) !void {
    switch (mode) {
        .body => try appendText(allocator, buf, text),
        .attr => {
            for (text) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "&quot;"),
                    else => try buf.append(allocator, c),
                }
            }
        },
    }
}

fn writeImage(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    var src: ?[]const u8 = null;
    var alt_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .link_text => alt_node = child,
            .link_destination, .uri => src = textOf(source, child),
            else => {},
        }
    }

    try buf.appendSlice(allocator, "<img");
    if (src) |s| {
        try buf.appendSlice(allocator, " src=\"");
        try buf.appendSlice(allocator, s);
        try buf.append(allocator, '"');
    }
    if (alt_node) |alt| {
        try buf.appendSlice(allocator, " alt=\"");
        try writeLinkText(allocator, buf, source, alt, .attr);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, " />");
}

fn writeAutolink(allocator: std.mem.Allocator, buf: *Writer, source: []const u8, node: ts.Node) !void {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .uri) {
            const uri = textOf(source, child);
            try buf.appendSlice(allocator, "<a href=\"");
            try buf.appendSlice(allocator, uri);
            try buf.appendSlice(allocator, "\">");
            try appendText(allocator, buf, uri);
            try buf.appendSlice(allocator, "</a>");
            return;
        }
    }
}

fn appendWithAllocator(allocator: std.mem.Allocator, out: *Writer, zx_str: []const u8) !void {
    for (zx_str, 0..) |c, idx| {
        if (c == '/' and idx + 1 < zx_str.len and zx_str[idx + 1] == '>') {
            try out.appendSlice(allocator, zx_str[0..idx]);
            try out.appendSlice(allocator, " @allocator={allocator}");
            try out.appendSlice(allocator, zx_str[idx..]);
            return;
        }
        if (c == '>') {
            try out.appendSlice(allocator, zx_str[0..idx]);
            try out.appendSlice(allocator, " @allocator={allocator}");
            try out.appendSlice(allocator, zx_str[idx..]);
            return;
        }
    }
    try out.appendSlice(allocator, zx_str);
}

fn textOf(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start < end and end <= source.len) return source[start..end];
    return "";
}

fn appendText(allocator: std.mem.Allocator, buf: *Writer, text: []const u8) !void {
    try buf.appendSlice(allocator, "{\"");
    for (text) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.appendSlice(allocator, "\"}");
}
