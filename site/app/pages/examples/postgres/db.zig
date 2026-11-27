//! Postgres backend for the shared studio UI. URL from `zx.secrets` (`POSTGRES_URL`).
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const Result = studio.Result;
pub const title = "Postgres Studio";
pub const subtitle = "zx.Db.Postgres over a server action. Press Ctrl/⌘+Enter to run.";
pub const input_id = "postgres-input";

var mu: std.Io.Mutex = .init;
var cached: ?zx.Db = null;

pub fn selectTable(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "SELECT * FROM \"{s}\" LIMIT 100;", .{name});
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

    const url = try zx.secrets.require(gpa, "POSTGRES_URL");
    defer gpa.free(url);

    var database = try zx.Db.Postgres.open(gpa, io, url, .{});
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

fn tables(gpa: std.mem.Allocator, database: *zx.Db) ![]const []const u8 {
    const rows = try database.all(gpa,
        \\SELECT tablename AS name
        \\FROM pg_catalog.pg_tables
        \\WHERE schemaname = 'public'
        \\ORDER BY tablename
    , .empty);
    const out = try gpa.alloc([]const u8, rows.len);
    for (rows, out) |row, *name| name.* = try gpa.dupe(u8, row.text("name"));
    return out;
}
