//! Postgres backend for the shared studio UI. URL from `zx.secrets` (`POSTGRES_URL`).
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const title = "Postgres Studio";
pub const subtitle = "zx.Db.Postgres over server events.";
pub const input_id = "postgres-input";
pub const check = studio.check;
pub const schema_sql =
    \\SELECT c.table_name::text AS tbl, c.column_name::text AS col, c.data_type::text AS type,
    \\  c.is_nullable = 'YES' AS nullable,
    \\  EXISTS (
    \\    SELECT 1 FROM information_schema.table_constraints t
    \\    JOIN information_schema.key_column_usage k USING (constraint_schema, constraint_name)
    \\    WHERE t.constraint_type = 'PRIMARY KEY' AND k.table_schema = c.table_schema
    \\      AND k.table_name = c.table_name AND k.column_name = c.column_name
    \\  ) AS pk
    \\FROM information_schema.columns c
    \\WHERE c.table_schema = 'public'
    \\ORDER BY c.table_name, c.ordinal_position
;

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return gpa.print("SELECT * FROM \"{s}\" LIMIT 100;", .{name});
}

const persistent = studio.persistent;

pub fn open(io: std.Io) !zx.Db {
    if (comptime !zx.platform.isServer()) return error.Unsupported;

    try mu.lock(io);
    defer mu.unlock(io);
    if (cached) |db| return db;

    const url = try zx.secrets.require(persistent, "POSTGRES_URL");
    defer persistent.free(url);

    // One connection: concurrent check/run requests queue on it instead of opening more.
    var database = try zx.Db.Postgres.open(persistent, io, url, .{ .max_pool_size = 1 });
    errdefer database.deinit();
    try seed(&database);
    cached = database;
    return database;
}

fn seed(database: *zx.Db) !void {
    _ = try database.run(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT UNIQUE
        \\)
    , .empty);
    _ = try database.run(
        \\INSERT INTO users (id, name, email) VALUES
        \\  (1, 'Ada', 'ada@example.com'),
        \\  (2, 'Linus', 'linus@example.com'),
        \\  (3, 'Grace', 'grace@example.com')
        \\ON CONFLICT (id) DO NOTHING
    , .empty);
}
