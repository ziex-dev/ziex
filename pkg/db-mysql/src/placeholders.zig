// Rewrites `:name` / `@name` / `$name` placeholders to MySQL's positional `?`.
const std = @import("std");

pub const Rewritten = struct {
    sql: []u8,
    /// Distinct names in order of first use, stored without sigil.
    names: []const []const u8,
    /// For each `?` in `sql`, the index into `names` that fills it.
    slots: []const u32,

    pub fn deinit(self: Rewritten, gpa: std.mem.Allocator) void {
        for (self.names) |n| gpa.free(n);
        gpa.free(self.names);
        gpa.free(self.slots);
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

/// Returns null when `sql` has no named placeholders. Mixing named placeholders with `?` is an error.
/// `@@system_variable` is left alone; any other `@name` is a placeholder, so statements with
/// user variables should use `?` bindings.
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
    var slots: std.ArrayList(u32) = .empty;
    errdefer slots.deinit(gpa);
    var has_positional = false;

    var i: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'', '"' => i = skipQuoted(sql, i, c, true),
            '`' => i = skipQuoted(sql, i, '`', false),
            '#' => i = std.mem.findScalarPos(u8, sql, i, '\n') orelse sql.len,
            '-' => if (i + 1 < sql.len and sql[i + 1] == '-' and (i + 2 == sql.len or std.ascii.isWhitespace(sql[i + 2]) or std.ascii.isControl(sql[i + 2]))) {
                i = std.mem.findScalarPos(u8, sql, i, '\n') orelse sql.len;
            } else {
                i += 1;
            },
            '/' => if (i + 1 < sql.len and sql[i + 1] == '*') {
                i = if (std.mem.findPos(u8, sql, i + 2, "*/")) |end| end + 2 else sql.len;
            } else {
                i += 1;
            },
            '?' => {
                has_positional = true;
                i += 1;
            },
            ':', '@', '$' => {
                if (c == ':' and i + 1 < sql.len and sql[i + 1] == ':') {
                    i += 2;
                } else if (c == '@' and i + 1 < sql.len and sql[i + 1] == '@') {
                    i += 2;
                    while (i < sql.len and (isIdent(sql[i]) or sql[i] == '.')) i += 1;
                } else if (i + 1 < sql.len and isIdentStart(sql[i + 1]) and !precededByIdent(sql, i)) {
                    var j = i + 1;
                    while (j < sql.len and isIdent(sql[j])) j += 1;
                    const name = sql[i + 1 .. j];
                    const index: u32 = for (names.items, 0..) |n, k| {
                        if (std.mem.eql(u8, n, name)) break @intCast(k);
                    } else blk: {
                        try names.append(gpa, try gpa.dupe(u8, name));
                        break :blk @intCast(names.items.len - 1);
                    };
                    try slots.append(gpa, index);
                    try out.appendSlice(gpa, sql[copied..i]);
                    try out.append(gpa, '?');
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
        slots.deinit(gpa);
        out.deinit(gpa);
        return null;
    }
    if (has_positional) return error.MixedPlaceholders;
    try out.appendSlice(gpa, sql[copied..]);
    const owned_sql = try out.toOwnedSlice(gpa);
    errdefer gpa.free(owned_sql);
    const owned_slots = try slots.toOwnedSlice(gpa);
    errdefer gpa.free(owned_slots);
    return .{ .sql = owned_sql, .names = try names.toOwnedSlice(gpa), .slots = owned_slots };
}

fn precededByIdent(sql: []const u8, i: usize) bool {
    // `a:b`, `x@y`, `foo$bar` are not placeholders
    return i > 0 and (isIdent(sql[i - 1]) or sql[i - 1] == '$');
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

// --- Tests --- //

const t = std.testing;

fn expectRewrite(input: []const u8, expected_sql: []const u8, expected_names: []const []const u8, expected_slots: []const u32) !void {
    const r = (try rewrite(t.allocator, input)).?;
    defer r.deinit(t.allocator);
    try t.expectEqualStrings(expected_sql, r.sql);
    try t.expectEqual(expected_names.len, r.names.len);
    for (expected_names, r.names) |a, b| try t.expectEqualStrings(a, b);
    try t.expectEqualSlices(u32, expected_slots, r.slots);
}

test "rewrites all sigils; repeated names get a slot each" {
    try expectRewrite(
        "SELECT * FROM u WHERE id = :id AND name = @name OR alias = $name OR id = :id",
        "SELECT * FROM u WHERE id = ? AND name = ? OR alias = ? OR id = ?",
        &.{ "id", "name" },
        &.{ 0, 1, 1, 0 },
    );
}

test "skips literals, identifiers, comments and system variables" {
    try expectRewrite(
        \\SELECT ':no', "@no", 'it\':no', 'it'':no', `:no`, @@session.x, a::b, 'x' -- :no
        \\# :no
        \\/* :no @no */ FROM t WHERE a = :yes
    ,
        \\SELECT ':no', "@no", 'it\':no', 'it'':no', `:no`, @@session.x, a::b, 'x' -- :no
        \\# :no
        \\/* :no @no */ FROM t WHERE a = ?
    , &.{"yes"}, &.{0});
}

test "double dash needs trailing space to be a comment" {
    try expectRewrite("SELECT 1--:a", "SELECT 1--?", &.{"a"}, &.{0});
    try expectRewrite("SELECT 1 -- :a\n, :b", "SELECT 1 -- :a\n, ?", &.{"b"}, &.{0});
}

test "no named placeholders" {
    try t.expectEqual(@as(?Rewritten, null), try rewrite(t.allocator, "SELECT ?, '::x', foo$bar, a:=1, @@v, `:c`"));
}

test "mixed placeholders rejected" {
    try t.expectError(error.MixedPlaceholders, rewrite(t.allocator, "SELECT ?, :x"));
}

test "index lookup accepts sigils" {
    const r = (try rewrite(t.allocator, "SELECT :a, :b")).?;
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(?usize, 1), r.indexOf("$b"));
    try t.expectEqual(@as(?usize, 0), r.indexOf("a"));
    try t.expectEqual(@as(?usize, null), r.indexOf("c"));
}
