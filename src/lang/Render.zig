const Render = @This();

const std = @import("std");
const ts = @import("tree_sitter");

const Parse = @import("Parse.zig");

const Ast = Parse.Parse;
const NodeKind = Parse.NodeKind;

ast: *Ast,
allocator: std.mem.Allocator,
indent_level: u32 = 0,
in_block: bool = false,
suppress_leading_space: bool = false,

pub fn init(ast: *Ast, allocator: std.mem.Allocator) Render {
    return .{ .ast = ast, .allocator = allocator };
}

pub fn deinit(_: *Render) void {}

fn writeIndent(self: *Render, w: *std.Io.Writer) !void {
    for (0..self.indent_level * 4) |_| try w.writeAll(" ");
}

pub const ExtractBlockResult = struct {
    zx_blocks: []const []const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ExtractBlockResult, allocator: std.mem.Allocator) void {
        for (self.zx_blocks) |block| {
            allocator.free(block);
        }
        allocator.free(self.zx_blocks);
        allocator.free(self.zig_source);
    }
};

/// Extract zx_block content and replace with placeholders for Zig formatting
pub fn extractBlocks(allocator: std.mem.Allocator, ast: *Ast) !ExtractBlockResult {
    var blocks = std.ArrayList([]const u8).empty;
    defer blocks.deinit(allocator);

    var cleaned_source = std.ArrayList(u8).empty;
    defer cleaned_source.deinit(allocator);

    const root = ast.tree.rootNode();
    try extractBlocksInner(ast, root, &blocks, &cleaned_source, allocator);

    try cleaned_source.append(allocator, 0);
    const cleaned = try allocator.dupeSentinel(u8, cleaned_source.items[0 .. cleaned_source.items.len - 1], 0);

    return ExtractBlockResult{
        .zx_blocks = try blocks.toOwnedSlice(allocator),
        .zig_source = cleaned,
    };
}

fn extractBlocksInner(
    ast: *Ast,
    node: ts.Node,
    blocks: *std.ArrayList([]const u8),
    cleaned_source: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const node_kind = NodeKind.fromNode(node);

    // If this is a zx_block, extract it and replace with placeholder
    if (node_kind == .zx_block) {
        const block_text = ast.source[start_byte..end_byte];
        const block_copy = try allocator.dupe(u8, block_text);
        try blocks.append(allocator, block_copy);

        // Use a valid Zig identifier as placeholder
        const placeholder = try allocator.print("__ZX_BLOCK_{d}__", .{blocks.items.len - 1});
        defer allocator.free(placeholder);
        try cleaned_source.appendSlice(allocator, placeholder);
        return;
    }

    // For other nodes, recursively process children
    const child_count = node.childCount();
    if (child_count == 0) {
        // Leaf node - copy source text
        if (start_byte < end_byte and end_byte <= ast.source.len) {
            try cleaned_source.appendSlice(allocator, ast.source[start_byte..end_byte]);
        }
        return;
    }

    // Process children with gaps
    var current_pos = start_byte;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_start = child.startByte();
        const child_end = child.endByte();

        // Copy gap before child
        if (current_pos < child_start and child_start <= ast.source.len) {
            try cleaned_source.appendSlice(allocator, ast.source[current_pos..child_start]);
        }

        // Process child
        try extractBlocksInner(ast, child, blocks, cleaned_source, allocator);
        current_pos = child_end;
    }

    // Copy remaining gap after last child
    if (current_pos < end_byte and end_byte <= ast.source.len) {
        try cleaned_source.appendSlice(allocator, ast.source[current_pos..end_byte]);
    }
}

fn parseBlockPlaceholder(source: []const u8, start: usize) struct { index: usize, end: usize } {
    var i = start;
    if (i + 11 >= source.len or !std.mem.startsWith(u8, source[i..], "__ZX_BLOCK_")) {
        return .{ .index = 0, .end = start };
    }

    i += 11; // skip "__ZX_BLOCK_"

    // Parse number
    const num_start = i;
    while (i < source.len and std.ascii.isDigit(source[i])) {
        i += 1;
    }

    if (i == num_start) {
        return .{ .index = 0, .end = start };
    }

    const num_str = source[num_start..i];
    const block_index = std.fmt.parseInt(usize, num_str, 10) catch {
        return .{ .index = 0, .end = start };
    };

    // Expect closing "__"
    if (i + 2 > source.len or !std.mem.eql(u8, source[i .. i + 2], "__")) {
        return .{ .index = 0, .end = start };
    }

    i += 2; // skip "__"

    return .{ .index = block_index, .end = i };
}

/// Replace __ZX_BLOCK_n__ placeholders with formatted zx_block content
pub fn patchInBlocks(allocator: std.mem.Allocator, extract_result: ExtractBlockResult) ![:0]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < extract_result.zig_source.len) {
        if (i + 12 < extract_result.zig_source.len and
            std.mem.startsWith(u8, extract_result.zig_source[i..], "__ZX_BLOCK_"))
        {
            const parsed = parseBlockPlaceholder(extract_result.zig_source, i);
            if (parsed.end > i and parsed.index < extract_result.zx_blocks.len) {
                const zx_block = extract_result.zx_blocks[parsed.index];

                // Calculate the indentation level where the placeholder appears
                const base_indent = getIndentationLevel(extract_result.zig_source, i);

                // Format the zx_block using the tree-sitter renderer
                var block_ast = try Parse.parse(allocator, zx_block, .zx);
                defer block_ast.deinit(allocator);

                var block_writer = std.Io.Writer.Allocating.init(allocator);
                defer block_writer.deinit();
                const root = block_ast.tree.rootNode();
                var block_renderer = Render.init(&block_ast, allocator);
                block_renderer.indent_level = base_indent;
                try block_renderer.renderNode(root, &block_writer.writer);
                const formatted_block = block_writer.written();

                try result.appendSlice(allocator, formatted_block);
                i = parsed.end;
                continue;
            }
        }

        try result.append(allocator, extract_result.zig_source[i]);
        i += 1;
    }

    try result.append(allocator, 0);
    const result_slice = result.items[0 .. result.items.len - 1 :0];
    return try allocator.dupeSentinel(u8, result_slice, 0);
}

fn getIndentationLevel(source: []const u8, pos: usize) u32 {
    // Find the start of the line containing pos
    var line_start = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') {
        line_start -= 1;
    }

    // Count leading spaces/tabs
    var spaces: u32 = 0;
    var idx = line_start;
    while (idx < pos and idx < source.len) {
        if (source[idx] == ' ') {
            spaces += 1;
        } else if (source[idx] == '\t') {
            spaces += 4;
        } else {
            break;
        }
        idx += 1;
    }

    return spaces / 4;
}

pub fn run(self: *Render, w: *std.Io.Writer) !void {
    const node = self.ast.tree.rootNode();

    var extract_result = try extractBlocks(self.allocator, self.ast);
    defer extract_result.deinit(self.allocator);

    var zig_ast = try std.zig.Ast.parse(self.allocator, extract_result.zig_source, .{ .mode = .zig });
    defer zig_ast.deinit(self.allocator);

    if (zig_ast.errors.len > 0) {
        try self.renderNode(node, w);
        return;
    }

    const formatted_zig = try zig_ast.renderAlloc(self.allocator);
    defer self.allocator.free(formatted_zig);

    self.allocator.free(extract_result.zig_source);
    extract_result.zig_source = try self.allocator.dupeSentinel(u8, formatted_zig, 0);

    const final_result = try patchInBlocks(self.allocator, extract_result);
    defer self.allocator.free(final_result);

    try w.writeAll(final_result);
}

