const std = @import("std");
const testing = std.testing;
const Transpile = @import("lang").Transpile;

fn expectNorm(source: []const u8, start: u32, end: u32, leading: bool, text: []const u8) !void {
    const normalized = Transpile.normalizeText(source, start, end).?;
    try testing.expectEqual(leading, normalized.leading_space);
    try testing.expectEqualStrings(text, normalized.text);
}

/// Text node begins at the first newline (prefix is the prior sibling in source).
fn afterNewline(source: []const u8) struct { start: u32, end: u32 } {
    return .{ .start = @intCast(std.mem.indexOfScalar(u8, source, '\n').?), .end = @intCast(source.len) };
}

test "normalizeText keeps space after expression across newline" {
    const source =
        \\{bank}
        \\                · Cash
    ;
    const r = afterNewline(source);
    try expectNorm(source, r.start, r.end, true, "· Cash");
}

test "normalizeText keeps space after closing tag across newline" {
    const source =
        \\</b>
        \\                · Cash
    ;
    const r = afterNewline(source);
    try expectNorm(source, r.start, r.end, true, "· Cash");
}

test "normalizeText does not insert space after opening tag" {
    const source =
        \\<span>
        \\                · Cash
    ;
    const r = afterNewline(source);
    try expectNorm(source, r.start, r.end, false, "· Cash");
}

test "normalizeText does not insert space after self-closing or void tag" {
    {
        const source =
            \\<br />
            \\                HINT
        ;
        const r = afterNewline(source);
        try expectNorm(source, r.start, r.end, false, "HINT");
    }
    {
        const source =
            \\<br>
            \\                HINT
        ;
        const r = afterNewline(source);
        try expectNorm(source, r.start, r.end, false, "HINT");
    }
}

test "normalizeText drops layout-only whitespace" {
    const source = "foo\n                \nbar";
    try testing.expect(Transpile.normalizeText(source, 3, 21) == null);
}

test "normalizeText skips space after whitespace-only expression" {
    const cases = [_][]const u8{
        "{' '}\n                in their name",
        "{\" \"}\n                in their name",
        "{  }\n                in their name",
    };
    for (cases) |source| {
        const r = afterNewline(source);
        try expectNorm(source, r.start, r.end, false, "in their name");
    }
}

test "normalizeText same-line spaces are kept without leading_space" {
    const source = "{bank} · Cash";
    const start: u32 = @intCast(std.mem.indexOfScalar(u8, source, ' ').?);
    try expectNorm(source, start, @intCast(source.len), false, " · Cash");
}

test "normalizeText does not insert trailing space before expression" {
    // Asymmetric on purpose: `label\n#\n{n}` must stay "label #n", not "label # n".
    // For `Hello\n{name}`, write `Hello{" "}{name}` or keep them on one line.
    const source =
        \\Hello
        \\{kind}
    ;
    const end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '\n').?);
    const normalized = Transpile.normalizeText(source, 0, end).?;
    try testing.expect(!normalized.leading_space);
    try testing.expectEqualStrings("Hello", normalized.text);
}
