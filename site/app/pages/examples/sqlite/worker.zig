// SQLite REPL backend, run in its own Web Worker (see `zx.worker`).
// The database lives in OPFS, so it survives reloads.
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const Result = studio.Result;

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

// Runs one statement; SQL errors come back in `err` so the page can show them.
pub fn exec(gpa: std.mem.Allocator, sql: []const u8) !Result {
    return studio.exec(&db, gpa, sql);
}

pub fn tables(gpa: std.mem.Allocator) ![]const []const u8 {
    const rows = try db.all(gpa, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name", .empty);
    const out = try gpa.alloc([]const u8, rows.len);
    for (rows, out) |row, *name| name.* = row.text("name");
    return out;
}
