const Db = @This();

const std = @import("std");
const Wire = @import("Wire.zig");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const Sqlite = @import("Db/Sqlite.zig");
pub const Wasm = @import("Db/Wasm.zig");
pub const Postgres = @import("Db/Postgres.zig");

pub const Error = error{
    Unimplemented,
    Closed,
    Busy,
    InvalidQuery,
    InvalidBindings,
    InvalidState,
    Unsupported,
    WrongBackend,
    OpenFailed,
    QueryFailed,
    RunFailed,
};

pub const OpenOptions = struct {
    readonly: bool = false,
    create: bool = true,
    max_pool_size: usize = 5,
};

pub const TransactionMode = enum {
    deferred,
    immediate,
    exclusive,
};

pub const ColumnType = enum {
    integer,
    float,
    text,
    blob,
    null,
    unknown,
};

pub const Value = Wire.Value;

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Row = struct {
    fields: []const Field,

    pub fn get(self: Row, name: []const u8) ?Value {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    pub fn as(self: Row, name: []const u8, comptime T: type) !T {
        const value = self.get(name) orelse return Error.InvalidQuery;
        return valueToType(T, value);
    }

    pub fn int(self: Row, name: []const u8) i64 {
        return switch (self.get(name) orelse .null) {
            .integer => |v| v,
            .float => |v| @intFromFloat(v),
            .boolean => |v| @intFromBool(v),
            else => 0,
        };
    }

    pub fn float(self: Row, name: []const u8) f64 {
        return switch (self.get(name) orelse .null) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            .boolean => |v| @floatFromInt(@intFromBool(v)),
            else => 0,
        };
    }

    pub fn text(self: Row, name: []const u8) []const u8 {
        return switch (self.get(name) orelse .null) {
            .text => |v| v,
            .blob => |v| v,
            else => "",
        };
    }

    pub fn boolean(self: Row, name: []const u8) bool {
        return switch (self.get(name) orelse .null) {
            .boolean => |v| v,
            .integer => |v| v != 0,
            .float => |v| v != 0,
            else => false,
        };
    }

    pub fn isNull(self: Row, name: []const u8) bool {
        return switch (self.get(name) orelse .null) {
            .null => true,
            else => false,
        };
    }
};

pub const NamedBinding = struct {
    name: []const u8,
    value: Value,
};

pub const Bindings = union(enum) {
    none,
    positional: []const Value,
    named: []const NamedBinding,

    pub const empty: Bindings = .{ .none = {} };

    pub fn fromPositional(values: []const Value) Bindings {
        return .{ .positional = values };
    }

    pub fn fromNamed(values: []const NamedBinding) Bindings {
        return .{ .named = values };
    }
};

fn BoundArgs(comptime ArgsT: type) type {
    if (ArgsT == Bindings) return struct {
        bindings: Bindings,
        fn init(value: Bindings) @This() {
            return .{ .bindings = value };
        }
        fn view(self: *const @This()) Bindings {
            return self.bindings;
        }
    };

    const info = @typeInfo(ArgsT);
    const is_empty = ArgsT == void or
        info == .enum_literal or
        (info == .@"struct" and info.@"struct".field_types.len == 0);
    if (is_empty) return struct {
        fn init(_: ArgsT) @This() {
            return .{};
        }
        fn view(_: *const @This()) Bindings {
            return .empty;
        }
    };

    if (info != .@"struct") {
        @compileError("Db bindings: expected a tuple or struct literal, got " ++ @typeName(ArgsT));
    }
    const fields = info.@"struct".field_names;

    if (info.@"struct".is_tuple) return struct {
        values: [fields.len]Value,
        fn init(value: ArgsT) @This() {
            var self: @This() = undefined;
            inline for (fields, 0..) |field_name, i| {
                self.values[i] = Value.of(@field(value, field_name));
            }
            return self;
        }
        fn view(self: *const @This()) Bindings {
            return .{ .positional = &self.values };
        }
    };

    return struct {
        values: [fields.len]NamedBinding,
        fn init(value: ArgsT) @This() {
            var self: @This() = undefined;
            inline for (fields, 0..) |field_name, i| {
                self.values[i] = .{ .name = field_name, .value = Value.of(@field(value, field_name)) };
            }
            return self;
        }
        fn view(self: *const @This()) Bindings {
            return .{ .named = &self.values };
        }
    };
}

pub const RunResult = struct {
    last_insert_id: i64 = 0,
    changes: usize = 0,
};