fn renderNode(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    const node_kind = NodeKind.fromNode(node);

    // Track if we're entering a zx_block
    const was_in_zx_block = self.in_block;
    if (node_kind == .zx_block) {
        self.in_block = true;
    }
    defer if (node_kind == .zx_block) {
        self.in_block = was_in_zx_block;
    };

    // If not in zx_block, render Zig code as-is
    if (!self.in_block) {
        try renderSourceWithChildren(self, node, w);
        return;
    }

    // We're in zx_block - apply formatting
    switch (node_kind) {
        .zx_block => {
            try renderBlock(self, node, w);
        },
        .zx_element => {
            try renderElement(self, node, w);
        },
        .zx_self_closing_element => {
            try renderSelfClosingElement(self, node, w);
        },
        .zx_fragment => {
            try renderFragment(self, node, w);
        },
        .zx_start_tag => {
            try renderStartTag(self, node, w);
        },
        .zx_end_tag => {
            try renderEndTag(self, node, w);
        },
        .zx_text => {
            try renderText(self, node, w);
        },
        .zx_child => {
            try renderChild(self, node, w);
        },
        .zx_expression_block => {
            try renderExpressionBlock(self, node, w);
        },
        .zx_template_string => {
            // Template strings are rendered as-is from source
            try renderTemplateString(self, node, w);
        },
        .comment => {
            // Comments are rendered as-is from source (trimmed of leading whitespace
            // since indentation is handled separately)
            try renderComment(self, node, w);
        },
        else => {
            try renderSourceWithChildren(self, node, w);
        },
    }
}

/// Render the source text with recursive child handling
fn renderSourceWithChildren(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const child_count = node.childCount();

    if (child_count == 0) {
        if (start_byte < end_byte and end_byte <= self.ast.source.len) {
            try w.writeAll(self.ast.source[start_byte..end_byte]);
        }
        return;
    }

    var current_pos = start_byte;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_start = child.startByte();
        const child_end = child.endByte();

        if (current_pos < child_start and child_start <= self.ast.source.len) {
            try w.writeAll(self.ast.source[current_pos..child_start]);
        }

        try self.renderNode(child, w);
        current_pos = child_end;
    }

    if (current_pos < end_byte and end_byte <= self.ast.source.len) {
        try w.writeAll(self.ast.source[current_pos..end_byte]);
    }
}

/// Render zx_block: ( <element> )
fn renderBlock(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const child_count = node.childCount();
    var element_node: ?ts.Node = null;

    // Find the main element inside the block
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .zx_element, .zx_self_closing_element, .zx_fragment => {
                element_node = child;
                break;
            },
            else => {},
        }
    }

    // Use the context's indent level as the base (set by patchInZxBlocks)
    const base_indent = self.indent_level;

    try w.writeAll("(");

    if (element_node) |elem| {
        // Check if element is multiline (has newlines in source)
        const elem_start = elem.startByte();
        const elem_end = elem.endByte();
        const is_multiline = if (elem_start < elem_end and elem_end <= self.ast.source.len)
            std.mem.indexOf(u8, self.ast.source[elem_start..elem_end], "\n") != null
        else
            false;

        if (is_multiline) {
            try w.writeAll("\n");
            // Set indent to base + 1 for the element
            self.indent_level = base_indent + 1;
            try self.writeIndent(w);
            try self.renderNode(elem, w);
            // Closing paren at base indent level
            self.indent_level = base_indent;
            try w.writeAll("\n");
            try self.writeIndent(w);
        } else {
            try self.renderNode(elem, w);
        }
    }

    try w.writeAll(")");
}

