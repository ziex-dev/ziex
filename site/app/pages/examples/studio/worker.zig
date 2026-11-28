// Tree-sitter SQL tokens for the studio editor, off the page's main thread (see `zx.worker`).
const std = @import("std");
const ts = @import("tree_sitter");
const ts_sql = @import("tree_sitter_sql");
const studio = @import("../studio_lib.zig");

const Kind = studio.Kind;

var parser: ?*ts.Parser = null;

pub fn tokenize(gpa: std.mem.Allocator, src: []const u8) ![]const studio.Token {
    const p = parser orelse blk: {
        const p = ts.Parser.create();
        try p.setLanguage(ts.Language.fromRaw(ts_sql.language()));
        parser = p;
        break :blk p;
    };
    const tree = p.parseString(src, null) orelse return error.ParseFailed;
    defer tree.destroy();

    var tokens: std.ArrayList(studio.Token) = .empty;
    var cursor = tree.walk();
    defer cursor.destroy();

    walk: while (true) {
        const node = cursor.node();
        if (atomic(node)) {
            if (node.endByte() > node.startByte())
                try tokens.append(gpa, .{ .start = node.startByte(), .end = node.endByte(), .kind = classify(node, src) });
        } else if (cursor.gotoFirstChild()) continue;

        while (!cursor.gotoNextSibling()) if (!cursor.gotoParent()) break :walk;
    }
    return tokens.items;
}

fn atomic(node: ts.Node) bool {
    if (node.childCount() == 0) return true;
    const kind = node.kind();
    return eql(kind, "identifier") or eql(kind, "literal") or eql(kind, "comment") or eql(kind, "marginalia");
}

fn classify(node: ts.Node, src: []const u8) Kind {
    const kind = node.kind();
    if (std.mem.startsWith(u8, kind, "keyword_")) return .keyword;
    if (eql(kind, "comment") or eql(kind, "marginalia")) return .comment;
    if (eql(kind, "parameter")) return .param;
    if (eql(kind, "literal")) {
        const c = src[node.startByte()];
        return if (std.ascii.isDigit(c) or c == '-' or c == '.') .number else .string;
    }
    if (eql(kind, "identifier")) {
        const parent = node.parent() orelse return .plain;
        const p = parent.kind();
        if (eql(p, "field") or eql(p, "column_definition")) return .column;
        if (eql(p, "object_reference")) {
            const grand = parent.parent() orelse return .table;
            return if (eql(grand.kind(), "invocation")) .function else .table;
        }
        if (eql(p, "relation") or eql(p, "term")) return .alias;
        return .plain;
    }
    if (!node.isNamed() and std.mem.findNone(u8, kind, "=<>!+-*/%|&^~:") == null) return .operator;
    return .plain;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
