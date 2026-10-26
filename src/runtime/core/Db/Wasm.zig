const Wasm = @This();

const std = @import("std");
const Db = @import("../Db.zig");
const Wire = @import("../Wire.zig");

binding_name: []u8,
allocator: std.mem.Allocator,

const StatementCtx = struct {
    binding_name: []u8,
    sql: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *StatementCtx) void {
        self.allocator.free(self.binding_name);
        self.allocator.free(self.sql);
    }
};

// --- Constructors --- //

// `allocator`/`io`/`options` exist for parity with other backends; wasm_allocator is always used.
pub fn open(allocator_unused: ?std.mem.Allocator, io: ?std.Io, filename: []const u8, options: Db.OpenOptions) !Db {
    _ = allocator_unused;
    _ = io;
    _ = options;
    const binding_name = filename;
    if (ext.db_open(binding_name.ptr, binding_name.len) < 0) return error.DatabaseOpenFailed;

    const allocator = std.heap.wasm_allocator;
    const self = try allocator.create(Wasm);
    errdefer allocator.destroy(self);

    self.* = .{
        .binding_name = try allocator.dupe(u8, binding_name),
        .allocator = allocator,
    };

    return self.db();
}

pub fn deserialize(_: ?std.mem.Allocator, _: ?std.Io, _: []const u8, _: Db.OpenOptions) !Db {
    return error.Unsupported;
}

pub fn db(self: *Wasm) Db {
    return .{ .userdata = self, .vtable = &database_vtable };
}

fn deinitState(self: *Wasm) void {
    self.allocator.free(self.binding_name);
}

fn prepare(ud: ?*anyopaque, sql: []const u8) !Db.Statement {
    const self: *Wasm = @ptrCast(@alignCast(ud));
    const allocator = self.allocator;

    const statement_ctx = try allocator.create(StatementCtx);
    errdefer allocator.destroy(statement_ctx);

    statement_ctx.* = .{
        .binding_name = try allocator.dupe(u8, self.binding_name),
        .sql = try allocator.dupe(u8, sql),
        .allocator = allocator,
    };

    return .{
        .db = .{ .userdata = ud, .vtable = &database_vtable },
        .handle = @ptrCast(statement_ctx),
    };
}

fn run(ud: ?*anyopaque, sql: []const u8, bindings: Db.Bindings) !Db.RunResult {
    const self: *Wasm = @ptrCast(@alignCast(ud));
    return runQuery(self.binding_name, sql, bindings);
}

fn transaction(_: ?*anyopaque, _: Db.TransactionMode, _: *anyopaque, _: Db.TransactionCallback) !void {
    return error.Unsupported;
}

fn close(ud: ?*anyopaque, _: bool) !void {
    const self: *Wasm = @ptrCast(@alignCast(ud));
    const allocator = self.allocator;
    self.deinitState();
    allocator.destroy(self);
}

