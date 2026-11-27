//! Shared SQL studio types and query execution for the examples.
const std = @import("std");
const zx = @import("zx");

pub const Result = struct {
    columns: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    changes: usize = 0,
    err: ?[]const u8 = null,
};

/// Run one statement against any `zx.Db` backend; SQL errors land in `err`.
pub fn exec(database: *zx.Db, gpa: std.mem.Allocator, sql: []const u8) Result {
    var stmt = database.prepare(sql) catch |err| return .{ .err = @errorName(err) };
    defer stmt.deinit();

    const names = stmt.columnNames() catch |err| return .{ .err = @errorName(err) };
    if (names.len == 0) {
        const res = stmt.run(.empty) catch |err| return .{ .err = @errorName(err) };
        return .{ .changes = res.changes };
    }
    const columns = gpa.alloc([]const u8, names.len) catch return .{ .err = "OutOfMemory" };
    for (names, columns) |n, *c| c.* = gpa.dupe(u8, n) catch return .{ .err = "OutOfMemory" };

    const values = stmt.values(gpa, .empty) catch |err| return .{ .err = @errorName(err) };
    const rows = gpa.alloc([]const []const u8, values.len) catch return .{ .err = "OutOfMemory" };
    for (values, rows) |vals, *row| {
        const cells = gpa.alloc([]const u8, vals.len) catch return .{ .err = "OutOfMemory" };
        for (vals, cells) |v, *cell| cell.* = format(gpa, v) catch return .{ .err = "OutOfMemory" };
        row.* = cells;
    }
    return .{ .columns = columns, .rows = rows };
}

pub fn format(gpa: std.mem.Allocator, v: zx.Db.Value) ![]const u8 {
    return switch (v) {
        .null => "NULL",
        .integer => |i| std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}),
        .text => |t| t,
        .blob => |b| std.fmt.allocPrint(gpa, "x'{x}'", .{b}),
        .boolean => |b| if (b) "1" else "0",
    };
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
