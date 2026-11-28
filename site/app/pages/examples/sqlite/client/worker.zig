// SQLite REPL backend, run in its own Web Worker (see `zx.worker`).
// The database lives in OPFS, so it survives reloads.
const std = @import("std");
const zx = @import("zx");
const studio = @import("../../studio_lib.zig");

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

pub fn run(gpa: std.mem.Allocator, src: []const u8) ![]const studio.Result {
    return studio.execAll(&db, gpa, zx.Io.Web.io(), src);
}

pub fn schema(gpa: std.mem.Allocator) ![]const studio.Table {
    return studio.schema(&db, gpa,
        \\SELECT m.name AS tbl, p.name AS col, p.type AS type, NOT p."notnull" AS nullable, p.pk > 0 AS pk
        \\FROM sqlite_master m JOIN pragma_table_info(m.name) p
        \\WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
        \\ORDER BY m.name, p.cid
    );
}

pub fn check(gpa: std.mem.Allocator, src: []const u8) !?studio.Diagnostic {
    return studio.diagnose(&db, gpa, src, studio.check);
}
