// Runs in its own Web Worker (see `zx.worker`), so SQLite stays out of the page's wasm
// and its database lives in OPFS behind sync access handles.
const std = @import("std");
const zx = @import("zx");

var db: zx.Db = undefined;

pub fn init() !void {
    db = try zx.Db.Sqlite.open(zx.allocator, zx.Io.Web.io(), "db/notes.db", .{});
    _ = try db.run("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)", .empty);
}

pub const Note = struct { id: i64, body: []const u8 };

pub fn add(body: []const u8) !i64 {
    _ = try db.run("INSERT INTO notes (body) VALUES (?1)", .{body});
    return try count();
}

pub fn count() !i64 {
    var arena: std.heap.ArenaAllocator = .init(zx.allocator);
    defer arena.deinit();
    const row = (try db.get(arena.allocator(), "SELECT count(*) AS n FROM notes", .empty)) orelse return 0;
    return row.int("n");
}

pub fn latest(gpa: std.mem.Allocator, limit: u32) ![]const Note {
    const rows = try db.all(gpa, "SELECT id, body FROM notes ORDER BY id DESC LIMIT ?1", .{limit});
    const out = try gpa.alloc(Note, rows.len);
    for (rows, out) |row, *note| note.* = .{ .id = row.int("id"), .body = row.text("body") };
    return out;
}
