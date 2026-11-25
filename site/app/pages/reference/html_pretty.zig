//! Formats and highlights the rendered HTML shown in docs examples, at render
//! time (previously prettier + a regex highlighter in the browser).
//! Elements go on their own indented lines; an element holding only short text
//! stays on one line. Output is escaped HTML with `tag`, `attribute`, `string`,
//! `punctuation`, `comment` and `keyword` spans for docs.css.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const max_inline = 80;
const void_tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };

const Node = union(enum) {
    element: struct { name: []const u8, attrs: []const u8, children: []Node, void: bool },
    text: []const u8,
    comment: []const u8,
    doctype: []const u8,
};

pub fn format(a: Allocator, html: []const u8) ![]const u8 {
    var p: Parser = .{ .a = a, .src = html };
    const nodes = try p.children(null);
    var out: Writer.Allocating = .init(a);
    for (nodes) |n| try print(&out.writer, n, 0);
    const s = out.written();
    return std.mem.trimEnd(u8, s, "\n");
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,

    fn children(p: *Parser, parent: ?[]const u8) Allocator.Error![]Node {
        var list: std.ArrayListUnmanaged(Node) = .empty;
        while (p.i < p.src.len) {
            const rest = p.src[p.i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const end = std.mem.indexOfPos(u8, p.src, p.i + 4, "-->") orelse p.src.len - 3;
                try list.append(p.a, .{ .comment = p.src[p.i .. end + 3] });
                p.i = end + 3;
            } else if (std.mem.startsWith(u8, rest, "<!")) {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.i, '>') orelse p.src.len - 1;
                try list.append(p.a, .{ .doctype = p.src[p.i .. end + 1] });
                p.i = end + 1;
            } else if (std.mem.startsWith(u8, rest, "</")) {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.i, '>') orelse p.src.len - 1;
                const name = std.mem.trim(u8, p.src[p.i + 2 .. end], " \t\n");
                p.i = end + 1;
                // Closes us (or an ancestor): stop either way.
                if (parent == null or std.ascii.eqlIgnoreCase(name, parent.?)) break;
                break;
            } else if (rest[0] == '<' and rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
                try list.append(p.a, try p.element());
            } else {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.i + 1, '<') orelse p.src.len;
                const text = p.src[p.i..end];
                if (std.mem.trim(u8, text, &std.ascii.whitespace).len > 0) try list.append(p.a, .{ .text = text });
                p.i = end;
            }
        }
        return list.items;
    }

    fn element(p: *Parser) !Node {
        var j = p.i + 1;
        while (j < p.src.len and !std.ascii.isWhitespace(p.src[j]) and p.src[j] != '>' and p.src[j] != '/') j += 1;
        const name = p.src[p.i + 1 .. j];
        // End of the open tag, skipping `>` inside quoted values.
        var quote: ?u8 = null;
        while (j < p.src.len) : (j += 1) {
            const c = p.src[j];
            if (quote) |q| {
                if (c == q) quote = null;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') break;
        }
        var attrs = std.mem.trim(u8, p.src[p.i + 1 + name.len .. @min(j, p.src.len)], " \t\n");
        const self_closing = std.mem.endsWith(u8, attrs, "/");
        if (self_closing) attrs = std.mem.trimEnd(u8, attrs[0 .. attrs.len - 1], " ");
        p.i = @min(j + 1, p.src.len);

        const is_void = self_closing or for (void_tags) |v| {
            if (std.ascii.eqlIgnoreCase(v, name)) break true;
        } else false;
        if (is_void) return .{ .element = .{ .name = name, .attrs = attrs, .children = &.{}, .void = true } };

        // Raw text elements keep their content verbatim.
        if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style")) {
            var close_buf: [16]u8 = undefined;
            const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch "</";
            const end = std.mem.indexOfPos(u8, p.src, p.i, close) orelse p.src.len;
            const body = p.src[p.i..end];
            p.i = if (std.mem.indexOfScalarPos(u8, p.src, end, '>')) |gt| gt + 1 else p.src.len;
            const kids = try p.a.alloc(Node, if (body.len > 0) 1 else 0);
            if (body.len > 0) kids[0] = .{ .text = body };
            return .{ .element = .{ .name = name, .attrs = attrs, .children = kids, .void = false } };
        }
        return .{ .element = .{ .name = name, .attrs = attrs, .children = try p.children(name), .void = false } };
    }
};

fn indent(w: *Writer, depth: usize) !void {
    try w.splatByteAll(' ', depth * 2);
}

fn print(w: *Writer, n: Node, depth: usize) Writer.Error!void {
    try indent(w, depth);
    switch (n) {
        .text => |t| {
            try escape(w, std.mem.trim(u8, t, &std.ascii.whitespace));
            try w.writeByte('\n');
        },
        .comment => |c| {
            try w.writeAll("<span class=\"comment\">");
            try escape(w, c);
            try w.writeAll("</span>\n");
        },
        .doctype => |d| {
            try w.writeAll("<span class=\"keyword\">");
            try escape(w, d);
            try w.writeAll("</span>\n");
        },
        .element => |e| {
            try openTag(w, e.name, e.attrs);
            if (e.void) return w.writeByte('\n');
            if (inlineText(e.children)) |text| {
                if (depth * 2 + e.name.len * 2 + e.attrs.len + text.len + 6 <= max_inline) {
                    try escape(w, text);
                    try closeTag(w, e.name);
                    return w.writeByte('\n');
                }
            }
            if (e.children.len == 0) {
                try closeTag(w, e.name);
                return w.writeByte('\n');
            }
            try w.writeByte('\n');
            for (e.children) |c| try print(w, c, depth + 1);
            try indent(w, depth);
            try closeTag(w, e.name);
            try w.writeByte('\n');
        },
    }
}

fn inlineText(children: []const Node) ?[]const u8 {
    if (children.len != 1) return null;
    return switch (children[0]) {
        .text => |t| std.mem.trim(u8, t, &std.ascii.whitespace),
        else => null,
    };
}

fn punct(w: *Writer, s: []const u8) !void {
    try w.writeAll("<span class=\"punctuation\">");
    try escape(w, s);
    try w.writeAll("</span>");
}

fn openTag(w: *Writer, name: []const u8, attrs: []const u8) !void {
    try punct(w, "<");
    try w.print("<span class=\"tag\">{s}</span>", .{name});
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i >= attrs.len) break;
        const start = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=') i += 1;
        try w.print(" <span class=\"attribute\">{s}</span>", .{attrs[start..i]});
        if (i < attrs.len and attrs[i] == '=') {
            try punct(w, "=");
            i += 1;
            const vstart = i;
            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const q = attrs[i];
                i = (std.mem.indexOfScalarPos(u8, attrs, i + 1, q) orelse attrs.len - 1) + 1;
            } else {
                while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) i += 1;
            }
            try w.writeAll("<span class=\"string\">");
            try escape(w, attrs[vstart..@min(i, attrs.len)]);
            try w.writeAll("</span>");
        }
    }
    try punct(w, ">");
}

fn closeTag(w: *Writer, name: []const u8) !void {
    try punct(w, "</");
    try w.print("<span class=\"tag\">{s}</span>", .{name});
    try punct(w, ">");
}

fn escape(w: *Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}
