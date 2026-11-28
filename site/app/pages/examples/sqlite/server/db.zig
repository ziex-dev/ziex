const std = @import("std");
const zx = @import("zx");
const studio = @import("../../studio_lib.zig");

pub const title = "SQLite Studio (server)";
pub const subtitle = "zx.Db.Wasm (Cloudflare D1) on wasi, zx.Db.Sqlite natively, over server events.";
pub const input_id = "sqlite-server-input";
pub const schema_sql =
    \\SELECT m.name AS tbl, p.name AS col, p.type AS type, NOT p."notnull" AS nullable, p.pk > 0 AS pk
    \\FROM sqlite_master m JOIN pragma_table_info(m.name) p
    \\WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT LIKE '\_cf\_%' ESCAPE '\'
    \\ORDER BY m.name, p.cid
;

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;
var next_check: i64 = 0;

const reset_key = "examples:d1:reset";
const reset_every: std.Io.Duration = .fromSeconds(60 * 60);
const check_every_s = 60;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return gpa.print("SELECT * FROM \"{s}\" LIMIT 100;", .{name});
}

// D1 prepares lazily, so ask SQLite to compile the statement via EXPLAIN without running it.
pub fn check(database: *zx.Db, arena: std.mem.Allocator, sql: []const u8, diagnostics: *zx.Db.Diagnostics) ?anyerror {
    if (comptime zx.platform.os != .wasi) return studio.check(database, arena, sql, diagnostics);
    const explain = arena.print("EXPLAIN {s}", .{sql}) catch |err| return err;
    var stmt = database.prepare(explain, .{ .diagnostics = diagnostics }) catch |err| return err;
    defer stmt.deinit();
    _ = stmt.all(arena, .empty) catch |err| return err;
    return null;
}

const persistent = studio.persistent;

pub fn open(io: std.Io) !zx.Db {
    if (comptime !zx.platform.isServer()) return error.Unsupported;

    try mu.lock(io);
    defer mu.unlock(io);

    var database = cached orelse blk: {
        var database: zx.Db = if (comptime zx.platform.os == .wasi)
            try zx.Db.Wasm.open(persistent, io, "studio", .{})
        else
            try zx.Db.Sqlite.open(persistent, io, ":memory:", .{});
        try seed(&database);
        cached = database;
        break :blk database;
    };

    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    if (now >= next_check) {
        next_check = now + check_every_s;
        maybeReset(persistent, &database) catch |err| std.log.warn("d1 studio reset failed: {t}", .{err});
    }
    return database;
}

/// The reset marker lives in KV (unreachable from SQL) with a TTL; once it
/// expires the next request wipes and re-seeds the db.
fn maybeReset(gpa: std.mem.Allocator, database: *zx.Db) !void {
    if (try zx.kv.get(gpa, reset_key)) |v| return gpa.free(v);
    try zx.kv.put(reset_key, "1", .{ .ttl = reset_every });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const objects = try database.all(arena,
        \\SELECT type, name FROM sqlite_master
        \\WHERE type IN ('view', 'table')
        \\  AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '\_cf\_%' ESCAPE '\'
        \\ORDER BY type = 'table'
    , .empty);
    // Second pass catches tables whose drop failed on a foreign key.
    for (0..2) |_| for (objects) |obj| {
        const name = try std.mem.replaceOwned(u8, arena, obj.text("name"), "\"", "\"\"");
        const sql = try arena.print("DROP {s} IF EXISTS \"{s}\"", .{ obj.text("type"), name });
        _ = database.run(sql, .empty) catch {};
    };
    try seed(database);
}

fn seed(database: *zx.Db) !void {
    _ = try database.run(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT UNIQUE
        \\)
    , .empty);
    _ = try database.run(
        \\INSERT OR IGNORE INTO users (id, name, email) VALUES
        \\  (1, 'Ada', 'ada@example.com'),
        \\  (2, 'Linus', 'linus@example.com'),
        \\  (3, 'Grace', 'grace@example.com')
    , .empty);
}
