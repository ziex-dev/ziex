// SQLite backend for `zx.Db`, over the amalgamation; in the browser, through a VFS (`web.zig`).
const std = @import("std");
const builtin = @import("builtin");
pub const c = @import("c");
const web = @import("web.zig");

const browser = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding;
comptime {
    if (browser) _ = web;
}

pub fn Backend(Db: type) type {
    return struct {
        const Sqlite = @This();

        const main_schema: [:0]const u8 = "main";

        // --- Thin C wrappers --- //

        const Conn = struct {
            ptr: *c.sqlite3,

            fn open(path: [*:0]const u8, flags: c_int) !Conn {
                var ptr: ?*c.sqlite3 = null;
                const rc = c.sqlite3_open_v2(path, &ptr, flags, null);
                if (rc != c.SQLITE_OK) {
                    // sqlite may hand back a handle even on failure; it must still be closed
                    if (ptr) |p| _ = c.sqlite3_close_v2(p);
                    return mapSqliteError(rc);
                }
                return .{ .ptr = ptr.? };
            }

            fn close(self: Conn) void {
                _ = c.sqlite3_close_v2(self.ptr);
            }

            fn exec(self: Conn, sql: [*:0]const u8) !void {
                try check(c.sqlite3_exec(self.ptr, sql, null, null, null));
            }

            fn busyTimeout(self: Conn, ms: c_int) !void {
                try check(c.sqlite3_busy_timeout(self.ptr, ms));
            }

            fn prepare(self: Conn, sql: []const u8) !Stmt {
                var stmt: ?*c.sqlite3_stmt = null;
                var tail: [*c]const u8 = null;
                try check(c.sqlite3_prepare_v2(self.ptr, sql.ptr, @intCast(sql.len), &stmt, &tail));
                // null stmt means the input was empty or only comments
                const ptr = stmt orelse return Db.Error.InvalidQuery;
                errdefer _ = c.sqlite3_finalize(ptr);

                // sqlite silently ignores everything after the first statement; reject it in debug
                if (builtin.mode == .debug and tail != null) {
                    const consumed: usize = @intFromPtr(tail) - @intFromPtr(sql.ptr);
                    if (consumed < sql.len) {
                        var extra: ?*c.sqlite3_stmt = null;
                        const rc = c.sqlite3_prepare_v2(self.ptr, tail, @intCast(sql.len - consumed), &extra, null);
                        if (extra) |e| _ = c.sqlite3_finalize(e);
                        if (rc != c.SQLITE_OK or extra != null) return error.MultipleStatements;
                    }
                }
                return .{ .ptr = ptr };
            }

            fn changes(self: Conn) usize {
                return @intCast(c.sqlite3_changes(self.ptr));
            }

            fn lastInsertId(self: Conn) i64 {
                return c.sqlite3_last_insert_rowid(self.ptr);
            }
        };

        const Stmt = struct {
            ptr: *c.sqlite3_stmt,

            fn deinit(self: Stmt) void {
                _ = c.sqlite3_finalize(self.ptr);
            }

            fn step(self: Stmt) !bool {
                return switch (c.sqlite3_step(self.ptr)) {
                    c.SQLITE_ROW => true,
                    c.SQLITE_DONE => false,
                    else => |rc| mapSqliteError(rc),
                };
            }

            fn stepToCompletion(self: Stmt) !void {
                while (try self.step()) {}
            }

            fn reset(self: Stmt) !void {
                try check(c.sqlite3_reset(self.ptr));
            }

            fn clearBindings(self: Stmt) !void {
                try check(c.sqlite3_clear_bindings(self.ptr));
            }

            fn columnCount(self: Stmt) usize {
                return @intCast(c.sqlite3_data_count(self.ptr));
            }

            fn columnName(self: Stmt, index: usize) []const u8 {
                const name = c.sqlite3_column_name(self.ptr, @intCast(index)) orelse return "";
                return std.mem.span(name);
            }

            fn columnBytes(self: Stmt, index: usize, ptr: ?*const anyopaque) []const u8 {
                const p: [*]const u8 = @ptrCast(ptr orelse return "");
                const len: usize = @intCast(c.sqlite3_column_bytes(self.ptr, @intCast(index)));
                return p[0..len];
            }
        };

        // The error `conn`'s last call left, if any.
        fn report(conn: Conn, diagnostics: *Db.Diagnostics) void {
            const rc = c.sqlite3_errcode(conn.ptr);
            if (rc == c.SQLITE_OK or rc == c.SQLITE_ROW or rc == c.SQLITE_DONE) return;
            const offset = c.sqlite3_error_offset(conn.ptr);
            diagnostics.set(std.mem.span(c.sqlite3_errmsg(conn.ptr)), if (offset >= 0) @intCast(offset) else null);
        }

        const Pool = struct {
            conns: []Conn,
            available: usize,
            mutex: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            allocator: std.mem.Allocator,

            fn init(allocator: std.mem.Allocator, size: usize, path: [*:0]const u8, flags: c_int, busy_timeout_ms: c_int) !*Pool {
                const pool = try allocator.create(Pool);
                errdefer allocator.destroy(pool);

                const conns = try allocator.alloc(Conn, size);
                errdefer allocator.free(conns);

                var opened: usize = 0;
                errdefer for (conns[0..opened]) |conn| conn.close();

                for (conns, 0..) |*slot, i| {
                    slot.* = try Conn.open(path, flags);
                    opened += 1;
                    try configureConnection(slot.*, busy_timeout_ms);
                    if (i == 0) try slot.exec("pragma journal_mode=wal");
                }

                pool.* = .{ .conns = conns, .available = size, .allocator = allocator };
                return pool;
            }

            fn deinit(self: *Pool) void {
                for (self.conns) |conn| conn.close();
                self.allocator.free(self.conns);
                self.allocator.destroy(self);
            }

            fn acquire(self: *Pool, io: std.Io) std.Io.Cancelable!Conn {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                while (self.available == 0) self.cond.waitUncancelable(io, &self.mutex);
                self.available -= 1;
                return self.conns[self.available];
            }

            fn release(self: *Pool, io: std.Io, conn: Conn) void {
                self.mutex.lockUncancelable(io);
                self.conns[self.available] = conn;
                self.available += 1;
                self.mutex.unlock(io);
                self.cond.signal(io);
            }
        };

        fn check(rc: c_int) !void {
            if (rc != c.SQLITE_OK) return mapSqliteError(rc);
        }

        const DatabaseMode = enum {
            single,
            pooled,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        mode: DatabaseMode,
        path: []u8,
        flags: c_int,
        busy_timeout_ms: c_int,
        schema: [:0]const u8 = main_schema,
        conn: ?Conn = null,
        pool: ?*Pool = null,
        owns_resources: bool = true,

        fn deinitState(self: *Sqlite) void {
            if (!self.owns_resources) return;
            if (self.pool) |pool| {
                pool.deinit();
            } else if (self.conn) |conn| {
                conn.close();
            }
            self.allocator.free(self.path);
        }

        fn acquire(self: *Sqlite, diagnostics: ?*Db.Diagnostics) !BorrowedConn {
            return switch (self.mode) {
                .single => .{ .conn = self.conn orelse return Db.Error.InvalidState, .io = self.io, .diagnostics = diagnostics },
                .pooled => .{ .conn = try (self.pool orelse return Db.Error.InvalidState).acquire(self.io), .io = self.io, .pool = self.pool, .diagnostics = diagnostics },
            };
        }

        const BorrowedConn = struct {
            conn: Conn,
            io: std.Io,
            pool: ?*Pool = null,
            diagnostics: ?*Db.Diagnostics = null,

            fn deinit(self: *BorrowedConn) void {
                if (self.diagnostics) |d| report(self.conn, d);
                if (self.pool) |pool| pool.release(self.io, self.conn);
            }
        };

        const PreparedExec = struct {
            borrowed: BorrowedConn,
            stmt: Stmt,

            fn deinit(self: *PreparedExec) void {
                self.stmt.deinit();
                self.borrowed.deinit();
            }
        };

        const StatementCtx = struct {
            allocator: std.mem.Allocator,
            db_ctx: *Sqlite,
            sql: []u8,
            diagnostics: ?*Db.Diagnostics,
            prototype: ?Stmt = null,
            column_names: [][]const u8,
            column_types: []Db.ColumnType,
            declared_types: []?[]const u8,
            param_count: usize,

            fn deinit(self: *StatementCtx) void {
                for (self.column_names) |name| self.allocator.free(name);
                self.allocator.free(self.column_names);
                self.allocator.free(self.column_types);
                for (self.declared_types) |decl_type| {
                    if (decl_type) |name| self.allocator.free(name);
                }
                self.allocator.free(self.declared_types);
                self.allocator.free(self.sql);
                if (self.prototype) |prototype| prototype.deinit();
            }
        };

        const IteratorCtx = struct {
            allocator: std.mem.Allocator,
            exec: PreparedExec,
            done: bool = false,
            current: ?Db.Row = null,

            fn releaseCurrent(self: *IteratorCtx) void {
                if (self.current) |row| {
                    freeRow(self.allocator, row);
                    self.current = null;
                }
            }
        };

        // --- Options --- //
        pub const OpenOptions = struct {
            readonly: bool = false,
            create: bool = true,
            safe_integers: bool = false,
            strict: bool = false,
            max_pool_size: usize = 5,
            /// How long a statement waits for a lock before failing with `SQLITE_BUSY`.
            busy_timeout: std.Io.Duration = .fromSeconds(5),
            schema: [:0]const u8 = main_schema,

            fn busyTimeoutMs(options: OpenOptions) c_int {
                return std.math.lossyCast(c_int, @max(0, options.busy_timeout.toMilliseconds()));
            }

            pub fn fromGeneric(generic: Db.OpenOptions) OpenOptions {
                return .{
                    .readonly = generic.readonly,
                    .create = generic.create,
                    .max_pool_size = generic.max_pool_size,
                };
            }
        };

        // --- Constructors --- //
        pub fn open(
            allocator: std.mem.Allocator,
            io: std.Io,
            location: []const u8,
            opts: OpenOptions,
        ) !Db {
            const self = openState(allocator, io, location, opts) catch |err| {
                std.log.err("Failed to open SQLite database: {s}\n Path: {s}", .{
                    @errorName(err),
                    location,
                });
                return err;
            };
            return self.db();
        }

        pub fn deserialize(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8, options: OpenOptions) !Db {
            const self = try deserializeState(allocator, io, bytes, options);
            return self.db();
        }

        /// Construct a `Db` value over an existing backend instance.
        pub fn db(self: *Sqlite) Db {
            return .{ .userdata = self, .vtable = &database_vtable };
        }

        pub fn from(database: Db) !*Sqlite {
            if (database.vtable != &database_vtable) return Db.Error.WrongBackend;
            return @ptrCast(@alignCast(database.userdata orelse return Db.Error.InvalidState));
        }

        pub const FileControlValue = union(enum) {
            none,
            integer: i64,
            bytes: []u8,
            const_bytes: []const u8,
        };

        fn openState(allocator: std.mem.Allocator, io: std.Io, filename: ?[]const u8, options: OpenOptions) !*Sqlite {
            if (browser) web.io = io;
            const path = resolvePath(filename orelse ":memory:");
            const flags = openFlags(options);

            try ensureParentDir(io, path);

            const self = try allocator.create(Sqlite);
            errdefer allocator.destroy(self);

            const path_copy = try allocator.dupe(u8, path);
            // errdefer allocator.free(path_copy);

            self.* = .{
                .io = io,
                .allocator = allocator,
                .mode = if (shouldPool(path, options)) .pooled else .single,
                .path = path_copy,
                .flags = flags,
                .busy_timeout_ms = options.busyTimeoutMs(),
                .schema = options.schema,
            };
            errdefer self.deinitState();

            if (self.mode == .pooled) {
                const path_z = try allocator.dupeSentinel(u8, path, 0);
                defer allocator.free(path_z);

                self.pool = try Pool.init(allocator, @max(options.max_pool_size, 1), path_z, flags, self.busy_timeout_ms);
            } else {
                const path_z = try allocator.dupeSentinel(u8, path, 0);
                defer allocator.free(path_z);

                self.conn = try Conn.open(path_z, flags);
                try configureConnection(self.conn.?, self.busy_timeout_ms);
            }

            return self;
        }

        fn deserializeState(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8, options: OpenOptions) !*Sqlite {
            if (browser) web.io = io;
            const self = try allocator.create(Sqlite);
            errdefer allocator.destroy(self);

            const path_copy = try allocator.dupe(u8, ":memory:");
            errdefer allocator.free(path_copy);

            const path_z = try allocator.dupeSentinel(u8, ":memory:", 0);
            defer allocator.free(path_z);

            const deser_flags = openFlags(.{
                .readonly = false,
                .create = true,
                .safe_integers = options.safe_integers,
                .strict = options.strict,
                .busy_timeout = options.busy_timeout,
            });

            self.* = .{
                .io = io,
                .allocator = allocator,
                .mode = .single,
                .path = path_copy,
                .flags = deser_flags,
                .busy_timeout_ms = options.busyTimeoutMs(),
                .conn = try Conn.open(path_z, deser_flags),
            };
            errdefer self.deinitState();

            try configureConnection(self.conn.?, self.busy_timeout_ms);

            const image = c.sqlite3_malloc64(bytes.len) orelse return error.NoMem;
            const image_bytes = @as([*]u8, @ptrCast(image))[0..bytes.len];
            @memcpy(image_bytes, bytes);

            const ds_flags: c_uint = c.SQLITE_DESERIALIZE_FREEONCLOSE | c.SQLITE_DESERIALIZE_RESIZEABLE;
            const rc = c.sqlite3_deserialize(
                self.conn.?.ptr,
                main_schema,
                @ptrCast(image),
                @intCast(bytes.len),
                @intCast(bytes.len),
                ds_flags,
            );
            if (rc != c.SQLITE_OK) {
                c.sqlite3_free(image);
                return mapSqliteError(rc);
            }

            return self;
        }

        // --- Connection vtable impls --- //

        fn prepare(ud: ?*anyopaque, sql: []const u8, diagnostics: ?*Db.Diagnostics) !Db.Statement {
            const db_ctx: *Sqlite = @ptrCast(@alignCast(ud));
            const allocator = db_ctx.allocator;

            const stmt_ctx = try allocator.create(StatementCtx);
            errdefer allocator.destroy(stmt_ctx);

            const sql_copy = try allocator.dupe(u8, sql);
            errdefer allocator.free(sql_copy);

            var borrowed = try db_ctx.acquire(diagnostics);
            defer borrowed.deinit();

            const prepared = try borrowed.conn.prepare(sql_copy);
            errdefer prepared.deinit();

            const meta = try collectStatementMeta(allocator, prepared);
            errdefer freeStatementMeta(allocator, meta);

            stmt_ctx.* = .{
                .allocator = allocator,
                .db_ctx = db_ctx,
                .sql = sql_copy,
                .diagnostics = diagnostics,
                .prototype = if (db_ctx.mode == .single) prepared else null,
                .column_names = meta.column_names,
                .column_types = meta.column_types,
                .declared_types = meta.declared_types,
                .param_count = meta.param_count,
            };

            if (db_ctx.mode != .single) prepared.deinit();

            return .{
                .db = .{ .userdata = ud, .vtable = &database_vtable },
                .userdata = @ptrCast(stmt_ctx),
            };
        }

        fn run(ud: ?*anyopaque, sql: []const u8, bindings: Db.Bindings) !Db.RunResult {
            const db_ctx: *Sqlite = @ptrCast(@alignCast(ud));
            var borrowed = try db_ctx.acquire(null);
            defer borrowed.deinit();

            var stmt = try borrowed.conn.prepare(sql);
            defer stmt.deinit();

            try bindStatement(stmt, bindings);
            try stmt.stepToCompletion();
            return .{
                .last_insert_id = borrowed.conn.lastInsertId(),
                .changes = borrowed.conn.changes(),
            };
        }

        fn transaction(ud: ?*anyopaque, mode: Db.TransactionMode, callback_ctx: *anyopaque, callback: Db.TransactionCallback) !void {
            const db_ctx: *Sqlite = @ptrCast(@alignCast(ud));
            var borrowed = try db_ctx.acquire(null);
            defer borrowed.deinit();

            try switch (mode) {
                .deferred => borrowed.conn.exec("begin"),
                .immediate => borrowed.conn.exec("begin immediate"),
                .exclusive => borrowed.conn.exec("begin exclusive"),
            };

            var tx_ctx = Sqlite{
                .allocator = db_ctx.allocator,
                .io = db_ctx.io,
                .mode = .single,
                .path = "",
                .flags = db_ctx.flags,
                .busy_timeout_ms = db_ctx.busy_timeout_ms,
                .schema = db_ctx.schema,
                .conn = borrowed.conn,
                .pool = null,
                .owns_resources = false,
            };

            var handle = Db{
                .userdata = @ptrCast(&tx_ctx),
                .vtable = &database_vtable,
            };

            callback(callback_ctx, &handle) catch |err| {
                borrowed.conn.exec("rollback") catch {};
                return err;
            };

            try borrowed.conn.exec("commit");
        }

        fn close(ud: ?*anyopaque, _: bool) !void {
            const db_ctx: *Sqlite = @ptrCast(@alignCast(ud));
            if (!db_ctx.owns_resources) return;

            const allocator = db_ctx.allocator;
            db_ctx.deinitState();
            allocator.destroy(db_ctx);
        }

        // --- SQLite-only extensions (reached via `Db.Sqlite.from(db)`) --- //

        /// Serialize the database to an in-memory image (SQLite `sqlite3_serialize`).
        /// SQLite-only.
        pub fn serialize(self: *Sqlite, allocator: std.mem.Allocator) ![]u8 {
            var borrowed = try self.acquire(null);
            defer borrowed.deinit();

            var size: c.sqlite3_int64 = 0;
            const bytes = c.sqlite3_serialize(borrowed.conn.ptr, self.schema, &size, 0) orelse {
                return error.NoMem;
            };
            defer c.sqlite3_free(bytes);

            const len: usize = @intCast(size);
            const result = try allocator.alloc(u8, len);
            @memcpy(result, @as([*]const u8, @ptrCast(bytes))[0..len]);
            return result;
        }

        /// Load a SQLite run-time loadable extension. SQLite-only; currently
        /// unsupported by this build.
        pub fn loadExtension(_: *Sqlite, _: []const u8, _: ?[]const u8) !void {
            return Db.Error.Unsupported;
        }

        /// Invoke `sqlite3_file_control`. SQLite-only.
        pub fn fileControl(self: *Sqlite, cmd: i32, value: FileControlValue) !void {
            var borrowed = try self.acquire(null);
            defer borrowed.deinit();

            switch (value) {
                .none => {
                    const rc = c.sqlite3_file_control(borrowed.conn.ptr, self.schema, cmd, null);
                    if (rc != c.SQLITE_OK) return mapSqliteError(rc);
                },
                .integer => |integer| {
                    var tmp = integer;
                    const rc = c.sqlite3_file_control(borrowed.conn.ptr, self.schema, cmd, &tmp);
                    if (rc != c.SQLITE_OK) return mapSqliteError(rc);
                },
                .bytes => |bytes| {
                    const rc = c.sqlite3_file_control(borrowed.conn.ptr, self.schema, cmd, bytes.ptr);
                    if (rc != c.SQLITE_OK) return mapSqliteError(rc);
                },
                .const_bytes => |bytes| {
                    const rc = c.sqlite3_file_control(borrowed.conn.ptr, self.schema, cmd, @constCast(bytes.ptr));
                    if (rc != c.SQLITE_OK) return mapSqliteError(rc);
                },
            }
        }

        /// Raw `*sqlite3` handle for single-connection databases (`null` for pooled).
        /// SQLite-only.
        pub fn nativeHandle(self: *Sqlite) ?*anyopaque {
            if (self.mode == .pooled) return null;
            return @ptrCast(self.conn.?.ptr);
        }

        // --- Statement vtable impls --- //

        fn all(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const Db.Row {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try prepareBoundStatement(stmt_ctx, bindings);
            defer exec.deinit();
            return readAllRows(allocator, exec.stmt);
        }

        fn get(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) !?Db.Row {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try prepareBoundStatement(stmt_ctx, bindings);
            defer exec.deinit();

            if (!try exec.stmt.step()) return null;
            return try cloneRow(allocator, exec.stmt);
        }

        fn runStatement(ud: ?*anyopaque, bindings: Db.Bindings) !Db.RunResult {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try prepareBoundStatement(stmt_ctx, bindings);
            defer exec.deinit();

            try exec.stmt.stepToCompletion();
            return .{
                .last_insert_id = exec.borrowed.conn.lastInsertId(),
                .changes = exec.borrowed.conn.changes(),
            };
        }

        fn values(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const []const Db.Value {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try prepareBoundStatement(stmt_ctx, bindings);
            defer exec.deinit();
            return readAllValues(allocator, exec.stmt);
        }

        fn iterate(ud: ?*anyopaque, bindings: Db.Bindings) !Db.Statement.Iterator {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const allocator = stmt_ctx.allocator;

            const iter_ctx = try allocator.create(IteratorCtx);
            errdefer allocator.destroy(iter_ctx);

            iter_ctx.* = .{
                .allocator = allocator,
                .exec = try prepareBoundStatement(stmt_ctx, bindings),
            };

            return .{
                .userdata = @ptrCast(iter_ctx),
                .next_fn = &iterateNext,
                .deinit_fn = &iterateDeinit,
            };
        }

        fn deinitStatement(ud: ?*anyopaque) void {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const allocator = stmt_ctx.allocator;
            stmt_ctx.deinit();
            allocator.destroy(stmt_ctx);
        }

        fn toString(ud: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            return allocator.dupe(u8, stmt_ctx.sql);
        }

        fn columnNames(ud: ?*anyopaque) anyerror![]const []const u8 {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            return stmt_ctx.column_names;
        }

        fn columnTypes(ud: ?*anyopaque) anyerror![]const Db.ColumnType {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            return stmt_ctx.column_types;
        }

        fn paramCount(ud: ?*anyopaque) anyerror!usize {
            const stmt_ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            return stmt_ctx.param_count;
        }

        // --- SQLite-only statement extensions (reached via `Db.Sqlite.fromStatement`) --- //

        /// Recover the SQLite statement context from a `Db.Statement`. The statement's
        /// vtable pointer is the type witness - returns `Db.Error.WrongBackend` if the
        /// statement was not prepared on a SQLite connection.
        fn fromStatement(statement: Db.Statement) !*StatementCtx {
            if (statement.db.vtable != &database_vtable) return Db.Error.WrongBackend;
            return @ptrCast(@alignCast(statement.userdata orelse return Db.Error.Closed));
        }

        /// SQLite's per-column declared type strings (`sqlite3_column_decltype`). This
        /// reflects SQLite's flexible typing and has no portable equivalent - use the
        /// neutral `Statement.columnTypes` for cross-backend type info.
        pub fn declaredTypes(statement: Db.Statement) ![]const ?[]const u8 {
            const stmt_ctx = try fromStatement(statement);
            return stmt_ctx.declared_types;
        }

        /// Raw `*sqlite3_stmt` for single-connection statements (`null` for pooled).
        pub fn nativeStatement(statement: Db.Statement) !?*anyopaque {
            const stmt_ctx = try fromStatement(statement);
            if (stmt_ctx.prototype) |prototype| return @ptrCast(prototype.ptr);
            return null;
        }

        fn iterateNext(ctx: *anyopaque) !?Db.Row {
            const iter_ctx: *IteratorCtx = @ptrCast(@alignCast(ctx));
            // Advancing invalidates the previously yielded row; reclaim it.
            iter_ctx.releaseCurrent();
            if (iter_ctx.done) return null;
            if (!try iter_ctx.exec.stmt.step()) {
                iter_ctx.done = true;
                return null;
            }
            const row = try cloneRow(iter_ctx.allocator, iter_ctx.exec.stmt);
            iter_ctx.current = row;
            return row;
        }

        fn iterateDeinit(ctx: *anyopaque) void {
            const iter_ctx: *IteratorCtx = @ptrCast(@alignCast(ctx));
            const allocator = iter_ctx.allocator;
            iter_ctx.releaseCurrent();
            iter_ctx.exec.deinit();
            allocator.destroy(iter_ctx);
        }

        const StatementMeta = struct {
            column_names: [][]const u8,
            column_types: []Db.ColumnType,
            declared_types: []?[]const u8,
            param_count: usize,
        };

        fn collectStatementMeta(allocator: std.mem.Allocator, stmt: Stmt) !StatementMeta {
            const column_count: usize = @intCast(c.sqlite3_column_count(stmt.ptr));
            const column_names = try allocator.alloc([]const u8, column_count);
            errdefer allocator.free(column_names);

            const column_types = try allocator.alloc(Db.ColumnType, column_count);
            errdefer allocator.free(column_types);

            const declared_types = try allocator.alloc(?[]const u8, column_count);
            errdefer allocator.free(declared_types);

            for (0..column_count) |index| {
                column_names[index] = try allocator.dupe(u8, stmt.columnName(index));
                errdefer {
                    for (column_names[0 .. index + 1]) |name| allocator.free(name);
                }

                const decl_ptr = c.sqlite3_column_decltype(stmt.ptr, @intCast(index));
                if (decl_ptr) |decl| {
                    const decl_slice = std.mem.span(decl);
                    declared_types[index] = try allocator.dupe(u8, decl_slice);
                    column_types[index] = mapDeclaredColumnType(decl_slice);
                } else {
                    declared_types[index] = null;
                    column_types[index] = .unknown;
                }
            }

            return .{
                .column_names = column_names,
                .column_types = column_types,
                .declared_types = declared_types,
                .param_count = @intCast(c.sqlite3_bind_parameter_count(stmt.ptr)),
            };
        }

        fn freeStatementMeta(allocator: std.mem.Allocator, meta: StatementMeta) void {
            for (meta.column_names) |name| allocator.free(name);
            allocator.free(meta.column_names);
            allocator.free(meta.column_types);
            for (meta.declared_types) |decl_type| {
                if (decl_type) |name| allocator.free(name);
            }
            allocator.free(meta.declared_types);
        }

        fn prepareBoundStatement(stmt_ctx: *StatementCtx, bindings: Db.Bindings) !PreparedExec {
            var borrowed = try stmt_ctx.db_ctx.acquire(stmt_ctx.diagnostics);
            errdefer borrowed.deinit();

            const stmt = try borrowed.conn.prepare(stmt_ctx.sql);
            errdefer stmt.deinit();

            try bindStatement(stmt, bindings);
            return .{
                .borrowed = borrowed,
                .stmt = stmt,
            };
        }

        fn bindStatement(stmt: Stmt, bindings: Db.Bindings) !void {
            try stmt.clearBindings();
            try stmt.reset();

            switch (bindings) {
                .none => return,
                .positional => |positional_values| {
                    for (positional_values, 0..) |value, index| {
                        try bindValue(stmt.ptr, @intCast(index + 1), value);
                    }
                },
                .named => |named_values| {
                    for (named_values) |entry| {
                        const param_index = try resolveNamedParam(stmt, entry.name);
                        if (param_index == 0) return Db.Error.InvalidBindings;
                        try bindValue(stmt.ptr, param_index, entry.value);
                    }
                },
            }
        }

        fn resolveNamedParam(stmt: Stmt, name: []const u8) !c_int {
            var buf: [256]u8 = undefined;

            if (name.len > 0 and (name[0] == ':' or name[0] == '@' or name[0] == '$')) {
                const name_z = std.mem.printSentinel(&buf, "{s}", .{name}, 0) catch
                    return Db.Error.InvalidBindings;
                return c.sqlite3_bind_parameter_index(stmt.ptr, name_z.ptr);
            }

            for ([_]u8{ ':', '@', '$' }) |sigil| {
                const candidate = std.mem.printSentinel(&buf, "{c}{s}", .{ sigil, name }, 0) catch
                    return Db.Error.InvalidBindings;
                const index = c.sqlite3_bind_parameter_index(stmt.ptr, candidate.ptr);
                if (index != 0) return index;
            }
            return 0;
        }

        fn bindValue(stmt: *c.sqlite3_stmt, index: c_int, value: Db.Value) !void {
            const rc: c_int = switch (value) {
                .null => c.sqlite3_bind_null(stmt, index),
                .integer => |v| c.sqlite3_bind_int64(stmt, index, @intCast(v)),
                .float => |v| c.sqlite3_bind_double(stmt, index, v),
                .text => |v| c.sqlite3_bind_text(stmt, index, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                .blob => |v| c.sqlite3_bind_blob(stmt, index, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                .boolean => |v| c.sqlite3_bind_int64(stmt, index, if (v) 1 else 0),
            };
            if (rc != c.SQLITE_OK) return mapSqliteError(rc);
        }

        fn readAllRows(allocator: std.mem.Allocator, stmt: Stmt) ![]const Db.Row {
            var rows = std.ArrayList(Db.Row).empty;
            errdefer {
                for (rows.items) |row| freeRow(allocator, row);
                rows.deinit(allocator);
            }

            while (try stmt.step()) {
                try rows.append(allocator, try cloneRow(allocator, stmt));
            }
            return rows.toOwnedSlice(allocator);
        }

        fn readAllValues(allocator: std.mem.Allocator, stmt: Stmt) ![]const []const Db.Value {
            var rows = std.ArrayList([]const Db.Value).empty;
            errdefer {
                for (rows.items) |row| allocator.free(row);
                rows.deinit(allocator);
            }

            while (try stmt.step()) {
                try rows.append(allocator, try cloneValueRow(allocator, stmt));
            }
            return rows.toOwnedSlice(allocator);
        }

        fn cloneRow(allocator: std.mem.Allocator, stmt: Stmt) !Db.Row {
            const column_count = stmt.columnCount();
            const fields = try allocator.alloc(Db.Field, column_count);
            errdefer allocator.free(fields);

            for (0..column_count) |index| {
                fields[index] = .{
                    .name = try allocator.dupe(u8, stmt.columnName(index)),
                    .value = try cloneValue(allocator, stmt, index),
                };
            }

            return .{ .fields = fields };
        }

        fn cloneValueRow(allocator: std.mem.Allocator, stmt: Stmt) ![]const Db.Value {
            const column_count = stmt.columnCount();
            const values_row = try allocator.alloc(Db.Value, column_count);
            errdefer allocator.free(values_row);

            for (0..column_count) |index| {
                values_row[index] = try cloneValue(allocator, stmt, index);
            }
            return values_row;
        }

        fn cloneValue(allocator: std.mem.Allocator, stmt: Stmt, index: usize) !Db.Value {
            const col: c_int = @intCast(index);
            return switch (c.sqlite3_column_type(stmt.ptr, col)) {
                c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(stmt.ptr, col) },
                c.SQLITE_FLOAT => .{ .float = c.sqlite3_column_double(stmt.ptr, col) },
                c.SQLITE_TEXT => .{ .text = try allocator.dupe(u8, stmt.columnBytes(index, c.sqlite3_column_text(stmt.ptr, col))) },
                c.SQLITE_BLOB => .{ .blob = try allocator.dupe(u8, stmt.columnBytes(index, c.sqlite3_column_blob(stmt.ptr, col))) },
                else => .null,
            };
        }

        fn freeRow(allocator: std.mem.Allocator, row: Db.Row) void {
            for (row.fields) |field| {
                allocator.free(field.name);
                switch (field.value) {
                    .text => |text| allocator.free(text),
                    .blob => |blob| allocator.free(blob),
                    else => {},
                }
            }
            allocator.free(row.fields);
        }

        fn mapDeclaredColumnType(declared: []const u8) Db.ColumnType {
            if (declared.len == 0) return .unknown;

            var buf: [64]u8 = undefined;
            const len = @min(buf.len, declared.len);
            for (declared[0..len], 0..) |byte, index| buf[index] = std.ascii.toUpper(byte);
            const upper = buf[0..len];

            if (std.mem.find(u8, upper, "INT") != null) return .integer;
            if (std.mem.find(u8, upper, "CHAR") != null) return .text;
            if (std.mem.find(u8, upper, "CLOB") != null) return .text;
            if (std.mem.find(u8, upper, "TEXT") != null) return .text;
            if (std.mem.find(u8, upper, "BLOB") != null) return .blob;
            if (std.mem.find(u8, upper, "REAL") != null) return .float;
            if (std.mem.find(u8, upper, "FLOA") != null) return .float;
            if (std.mem.find(u8, upper, "DOUB") != null) return .float;
            return .unknown;
        }

        fn shouldPool(path: []const u8, options: OpenOptions) bool {
            // Browser sqlite is built single-threaded.
            return !browser and options.max_pool_size > 1 and !isMemoryPath(path);
        }

        fn isMemoryPath(path: []const u8) bool {
            return std.mem.eql(u8, path, ":memory:") or
                std.mem.eql(u8, path, "") or
                std.mem.startsWith(u8, path, "file::memory:");
        }

        // TODO: get rid of this for stricter URI
        fn resolvePath(location: []const u8) []const u8 {
            if (location.len == 0) return ":memory:";

            if (std.mem.startsWith(u8, location, "mem://")) return ":memory:";
            if (std.mem.eql(u8, location, "memory:") or
                std.mem.eql(u8, location, "memory://") or
                std.mem.eql(u8, location, "sqlite::memory:")) return ":memory:";

            if (std.mem.startsWith(u8, location, "sqlite:///")) return location["sqlite://".len..];
            if (std.mem.startsWith(u8, location, "sqlite://")) return trimOrMemory(location["sqlite://".len..]);
            if (std.mem.startsWith(u8, location, "file://")) return trimOrMemory(location["file://".len..]);
            if (std.mem.startsWith(u8, location, "file:")) return trimOrMemory(location["file:".len..]);

            return location;
        }

        fn trimOrMemory(value: []const u8) []const u8 {
            return if (value.len == 0) ":memory:" else value;
        }

        fn ensureParentDir(io: std.Io, path: []const u8) !void {
            if (isMemoryPath(path) or isUriPath(path)) return;
            const parent = std.Io.Dir.path.dirname(path) orelse return;
            if (parent.len == 0) return;
            if (std.Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true })) |st| {
                if (st.kind == .directory) return;
            } else |_| {}
            std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        fn isUriPath(path: []const u8) bool {
            return std.mem.findScalar(u8, path, ':') != null and
                !std.mem.startsWith(u8, path, "./") and
                !std.mem.startsWith(u8, path, "../") and
                !std.Io.Dir.path.isAbsolute(path);
        }

        fn configureConnection(conn: Conn, busy_timeout_ms: c_int) !void {
            if (busy_timeout_ms > 0) {
                try conn.busyTimeout(busy_timeout_ms);
            }
            // One connection per file in the browser. Exclusive WAL keeps the WAL open and
            // appends to it instead of creating and deleting a journal per transaction, and
            // needs no shared memory; ~50x faster writes on OPFS. NORMAL is SQLite's WAL default
            // advice: always consistent, an OS crash may drop the latest commits.
            if (browser) try conn.exec("PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        }

        fn openFlags(options: OpenOptions) c_int {
            var flags: c_int = c.SQLITE_OPEN_EXRESCODE | c.SQLITE_OPEN_FULLMUTEX;
            if (options.readonly) return flags | c.SQLITE_OPEN_READONLY;

            flags |= c.SQLITE_OPEN_READWRITE;
            if (options.create) flags |= c.SQLITE_OPEN_CREATE;
            return flags;
        }

        fn mapSqliteError(rc: c_int) anyerror {
            return switch (rc) {
                c.SQLITE_BUSY, c.SQLITE_BUSY_RECOVERY, c.SQLITE_BUSY_SNAPSHOT, c.SQLITE_BUSY_TIMEOUT => Db.Error.Busy,
                c.SQLITE_MISUSE => Db.Error.InvalidState,
                c.SQLITE_NOTADB, c.SQLITE_CANTOPEN => Db.Error.InvalidQuery,
                c.SQLITE_RANGE => Db.Error.InvalidBindings,
                else => sqliteErrorFromCode(rc),
            };
        }

        fn sqliteErrorFromCode(rc: c_int) anyerror {
            return switch (rc) {
                c.SQLITE_ABORT => error.Abort,
                c.SQLITE_AUTH => error.Auth,
                c.SQLITE_BUSY => error.Busy,
                c.SQLITE_CANTOPEN => error.CantOpen,
                c.SQLITE_CONSTRAINT => error.Constraint,
                c.SQLITE_CORRUPT => error.Corrupt,
                c.SQLITE_EMPTY => error.Empty,
                c.SQLITE_ERROR => error.Error,
                c.SQLITE_FORMAT => error.Format,
                c.SQLITE_FULL => error.Full,
                c.SQLITE_INTERNAL => error.Internal,
                c.SQLITE_INTERRUPT => error.Interrupt,
                c.SQLITE_IOERR => error.IoErr,
                c.SQLITE_LOCKED => error.Locked,
                c.SQLITE_MISMATCH => error.Mismatch,
                c.SQLITE_MISUSE => error.Misuse,
                c.SQLITE_NOLFS => error.NoLFS,
                c.SQLITE_NOMEM => error.NoMem,
                c.SQLITE_NOTADB => error.NotADB,
                c.SQLITE_NOTFOUND => error.Notfound,
                c.SQLITE_NOTICE => error.Notice,
                c.SQLITE_PERM => error.Perm,
                c.SQLITE_PROTOCOL => error.Protocol,
                c.SQLITE_RANGE => error.Range,
                c.SQLITE_READONLY => error.ReadOnly,
                c.SQLITE_SCHEMA => error.Schema,
                c.SQLITE_TOOBIG => error.TooBig,
                c.SQLITE_WARNING => error.Warning,
                c.SQLITE_ERROR_MISSING_COLLSEQ => error.ErrorMissingCollseq,
                c.SQLITE_ERROR_RETRY => error.ErrorRetry,
                c.SQLITE_ERROR_SNAPSHOT => error.ErrorSnapshot,
                c.SQLITE_IOERR_READ => error.IoerrRead,
                c.SQLITE_IOERR_SHORT_READ => error.IoerrShortRead,
                c.SQLITE_IOERR_WRITE => error.IoerrWrite,
                c.SQLITE_IOERR_FSYNC => error.IoerrFsync,
                c.SQLITE_IOERR_DIR_FSYNC => error.IoerrDir_fsync,
                c.SQLITE_IOERR_TRUNCATE => error.IoerrTruncate,
                c.SQLITE_IOERR_FSTAT => error.IoerrFstat,
                c.SQLITE_IOERR_UNLOCK => error.IoerrUnlock,
                c.SQLITE_IOERR_RDLOCK => error.IoerrRdlock,
                c.SQLITE_IOERR_DELETE => error.IoerrDelete,
                c.SQLITE_IOERR_BLOCKED => error.IoerrBlocked,
                c.SQLITE_IOERR_NOMEM => error.IoerrNomem,
                c.SQLITE_IOERR_ACCESS => error.IoerrAccess,
                c.SQLITE_IOERR_CHECKRESERVEDLOCK => error.IoerrCheckreservedlock,
                c.SQLITE_IOERR_LOCK => error.IoerrLock,
                c.SQLITE_IOERR_CLOSE => error.IoerrClose,
                c.SQLITE_IOERR_DIR_CLOSE => error.IoerrDirClose,
                c.SQLITE_IOERR_SHMOPEN => error.IoerrShmopen,
                c.SQLITE_IOERR_SHMSIZE => error.IoerrShmsize,
                c.SQLITE_IOERR_SHMLOCK => error.IoerrShmlock,
                c.SQLITE_IOERR_SHMMAP => error.ioerrshmmap,
                c.SQLITE_IOERR_SEEK => error.IoerrSeek,
                c.SQLITE_IOERR_DELETE_NOENT => error.IoerrDeleteNoent,
                c.SQLITE_IOERR_MMAP => error.IoerrMmap,
                c.SQLITE_IOERR_GETTEMPPATH => error.IoerrGetTempPath,
                c.SQLITE_IOERR_CONVPATH => error.IoerrConvPath,
                c.SQLITE_IOERR_VNODE => error.IoerrVnode,
                c.SQLITE_IOERR_AUTH => error.IoerrAuth,
                c.SQLITE_IOERR_BEGIN_ATOMIC => error.IoerrBeginAtomic,
                c.SQLITE_IOERR_COMMIT_ATOMIC => error.IoerrCommitAtomic,
                c.SQLITE_IOERR_ROLLBACK_ATOMIC => error.IoerrRollbackAtomic,
                c.SQLITE_IOERR_DATA => error.IoerrData,
                c.SQLITE_IOERR_CORRUPTFS => error.IoerrCorruptFS,
                c.SQLITE_LOCKED_SHAREDCACHE => error.LockedSharedCache,
                c.SQLITE_LOCKED_VTAB => error.LockedVTab,
                c.SQLITE_BUSY_RECOVERY => error.BusyRecovery,
                c.SQLITE_BUSY_SNAPSHOT => error.BusySnapshot,
                c.SQLITE_BUSY_TIMEOUT => error.BusyTimeout,
                c.SQLITE_CANTOPEN_NOTEMPDIR => error.CantOpenNoTempDir,
                c.SQLITE_CANTOPEN_ISDIR => error.CantOpenIsDir,
                c.SQLITE_CANTOPEN_FULLPATH => error.CantOpenFullPath,
                c.SQLITE_CANTOPEN_CONVPATH => error.CantOpenConvPath,
                c.SQLITE_CANTOPEN_DIRTYWAL => error.CantOpenDirtyWal,
                c.SQLITE_CANTOPEN_SYMLINK => error.CantOpenSymlink,
                c.SQLITE_CORRUPT_VTAB => error.CorruptVTab,
                c.SQLITE_CORRUPT_SEQUENCE => error.CorruptSequence,
                c.SQLITE_CORRUPT_INDEX => error.CorruptIndex,
                c.SQLITE_READONLY_RECOVERY => error.ReadonlyRecovery,
                c.SQLITE_READONLY_CANTLOCK => error.ReadonlyCantlock,
                c.SQLITE_READONLY_ROLLBACK => error.ReadonlyRollback,
                c.SQLITE_READONLY_DBMOVED => error.ReadonlyDbMoved,
                c.SQLITE_READONLY_CANTINIT => error.ReadonlyCantInit,
                c.SQLITE_READONLY_DIRECTORY => error.ReadonlyDirectory,
                c.SQLITE_ABORT_ROLLBACK => error.AbortRollback,
                c.SQLITE_CONSTRAINT_CHECK => error.ConstraintCheck,
                c.SQLITE_CONSTRAINT_COMMITHOOK => error.ConstraintCommithook,
                c.SQLITE_CONSTRAINT_FOREIGNKEY => error.ConstraintForeignKey,
                c.SQLITE_CONSTRAINT_FUNCTION => error.ConstraintFunction,
                c.SQLITE_CONSTRAINT_NOTNULL => error.ConstraintNotNull,
                c.SQLITE_CONSTRAINT_PRIMARYKEY => error.ConstraintPrimaryKey,
                c.SQLITE_CONSTRAINT_TRIGGER => error.ConstraintTrigger,
                c.SQLITE_CONSTRAINT_UNIQUE => error.ConstraintUnique,
                c.SQLITE_CONSTRAINT_VTAB => error.ConstraintVTab,
                c.SQLITE_CONSTRAINT_ROWID => error.ConstraintRowId,
                c.SQLITE_CONSTRAINT_PINNED => error.ConstraintPinned,
                c.SQLITE_CONSTRAINT_DATATYPE => error.ConstraintDatatype,
                c.SQLITE_NOTICE_RECOVER_WAL => error.NoticeRecoverWal,
                c.SQLITE_NOTICE_RECOVER_ROLLBACK => error.NoticeRecoverRollback,
                c.SQLITE_WARNING_AUTOINDEX => error.WarningAutoIndex,
                c.SQLITE_AUTH_USER => error.AuthUser,
                c.SQLITE_OK_LOAD_PERMANENTLY => error.OkLoadPermanently,
                else => error.Sqlite,
            };
        }

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
            .stmtDeinit = &deinitStatement,
            .stmtToString = &toString,
            .stmtColumnNames = &columnNames,
            .stmtColumnTypes = &columnTypes,
            .stmtParamCount = &paramCount,
        };
    };
}