/// Render zx_fragment: <>...</>
fn renderFragment(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const child_count = node.childCount();
    var content_nodes = std.ArrayList(ts.Node).empty;
    defer content_nodes.deinit(self.allocator);

    // Collect all child nodes (skip fragment opening/closing tags)
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        // Skip fragment markers (< and > tokens)
        if (child_kind == .zx_child) {
            try content_nodes.append(self.allocator, child);
        }
    }

    try w.writeAll("<>");
    self.suppress_leading_space = false;

    // Check if we have meaningful content
    const has_meaningful_content = blk: {
        for (content_nodes.items) |child| {
            if (hasMeaningfulContent(self, child)) {
                break :blk true;
            }
        }
        break :blk false;
    };

    // Check if content is multiline
    const is_vertical = blk: {
        if (!has_meaningful_content) break :blk false;

        // Check for newlines in the fragment
        const elem_start = node.startByte();
        const elem_end = node.endByte();
        if (elem_start < elem_end and elem_end <= self.ast.source.len) {
            if (std.mem.indexOf(u8, self.ast.source[elem_start..elem_end], "\n") != null) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (is_vertical) {
        self.indent_level += 1;
    }

    // Render content
    var rendered_any = false;
    var last_content_end: usize = node.startByte() + 2; // After "<>"
    for (content_nodes.items) |child| {
        // Calculate newline count between last content and this child
        const newline_count = countNewlines(self.ast.source, last_content_end, child.startByte());

        // Check if child has meaningful content
        // In inline mode (or if on same line in vertical mode), also consider spaces-only as meaningful
        const is_meaningful = hasMeaningfulContent(self, child) or
            ((!is_vertical or newline_count == 0) and hasInlineSpacesOnly(self, child));
        if (!is_meaningful) continue;

        if (is_vertical and (!rendered_any or newline_count > 0)) {
            try w.writeAll("\n");
            // Add one extra newline if there was a blank line in source
            if (newline_count > 1 and rendered_any) {
                try w.writeAll("\n");
            }
            try self.writeIndent(w);
            self.suppress_leading_space = true;
        }

        try renderChildInner(self, child, w, !is_vertical or newline_count == 0);
        self.suppress_leading_space = false;
        last_content_end = child.endByte();
        rendered_any = true;
    }

    if (is_vertical and rendered_any) {
        self.indent_level -= 1;
        try w.writeAll("\n");
        try self.writeIndent(w);
    } else if (is_vertical) {
        self.indent_level -= 1;
    }

    try w.writeAll("</>");
}

/// Render zx_element: <tag>content</tag>
fn renderElement(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const child_count = node.childCount();
    var start_tag_node: ?ts.Node = null;
    var end_tag_node: ?ts.Node = null;
    var content_nodes = std.ArrayList(ts.Node).empty;
    defer content_nodes.deinit(self.allocator);

    // Collect all parts
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        if (child_kind == .zx_start_tag) {
            start_tag_node = child;
        } else if (child_kind == .zx_end_tag) {
            end_tag_node = child;
        } else {
            try content_nodes.append(self.allocator, child);
        }
    }

    // Render start tag
    if (start_tag_node) |st| {
        try renderStartTag(self, st, w);
        self.suppress_leading_space = false;
    }

    // - If there's whitespace/newline between start tag and first content -> vertical
    // - Otherwise -> horizontal
    const has_meaningful_content = blk: {
        for (content_nodes.items) |child| {
            const child_kind = NodeKind.fromNode(child);
            // Comments are meaningful content that should preserve vertical layout
            if (child_kind == .comment) {
                break :blk true;
            }
            if (child_kind == .zx_child) {
                // Check if zx_child has meaningful content
                const cc = child.childCount();
                var j: u32 = 0;
                while (j < cc) : (j += 1) {
                    const gc = child.child(j) orelse continue;
                    const gck = NodeKind.fromNode(gc);
                    if (gck == .zx_text) {
                        const text = self.ast.source[gc.startByte()..gc.endByte()];
                        if (std.mem.trim(u8, text, &std.ascii.whitespace).len > 0) {
                            break :blk true;
                        }
                    } else {
                        break :blk true;
                    }
                }
            }
        }
        break :blk false;
    };

    const is_vertical = blk: {
        if (!has_meaningful_content) break :blk false;

        // Check for newlines in the element's content area
        // This is similar to how fragments check for multiline content
        const start_tag_end = if (start_tag_node) |st| st.endByte() else node.startByte();
        const end_tag_start = if (end_tag_node) |et| et.startByte() else node.endByte();
        if (start_tag_end < end_tag_start and end_tag_start <= self.ast.source.len) {
            if (std.mem.indexOf(u8, self.ast.source[start_tag_end..end_tag_start], "\n") != null) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (is_vertical) {
        self.indent_level += 1;
    }

    // Render content - skip whitespace-only children
    var rendered_any = false;
    var last_content_end: usize = if (start_tag_node) |st| st.endByte() else node.startByte();
    for (content_nodes.items) |child| {
        const child_kind = NodeKind.fromNode(child);
        if (child_kind == .zx_child) {
            // Calculate newline count between last content and this child
            const newline_count = countNewlines(self.ast.source, last_content_end, child.startByte());

            // Check if child has meaningful content
            // In inline mode (or if on same line in vertical mode), also consider spaces-only as meaningful
            const is_meaningful = hasMeaningfulContent(self, child) or
                ((!is_vertical or newline_count == 0) and hasInlineSpacesOnly(self, child));
            if (!is_meaningful) continue;

            // Check if this child should be on a new line
            if (is_vertical and (!rendered_any or newline_count > 0)) {
                try w.writeAll("\n");
                // Add one extra newline if there was a blank line in source
                if (newline_count > 1 and rendered_any) {
                    try w.writeAll("\n");
                }
                try self.writeIndent(w);
                self.suppress_leading_space = true;
            }
            try renderChildInner(self, child, w, !is_vertical or newline_count == 0);
            self.suppress_leading_space = false; // Reset just in case
            last_content_end = child.endByte();
            rendered_any = true;
        } else if (child_kind == .comment) {
            // Comments need proper newline handling like zx_child
            const newline_count = countNewlines(self.ast.source, last_content_end, child.startByte());

            // Comments should always be on their own line in vertical mode
            if (is_vertical and (!rendered_any or newline_count > 0)) {
                try w.writeAll("\n");
                // Add one extra newline if there was a blank line in source
                if (newline_count > 1 and rendered_any) {
                    try w.writeAll("\n");
                }
                try self.writeIndent(w);
            }
            try self.renderNode(child, w);
            last_content_end = child.endByte();
            rendered_any = true;
        } else {
            try self.renderNode(child, w);
            last_content_end = child.endByte();
            rendered_any = true;
        }
    }

    if (is_vertical and rendered_any) {
        self.indent_level -= 1;
        try w.writeAll("\n");
        try self.writeIndent(w);
        self.suppress_leading_space = true; // End tag starts on new line
    } else if (is_vertical) {
        self.indent_level -= 1;
    }

    // Render end tag
    if (end_tag_node) |et| {
        try renderEndTag(self, et, w);
    }
}

/// Render self-closing element: <Tag attr="value" />
fn renderSelfClosingElement(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    try w.writeAll("<");

    // Tag name
    const tag_name_node = node.childByFieldName("name");
    if (tag_name_node) |name_node| {
        const tag_name_text = try self.ast.getNodeText(name_node);
        try w.writeAll(tag_name_text);
    }

    // Attributes
    var multiline_close = false;
    try renderAttributesFromNode(self, node, w, &multiline_close);

    if (multiline_close) {
        try w.writeAll("\n");
        try self.writeIndent(w);
        try w.writeAll("/>");
    } else {
        try w.writeAll(" />");
    }
}

/// Render start tag: <tag attrs>
fn renderStartTag(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    try w.writeAll("<");

    // Tag name
    const tag_name_node = node.childByFieldName("name");
    if (tag_name_node) |name_node| {
        const tag_name_text = try self.ast.getNodeText(name_node);
        try w.writeAll(tag_name_text);
    }

    // Attributes
    var multiline_close = false;
    try renderAttributesFromNode(self, node, w, &multiline_close);

    if (multiline_close) {
        try w.writeAll("\n");
        try self.writeIndent(w);
        try w.writeAll(">");
    } else {
        try w.writeAll(">");
    }
}

/// Render end tag: </tag>
fn renderEndTag(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    try w.writeAll("</");

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        if (child_kind == .zx_tag_name) {
            const tag_name = try self.ast.getNodeText(child);
            try w.writeAll(tag_name);
            break;
        }
    }

    try w.writeAll(">");
}

/// Render text content
/// Collapses multiple consecutive whitespace to a single space while
/// preserving leading/trailing single spaces (for inline text with expressions)
fn renderText(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte >= end_byte or end_byte > self.ast.source.len) return;

    const text = self.ast.source[start_byte..end_byte];
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);

    if (trimmed.len == 0) {
        // If text is only spaces (no newlines/tabs), collapse to single space
        // If it contains newlines or tabs, skip it (layout whitespace)
        const has_newline_or_tab = std.mem.indexOfAny(u8, text, "\n\r\t") != null;
        if (!has_newline_or_tab and text.len > 0 and !self.suppress_leading_space) try w.writeAll(" ");
        self.suppress_leading_space = false;
        return;
    }

    // Calculate leading whitespace length using pointer arithmetic
    const leading_ws_len = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
    const leading_ws = text[0..leading_ws_len];
    const has_leading_ws = leading_ws_len > 0;

    // Determine if we should print a space
    var should_print_space = false;
    if (has_leading_ws) {
        if (self.suppress_leading_space) {
            // If we are at the start of a line, check if the whitespace is just indentation
            // or if it contains explicit spaces beyond the expected indentation.

            // Find the last newline in leading whitespace
            const last_nl = std.mem.lastIndexOfScalar(u8, leading_ws, '\n');

            var spaces_after_nl: usize = 0;
            if (last_nl) |nl_idx| {
                spaces_after_nl = leading_ws.len - nl_idx - 1;
            } else {
                spaces_after_nl = leading_ws.len;
            }

            const expected_indent = self.indent_level * 4;

            // If we have more spaces than expected indentation, preserve one space
            if (spaces_after_nl > expected_indent) {
                should_print_space = true;
            }
        } else {
            // Normal case: collapse whitespace to a single space
            should_print_space = true;
        }
    }

    // If we have leading whitespace but decided NOT to print a space because of suppression/newlines,
    // we should check if the trimmed content itself starts with something that might need separation
    // if it was inline. But here we are handling text node boundaries.

    // Write leading space if needed
    if (should_print_space) {
        try w.writeAll(" ");
    }
    self.suppress_leading_space = false;

    // Write the trimmed content (no internal whitespace normalization for now)
    try w.writeAll(trimmed);

    // Write trailing space only if there was trailing whitespace that is not a newline
    // (newlines are layout whitespace handled by the caller, spaces are inline content)
    const trailing_start = @intFromPtr(trimmed.ptr) + trimmed.len - @intFromPtr(text.ptr);
    const trailing_ws = text[trailing_start..];
    // Only preserve trailing space if it's spaces/tabs without newlines before the first newline
    const has_trailing_space = blk: {
        for (trailing_ws) |c| {
            if (c == ' ' or c == '\t') continue;
            // Hit a newline or other non-space - no trailing space to preserve
            break :blk false;
        }
        // If we get here, all trailing whitespace is spaces/tabs (no newlines)
        break :blk trailing_ws.len > 0;
    };
    if (has_trailing_space) {
        try w.writeAll(" ");
    }
}

