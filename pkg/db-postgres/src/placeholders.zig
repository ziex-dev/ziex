// Rewrites `:name` / `@name` / `$name` placeholders to `$1..$n`.
const std = @import("std");

pub const Rewritten = struct {
    sql: []u8,
    /// names[i] is bound to `$<i+1>`, stored without sigil.
    names: []const []const u8,

    pub fn deinit(self: Rewritten, gpa: std.mem.Allocator) void {
        for (self.names) |n| gpa.free(n);
        gpa.free(self.names);
        gpa.free(self.sql);
    }

    pub fn indexOf(self: Rewritten, name: []const u8) ?usize {
        const bare = stripSigil(name);
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, bare)) return i;
        return null;
    }
};

pub fn stripSigil(name: []const u8) []const u8 {
    if (name.len > 0 and (name[0] == ':' or name[0] == '@' or name[0] == '$')) return name[1..];
    return name;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Returns null when `sql` has no named placeholders. Mixing named and `$n` placeholders is an error.
pub fn rewrite(gpa: std.mem.Allocator, sql: []const u8) !?Rewritten {
    // output is only built once a named placeholder is found; `copied` marks what's been emitted
    var copied: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var has_numbered = false;

    var i: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'' => i = skipQuoted(sql, i, '\'', isEscapeString(sql, i)),
            '"' => i = skipQuoted(sql, i, '"', false),
            '-' => if (i + 1 < sql.len and sql[i + 1] == '-') {
                i = std.mem.findScalarPos(u8, sql, i, '\n') orelse sql.len;
            } else {
                i += 1;
            },
            '/' => if (i + 1 < sql.len and sql[i + 1] == '*') {
                i = skipBlockComment(sql, i);
            } else {
                i += 1;
            },
            ':', '@', '$' => {
                // `::type` cast
                if (c == ':' and i + 1 < sql.len and sql[i + 1] == ':') {
                    i += 2;
                } else if (c == '$' and i + 1 < sql.len and std.ascii.isDigit(sql[i + 1])) {
                    has_numbered = true;
                    i += 1;
                } else if (if (c == '$') dollarQuoteEnd(sql, i) else null) |end| {
                    i = end;
                } else if (i + 1 < sql.len and isIdentStart(sql[i + 1]) and !precededByIdent(sql, i)) {
                    var j = i + 1;
                    while (j < sql.len and isIdent(sql[j])) j += 1;
                    const name = sql[i + 1 .. j];
                    const index = for (names.items, 0..) |n, k| {
                        if (std.mem.eql(u8, n, name)) break k;
                    } else blk: {
                        try names.append(gpa, try gpa.dupe(u8, name));
                        break :blk names.items.len - 1;
                    };
                    try out.appendSlice(gpa, sql[copied..i]);
                    try out.print(gpa, "${d}", .{index + 1});
                    i = j;
                    copied = j;
                    continue;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }

    if (names.items.len == 0) {
        names.deinit(gpa);
        return null;
    }
    if (has_numbered) return error.MixedPlaceholders;
    try out.appendSlice(gpa, sql[copied..]);
    return .{ .sql = try out.toOwnedSlice(gpa), .names = try names.toOwnedSlice(gpa) };
}

fn precededByIdent(sql: []const u8, i: usize) bool {
    // `a:b`, `x@y`, `foo$bar` are not placeholders
    return i > 0 and (isIdent(sql[i - 1]) or sql[i - 1] == '$');
}

fn isEscapeString(sql: []const u8, quote: usize) bool {
    return quote > 0 and (sql[quote - 1] == 'E' or sql[quote - 1] == 'e') and
        (quote == 1 or !isIdent(sql[quote - 2]));
}

fn skipQuoted(sql: []const u8, start: usize, quote: u8, backslash_escapes: bool) usize {
    var i = start + 1;
    while (i < sql.len) : (i += 1) {
        if (backslash_escapes and sql[i] == '\\') {
            i += 1;
        } else if (sql[i] == quote) {
            if (i + 1 < sql.len and sql[i + 1] == quote) {
                i += 1;
            } else return i + 1;
        }
    }
    return sql.len;
}

fn skipBlockComment(sql: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i + 1 < sql.len) {
        if (sql[i] == '/' and sql[i + 1] == '*') {
            depth += 1;
            i += 2;
        } else if (sql[i] == '*' and sql[i + 1] == '/') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
        } else i += 1;
    }
    return sql.len;
}

/// End index of a `$tag$...$tag$` literal starting at `start`, if it is one.
fn dollarQuoteEnd(sql: []const u8, start: usize) ?usize {
    var j = start + 1;
    while (j < sql.len and isIdent(sql[j])) j += 1;
    if (j >= sql.len or sql[j] != '$') return null;
    const tag = sql[start .. j + 1];
    const close = std.mem.findPos(u8, sql, j + 1, tag) orelse return sql.len;
    return close + tag.len;
}

// --- Tests --- //

const t = std.testing;

fn expectRewrite(input: []const u8, expected_sql: []const u8, expected_names: []const []const u8) !void {
    const r = (try rewrite(t.allocator, input)).?;
    defer r.deinit(t.allocator);
    try t.expectEqualStrings(expected_sql, r.sql);
    try t.expectEqual(expected_names.len, r.names.len);
    for (expected_names, r.names) |a, b| try t.expectEqualStrings(a, b);
}

test "rewrites all sigils and reuses repeated names" {
    try expectRewrite(
        "SELECT * FROM u WHERE id = :id AND name = @name OR alias = $name OR id = :id",
        "SELECT * FROM u WHERE id = $1 AND name = $2 OR alias = $2 OR id = $1",
        &.{ "id", "name" },
    );
}

test "skips literals, comments, casts and dollar quotes" {
    try expectRewrite(
        \\SELECT ':no', "@no", E'it\'s :no', $$ :no $$, $fn$ @no $fn$, x::int -- :no
        \\/* :no /* @no */ */ FROM t WHERE a = :yes
    ,
        \\SELECT ':no', "@no", E'it\'s :no', $$ :no $$, $fn$ @no $fn$, x::int -- :no
        \\/* :no /* @no */ */ FROM t WHERE a = $1
    , &.{"yes"});
}

test "no named placeholders" {
    try t.expectEqual(@as(?Rewritten, null), try rewrite(t.allocator, "SELECT $1, '::x', a::text, foo$bar, j @> k"));
}

test "mixed placeholders rejected" {
    try t.expectError(error.MixedPlaceholders, rewrite(t.allocator, "SELECT $1, :x"));
}

test "index lookup accepts sigils" {
    const r = (try rewrite(t.allocator, "SELECT :a, :b")).?;
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(?usize, 1), r.indexOf("$b"));
    try t.expectEqual(@as(?usize, 0), r.indexOf("a"));
    try t.expectEqual(@as(?usize, null), r.indexOf("c"));
}
