const std = @import("std");
const lang = @import("lang");
const lsp = @import("lsp");
const docs = @import("../data/elements.zig");
const html_hover = @import("hover.zig");

const Parse = lang.Parse;
const NodeKind = Parse.NodeKind;
const builtins = lang.Ast.check.builtins;

const CompletionItem = lsp.types.completion.Item;
const CompletionResult = lsp.types.completion.Result;

const ContextKind = enum { tag_name, attribute };

const Context = struct {
    kind: ContextKind,
    prefix: []const u8 = "",
    tag: []const u8 = "",
    closing: bool = false,
    has_at: bool = false,
};

/// Return HTML/ZX completion items for `offset` in `source`, or null when the
/// cursor is outside ZX markup (so the caller can fall back to ZLS).
pub fn complete(
    arena: std.mem.Allocator,
    source: []const u8,
    offset: u32,
) !?CompletionResult {
    if (offset > source.len) return null;
    const ctx = detectContext(arena, source, offset) orelse return null;

    var items: std.ArrayList(CompletionItem) = .empty;

    switch (ctx.kind) {
        .tag_name => try appendTagCompletions(arena, &items, ctx.prefix, ctx.closing),
        .attribute => {
            try appendBuiltinCompletions(arena, &items, ctx.prefix, ctx.has_at);
            try appendAttributeCompletions(arena, &items, ctx.tag, ctx.prefix, ctx.has_at);
        },
    }

    if (items.items.len == 0) return null;
    return .{
        .completion_list = .{
            .isIncomplete = false,
            .items = try items.toOwnedSlice(arena),
        },
    };
}

fn detectContext(arena: std.mem.Allocator, source: []const u8, offset: u32) ?Context {
    if (detectFromParse(arena, source, offset)) |ctx| return ctx;
    return detectFromText(source, offset, false);
}

fn detectFromParse(arena: std.mem.Allocator, source: []const u8, offset: u32) ?Context {
    var parse = Parse.parse(arena, source, .zx) catch return null;
    defer parse.deinit(arena);

    const root = parse.tree.rootNode();
    const in_markup = parseSaysMarkupLt(root, source, offset);
    const node = root.descendantForByteRange(offset, offset) orelse {
        return detectFromText(source, offset, in_markup);
    };

    if (!inZxMarkup(node)) return detectFromText(source, offset, in_markup);

    var current: ?@TypeOf(node) = node;
    while (current) |n| : (current = n.parent()) {
        switch (NodeKind.fromNode(n)) {
            .zx_tag_name => {
                const text = nodeText(n, source);
                return .{
                    .kind = .tag_name,
                    .prefix = prefixOf(text, n.startByte(), offset),
                    .closing = isClosingTag(source, n.startByte()),
                };
            },
            .zx_attribute_name, .zx_builtin_name => {
                const text = nodeText(n, source);
                const has_at = text.len > 0 and text[0] == '@';
                const prefix = if (has_at)
                    prefixOf(text[1..], n.startByte() + 1, offset)
                else
                    prefixOf(text, n.startByte(), offset);
                return .{
                    .kind = .attribute,
                    .prefix = prefix,
                    .tag = enclosingTagName(n, source) orelse "",
                    .has_at = has_at,
                };
            },
            .zx_start_tag, .zx_self_closing_element => {
                const tag = blk: {
                    const name_node = n.childByFieldName("name") orelse break :blk "";
                    break :blk nodeText(name_node, source);
                };
                const line_ctx = attributePrefixAt(source, offset);
                return .{
                    .kind = .attribute,
                    .prefix = line_ctx.prefix,
                    .tag = tag,
                    .has_at = line_ctx.has_at,
                };
            },
            else => {},
        }
    }

    return detectFromText(source, offset, in_markup);
}

/// True when the parser places the `<` nearest before `offset` inside ZX
/// markup. A tag that is still being typed lands under an `ERROR` node, so the
/// tag itself carries no context, but the token *before* the `<` is still
/// classified - and that is enough to tell markup apart from a Zig `<`.
fn parseSaysMarkupLt(root: anytype, source: []const u8, offset: u32) bool {
    if (offset == 0 or offset > source.len) return false;
    const lt = std.mem.lastIndexOfScalar(u8, source[0..offset], '<') orelse return false;
    if (lt == 0) return false;
    const prev = root.descendantForByteRange(@intCast(lt - 1), @intCast(lt)) orelse return false;
    return inZxMarkup(prev);
}