/// Render template string: `text {expr} more text`
/// Template strings are rendered as-is from source, preserving their format
fn renderTemplateString(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte >= end_byte or end_byte > self.ast.source.len) return;

    // Write the template string exactly as it appears in source
    try w.writeAll(self.ast.source[start_byte..end_byte]);
}

/// Render comment: // ...
/// Comments are rendered trimmed of leading whitespace since indentation is handled by the caller
fn renderComment(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte >= end_byte or end_byte > self.ast.source.len) return;

    const comment_text = self.ast.source[start_byte..end_byte];
    // Trim leading whitespace (indentation is handled separately)
    const trimmed = std.mem.trimStart(u8, comment_text, &std.ascii.whitespace);
    try w.writeAll(trimmed);
}

fn countNewlines(source: []const u8, start: usize, end: usize) usize {
    if (start >= end or end > source.len) return 0;
    const text = source[start..end];
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            count += 1;
            if (count > 1) return count;
        }
    }
    return count;
}

/// Check if a child node has meaningful (non-whitespace) content
fn hasMeaningfulContent(self: *Render, node: ts.Node) bool {
    const child_count = node.childCount();
    if (child_count == 0) return false;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        if (child_kind == .zx_text) {
            const text = self.ast.getNodeText(child) catch continue;
            const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);

            if (trimmed.len > 0) {
                return true;
            } else if (text.len == 1 and text[0] == ' ') {
                return true;
            }
        } else {
            return true;
        }
    }
    return false;
}

/// Check if a text node contains only inline spaces (no newlines or tabs)
fn hasInlineSpacesOnly(self: *Render, node: ts.Node) bool {
    const text = self.ast.getNodeText(node) catch return false;
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len > 0) return false; // Has content, not spaces-only

    // Check if text contains newlines or tabs (vertical/layout spaces)
    const has_newline_or_tab = std.mem.indexOfAny(u8, text, "\n\r\t") != null;
    return !has_newline_or_tab and text.len > 0;
}

/// Render zx_child node
fn renderChild(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    try renderChildInner(self, node, w, false);
}

/// Render zx_child node with option to preserve inline spaces
fn renderChildInner(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
    preserve_inline_spaces: bool,
) !void {
    const child_count = node.childCount();
    if (child_count == 0) return;

    // Check if meaningful, with option to preserve inline spaces
    const is_meaningful = hasMeaningfulContent(self, node) or
        (preserve_inline_spaces and hasInlineSpacesOnly(self, node));
    if (!is_meaningful) return;

    // Render children
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try self.renderNode(child, w);
    }
}

/// Render expression block: {expr} or control flow
fn renderExpressionBlock(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    const child_count = node.childCount();

    // Check for control flow expressions
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        switch (child_kind) {
            .if_expression => {
                try renderIfExpression(self, child, w);
                return;
            },
            .for_expression => {
                try renderForExpression(self, child, w);
                return;
            },
            .while_expression => {
                try renderWhileExpression(self, child, w);
                return;
            },
            .switch_expression => {
                try renderSwitchExpression(self, child, w);
                return;
            },
            else => {},
        }
    }

    // Simple expression - render source as-is (keeps original braces and format)
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte < end_byte and end_byte <= self.ast.source.len) {
        const text = self.ast.source[start_byte..end_byte];
        // Normalize whitespace in simple expressions
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        try w.writeAll(trimmed);
    }
}

/// Render if expression: {if (cond) |payload| (<then>) else |else_payload| (<else>)}
/// Supports payload captures and else-if chains
fn renderIfExpression(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var then_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;
    var last_token_before_then: ?ts.Node = null;

    const child_count = node.childCount();
    var in_condition = false;
    var in_then = false;
    var in_else = false;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "if")) {
            in_condition = true;
        } else if (std.mem.eql(u8, child_type, "(") and in_condition) {
            // Start of condition
        } else if (std.mem.eql(u8, child_type, ")") and in_condition) {
            in_condition = false;
            in_then = true;
            last_token_before_then = child;
        } else if (std.mem.eql(u8, child_type, "else")) {
            in_then = false;
            in_else = true;
        } else if (in_condition and condition_node == null) {
            condition_node = child;
        } else if (in_then and child_kind == .payload) {
            // Capture payload like |un|
            payload_node = child;
            last_token_before_then = child;
        } else if (in_then and then_node == null) {
            then_node = child;
        } else if (in_else and child_kind == .payload) {
            // Capture else payload like |err|
            else_payload_node = child;
        } else if (in_else and else_node == null) {
            else_node = child;
        }
    }

    // Determine if branches should be multiline based on preceding newline before first branch
    const is_multiline = blk: {
        if (then_node) |then_b| {
            // Check for newline between last token before then and the then branch
            const prev_end = if (last_token_before_then) |t| t.endByte() else node.startByte();
            const then_start = then_b.startByte();
            if (prev_end < then_start and then_start <= self.ast.source.len) {
                const between = self.ast.source[prev_end..then_start];
                if (std.mem.indexOf(u8, between, "\n") != null) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };

    try w.writeAll("{if ");

    // Condition
    if (condition_node) |cond| {
        const cond_text = try self.ast.getNodeText(cond);
        const trimmed = std.mem.trim(u8, cond_text, &std.ascii.whitespace);
        if (trimmed.len > 0 and trimmed[0] != '(') {
            try w.writeAll("(");
            try w.writeAll(trimmed);
            try w.writeAll(")");
        } else {
            try w.writeAll(trimmed);
        }
    }

    try w.writeAll(" ");

    // Payload (e.g., |un|)
    if (payload_node) |payload| {
        const payload_text = try self.ast.getNodeText(payload);
        try w.writeAll(payload_text);
        try w.writeAll(" ");
    }

    self.indent_level -= 1;
    // Then branch
    if (then_node) |then_b| {
        try renderBranchWithMultiline(self, then_b, w, is_multiline);
    }

    // Else branch
    if (else_node) |else_b| {
        if (is_multiline) {
            try w.writeAll("\n");
            try self.writeIndent(w);
            try w.writeAll("else ");
        } else {
            try w.writeAll(" else ");
        }
        // Else payload (e.g., |err|)
        if (else_payload_node) |else_payload| {
            const else_payload_text = try self.ast.getNodeText(else_payload);
            try w.writeAll(else_payload_text);
            try w.writeAll(" ");
        }
        try renderBranchWithMultiline(self, else_b, w, is_multiline);
    }

    try w.writeAll("}");
    self.indent_level += 1;
}

/// Helper to render if/else branches consistently
/// Handles else-if chains by recursively calling renderIfExpression
fn renderBranch(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    try renderBranchWithMultiline(self, node, w, false);
}

/// Helper to render if/else branches with explicit multiline control
/// When force_multiline is true, branches will be formatted on separate lines
fn renderBranchWithMultiline(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
    force_multiline: bool,
) anyerror!void {
    const node_kind = NodeKind.fromNode(node);
    switch (node_kind) {
        .zx_block => {
            try renderBlockInlineWithMultiline(self, node, w, force_multiline);
        },
        .if_expression => {
            // Handle else-if chains - render without outer braces
            try renderIfExpressionInnerWithMultiline(self, node, w, force_multiline);
        },
        .parenthesized_expression => {
            try w.writeAll(try self.ast.getNodeText(node));
        },
        else => {
            try w.writeAll(try self.ast.getNodeText(node));
        },
    }
}

/// Render if expression without outer braces (for else-if chains)
fn renderIfExpressionInner(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    try renderIfExpressionInnerWithMultiline(self, node, w, false);
}

/// Render if expression without outer braces with explicit multiline control
fn renderIfExpressionInnerWithMultiline(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
    force_multiline: bool,
) anyerror!void {
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var then_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    const child_count = node.childCount();
    var in_condition = false;
    var in_then = false;
    var in_else = false;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "if")) {
            in_condition = true;
        } else if (std.mem.eql(u8, child_type, "(") and in_condition) {
            // Start of condition
        } else if (std.mem.eql(u8, child_type, ")") and in_condition) {
            in_condition = false;
            in_then = true;
        } else if (std.mem.eql(u8, child_type, "else")) {
            in_then = false;
            in_else = true;
        } else if (in_condition and condition_node == null) {
            condition_node = child;
        } else if (in_then and child_kind == .payload) {
            payload_node = child;
        } else if (in_then and then_node == null) {
            then_node = child;
        } else if (in_else and child_kind == .payload) {
            // Capture else payload like |err|
            else_payload_node = child;
        } else if (in_else and else_node == null) {
            else_node = child;
        }
    }

    try w.writeAll("if ");

    // Condition
    if (condition_node) |cond| {
        const cond_text = try self.ast.getNodeText(cond);
        const trimmed = std.mem.trim(u8, cond_text, &std.ascii.whitespace);
        if (trimmed.len > 0 and trimmed[0] != '(') {
            try w.writeAll("(");
            try w.writeAll(trimmed);
            try w.writeAll(")");
        } else {
            try w.writeAll(trimmed);
        }
    }

    try w.writeAll(" ");

    // Payload
    if (payload_node) |payload| {
        const payload_text = try self.ast.getNodeText(payload);
        try w.writeAll(payload_text);
        try w.writeAll(" ");
    }

    // Then branch
    if (then_node) |then_b| {
        try renderBranchWithMultiline(self, then_b, w, force_multiline);
    }

    // Else branch
    if (else_node) |else_b| {
        if (force_multiline) {
            try w.writeAll("\n");
            try self.writeIndent(w);
            try w.writeAll("else ");
        } else {
            try w.writeAll(" else ");
        }
        // Else payload (e.g., |err|)
        if (else_payload_node) |else_payload| {
            const else_payload_text = try self.ast.getNodeText(else_payload);
            try w.writeAll(else_payload_text);
            try w.writeAll(" ");
        }
        try renderBranchWithMultiline(self, else_b, w, force_multiline);
    }
}