pub const TransactionCallback = *const fn (ctx: *anyopaque, db: *Db) anyerror!void;

pub const VTable = struct {
    prepare: *const fn (userdata: ?*anyopaque, sql: []const u8) anyerror!Statement,
    run: *const fn (userdata: ?*anyopaque, sql: []const u8, bindings: Bindings) anyerror!RunResult,
    transaction: *const fn (userdata: ?*anyopaque, mode: TransactionMode, cb_ctx: *anyopaque, cb: TransactionCallback) anyerror!void,
    close: *const fn (userdata: ?*anyopaque, throw_on_error: bool) anyerror!void,
    stmtAll: *const fn (stmt: ?*anyopaque, allocator: std.mem.Allocator, bindings: Bindings) anyerror![]const Row,
    stmtGet: *const fn (stmt: ?*anyopaque, allocator: std.mem.Allocator, bindings: Bindings) anyerror!?Row,
    stmtRun: *const fn (stmt: ?*anyopaque, bindings: Bindings) anyerror!RunResult,
    stmtValues: *const fn (stmt: ?*anyopaque, allocator: std.mem.Allocator, bindings: Bindings) anyerror![]const []const Value,
    stmtIterate: *const fn (stmt: ?*anyopaque, bindings: Bindings) anyerror!Statement.Iterator,
    stmtDeinit: *const fn (stmt: ?*anyopaque) void,
    stmtToString: *const fn (stmt: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    stmtColumnNames: *const fn (stmt: ?*anyopaque) []const []const u8,
    stmtColumnTypes: *const fn (stmt: ?*anyopaque) []const ColumnType,
    stmtParamCount: *const fn (stmt: ?*anyopaque) usize,
};

pub fn prepare(self: Db, sql: []const u8) !Statement {
    return self.vtable.prepare(self.userdata, sql);
}

/// Execute a statement that returns no rows (INSERT/UPDATE/DELETE/DDL).
/// `args` is an inline binding literal - see `BoundArgs` for accepted shapes,
/// e.g. `.{ "Ada", 9.5 }` (positional) or `.{ .name = "Ada" }` (named).
pub fn run(self: Db, sql: []const u8, args: anytype) !RunResult {
    const bound = BoundArgs(@TypeOf(args)).init(args);
    return self.vtable.run(self.userdata, sql, bound.view());
}

/// Prepare `sql` and fetch the first row (or null)
pub fn get(self: Db, allocator: std.mem.Allocator, sql: []const u8, args: anytype) !?Row {
    var statement = try self.prepare(sql);
    defer statement.deinit();
    return statement.get(allocator, args);
}

/// Prepare `sql` and fetch all rows
pub fn all(self: Db, allocator: std.mem.Allocator, sql: []const u8, args: anytype) ![]const Row {
    var statement = try self.prepare(sql);
    defer statement.deinit();
    return statement.all(allocator, args);
}

/// Prepare `sql` and fetch the first row into `T` (or null)
pub fn row(self: Db, allocator: std.mem.Allocator, comptime T: type, sql: []const u8, args: anytype) !?T {
    var statement = try self.prepare(sql);
    defer statement.deinit();
    return statement.row(allocator, T, args);
}

/// Prepare `sql` and fetch all rows into `[]T`
pub fn rows(self: Db, allocator: std.mem.Allocator, comptime T: type, sql: []const u8, args: anytype) ![]const T {
    var statement = try self.prepare(sql);
    defer statement.deinit();
    return statement.rows(allocator, T, args);
}

pub fn transaction(self: Db, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Db) anyerror!void) !void {
    return self.transactionWith(.deferred, ctx, cb);
}

pub fn transactionWith(self: Db, mode: TransactionMode, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Db) anyerror!void) !void {
    const Ctx = @TypeOf(ctx);
    const Trampoline = struct {
        fn call(raw_ctx: *anyopaque, handle: *Db) anyerror!void {
            const typed: *const Ctx = @ptrCast(@alignCast(raw_ctx));
            return cb(typed.*, handle.*);
        }
    };
    var ctx_copy = ctx;
    return self.vtable.transaction(self.userdata, mode, @ptrCast(&ctx_copy), &Trampoline.call);
}

/// Like `deinit`, but returns the error if closing fails.
pub fn close(self: *Db) !void {
    return self.vtable.close(self.userdata, true);
}

pub fn deinit(self: *Db) void {
    self.vtable.close(self.userdata, false) catch {};
}

