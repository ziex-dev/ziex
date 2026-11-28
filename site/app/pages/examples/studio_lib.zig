//! Shared SQL studio types and query execution for the examples.
const std = @import("std");
const zx = @import("zx");

pub const Diagnostic = struct {
    message: []const u8,
    // Byte range in the editor text
    start: u32 = 0,
    end: u32 = 0,
};

pub const Result = struct {
    sql: []const u8 = "",
    columns: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    changes: usize = 0,
    err: ?Diagnostic = null,
    // Time the database took, measured where the query runs
    micros: u64 = 0,
};

pub const Column = struct {
    name: []const u8,
    type: []const u8,
    nullable: bool,
    pk: bool,
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,

    pub fn column(self: Table, name: []const u8) ?Column {
        for (self.columns) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        return null;
    }
};

pub const Kind = enum { plain, keyword, string, number, comment, operator, param, table, column, function, alias };

pub const Token = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

pub const Suggestion = struct {
    label: []const u8,
    detail: []const u8,
    kind: Kind,
};

pub const Completion = struct {
    start: usize,
    items: []const Suggestion,
};

pub const Span = struct { start: u32, end: u32 };

// For the backends' process-lifetime connection, so it stays off the leak-checked allocator.
pub const persistent = if (zx.platform.os == .wasi) zx.allocator else std.heap.smp_allocator;

pub const Check = fn (*zx.Db, std.mem.Allocator, []const u8, *zx.Db.Diagnostics) ?anyerror;

// Expects text columns `tbl`, `col`, `type` and boolean `nullable`, `pk`, ordered by table.
pub fn schema(database: *zx.Db, arena: std.mem.Allocator, sql: []const u8) ![]const Table {
    const rows = try database.all(arena, sql, .empty);
    var tables: std.ArrayList(Table) = .empty;
    var columns: std.ArrayList(Column) = .empty;
    for (rows, 0..) |row, i| {
        try columns.append(arena, .{
            .name = try arena.dupe(u8, row.text("col")),
            .type = try arena.dupe(u8, row.text("type")),
            .nullable = row.boolean("nullable"),
            .pk = row.boolean("pk"),
        });
        const name = row.text("tbl");
        if (i + 1 < rows.len and std.mem.eql(u8, name, rows[i + 1].text("tbl"))) continue;
        try tables.append(arena, .{ .name = try arena.dupe(u8, name), .columns = try columns.toOwnedSlice(arena) });
    }
    return tables.items;
}

// Asks the DB to parse and describe the statement without running it.
pub fn check(database: *zx.Db, _: std.mem.Allocator, sql: []const u8, diagnostics: *zx.Db.Diagnostics) ?anyerror {
    var stmt = database.prepare(sql, .{ .diagnostics = diagnostics }) catch |err| return err;
    defer stmt.deinit();
    _ = stmt.columnNames() catch |err| return err;
    return null;
}

pub fn diagnose(database: *zx.Db, arena: std.mem.Allocator, src: []const u8, comptime checkFn: Check) ?Diagnostic {
    const spans = split(arena, src) catch return null;
    for (spans) |span| {
        var diagnostics: zx.Db.Diagnostics = .{};
        const err = checkFn(database, arena, src[span.start..span.end], &diagnostics) orelse continue;
        return describe(arena, src, span, err, &diagnostics);
    }
    return null;
}

// Runs each statement in `src`, stopping at the first failure.
pub fn execAll(database: *zx.Db, gpa: std.mem.Allocator, io: std.Io, src: []const u8) []const Result {
    const spans = split(gpa, src) catch return &.{};
    var results: std.ArrayList(Result) = .empty;
    for (spans) |span| {
        const sql = src[span.start..span.end];
        var diagnostics: zx.Db.Diagnostics = .{};
        const started = std.Io.Timestamp.now(io, .awake);
        var result = exec(database, gpa, sql, &diagnostics) catch |err| Result{ .sql = sql, .err = describe(gpa, src, span, err, &diagnostics) };
        result.micros = @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds, std.time.ns_per_us));
        results.append(gpa, result) catch break;
        if (result.err != null) break;
    }
    return results.items;
}

