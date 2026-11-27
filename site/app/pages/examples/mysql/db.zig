//! MySQL backend for the shared studio UI. URL from `zx.secrets` (`MYSQL_URL`).
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const Result = studio.Result;
pub const title = "MySQL Studio";
pub const subtitle = "zx.Db.Mysql over a server action. Press Ctrl/⌘+Enter to run.";
pub const input_id = "mysql-input";

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return gpa.print("SELECT * FROM `{s}` LIMIT 100;", .{name});
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
    if (cached) |db| return db;

    const url = try zx.secrets.require(gpa, "MYSQL_URL");
    defer gpa.free(url);

    var database = try zx.Db.Mysql.open(gpa, io, url, .{});
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

fn tables(gpa: std.mem.Allocator, database: *zx.Db) ![]const []const u8 {
    const rows = try database.all(gpa,
        \\SELECT table_name AS name
        \\FROM information_schema.tables
        \\WHERE table_schema = DATABASE()
        \\ORDER BY table_name
    , .empty);
    const out = try gpa.alloc([]const u8, rows.len);
    for (rows, out) |row, *name| name.* = try gpa.dupe(u8, row.text("name"));
    return out;
}