pub const Statement = struct {
    db: Db,
    userdata: ?*anyopaque = null,

    pub const Iterator = struct {
        userdata: ?*anyopaque = null,
        next_fn: ?*const fn (ctx: *anyopaque) anyerror!?Row = null,
        deinit_fn: ?*const fn (ctx: *anyopaque) void = null,

        /// Yield the next row, or `null` when exhausted. The returned row is
        /// owned by the iterator and valid only until the next `next` call or
        /// `deinit` - copy out any fields you need to keep. Do not free it.
        pub fn next(self: *Iterator) !?Row {
            const ctx = self.userdata orelse return null;
            const next_fn = self.next_fn orelse return null;
            return next_fn(ctx);
        }

        pub fn deinit(self: *Iterator) void {
            const ctx = self.userdata orelse return;
            const deinit_fn = self.deinit_fn orelse return;
            deinit_fn(ctx);
            self.userdata = null;
            self.next_fn = null;
            self.deinit_fn = null;
        }
    };

    pub fn all(self: *Statement, allocator: std.mem.Allocator, args: anytype) ![]const Row {
        const handle = try self.requireHandle();
        const bound = BoundArgs(@TypeOf(args)).init(args);
        return self.db.vtable.stmtAll(handle, allocator, bound.view());
    }

    pub fn rows(self: *Statement, allocator: std.mem.Allocator, comptime T: type, args: anytype) ![]const T {
        const all_rows = try self.all(allocator, args);
        // Field names are shared across rows from the wasm columnar decoder; do not
        // free individual field name slices. Arena request allocators reclaim all.
        const typed_rows = try allocator.alloc(T, all_rows.len);
        errdefer allocator.free(typed_rows);

        if (all_rows.len == 0) return typed_rows;

        // Build name→index once; O(fields) lookups instead of O(rows·fields²).
        var index_of: [infoFieldCount(T)]?usize = @splat(null);
        inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, fi| {
            for (all_rows[0].fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    index_of[fi] = i;
                    break;
                }
            }
        }

        for (all_rows, 0..) |result_row, index| {
            typed_rows[index] = try rowToTypeIndexed(T, result_row, &index_of);
        }
        return typed_rows;
    }

    pub fn get(self: *Statement, allocator: std.mem.Allocator, args: anytype) !?Row {
        const handle = try self.requireHandle();
        const bound = BoundArgs(@TypeOf(args)).init(args);
        return self.db.vtable.stmtGet(handle, allocator, bound.view());
    }

    pub fn row(self: *Statement, allocator: std.mem.Allocator, comptime T: type, args: anytype) !?T {
        const maybe_row = try self.get(allocator, args);
        const result_row = maybe_row orelse return null;
        return try rowToType(T, result_row);
    }

    pub fn run(self: *Statement, args: anytype) !RunResult {
        const handle = try self.requireHandle();
        const bound = BoundArgs(@TypeOf(args)).init(args);
        return self.db.vtable.stmtRun(handle, bound.view());
    }

    pub fn values(self: *Statement, allocator: std.mem.Allocator, args: anytype) ![]const []const Value {
        const handle = try self.requireHandle();
        const bound = BoundArgs(@TypeOf(args)).init(args);
        return self.db.vtable.stmtValues(handle, allocator, bound.view());
    }

    pub fn iterate(self: *Statement, args: anytype) !Iterator {
        const handle = try self.requireHandle();
        const bound = BoundArgs(@TypeOf(args)).init(args);
        return self.db.vtable.stmtIterate(handle, bound.view());
    }

    pub fn deinit(self: *Statement) void {
        const handle = self.userdata orelse return;
        self.db.vtable.stmtDeinit(handle);
        self.userdata = null;
    }

    pub fn toString(self: *Statement, allocator: std.mem.Allocator) ![]u8 {
        const handle = try self.requireHandle();
        return self.db.vtable.stmtToString(handle, allocator);
    }

    pub fn columnNames(self: *Statement) ![]const []const u8 {
        const handle = try self.requireHandle();
        return self.db.vtable.stmtColumnNames(handle);
    }

    pub fn columnTypes(self: *Statement) ![]const ColumnType {
        const handle = try self.requireHandle();
        return self.db.vtable.stmtColumnTypes(handle);
    }

    pub fn paramCount(self: *Statement) !usize {
        const handle = try self.requireHandle();
        return self.db.vtable.stmtParamCount(handle);
    }

    fn requireHandle(self: *Statement) !*anyopaque {
        return self.userdata orelse Error.Closed;
    }
};

