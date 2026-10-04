const std = @import("std");
const zx = @import("zx");
const pg = if (zx.platform.isClient()) void else @import("pg");

const Database = @This();

pool: if (zx.platform.isClient()) void else *pg.Pool,

pub fn getCount(self: Database) !i64 {
    if (zx.platform.isClient()) return error.ClientHasNoDatabase;

    var result = try self.pool.query("SELECT count FROM ziex", .{});
    defer result.deinit();

    if (try result.next()) |row|
        return row.get(i64, 0);

    _ = try self.pool.exec("INSERT INTO ziex (count) VALUES (0)", .{});
    return 0;
}

pub fn setCount(self: Database, count: i64) !void {
    _ = try self.pool.exec("UPDATE ziex SET count = $1", .{count});
}

pub fn setup(self: Database) !void {
    _ = try self.pool.exec(@embedFile("migrations/init.sql"), .{});
}

pub fn init(io: anytype, allocator: std.mem.Allocator, uri: []const u8) !Database {
    if (zx.platform.isClient()) return error.ClientHasNoDatabase;

    if (uri.len == 0) return error.InvalidDatabaseUrl;

    const pgUri = try std.Uri.parse(uri);
    std.log.info("DB: {s}", .{uri});
    const pool = try pg.Pool.initUri(io, allocator, pgUri, .{ .size = 4 });

    const db: Database = .{ .pool = pool };
    try db.setup();
    return db;
}

pub fn deinit(self: *Database) void {
    if (zx.platform.isClient()) return;
    self.pool.deinit();
}