fn exec(database: *zx.Db, gpa: std.mem.Allocator, sql: []const u8, diagnostics: *zx.Db.Diagnostics) !Result {
    var stmt = try database.prepare(sql, .{ .diagnostics = diagnostics });
    defer stmt.deinit();

    const names = try stmt.columnNames();
    if (names.len == 0) {
        // Backends without column metadata (e.g. D1 over wasm) report no columns for any statement.
        if (returnsRows(sql)) return execRows(&stmt, gpa, sql);
        const res = try stmt.run(.empty);
        return .{ .sql = sql, .changes = res.changes };
    }
    const columns = try gpa.alloc([]const u8, names.len);
    for (names, columns) |n, *c| c.* = try gpa.dupe(u8, n);

    const values = try stmt.values(gpa, .empty);
    const rows = try gpa.alloc([]const []const u8, values.len);
    for (values, rows) |vals, *row| {
        const cells = try gpa.alloc([]const u8, vals.len);
        for (vals, cells) |v, *cell| cell.* = try format(gpa, v);
        row.* = cells;
    }
    return .{ .sql = sql, .columns = columns, .rows = rows };
}

fn execRows(stmt: *zx.Db.Statement, gpa: std.mem.Allocator, sql: []const u8) !Result {
    const all_rows = try stmt.all(gpa, .empty);
    if (all_rows.len == 0) return .{ .sql = sql, .columns = &.{"(no rows)"} };

    const columns = try gpa.alloc([]const u8, all_rows[0].fields.len);
    for (all_rows[0].fields, columns) |f, *c| c.* = f.name;

    const rows = try gpa.alloc([]const []const u8, all_rows.len);
    for (all_rows, rows) |r, *row| {
        const cells = try gpa.alloc([]const u8, r.fields.len);
        for (r.fields, cells) |f, *cell| cell.* = try format(gpa, f.value);
        row.* = cells;
    }
    return .{ .sql = sql, .columns = columns, .rows = rows };
}

// The DB's own message and position, falling back to the error name and the whole statement.
fn describe(arena: std.mem.Allocator, src: []const u8, span: Span, err: anyerror, diagnostics: *const zx.Db.Diagnostics) Diagnostic {
    const message = diagnostics.message() orelse return .{ .message = @errorName(err), .start = span.start, .end = span.end };
    const stmt = src[span.start..span.end];
    var range = span;
    if (diagnostics.offset) |at| {
        if (at < stmt.len) range = word(src, span.start + @as(u32, @intCast(at)));
    } else if (quoted(message)) |q| {
        if (findIgnoreCase(stmt, q)) |at| range = .{ .start = span.start + @as(u32, @intCast(at)), .end = span.start + @as(u32, @intCast(at + q.len)) };
    }
    return .{ .message = arena.dupe(u8, message) catch @errorName(err), .start = range.start, .end = range.end };
}

fn word(src: []const u8, at: u32) Span {
    var end = at;
    while (end < src.len and isIdent(src[end])) end += 1;
    return .{ .start = at, .end = @max(end, @min(at + 1, @as(u32, @intCast(src.len)))) };
}

// First '…' or "…" in a message, e.g. MySQL's `near 'FORM users'` or `Unknown column 'age'`.
fn quoted(message: []const u8) ?[]const u8 {
    const open = std.mem.findAny(u8, message, "'\"") orelse return null;
    const close = std.mem.findScalarPos(u8, message, open + 1, message[open]) orelse return null;
    return if (close > open + 1) message[open + 1 .. close] else null;
}

// Statement ranges in `src`, split on `;` outside strings, comments and dollar quotes; trimmed,
// and skipping ones that hold only comments.
pub fn split(gpa: std.mem.Allocator, src: []const u8) ![]const Span {
    var out: std.ArrayList(Span) = .empty;
    var code: ?Span = null;
    var i: usize = 0;
    while (i < src.len) {
        const at = i;
        const c = src[i];
        if (c == ';') {
            if (code) |s| try out.append(gpa, s);
            code = null;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "--")) {
            i = std.mem.findScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            i = if (std.mem.findPos(u8, src, i + 2, "*/")) |e| e + 2 else src.len;
            continue;
        }
        i = switch (c) {
            '\'', '"', '`' => if (std.mem.findScalarPos(u8, src, i + 1, c)) |e| e + 1 else src.len,
            '$' => dollarQuoteEnd(src, i) orelse i + 1,
            else => i + 1,
        };
        if (std.ascii.isWhitespace(c)) continue;
        const begin: u32 = if (code) |s| s.start else @intCast(at);
        code = .{ .start = begin, .end = @intCast(i) };
    }
    if (code) |s| try out.append(gpa, s);
    return out.toOwnedSlice(gpa);
}

