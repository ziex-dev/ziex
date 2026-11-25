// SQLite REPL backend, run in its own Web Worker (see `zx.worker`).
// The database lives in OPFS, so it survives reloads.
const std = @import("std");
const zx = @import("zx");

var db: zx.Db = undefined;

pub fn init() !void {
    db = try zx.Db.Sqlite.open(zx.allocator, zx.Io.Web.io(), "db/repl.db", .{});
    _ = try db.run(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT UNIQUE
        \\)
    , .empty);
    _ = try db.run(
        \\INSERT OR IGNORE INTO users (id, name, email) VALUES
        \\  (1, 'Ada', 'ada@example.com'),
        \\  (2, 'Linus', 'linus@example.com'),
        \\  (3, 'Grace', 'grace@example.com')
    , .empty);
}

pub const Result = struct {
    columns: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    changes: usize = 0,
    err: ?[]const u8 = null,
};

// Runs one statement; SQL errors come back in `err` so the page can show them.
pub fn exec(gpa: std.mem.Allocator, sql: []const u8) !Result {
    var stmt = db.prepare(sql) catch |err| return .{ .err = @errorName(err) };
    defer stmt.deinit();

    // Owned by `stmt`, so copy before it's freed.
    const names = try stmt.columnNames();
    if (names.len == 0) {
        const res = stmt.run(.empty) catch |err| return .{ .err = @errorName(err) };
        return .{ .changes = res.changes };
    }
    const columns = try gpa.alloc([]const u8, names.len);
    for (names, columns) |n, *c| c.* = try gpa.dupe(u8, n);

    const values = stmt.values(gpa, .empty) catch |err| return .{ .err = @errorName(err) };
    const rows = try gpa.alloc([]const []const u8, values.len);
    for (values, rows) |vals, *row| {
        const cells = try gpa.alloc([]const u8, vals.len);
        for (vals, cells) |v, *cell| cell.* = try format(gpa, v);
        row.* = cells;
    }
    return .{ .columns = columns, .rows = rows };
}

pub fn tables(gpa: std.mem.Allocator) ![]const []const u8 {
    const rows = try db.all(gpa, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name", .empty);
    const out = try gpa.alloc([]const u8, rows.len);
    for (rows, out) |row, *name| name.* = row.text("name");
    return out;
}

fn format(gpa: std.mem.Allocator, v: zx.Db.Value) ![]const u8 {
    return switch (v) {
        .null => "NULL",
        .integer => |i| std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}),
        .text => |t| t,
        .blob => |b| std.fmt.allocPrint(gpa, "x'{x}'", .{b}),
        .boolean => |b| if (b) "1" else "0",
    };
}
