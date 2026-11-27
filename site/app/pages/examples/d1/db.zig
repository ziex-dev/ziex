const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const Result = studio.Result;
pub const title = "D1 Studio";
pub const subtitle = "zx.Db.Wasm (Cloudflare D1) over a server action. Press Ctrl/⌘+Enter to run.";
pub const input_id = "d1-input";

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;
var next_check: i64 = 0;

const reset_key = "examples:d1:reset";
const reset_every: std.Io.Duration = .fromSeconds(60 * 60);
const check_every_s = 60;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return gpa.print("SELECT * FROM \"{s}\" LIMIT 100;", .{name});
}

pub fn bootstrap(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var database = try open(gpa, io);
    return tables(arena, &database);
}

pub fn exec(gpa: std.mem.Allocator, io: std.Io, sql: []const u8) Result {
    var database = open(gpa, io) catch |err| return .{ .err = @errorName(err) };
    return studio.exec(&database, gpa, sql);
}

pub fn listTables(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var database = try open(gpa, io);
    return tables(arena, &database);
}

fn open(gpa: std.mem.Allocator, io: std.Io) !zx.Db {
    if (comptime !zx.platform.isServer()) return error.Unsupported;

    try mu.lock(io);
    defer mu.unlock(io);

    var database = cached orelse blk: {
        var database: zx.Db = if (comptime zx.platform.os == .wasi)
            try zx.Db.Wasm.open(gpa, io, "studio", .{})
        else
            try zx.Db.Sqlite.open(gpa, io, ":memory:", .{});
        try seed(&database);
        cached = database;
        break :blk database;
    };

    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    if (now >= next_check) {
        next_check = now + check_every_s;
        maybeReset(gpa, &database) catch |err| std.log.warn("d1 studio reset failed: {t}", .{err});
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

fn tables(gpa: std.mem.Allocator, database: *zx.Db) ![]const []const u8 {
    const rows = try database.all(gpa,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        \\ORDER BY name
    , .empty);
    const out = try gpa.alloc([]const u8, rows.len);
    for (rows, out) |row, *name| name.* = try gpa.dupe(u8, row.text("name"));
    return out;
}