/// Render for expression: {for (items) |item| (<body>)}
fn renderForExpression(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    var iterables = std.ArrayList(ts.Node).empty;
    defer iterables.deinit(self.allocator);
    var payload_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var seen_for = false;
    var seen_payload = false;
    var in_parens = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "for")) {
            seen_for = true;
            continue;
        }

        if (child_kind == .payload) {
            payload_node = child;
            seen_payload = true;
            continue;
        }

        if (seen_payload) {
            if (child_kind == .zx_block or child_kind == .parenthesized_expression) {
                body_node = child;
                break;
            }
            continue;
        }

        if (seen_for) {
            if (std.mem.eql(u8, child_type, "(")) {
                in_parens = true;
                continue;
            }
            if (std.mem.eql(u8, child_type, ")")) {
                in_parens = false;
                continue;
            }
            if (in_parens) {
                if (std.mem.eql(u8, child_type, ",")) continue;
                try iterables.append(self.allocator, child);
            }
        }
    }

    try w.writeAll("{for (");
    for (iterables.items, 0..) |it, it_idx| {
        if (it_idx > 0) try w.writeAll(", ");
        try w.writeAll(try self.ast.getNodeText(it));
    }
    try w.writeAll(") ");

    if (payload_node) |pay| {
        try w.writeAll(try self.ast.getNodeText(pay));
    }

    try w.writeAll(" ");

    if (body_node) |body| {
        const body_kind = NodeKind.fromNode(body);
        self.indent_level -= 1;
        switch (body_kind) {
            .zx_block => {
                try renderBlockInline(self, body, w);
            },
            .parenthesized_expression => {
                // Render parenthesized expression as (content) - check for control flow inside
                try renderParenthesizedBody(self, body, w);
            },
            .if_expression => {
                // If the body is a direct if_expression, render it without extra braces
                try renderIfExpressionInner(self, body, w);
            },
            .for_expression => {
                try renderForExpressionInner(self, body, w);
            },
            .while_expression => {
                try renderWhileExpressionInner(self, body, w);
            },
            .switch_expression => {
                try renderSwitchExpressionInner(self, body, w);
            },
            else => {},
        }
        self.indent_level += 1;
    }

    try w.writeAll("}");
}

/// Render a parenthesized expression body as (...) - handles control flow inside
fn renderParenthesizedBody(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    const child_count = node.childCount();
    var content_node: ?ts.Node = null;
    var is_control_flow = false;

    // Find the content inside the parentheses
    var fallback_node: ?ts.Node = null;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .if_expression, .for_expression, .while_expression, .switch_expression => {
                content_node = child;
                is_control_flow = true;
                break;
            },
            .zx_element, .zx_self_closing_element, .zx_fragment => {
                content_node = child;
                break;
            },
            else => {
                // Skip the surrounding parentheses (anonymous "(" / ")" nodes)
                // and remember the first real expression as a fallback.
                if (fallback_node == null and child.isNamed()) {
                    fallback_node = child;
                }
            },
        }
    }

    // No control-flow/HTML body found: render the plain expression as is
    if (content_node == null) content_node = fallback_node;

    // Check for multiline
    const content_start = if (content_node) |c| c.startByte() else node.startByte();
    const content_end = if (content_node) |c| c.endByte() else node.endByte();
    const block_start = node.startByte();
    const block_end = node.endByte();

    const has_preceding_newline = if (block_start < content_start and content_start <= self.ast.source.len)
        std.mem.indexOf(u8, self.ast.source[block_start..content_start], "\n") != null
    else
        false;

    const has_trailing_newline = if (content_end < block_end and block_end <= self.ast.source.len)
        std.mem.indexOf(u8, self.ast.source[content_end..block_end], "\n") != null
    else
        false;

    const is_multiline = has_preceding_newline or has_trailing_newline;

    try w.writeAll("(");

    if (content_node) |content| {
        const content_kind = NodeKind.fromNode(content);

        if (is_multiline) {
            try w.writeAll("\n");
            self.indent_level += 2;
            try self.writeIndent(w);
        }

        // For control flow expressions, we need to adjust indent before calling
        // because their branch renderers expect a pre-decremented level
        if (is_control_flow) {
            self.indent_level -= 1;
        }

        switch (content_kind) {
            .if_expression => try renderIfExpressionInner(self, content, w),
            .for_expression => try renderForExpressionInner(self, content, w),
            .while_expression => try renderWhileExpressionInner(self, content, w),
            .switch_expression => try renderSwitchExpressionInner(self, content, w),
            .zx_element => try renderElement(self, content, w),
            .zx_self_closing_element => try renderSelfClosingElement(self, content, w),
            .zx_fragment => try renderFragment(self, content, w),
            else => try self.renderNode(content, w),
        }

        if (is_control_flow) {
            self.indent_level += 1;
        }

        if (is_multiline) {
            self.indent_level -= 2;
            try w.writeAll("\n");
            self.indent_level += 1;
            try self.writeIndent(w);
            self.indent_level -= 1;
        }
    }

    try w.writeAll(")");
}