fn infoFieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn rowToType(comptime T: type, source_row: Row) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Db.Statement.row/rows expects a struct type, got " ++ @typeName(T));
    }

    var value: T = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        @field(value, field_name) = try source_row.as(field_name, field_type);
    }
    return value;
}

fn rowToTypeIndexed(comptime T: type, source_row: Row, index_of: *const [infoFieldCount(T)]?usize) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Db.Statement.row/rows expects a struct type, got " ++ @typeName(T));
    }

    var value: T = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types, 0..) |field_name, field_type, fi| {
        const idx = index_of.*[fi] orelse return Error.InvalidQuery;
        if (idx >= source_row.fields.len) return Error.InvalidQuery;
        @field(value, field_name) = try valueToType(field_type, source_row.fields[idx].value);
    }
    return value;
}

fn valueToType(comptime T: type, value: Value) !T {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => switch (value) {
            .integer => |v| @as(T, @intCast(v)),
            .float => |v| @as(T, @intFromFloat(v)),
            .boolean => |v| @as(T, if (v) 1 else 0),
            else => Error.InvalidQuery,
        },
        .float, .comptime_float => switch (value) {
            .float => |v| @as(T, @floatCast(v)),
            .integer => |v| @as(T, @floatFromInt(v)),
            .boolean => |v| @as(T, if (v) 1 else 0),
            else => Error.InvalidQuery,
        },
        .bool => switch (value) {
            .boolean => |v| v,
            .integer => |v| v != 0,
            .float => |v| v != 0,
            else => Error.InvalidQuery,
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk switch (value) {
                    .text => |v| v,
                    .blob => |v| v,
                    else => Error.InvalidQuery,
                };
            }
            @compileError("Unsupported Db.Row.as target: " ++ @typeName(T));
        },
        .optional => |opt| switch (value) {
            .null => null,
            else => try valueToType(opt.child, value),
        },
        else => @compileError("Unsupported Db.Row.as target: " ++ @typeName(T)),
    };
}

fn failingPrepare(_: ?*anyopaque, _: []const u8) anyerror!Statement {
    return Error.Closed;
}
fn failingRun(_: ?*anyopaque, _: []const u8, _: Bindings) anyerror!RunResult {
    return Error.Closed;
}
fn failingTransaction(_: ?*anyopaque, _: TransactionMode, _: *anyopaque, _: TransactionCallback) anyerror!void {
    return Error.Closed;
}
fn failingClose(_: ?*anyopaque, _: bool) anyerror!void {
    return;
}
fn failingStmtAll(_: ?*anyopaque, _: std.mem.Allocator, _: Bindings) anyerror![]const Row {
    return Error.Closed;
}
fn failingStmtGet(_: ?*anyopaque, _: std.mem.Allocator, _: Bindings) anyerror!?Row {
    return Error.Closed;
}
fn failingStmtRun(_: ?*anyopaque, _: Bindings) anyerror!RunResult {
    return Error.Closed;
}
fn failingStmtValues(_: ?*anyopaque, _: std.mem.Allocator, _: Bindings) anyerror![]const []const Value {
    return Error.Closed;
}
fn failingStmtIterate(_: ?*anyopaque, _: Bindings) anyerror!Statement.Iterator {
    return Error.Closed;
}
fn failingStmtDeinit(_: ?*anyopaque) void {}
fn failingStmtToString(_: ?*anyopaque, _: std.mem.Allocator) anyerror![]u8 {
    return Error.Closed;
}
fn failingStmtColumnNames(_: ?*anyopaque) []const []const u8 {
    return &.{};
}
fn failingStmtColumnTypes(_: ?*anyopaque) []const ColumnType {
    return &.{};
}
fn failingStmtParamCount(_: ?*anyopaque) usize {
    return 0;
}

pub const failing_vtable = VTable{
    .prepare = &failingPrepare,
    .run = &failingRun,
    .transaction = &failingTransaction,
    .close = &failingClose,
    .stmtAll = &failingStmtAll,
    .stmtGet = &failingStmtGet,
    .stmtRun = &failingStmtRun,
    .stmtValues = &failingStmtValues,
    .stmtIterate = &failingStmtIterate,
    .stmtDeinit = &failingStmtDeinit,
    .stmtToString = &failingStmtToString,
    .stmtColumnNames = &failingStmtColumnNames,
    .stmtColumnTypes = &failingStmtColumnTypes,
    .stmtParamCount = &failingStmtParamCount,
};

pub const failing = Db{ .vtable = &failing_vtable };