fn detectFromText(source: []const u8, offset: u32, in_markup: bool) ?Context {
    if (offset == 0) return null;
    const before = source[0..offset];

    const lt = std.mem.lastIndexOfScalar(u8, before, '<') orelse return null;
    const after_lt = before[lt + 1 ..];
    if (!in_markup and !looksLikeMarkupLt(source, lt)) return null;
    if (std.mem.indexOfScalar(u8, after_lt, '>') != null) return null;

    const closing = after_lt.len > 0 and after_lt[0] == '/';
    const name_start: usize = if (closing) 1 else 0;
    const rest = after_lt[name_start..];

    if (isTagNameOnly(rest)) {
        return .{ .kind = .tag_name, .prefix = rest, .closing = closing };
    }

    const tag_end = indexOfTagNameEnd(rest) orelse return null;
    const tag = rest[0..tag_end];
    const attr_part = rest[tag_end..];
    if (attr_part.len == 0 or !std.ascii.isWhitespace(attr_part[0])) return null;

    const line_ctx = attributePrefixFrom(attr_part);
    return .{
        .kind = .attribute,
        .prefix = line_ctx.prefix,
        .tag = tag,
        .has_at = line_ctx.has_at,
    };
}

/// Text-only fallback for when the parse tree cannot classify the `<`:
/// markup children always start right after `(` or a preceding `>`.
fn looksLikeMarkupLt(source: []const u8, lt: usize) bool {
    var i = lt;
    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (std.ascii.isWhitespace(c)) continue;
        if (c == '(' or c == '>') return true;
        break;
    }
    return false;
}

fn isTagNameOnly(rest: []const u8) bool {
    for (rest) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn indexOfTagNameEnd(rest: []const u8) ?usize {
    if (rest.len == 0) return null;
    if (!(std.ascii.isAlphabetic(rest[0]) or rest[0] == '_')) return null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') continue;
        return i;
    }
    return null;
}

const AttrPrefix = struct { prefix: []const u8, has_at: bool };

fn attributePrefixAt(source: []const u8, offset: u32) AttrPrefix {
    return attributePrefixFrom(source[0..offset]);
}

fn attributePrefixFrom(text: []const u8) AttrPrefix {
    var i = text.len;
    while (i > 0 and !std.ascii.isWhitespace(text[i - 1]) and text[i - 1] != '<' and text[i - 1] != '/') : (i -= 1) {}
    const token = text[i..];
    if (token.len > 0 and token[0] == '@') {
        return .{ .prefix = token[1..], .has_at = true };
    }
    return .{ .prefix = token, .has_at = false };
}

fn appendTagCompletions(
    arena: std.mem.Allocator,
    items: *std.ArrayList(CompletionItem),
    prefix: []const u8,
    closing: bool,
) !void {
    const elements = lang.Ast.check.elements;

    // Typing an uppercase prefix means a ZX component name, not an HTML tag.
    if (prefix.len > 0 and std.ascii.isUpper(prefix[0])) return;

    if (prefixMatches(prefix, "fragment")) {
        const insert: []const u8 = if (closing) "fragment" else "fragment>$0</fragment>";
        try items.append(arena, .{
            .label = "fragment",
            .kind = .Class,
            .detail = "ZX fragment",
            .insertText = insert,
            .insertTextFormat = if (closing) .PlainText else .Snippet,
            .filterText = "fragment",
            .sortText = "0fragment",
            .documentation = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = "**`<fragment>`** - Ziex fragment element (renders children with no wrapper).",
                },
            },
        });
    }

    for (docs.elementNames()) |name| {
        if (!prefixMatches(prefix, name)) continue;
        const doc = docs.element(name);
        const desc = if (doc) |d| truncate(d.description, 120) else "";
        const insert: []const u8 = if (closing)
            name
        else if (elements.isVoid(name))
            try arena.print("{s} />", .{name})
        else
            try arena.print("{s}>$0</{s}>", .{ name, name });
        try items.append(arena, .{
            .label = name,
            .kind = .Class,
            .detail = "HTML element",
            .insertText = insert,
            .insertTextFormat = if (closing or elements.isVoid(name)) .PlainText else .Snippet,
            .filterText = name,
            .sortText = try arena.print("1{s}", .{name}),
            .documentation = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = try arena.print("**`<{s}>`**\n\n{s}", .{ name, desc }),
                },
            },
        });
    }
}