/// Render while expression: {while (cond) |payload| : (continue_expr) (<body>) else |err| (<else_body>)}
fn renderWhileExpression(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var continue_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var in_else = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        condition_node = node.childByFieldName("condition");

        if (std.mem.eql(u8, child_type, "else")) {
            in_else = true;
            continue;
        }

        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .payload => {
                if (in_else) {
                    else_payload_node = child;
                } else if (body_node == null) {
                    payload_node = child;
                }
            },
            .assignment_expression => {
                continue_node = child;
            },
            .zx_block => {
                if (in_else) {
                    else_node = child;
                } else {
                    body_node = child;
                }
            },
            else => {},
        }
    }

    try w.writeAll("{while (");

    // Condition
    if (condition_node) |cond| {
        const cond_text = try self.ast.getNodeText(cond);
        try w.writeAll(std.mem.trim(u8, cond_text, &std.ascii.whitespace));
    }

    try w.writeAll(")");

    // Payload (e.g., |value|)
    if (payload_node) |payload| {
        try w.writeAll(" ");
        const payload_text = try self.ast.getNodeText(payload);
        try w.writeAll(payload_text);
    }

    // Continue expression (optional)
    if (continue_node) |cont| {
        try w.writeAll(" : (");
        const cont_text = try self.ast.getNodeText(cont);
        try w.writeAll(std.mem.trim(u8, cont_text, &std.ascii.whitespace));
        try w.writeAll(")");
    }

    try w.writeAll(" ");

    // Body
    if (body_node) |body| {
        self.indent_level -= 1;
        try renderBlockInline(self, body, w);
        self.indent_level += 1;
    }

    // Else branch
    if (else_node) |else_b| {
        try w.writeAll(" else ");
        // Else payload (e.g., |err|)
        if (else_payload_node) |else_payload| {
            const else_payload_text = try self.ast.getNodeText(else_payload);
            try w.writeAll(else_payload_text);
            try w.writeAll(" ");
        }
        self.indent_level -= 1;
        try renderBlockInline(self, else_b, w);
        self.indent_level += 1;
    }

    try w.writeAll("}");
}

/// Render switch expression: {switch (val) { .case => (<body>), ... }}
fn renderSwitchExpression(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    var switch_expr_node: ?ts.Node = null;
    var cases = std.ArrayList(struct { pattern: []const u8, payload: ?[]const u8, value: ts.Node }).empty;
    defer cases.deinit(self.allocator);

    const child_count = node.childCount();
    var i: u32 = 0;
    var found_switch = false;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "switch")) {
            found_switch = true;
            continue;
        }

        // Skip delimiters
        if (std.mem.eql(u8, child_type, "(") or
            std.mem.eql(u8, child_type, ")") or
            std.mem.eql(u8, child_type, "{") or
            std.mem.eql(u8, child_type, "}"))
        {
            continue;
        }

        if (found_switch and switch_expr_node == null and child_kind != .switch_case) {
            switch_expr_node = child;
            continue;
        }

        if (child_kind == .switch_case) {
            // Parse switch case: pattern [payload] '=>' value
            var first_pattern: ?ts.Node = null;
            var last_pattern: ?ts.Node = null;
            var payload_node: ?ts.Node = null;
            var value_node: ?ts.Node = null;
            var seen_arrow = false;

            const case_child_count = child.childCount();
            var j: u32 = 0;
            while (j < case_child_count) : (j += 1) {
                const case_child = child.child(j) orelse continue;
                const case_child_kind = case_child.kind();

                if (std.mem.eql(u8, case_child_kind, "=>")) {
                    seen_arrow = true;
                } else if (std.mem.eql(u8, case_child_kind, "payload")) {
                    payload_node = case_child;
                } else if (!seen_arrow) {
                    if (!std.mem.eql(u8, case_child_kind, ",")) {
                        if (first_pattern == null) first_pattern = case_child;
                        last_pattern = case_child;
                    }
                } else if (seen_arrow and value_node == null) {
                    value_node = case_child;
                }
            }

            if (first_pattern != null and last_pattern != null) {
                const start = first_pattern.?.startByte();
                const end = last_pattern.?.endByte();
                const pattern_text = self.ast.source[start..end];
                const payload_text = if (payload_node) |pl| try self.ast.getNodeText(pl) else null;
                if (value_node) |v| {
                    try cases.append(self.allocator, .{
                        .pattern = pattern_text,
                        .payload = payload_text,
                        .value = v,
                    });
                }
            }
        }
    }

    try w.writeAll("{switch (");

    if (switch_expr_node) |expr| {
        const expr_text = try self.ast.getNodeText(expr);
        try w.writeAll(expr_text);
    }

    try w.writeAll(") {");

    for (cases.items) |case| {
        try w.writeAll("\n");
        self.indent_level += 1;
        try self.writeIndent(w);
        self.indent_level -= 1;
        try w.writeAll(std.mem.trim(u8, case.pattern, &std.ascii.whitespace));
        try w.writeAll(" => ");
        if (case.payload) |payload| {
            try w.writeAll(payload);
            try w.writeAll(" ");
        }
        const is_nested_switch = NodeKind.fromNode(case.value) == .switch_expression;

        // For nested switches, keep indent level elevated
        if (is_nested_switch) self.indent_level += 1;
        try renderCaseValue(self, case.value, w);
        if (is_nested_switch) self.indent_level -= 1;

        try w.writeAll(",");
    }

    try w.writeAll("\n");
    try self.writeIndent(w);
    try w.writeAll("}}");
}

/// Render switch case value, handling parenthesized expressions with nested control flow/zx
fn renderCaseValue(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    const kind = NodeKind.fromNode(node);

    switch (kind) {
        .zx_block => {
            try renderBlockInline(self, node, w);
        },
        .if_expression => {
            // Detect if branches should be multiline based on preceding newline
            const is_multiline = detectIfMultiline(self, node);
            try renderIfExpressionInnerWithMultiline(self, node, w, is_multiline);
        },
        .for_expression => {
            try renderForExpressionInner(self, node, w);
        },
        .while_expression => {
            try renderWhileExpressionInner(self, node, w);
        },
        .switch_expression => {
            try renderSwitchExpressionInner(self, node, w);
        },
        .parenthesized_expression => {
            // Check if contains control flow or zx_block
            if (findSpecialChild(node)) |child| {
                try renderCaseValue(self, child, w);
            } else {
                // Simple parenthesized expression like ("Admin")
                try w.writeAll(try self.ast.getNodeText(node));
            }
        },
        else => {
            try w.writeAll(try self.ast.getNodeText(node));
        },
    }
}