fn all(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const Db.Row {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    return selectRows(allocator, ext.db_all, statement_ctx.binding_name, statement_ctx.sql, bindings);
}

fn get(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) !?Db.Row {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    const rows = try selectRows(allocator, ext.db_get, statement_ctx.binding_name, statement_ctx.sql, bindings);
    if (rows.len == 0) {
        allocator.free(rows);
        return null;
    }
    const row = rows[0];
    allocator.free(rows);
    return row;
}

fn runStatement(ud: ?*anyopaque, bindings: Db.Bindings) !Db.RunResult {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    return runQuery(statement_ctx.binding_name, statement_ctx.sql, bindings);
}

fn values(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const []const Db.Value {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    return selectValues(allocator, statement_ctx.binding_name, statement_ctx.sql, bindings);
}

fn iterate(_: ?*anyopaque, _: Db.Bindings) !Db.Statement.Iterator {
    return error.Unsupported;
}

fn finalize(ud: ?*anyopaque) void {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    const allocator = statement_ctx.allocator;
    statement_ctx.deinit();
    allocator.destroy(statement_ctx);
}

fn toString(ud: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const statement_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
    return allocator.dupe(u8, statement_ctx.sql);
}

fn columnNames(_: ?*anyopaque) []const []const u8 {
    return &.{};
}

fn columnTypes(_: ?*anyopaque) []const Db.ColumnType {
    return &.{};
}

fn paramsCount(_: ?*anyopaque) usize {
    return 0;
}

const HostQuery = fn (
    ns_ptr: [*]const u8,
    ns_len: usize,
    sql_ptr: [*]const u8,
    sql_len: usize,
    bindings_ptr: [*]const u8,
    bindings_len: usize,
    out_ptr: *[*]u8,
) callconv(.c) i32;

const HostBytes = struct {
    bytes: []u8,

    fn free(self: HostBytes) void {
        std.heap.wasm_allocator.free(self.bytes);
    }
};

fn encodeBindings(w: *std.Io.Writer, bindings: Db.Bindings) !void {
    switch (bindings) {
        .none => try Wire.encodeArgs(w, .none),
        .positional => |vals| try Wire.encodeArgs(w, .{ .list = vals }),
        .named => return error.Unsupported,
    }
}

fn cloneValue(allocator: std.mem.Allocator, v: Wire.Value) !Db.Value {
    return switch (v) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
        else => v,
    };
}

fn callHost(comptime op: HostQuery, binding_name: []const u8, sql: []const u8, bindings: Db.Bindings) !?HostBytes {
    var bindings_buf = std.Io.Writer.Allocating.init(std.heap.wasm_allocator);
    defer bindings_buf.deinit();
    try encodeBindings(&bindings_buf.writer, bindings);
    const bindings_bytes = bindings_buf.written();

    var ptr: [*]u8 = undefined;
    const n = op(
        binding_name.ptr,
        binding_name.len,
        sql.ptr,
        sql.len,
        bindings_bytes.ptr,
        bindings_bytes.len,
        &ptr,
    );
    if (n < 0) return error.DatabaseQueryFailed;
    if (n == 0) return null;
    return .{ .bytes = ptr[0..@intCast(n)] };
}

fn mapWire(err: anyerror) anyerror {
    return switch (err) {
        error.EndOfStream, error.BadMagic, error.BadKind, error.Unsupported => error.DatabaseQueryFailed,
        else => err,
    };
}

fn runQuery(binding_name: []const u8, sql: []const u8, bindings: Db.Bindings) !Db.RunResult {
    const result = callHost(ext.db_run, binding_name, sql, bindings) catch |err| switch (err) {
        error.DatabaseQueryFailed => return error.DatabaseRunFailed,
        else => |e| return e,
    };
    const payload = result orelse return error.DatabaseRunFailed;
    defer payload.free();

    const decoded = Wire.decodePair(payload.bytes) catch return error.DatabaseRunFailed;
    return .{ .last_insert_id = decoded.a, .changes = @intCast(decoded.b) };
}

fn freeRowValues(allocator: std.mem.Allocator, fields: []const Db.Field) void {
    for (fields) |f| switch (f.value) {
        .text => |t| allocator.free(t),
        .blob => |b| allocator.free(b),
        else => {},
    };
}

fn selectRows(
    allocator: std.mem.Allocator,
    comptime op: HostQuery,
    binding_name: []const u8,
    sql: []const u8,
    bindings: Db.Bindings,
) ![]const Db.Row {
    const payload = try callHost(op, binding_name, sql, bindings) orelse return &.{};
    defer payload.free();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const records = Wire.decodeRecords(arena_state.allocator(), payload.bytes) catch |err| return mapWire(err);
    if (records.len == 0) return &.{};

    const ncols = records[0].fields.len;
    // Column names are shared across rows (same pointers); callers free them once.
    const names = try allocator.alloc([]const u8, ncols);
    var names_pending = true;
    errdefer {
        if (names_pending) {
            for (names) |n| allocator.free(n);
            allocator.free(names);
        }
    }
    for (names, records[0].fields) |*n, f| n.* = try allocator.dupe(u8, f.name);

    const rows = try allocator.alloc(Db.Row, records.len);
    errdefer allocator.free(rows);
    var filled: usize = 0;
    errdefer {
        while (filled > 0) {
            filled -= 1;
            freeRowValues(allocator, rows[filled].fields);
            allocator.free(rows[filled].fields);
        }
    }

    for (records, rows) |rec, *row| {
        const fields = try allocator.alloc(Db.Field, ncols);
        errdefer allocator.free(fields);
        for (fields, rec.fields, names) |*df, wf, name| {
            df.* = .{ .name = name, .value = try cloneValue(allocator, wf.value) };
        }
        row.* = .{ .fields = fields };
        filled += 1;
    }
    // Transfer name string ownership to row fields; drop the temporary pointer array.
    names_pending = false;
    allocator.free(names);
    return rows;
}

fn selectValues(allocator: std.mem.Allocator, binding_name: []const u8, sql: []const u8, bindings: Db.Bindings) ![]const []const Db.Value {
    const payload = try callHost(ext.db_values, binding_name, sql, bindings) orelse return &.{};
    defer payload.free();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const wire_rows = Wire.decodeRows(arena_state.allocator(), payload.bytes) catch |err| return mapWire(err);

    const rows = try allocator.alloc([]const Db.Value, wire_rows.len);
    errdefer allocator.free(rows);
    var filled: usize = 0;
    errdefer {
        while (filled > 0) {
            filled -= 1;
            for (rows[filled]) |v| switch (v) {
                .text => |t| allocator.free(t),
                .blob => |b| allocator.free(b),
                else => {},
            };
            allocator.free(rows[filled]);
        }
    }

    for (wire_rows, rows) |wr, *row| {
        const cells = try allocator.alloc(Db.Value, wr.len);
        errdefer allocator.free(cells);
        for (wr, cells) |wv, *dv| dv.* = try cloneValue(allocator, wv);
        row.* = cells;
        filled += 1;
    }
    return rows;
}

const ext = struct {
    pub extern "__zx_db" fn db_open(
        ns_ptr: [*]const u8,
        ns_len: usize,
    ) i32;

    pub extern "__zx_db" fn db_run(
        ns_ptr: [*]const u8,
        ns_len: usize,
        sql_ptr: [*]const u8,
        sql_len: usize,
        bindings_ptr: [*]const u8,
        bindings_len: usize,
        out_ptr: *[*]u8,
    ) i32;

    pub extern "__zx_db" fn db_get(
        ns_ptr: [*]const u8,
        ns_len: usize,
        sql_ptr: [*]const u8,
        sql_len: usize,
        bindings_ptr: [*]const u8,
        bindings_len: usize,
        out_ptr: *[*]u8,
    ) i32;

    pub extern "__zx_db" fn db_all(
        ns_ptr: [*]const u8,
        ns_len: usize,
        sql_ptr: [*]const u8,
        sql_len: usize,
        bindings_ptr: [*]const u8,
        bindings_len: usize,
        out_ptr: *[*]u8,
    ) i32;

    pub extern "__zx_db" fn db_values(
        ns_ptr: [*]const u8,
        ns_len: usize,
        sql_ptr: [*]const u8,
        sql_len: usize,
        bindings_ptr: [*]const u8,
        bindings_len: usize,
        out_ptr: *[*]u8,
    ) i32;
};

const database_vtable = Db.VTable{
    .prepare = &prepare,
    .run = &run,
    .transaction = &transaction,
    .close = &close,
    .stmtAll = &all,
    .stmtGet = &get,
    .stmtRun = &runStatement,
    .stmtValues = &values,
    .stmtIterate = &iterate,
    .stmtFinalize = &finalize,
    .stmtToString = &toString,
    .stmtColumnNames = &columnNames,
    .stmtColumnTypes = &columnTypes,
    .stmtParamsCount = &paramsCount,
};
