const std = @import("std");

pub fn Backend(Db: type) type {
    return struct {
        const Postgres = @This();

        allocator: std.mem.Allocator,

        pub const OpenOptions = Db.OpenOptions;

        pub fn open(allocator: std.mem.Allocator, io: std.Io, uri: []const u8, options: OpenOptions) !Db {
            _ = allocator;
            _ = io;
            _ = uri;
            _ = options;
            return Db.Error.Unsupported;
        }

        pub fn deserialize(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8, options: OpenOptions) !Db {
            _ = allocator;
            _ = io;
            _ = bytes;
            _ = options;
            return Db.Error.Unsupported;
        }

        pub fn db(self: *Postgres) Db {
            return .{ .userdata = self, .vtable = &database_vtable };
        }

        pub fn from(database: Db) !*Postgres {
            if (database.vtable != &database_vtable) return Db.Error.WrongBackend;
            return @ptrCast(@alignCast(database.userdata orelse return Db.Error.InvalidState));
        }

        fn prepare(_: ?*anyopaque, _: []const u8) !Db.Statement {
            return Db.Error.Unsupported;
        }
        fn run(_: ?*anyopaque, _: []const u8, _: Db.Bindings) !Db.RunResult {
            return Db.Error.Unsupported;
        }
        fn transaction(_: ?*anyopaque, _: Db.TransactionMode, _: *anyopaque, _: Db.TransactionCallback) !void {
            return Db.Error.Unsupported;
        }
        fn close(_: ?*anyopaque, _: bool) !void {
            return;
        }
        fn stmtAll(_: ?*anyopaque, _: std.mem.Allocator, _: Db.Bindings) ![]const Db.Row {
            return Db.Error.Unsupported;
        }
        fn stmtGet(_: ?*anyopaque, _: std.mem.Allocator, _: Db.Bindings) !?Db.Row {
            return Db.Error.Unsupported;
        }
        fn stmtRun(_: ?*anyopaque, _: Db.Bindings) !Db.RunResult {
            return Db.Error.Unsupported;
        }
        fn stmtValues(_: ?*anyopaque, _: std.mem.Allocator, _: Db.Bindings) ![]const []const Db.Value {
            return Db.Error.Unsupported;
        }
        fn stmtIterate(_: ?*anyopaque, _: Db.Bindings) !Db.Statement.Iterator {
            return Db.Error.Unsupported;
        }
        fn stmtDeinit(_: ?*anyopaque) void {}
        fn stmtToString(_: ?*anyopaque, _: std.mem.Allocator) ![]u8 {
            return Db.Error.Unsupported;
        }
        fn stmtColumnNames(_: ?*anyopaque) []const []const u8 {
            return &.{};
        }
        fn stmtColumnTypes(_: ?*anyopaque) []const Db.ColumnType {
            return &.{};
        }
        fn stmtParamCount(_: ?*anyopaque) usize {
            return 0;
        }

        pub const database_vtable: Db.VTable = .{
            .prepare = &prepare,
            .run = &run,
            .transaction = &transaction,
            .close = &close,
            .stmtAll = &stmtAll,
            .stmtGet = &stmtGet,
            .stmtRun = &stmtRun,
            .stmtValues = &stmtValues,
            .stmtIterate = &stmtIterate,
            .stmtDeinit = &stmtDeinit,
            .stmtToString = &stmtToString,
            .stmtColumnNames = &stmtColumnNames,
            .stmtColumnTypes = &stmtColumnTypes,
            .stmtParamCount = &stmtParamCount,
        };
    };
}
