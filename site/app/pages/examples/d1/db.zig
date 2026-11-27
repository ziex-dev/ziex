//! D1 / wasm backend for the shared studio UI.
//! On Cloudflare Workers this opens `zx.Db.Wasm` against the `"default"` binding
//! (`wrangler` `DB` → `ziex({ db: "DB" })`). Locally it falls back to `zx.db` (sqlite).
const std = @import("std");
const zx = @import("zx");
const studio = @import("../studio_lib.zig");

pub const Result = studio.Result;
pub const title = "D1 Studio";
pub const subtitle = "zx.Db.Wasm (Cloudflare D1) over a server action. Press Ctrl/⌘+Enter to run.";
pub const input_id = "d1-input";

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

    var database: zx.Db = if (comptime zx.platform.os == .wasi)
        try zx.Db.Wasm.open(gpa, io, "default", .{})
    else
        // Same SQL API as D1; App already opened sqlite as `zx.db` for local preview.
        zx.db;

    try seed(&database);
    cached = database;
    return database;
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
