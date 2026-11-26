//! Semantic tokens for the Zig written inside `.zx` markup: `{for (items) |t| (`,
//! `onclick={ctx.bind(move)}`, `{card}` in a template attribute. ZLS reads `.zx` files as
//! Zig and steps over the markup, so it never colours these; we tokenize them with the
//! Zig tokenizer and merge them into ZLS's tokens (ZLS wins where both cover a range).
const std = @import("std");
const lang = @import("lang");
const text = @import("../text.zig");

/// ZLS's legend, in order (`@typeInfo(semantic_tokens.TokenType).enum.field_names`).
pub const TokenType = enum(u32) {
    namespace,
    type,
    class,
    @"enum",
    interface,
    @"struct",
    typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    event,
    function,
    method,
    macro,
    keyword,
    modifier,
    comment,
    string,
    escapeSequence,
    number,
    regexp,
    operator,
    decorator,
    errorTag,
    builtin,
    label,
    keywordLiteral,
};

pub const Span = struct { start: usize, end: usize };
pub const Token = struct { start: usize, end: usize, kind: TokenType };

/// Byte ranges of Zig code inside markup: `{...}` expressions and template
/// substitutions, without the braces and without any markup nested in them.
pub fn zigSpans(arena: std.mem.Allocator, source: []const u8) ![]Span {
    var parse = try lang.Parse.parse(arena, source, .zx);
    defer parse.deinit(arena);
    var spans: std.ArrayList(Span) = .empty;
    try walk(arena, source, parse.tree.rootNode(), &spans);
    return spans.items;
}

fn walk(arena: std.mem.Allocator, source: []const u8, node: anytype, spans: *std.ArrayList(Span)) !void {
    const kind = lang.Parse.NodeKind.fromNode(node);
    if (kind == .zx_expression_block or kind == .zx_template_substitution) {
        var start: usize = node.startByte();
        var end: usize = node.endByte();
        if (start < end and source[start] == '{') start += 1;
        if (end > start and source[end - 1] == '}') end -= 1;

        var holes: std.ArrayList(Span) = .empty;
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| try collectHoles(arena, child, &holes);
        }
        std.mem.sort(Span, holes.items, {}, struct {
            fn less(_: void, a: Span, b: Span) bool {
                return a.start < b.start;
            }
        }.less);
        var at = start;
        for (holes.items) |h| {
            if (h.start > at) try spans.append(arena, .{ .start = at, .end = @min(h.start, end) });
            at = @max(at, h.end);
        }
        if (at < end) try spans.append(arena, .{ .start = at, .end = end });
    }
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (node.child(i)) |child| try walk(arena, source, child, spans);
    }
}

// Markup (and template text) inside an expression: not Zig, so not tokenized here.
fn collectHoles(arena: std.mem.Allocator, node: anytype, holes: *std.ArrayList(Span)) !void {
    switch (lang.Parse.NodeKind.fromNode(node)) {
        .zx_block, .zx_element, .zx_self_closing_element, .zx_fragment, .zx_template_string, .zx_expression_block => {
            try holes.append(arena, .{ .start = node.startByte(), .end = node.endByte() });
            return;
        },
        else => {},
    }
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (node.child(i)) |child| try collectHoles(arena, child, holes);
    }
}

/// Zig tokens in the markup's code spans, classified like ZLS would at a glance.
pub fn markupTokens(arena: std.mem.Allocator, source: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    for (try zigSpans(arena, source)) |span| {
        const code = try arena.dupeSentinel(u8, source[span.start..span.end], 0);
        var tokens: std.ArrayList(std.zig.Token) = .empty;
        var tokenizer: std.zig.Tokenizer = .init(code);
        while (true) {
            const t = tokenizer.next();
            if (t.tag == .eof) break;
            try tokens.append(arena, t);
        }
        var in_payload = false;
        for (tokens.items, 0..) |t, i| {
            const prev: ?std.zig.Token.Tag = if (i > 0) tokens.items[i - 1].tag else null;
            const next: ?std.zig.Token.Tag = if (i + 1 < tokens.items.len) tokens.items[i + 1].tag else null;
            if (t.tag == .pipe) {
                // `) |a, b|` opens a capture list; the next pipe closes it.
                if (in_payload) in_payload = false else if (prev == .r_paren) in_payload = true;
                continue;
            }
            const kind = classify(code[t.loc.start..t.loc.end], t.tag, prev, next, in_payload) orelse continue;
            try out.append(arena, .{ .start = span.start + t.loc.start, .end = span.start + t.loc.end, .kind = kind });
        }
    }
    return out.items;
}

fn classify(name: []const u8, tag: std.zig.Token.Tag, prev: ?std.zig.Token.Tag, next: ?std.zig.Token.Tag, in_payload: bool) ?TokenType {
    return switch (tag) {
        .identifier => {
            for ([_][]const u8{ "true", "false", "null", "undefined" }) |lit| {
                if (std.mem.eql(u8, name, lit)) return .keywordLiteral;
            }
            if (std.zig.primitives.isPrimitive(name)) return .type;
            if (in_payload) return .parameter;
            if (prev == .period) return if (next == .l_paren) .method else .property;
            if (next == .l_paren) return .function;
            return .variable;
        },
        .builtin => .builtin,
        .number_literal => .number,
        .string_literal, .multiline_string_literal_line, .char_literal => .string,
        .doc_comment, .container_doc_comment => .comment,
        .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace, .comma, .semicolon, .period, .colon, .invalid => null,
        else => if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) .keyword else .operator,
    };
}

const Abs = struct { line: u32, char: u32, len: u32, kind: u32, mods: u32 };

/// ZLS's encoded tokens with the markup tokens added, re-encoded (LSP relative form).
pub fn merge(arena: std.mem.Allocator, source: []const u8, zls: []const u32, encoding: text.Encoding) ![]u32 {
    var all: std.ArrayList(Abs) = .empty;
    var line: u32 = 0;
    var char: u32 = 0;
    var i: usize = 0;
    while (i + 5 <= zls.len) : (i += 5) {
        line += zls[i];
        char = if (zls[i] == 0) char + zls[i + 1] else zls[i + 1];
        try all.append(arena, .{ .line = line, .char = char, .len = zls[i + 2], .kind = zls[i + 3], .mods = zls[i + 4] });
    }
    const from_zls = all.items.len;

    for (try markupTokens(arena, source)) |t| {
        const a = text.offsetToPosition(source, t.start, encoding);
        const b = text.offsetToPosition(source, t.end, encoding);
        if (b.line != a.line or b.character <= a.character) continue;
        const tok: Abs = .{ .line = a.line, .char = a.character, .len = b.character - a.character, .kind = @intFromEnum(t.kind), .mods = 0 };
        const overlaps = for (all.items[0..from_zls]) |z| {
            if (z.line == tok.line and z.char < tok.char + tok.len and tok.char < z.char + z.len) break true;
        } else false;
        if (!overlaps) try all.append(arena, tok);
    }

    std.mem.sort(Abs, all.items, {}, struct {
        fn less(_: void, x: Abs, y: Abs) bool {
            return if (x.line != y.line) x.line < y.line else x.char < y.char;
        }
    }.less);

    const out = try arena.alloc(u32, all.items.len * 5);
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    for (all.items, 0..) |t, n| {
        out[n * 5] = t.line - prev_line;
        out[n * 5 + 1] = if (t.line == prev_line) t.char - prev_char else t.char;
        out[n * 5 + 2] = t.len;
        out[n * 5 + 3] = t.kind;
        out[n * 5 + 4] = t.mods;
        prev_line = t.line;
        prev_char = t.char;
    }
    return out;
}
