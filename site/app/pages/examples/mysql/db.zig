//! MySQL backend for the shared studio UI. URL from `zx.secrets` (`MYSQL_URL`).
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const title = "MySQL Studio";
pub const subtitle = "zx.Db.Mysql over server events.";
pub const input_id = "mysql-input";
pub const check = studio.check;
pub const schema_sql =
    \\SELECT table_name AS tbl, column_name AS col, column_type AS type,
    \\  is_nullable = 'YES' AS nullable, column_key = 'PRI' AS pk
    \\FROM information_schema.columns
    \\WHERE table_schema = DATABASE()
    \\ORDER BY table_name, ordinal_position
;

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return gpa.print("SELECT * FROM `{s}` LIMIT 100;", .{name});
}

const persistent = studio.persistent;

pub fn open(io: std.Io) !zx.Db {
    if (comptime !zx.platform.isServer()) return error.Unsupported;

    try mu.lock(io);
    defer mu.unlock(io);
    if (cached) |db| return db;

    const url = try zx.secrets.require(persistent, "MYSQL_URL");
    defer persistent.free(url);

    // One connection: concurrent check/run requests queue on it instead of opening more.
    var database = try zx.Db.Mysql.open(persistent, io, url, .{ .max_pool_size = 1 });
    errdefer database.deinit();
    try seed(&database);
    cached = database;
    return database;
}

fn seed(database: *zx.Db) !void {
    _ = try database.run(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INT PRIMARY KEY AUTO_INCREMENT,
        \\  name TEXT NOT NULL,
        \\  email VARCHAR(255) UNIQUE
        \\)
    , .empty);
    _ = try database.run(
        \\INSERT IGNORE INTO users (id, name, email) VALUES
        \\  (1, 'Ada', 'ada@example.com'),
        \\  (2, 'Linus', 'linus@example.com'),
        \\  (3, 'Grace', 'grace@example.com')
    , .empty);
}