/// Detect if an if expression should be rendered multiline based on preceding newline before first branch
fn detectIfMultiline(self: *Render, node: ts.Node) bool {
    var last_token_before_then: ?ts.Node = null;
    var then_node: ?ts.Node = null;

    const child_count = node.childCount();
    var in_condition = false;
    var in_then = false;
    var in_else = false;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "if")) {
            in_condition = true;
        } else if (std.mem.eql(u8, child_type, "(") and in_condition) {
            // Start of condition
        } else if (std.mem.eql(u8, child_type, ")") and in_condition) {
            in_condition = false;
            in_then = true;
            last_token_before_then = child;
        } else if (std.mem.eql(u8, child_type, "else")) {
            in_then = false;
            in_else = true;
        } else if (in_then and child_kind == .payload) {
            last_token_before_then = child;
        } else if (in_then and then_node == null) {
            then_node = child;
        } else if (in_else and child_kind == .payload) {
            // Skip else payload, it doesn't affect multiline detection
        }
    }

    // Check for newline between last token before then and the then branch
    if (then_node) |then_b| {
        const prev_end = if (last_token_before_then) |t| t.endByte() else node.startByte();
        const then_start = then_b.startByte();
        if (prev_end < then_start and then_start <= self.ast.source.len) {
            const between = self.ast.source[prev_end..then_start];
            if (std.mem.indexOf(u8, between, "\n") != null) {
                return true;
            }
        }
    }

    return false;
}

/// Find control flow or zx_block inside a node
fn findSpecialChild(node: ts.Node) ?ts.Node {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .if_expression, .for_expression, .while_expression, .switch_expression, .zx_block => return child,
            else => {
                if (findSpecialChild(child)) |found| return found;
            },
        }
    }
    return null;
}

/// Render for expression without outer braces (for use in case values)
fn renderForExpressionInner(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    var iterables = std.ArrayList(ts.Node).empty;
    defer iterables.deinit(self.allocator);
    var payload_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var seen_for = false;
    var seen_payload = false;
    var in_parens = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "for")) {
            seen_for = true;
            continue;
        }

        if (child_kind == .payload) {
            payload_node = child;
            seen_payload = true;
            continue;
        }

        if (seen_payload) {
            if (child_kind == .zx_block or child_kind == .parenthesized_expression) {
                body_node = child;
                break;
            }
            continue;
        }

        if (seen_for) {
            if (std.mem.eql(u8, child_type, "(")) {
                in_parens = true;
                continue;
            }
            if (std.mem.eql(u8, child_type, ")")) {
                in_parens = false;
                continue;
            }
            if (in_parens) {
                if (std.mem.eql(u8, child_type, ",")) continue;
                try iterables.append(self.allocator, child);
            }
        }
    }

    try w.writeAll("for (");
    for (iterables.items, 0..) |it, it_idx| {
        if (it_idx > 0) try w.writeAll(", ");
        try w.writeAll(try self.ast.getNodeText(it));
    }
    try w.writeAll(") ");

    if (payload_node) |pay| {
        try w.writeAll(try self.ast.getNodeText(pay));
    }

    try w.writeAll(" ");

    if (body_node) |body| {
        try renderBranch(self, body, w);
    }
}

/// Render while expression without outer braces (for use in case values)
fn renderWhileExpressionInner(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var continue_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var in_else = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        condition_node = node.childByFieldName("condition");

        if (std.mem.eql(u8, child_type, "else")) {
            in_else = true;
            continue;
        }

        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .payload => {
                if (in_else) {
                    else_payload_node = child;
                } else if (body_node == null) {
                    payload_node = child;
                }
            },
            .assignment_expression => {
                continue_node = child;
            },
            .zx_block => {
                if (in_else) {
                    else_node = child;
                } else {
                    body_node = child;
                }
            },
            else => {},
        }
    }

    try w.writeAll("while (");

    if (condition_node) |cond| {
        const cond_text = try self.ast.getNodeText(cond);
        try w.writeAll(std.mem.trim(u8, cond_text, &std.ascii.whitespace));
    }

    try w.writeAll(")");

    // Payload (e.g., |value|)
    if (payload_node) |payload| {
        try w.writeAll(" ");
        const payload_text = try self.ast.getNodeText(payload);
        try w.writeAll(payload_text);
    }

    if (continue_node) |cont| {
        try w.writeAll(" : (");
        const cont_text = try self.ast.getNodeText(cont);
        try w.writeAll(std.mem.trim(u8, cont_text, &std.ascii.whitespace));
        try w.writeAll(")");
    }

    try w.writeAll(" ");

    if (body_node) |body| {
        try renderBlockInline(self, body, w);
    }

    // Else branch
    if (else_node) |else_b| {
        try w.writeAll(" else ");
        // Else payload (e.g., |err|)
        if (else_payload_node) |else_payload| {
            const else_payload_text = try self.ast.getNodeText(else_payload);
            try w.writeAll(else_payload_text);
            try w.writeAll(" ");
        }
        try renderBlockInline(self, else_b, w);
    }
}

/// Render switch expression without outer braces (for use in case values)
fn renderSwitchExpressionInner(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) anyerror!void {
    var switch_expr_node: ?ts.Node = null;
    var cases = std.ArrayList(struct { pattern: []const u8, payload: ?[]const u8, value: ts.Node }).empty;
    defer cases.deinit(self.allocator);

    const child_count = node.childCount();
    var i: u32 = 0;
    var found_switch = false;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "switch")) {
            found_switch = true;
            continue;
        }

        if (std.mem.eql(u8, child_type, "(") or
            std.mem.eql(u8, child_type, ")") or
            std.mem.eql(u8, child_type, "{") or
            std.mem.eql(u8, child_type, "}"))
        {
            continue;
        }

        if (found_switch and switch_expr_node == null and child_kind != .switch_case) {
            switch_expr_node = child;
            continue;
        }

        if (child_kind == .switch_case) {
            // Parse switch case: pattern [payload] '=>' value
            var first_pattern: ?ts.Node = null;
            var last_pattern: ?ts.Node = null;
            var payload_node: ?ts.Node = null;
            var value_node: ?ts.Node = null;
            var seen_arrow = false;

            const case_child_count = child.childCount();
            var j: u32 = 0;
            while (j < case_child_count) : (j += 1) {
                const case_child = child.child(j) orelse continue;
                const case_child_kind = case_child.kind();

                if (std.mem.eql(u8, case_child_kind, "=>")) {
                    seen_arrow = true;
                } else if (std.mem.eql(u8, case_child_kind, "payload")) {
                    payload_node = case_child;
                } else if (!seen_arrow) {
                    if (!std.mem.eql(u8, case_child_kind, ",")) {
                        if (first_pattern == null) first_pattern = case_child;
                        last_pattern = case_child;
                    }
                } else if (seen_arrow and value_node == null) {
                    value_node = case_child;
                }
            }

            if (first_pattern != null and last_pattern != null) {
                const start = first_pattern.?.startByte();
                const end = last_pattern.?.endByte();
                const pattern_text = self.ast.source[start..end];
                const payload_text = if (payload_node) |pl| try self.ast.getNodeText(pl) else null;
                if (value_node) |v| {
                    try cases.append(self.allocator, .{
                        .pattern = pattern_text,
                        .payload = payload_text,
                        .value = v,
                    });
                }
            }
        }
    }

    try w.writeAll("switch (");

    if (switch_expr_node) |expr| {
        const expr_text = try self.ast.getNodeText(expr);
        try w.writeAll(expr_text);
    }

    try w.writeAll(") {");

    for (cases.items) |case| {
        try w.writeAll("\n");
        self.indent_level += 1;
        try self.writeIndent(w);
        self.indent_level -= 1;
        try w.writeAll(std.mem.trim(u8, case.pattern, &std.ascii.whitespace));
        try w.writeAll(" => ");
        if (case.payload) |payload| {
            try w.writeAll(payload);
            try w.writeAll(" ");
        }
        const is_nested_switch = NodeKind.fromNode(case.value) == .switch_expression;

        // For nested switches, keep indent level elevated
        if (is_nested_switch) self.indent_level += 1;
        try renderCaseValue(self, case.value, w);
        if (is_nested_switch) self.indent_level -= 1;

        try w.writeAll(",");
    }

    try w.writeAll("\n");
    try self.writeIndent(w);
    try w.writeAll("}");
}