fn appendAttributeCompletions(
    arena: std.mem.Allocator,
    items: *std.ArrayList(CompletionItem),
    tag: []const u8,
    prefix: []const u8,
    has_at: bool,
) !void {
    if (has_at) return;
    // Custom / ZX components don't take standard HTML attributes.
    if (lang.Ast.check.elements.isCustomOrComponent(tag)) return;

    var seen: std.StringHashMapUnmanaged(void) = .empty;

    if (tag.len > 0) {
        for (docs.elementAttributeKeys()) |key| {
            if (!std.mem.startsWith(u8, key, tag)) continue;
            if (key.len <= tag.len or key[tag.len] != '\t') continue;
            const attr = key[tag.len + 1 ..];
            if (!prefixMatches(prefix, attr)) continue;
            if ((try seen.getOrPut(arena, attr)).found_existing) continue;
            try items.append(arena, try makeAttrItem(arena, attr, tag, "1"));
        }
    }

    for (docs.globalAttributeNames()) |attr| {
        if (!prefixMatches(prefix, attr)) continue;
        if ((try seen.getOrPut(arena, attr)).found_existing) continue;
        try items.append(arena, try makeAttrItem(arena, attr, tag, "2"));
    }
}

fn appendBuiltinCompletions(
    arena: std.mem.Allocator,
    items: *std.ArrayList(CompletionItem),
    prefix: []const u8,
    has_at: bool,
) !void {
    for (builtins.names()) |full| {
        const bare = if (full.len > 0 and full[0] == '@') full[1..] else full;
        if (!prefixMatches(prefix, bare) and !prefixMatches(prefix, full)) continue;

        const name = if (has_at) bare else full;
        const insert = if (builtins.isFlag(full))
            name
        else
            try arena.print("{s}={{$1}}", .{name});

        const md = try html_hover.builtinAttributeMarkdown(arena, full) orelse "ZX builtin attribute";

        try items.append(arena, .{
            .label = full,
            .kind = .Property,
            .detail = "ZX builtin attribute",
            .insertText = insert,
            .insertTextFormat = .Snippet,
            .filterText = full,
            .sortText = try arena.print("0{s}", .{full}),
            .documentation = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = md,
                },
            },
        });
    }
}

fn makeAttrItem(
    arena: std.mem.Allocator,
    attr: []const u8,
    tag: []const u8,
    sort_prefix: []const u8,
) !CompletionItem {
    const doc = docs.attribute(tag, attr);
    const value: []const u8 = if (doc) |d| blk: {
        if (tag.len > 0) {
            break :blk try arena.print(
                "**`{s}`** attribute of `<{s}>`\n\n{s}",
                .{ attr, tag, truncate(d.description, 200) },
            );
        }
        break :blk try arena.print(
            "**`{s}`** attribute\n\n{s}",
            .{ attr, truncate(d.description, 200) },
        );
    } else try arena.print("**`{s}`** attribute", .{attr});

    return .{
        .label = attr,
        .kind = .Property,
        .detail = "HTML attribute",
        .insertText = try arena.print("{s}=\"$1\"", .{attr}),
        .insertTextFormat = .Snippet,
        .sortText = try arena.print("{s}{s}", .{ sort_prefix, attr }),
        .documentation = .{
            .markup_content = .{
                .kind = .markdown,
                .value = value,
            },
        },
    };
}

fn prefixMatches(prefix: []const u8, candidate: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix.len > candidate.len) return false;
    return std.ascii.startsWithIgnoreCase(candidate, prefix);
}

fn truncate(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return text[0..max];
}

fn prefixOf(text: []const u8, start: u32, offset: u32) []const u8 {
    if (offset <= start) return "";
    const len = @min(text.len, offset - start);
    return text[0..len];
}

fn isClosingTag(source: []const u8, tag_name_start: u32) bool {
    if (tag_name_start == 0) return false;
    var i = tag_name_start;
    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (std.ascii.isWhitespace(c)) continue;
        return c == '/';
    }
    return false;
}

fn inZxMarkup(node: anytype) bool {
    var current: ?@TypeOf(node) = node;
    while (current) |n| : (current = n.parent()) {
        switch (NodeKind.fromNode(n)) {
            .zx_block,
            .zx_element,
            .zx_self_closing_element,
            .zx_fragment,
            .zx_start_tag,
            .zx_end_tag,
            .zx_child,
            .zx_text,
            => return true,
            else => {},
        }
    }
    return false;
}

fn enclosingTagName(node: anytype, source: []const u8) ?[]const u8 {
    var current = node.parent();
    while (current) |n| : (current = n.parent()) {
        switch (NodeKind.fromNode(n)) {
            .zx_start_tag, .zx_self_closing_element => {
                const name_node = n.childByFieldName("name") orelse return null;
                return nodeText(name_node, source);
            },
            .zx_element, .zx_child => return null,
            else => {},
        }
    }
    return null;
}

fn nodeText(node: anytype, source: []const u8) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start < end and end <= source.len) return source[start..end];
    return "";
}