// `$tag$ … $tag$` (Postgres); `$1` placeholders aren't quotes.
fn dollarQuoteEnd(src: []const u8, i: usize) ?usize {
    const close = std.mem.findScalarPos(u8, src, i + 1, '$') orelse return null;
    const tag_name = src[i + 1 .. close];
    if (tag_name.len > 0 and std.ascii.isDigit(tag_name[0])) return null;
    for (tag_name) |ch| if (!isIdent(ch)) return null;
    const tag = src[i .. close + 1];
    return if (std.mem.findPos(u8, src, close + 1, tag)) |e| e + tag.len else src.len;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn findTable(tables: []const Table, name: []const u8) ?Table {
    for (tables) |t| if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    return null;
}

// Names matching the identifier before `caret`; after `tbl.` only that table's columns.
pub fn complete(buf: []Suggestion, tables: []const Table, text: []const u8, caret: usize) Completion {
    const end = @min(caret, text.len);
    const start = identStart(text, end);
    const prefix = text[start..end];
    var n: usize = 0;

    if (start > 0 and text[start - 1] == '.') {
        const qualifier = unquote(text[identStart(text, start - 1) .. start - 1]);
        const table = findTable(tables, qualifier) orelse return .{ .start = start, .items = &.{} };
        for (table.columns) |c| add(buf, &n, prefix, .{ .label = c.name, .detail = c.type, .kind = .column });
    } else if (prefix.len > 0 and !std.ascii.isDigit(prefix[0])) {
        for (tables) |t| add(buf, &n, prefix, .{ .label = t.name, .detail = "table", .kind = .table });
        for (tables) |t| for (t.columns) |c| add(buf, &n, prefix, .{ .label = c.name, .detail = t.name, .kind = .column });
    }
    return .{ .start = start, .items = buf[0..n] };
}

fn add(buf: []Suggestion, n: *usize, prefix: []const u8, s: Suggestion) void {
    if (n.* == buf.len or s.label.len <= prefix.len) return;
    if (!std.ascii.startsWithIgnoreCase(s.label, prefix)) return;
    for (buf[0..n.*]) |existing| if (std.mem.eql(u8, existing.label, s.label)) return;
    buf[n.*] = s;
    n.* += 1;
}

fn identStart(text: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and isIdent(text[i - 1])) i -= 1;
    return i;
}

pub fn unquote(name: []const u8) []const u8 {
    if (name.len >= 2 and (name[0] == '"' or name[0] == '`') and name[name.len - 1] == name[0]) return name[1 .. name.len - 1];
    return name;
}

fn returnsRows(sql: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, sql, " \t\r\n(");
    const keywords = [_][]const u8{ "SELECT", "WITH", "PRAGMA", "EXPLAIN", "VALUES" };
    for (keywords) |kw| {
        if (trimmed.len >= kw.len and std.ascii.eqlIgnoreCase(trimmed[0..kw.len], kw)) return true;
    }
    return containsIgnoreCase(sql, "RETURNING");
}

pub fn format(gpa: std.mem.Allocator, v: zx.Db.Value) ![]const u8 {
    return switch (v) {
        .null => "NULL",
        .integer => |i| gpa.print("{d}", .{i}),
        .float => |f| gpa.print("{d}", .{f}),
        .text => |t| t,
        .blob => |b| gpa.print("x'{x}'", .{b}),
        .boolean => |b| if (b) "1" else "0",
    };
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return findIgnoreCase(haystack, needle) != null;
}

test split {
    const src = " SELECT 1; -- c\n SELECT ';' AS x ; /* only */ ;\nSELECT $$a;b$$, $1 -- end";
    const spans = try split(std.testing.allocator, src);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(3, spans.len);
    try std.testing.expectEqualStrings("SELECT 1", src[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("SELECT ';' AS x", src[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("SELECT $$a;b$$, $1", src[spans[2].start..spans[2].end]);
}