/// Render zx_block inline (for use in control flow expressions)
fn renderBlockInline(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
) !void {
    try renderBlockInlineWithMultiline(self, node, w, false);
}

/// Render zx_block inline with explicit multiline control
/// When force_multiline is true, the block will be rendered on multiple lines
fn renderBlockInlineWithMultiline(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
    force_multiline: bool,
) anyerror!void {
    const child_count = node.childCount();
    var content_node: ?ts.Node = null;
    var content_type: enum { element, control_flow } = .element;

    // Find the main content (element or control flow expression)
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .zx_element, .zx_self_closing_element, .zx_fragment => {
                content_node = child;
                content_type = .element;
                break;
            },
            .if_expression, .for_expression, .while_expression, .switch_expression => {
                content_node = child;
                content_type = .control_flow;
                break;
            },
            else => {},
        }
    }

    try w.writeAll("(");

    if (content_node) |content| {
        const content_kind = NodeKind.fromNode(content);

        // Check if content is multiline:
        // 1. Content has newlines inside itself
        // 2. OR there's a newline between the block start and the content (preceding newline)
        // 3. OR there's a newline between the content end and the block end (trailing newline)
        // 4. OR force_multiline is set
        const content_start = content.startByte();
        const content_end = content.endByte();
        const block_start = node.startByte();
        const block_end = node.endByte();

        const content_is_multiline = if (content_start < content_end and content_end <= self.ast.source.len)
            std.mem.indexOf(u8, self.ast.source[content_start..content_end], "\n") != null
        else
            false;

        const has_preceding_newline = if (block_start < content_start and content_start <= self.ast.source.len)
            std.mem.indexOf(u8, self.ast.source[block_start..content_start], "\n") != null
        else
            false;

        const has_trailing_newline = if (content_end < block_end and block_end <= self.ast.source.len)
            std.mem.indexOf(u8, self.ast.source[content_end..block_end], "\n") != null
        else
            false;

        const is_multiline = content_is_multiline or has_preceding_newline or has_trailing_newline or force_multiline;

        if (is_multiline) {
            try w.writeAll("\n");
            self.indent_level += 2;
            try self.writeIndent(w);

            switch (content_type) {
                .element => switch (content_kind) {
                    .zx_element => try renderElement(self, content, w),
                    .zx_self_closing_element => try renderSelfClosingElement(self, content, w),
                    .zx_fragment => try renderFragment(self, content, w),
                    else => try self.renderNode(content, w),
                },
                .control_flow => switch (content_kind) {
                    .if_expression => try renderIfExpressionInner(self, content, w),
                    .for_expression => try renderForExpressionInner(self, content, w),
                    .while_expression => try renderWhileExpressionInner(self, content, w),
                    .switch_expression => try renderSwitchExpressionInner(self, content, w),
                    else => try self.renderNode(content, w),
                },
            }

            self.indent_level -= 2;
            try w.writeAll("\n");
            self.indent_level += 1;
            try self.writeIndent(w);
            try w.writeAll(")");
            self.indent_level -= 1;
        } else {
            switch (content_type) {
                .element => switch (content_kind) {
                    .zx_element => try renderElement(self, content, w),
                    .zx_self_closing_element => try renderSelfClosingElement(self, content, w),
                    .zx_fragment => try renderFragment(self, content, w),
                    else => try self.renderNode(content, w),
                },
                .control_flow => switch (content_kind) {
                    .if_expression => try renderIfExpressionInner(self, content, w),
                    .for_expression => try renderForExpressionInner(self, content, w),
                    .while_expression => try renderWhileExpressionInner(self, content, w),
                    .switch_expression => try renderSwitchExpressionInner(self, content, w),
                    else => try self.renderNode(content, w),
                },
            }
            try w.writeAll(")");
        }
    } else {
        try w.writeAll(")");
    }
}

/// Render attributes from a node (start tag or self-closing element)
/// If the first attribute in the source starts on a different line than the tag name,
/// all attributes are formatted one-per-line with proper indentation.
fn renderAttributesFromNode(
    self: *Render,
    node: ts.Node,
    w: *std.Io.Writer,
    multiline_close: *bool,
) !void {
    const child_count = node.childCount();

    // Detect multiline: check if the first attribute starts on a different line than the tag name
    const tag_name_node = node.childByFieldName("name");
    const tag_line = if (tag_name_node) |n| n.startPoint().row else 0;
    var is_multiline = false;
    {
        var j: u32 = 0;
        while (j < child_count) : (j += 1) {
            const child = node.child(j) orelse continue;
            if (NodeKind.fromNode(child) == .zx_attribute) {
                is_multiline = child.startPoint().row != tag_line;
                break;
            }
        }
    }

    multiline_close.* = is_multiline;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        if (child_kind == .zx_attribute) {
            if (is_multiline) {
                try w.writeAll("\n");
                // Indent one level deeper than the tag
                for (0..(self.indent_level + 1) * 4) |_| try w.writeAll(" ");
            } else {
                try w.writeAll(" ");
            }

            // Get the actual attribute (first child)
            const attr_child = child.child(0) orelse continue;
            const attr_kind = NodeKind.fromNode(attr_child);

            switch (attr_kind) {
                .zx_builtin_attribute, .zx_regular_attribute => {
                    // Name
                    const name_node = attr_child.childByFieldName("name");
                    if (name_node) |n| {
                        const name_text = try self.ast.getNodeText(n);
                        try w.writeAll(name_text);
                    }

                    // Value (optional)
                    const value_node = attr_child.childByFieldName("value");
                    if (value_node) |v| {
                        try w.writeAll("=");
                        // Write the value as-is from source
                        const v_start = v.startByte();
                        const v_end = v.endByte();
                        if (v_start < v_end and v_end <= self.ast.source.len) {
                            try w.writeAll(self.ast.source[v_start..v_end]);
                        }
                    }
                },
                .zx_shorthand_attribute => {
                    // Shorthand: {name} renders as {name} (preserving shorthand form)
                    const c_start = attr_child.startByte();
                    const c_end = attr_child.endByte();
                    if (c_start < c_end and c_end <= self.ast.source.len) {
                        try w.writeAll(self.ast.source[c_start..c_end]);
                    }
                },
                .zx_builtin_shorthand_attribute => {
                    // Builtin shorthand: @{name} renders as @{name} (preserving shorthand form)
                    const c_start = attr_child.startByte();
                    const c_end = attr_child.endByte();
                    if (c_start < c_end and c_end <= self.ast.source.len) {
                        try w.writeAll(self.ast.source[c_start..c_end]);
                    }
                },
                .zx_spread_attribute => {
                    // Spread: {..expr} renders as {..expr} (preserving spread form)
                    const c_start = attr_child.startByte();
                    const c_end = attr_child.endByte();
                    if (c_start < c_end and c_end <= self.ast.source.len) {
                        try w.writeAll(self.ast.source[c_start..c_end]);
                    }
                },
                else => {
                    // Fallback - render source
                    const c_start = child.startByte();
                    const c_end = child.endByte();
                    if (c_start < c_end and c_end <= self.ast.source.len) {
                        try w.writeAll(self.ast.source[c_start..c_end]);
                    }
                },
            }
        }
    }
}
