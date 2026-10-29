const std = @import("std");
const Io = std.Io;
pub const c = @import("c");

const zqlite = @import("zqlite.zig");
const Blob = zqlite.Blob;
const Error = zqlite.Error;

pub const Conn = struct {
    conn: *c.sqlite3,
    _pool: ?*zqlite.Pool = null,

    pub fn init(path: [*:0]const u8, flags: c_int) !Conn {
        // sqlite requires either READONLY or READWRITE flag
        var full_flags = flags;
        if (flags & c.SQLITE_OPEN_READONLY != c.SQLITE_OPEN_READONLY) {
            full_flags |= c.SQLITE_OPEN_READWRITE;
        }

        var conn: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &conn, full_flags, null);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
        return .{ .conn = conn.? };
    }

    pub fn release(self: Conn, io: Io) void {
        self._pool.?.release(io, self);
    }

    pub fn close(self: Conn) void {
        _ = c.sqlite3_close_v2(self.conn);
    }

    // in case someone cares about getting this error
    pub fn tryClose(self: Conn) !void {
        const rc = c.sqlite3_close_v2(self.conn);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn busyTimeout(self: Conn, ms: c_int) !void {
        const rc = c.sqlite3_busy_timeout(self.conn, ms);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn exec(self: Conn, sql: []const u8, values: anytype) !void {
        const stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bind(values);
        try stmt.stepToCompletion();
    }

    pub fn execNoArgs(self: Conn, sql: [*:0]const u8) !void {
        const rc = c.sqlite3_exec(self.conn, sql, null, null, null);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn prepare(self: Conn, sql: []const u8) !Stmt {
        var n_stmt: ?*c.sqlite3_stmt = null;
        var pz_tail: [*:0]const u8 = undefined;

        const rc = c.sqlite3_prepare_v2(self.conn, sql.ptr, @intCast(sql.len), &n_stmt, @ptrCast(&pz_tail));
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }

        if (@import("builtin").mode == .debug) {
            if (pz_tail[0] != 0) {
                // SQlite just returns a pointer to the string we passed in,
                // which may not be null terminated, so compute the
                // length of the remaining using pointer arithmetic
                const tail_len: c_int = @intCast(sql.len - @as(usize, @intCast(pz_tail - sql.ptr)));

                var tail_stmt: ?*c.sqlite3_stmt = null;
                defer if (tail_stmt != null) {
                    _ = c.sqlite3_finalize(tail_stmt);
                };

                const rc2 = c.sqlite3_prepare_v2(self.conn, pz_tail, tail_len, &tail_stmt, null);
                if (rc2 != c.SQLITE_OK or tail_stmt != null) {
                    // SQlite only compiles the first statement it finds,
                    // and silently ignores the rest. Make this an error instead.
                    return error.MultipleStatements;
                }
            }
        }

        return .{ .stmt = n_stmt.?, .conn = self.conn };
    }

    pub fn changes(self: Conn) usize {
        return @intCast(c.sqlite3_changes(self.conn));
    }

    pub fn lastInsertedRowId(self: Conn) i64 {
        return @intCast(c.sqlite3_last_insert_rowid(self.conn));
    }

    pub fn row(self: Conn, sql: []const u8, values: anytype) !?Row {
        const stmt = try self.prepare(sql);
        errdefer stmt.deinit();

        try stmt.bind(values);
        if (try stmt.step() == false) {
            stmt.deinit();
            return null;
        }
        return .{ .stmt = stmt };
    }

    pub fn rows(self: Conn, sql: []const u8, values: anytype) !Rows {
        const stmt = try self.prepare(sql);
        errdefer stmt.deinit();
        try stmt.bind(values);
        return .{ .stmt = stmt, .err = null };
    }

    pub fn transaction(self: Conn) !void {
        return self.execNoArgs("begin");
    }

    pub fn exclusiveTransaction(self: Conn) !void {
        return self.execNoArgs("begin exclusive");
    }

    pub fn commit(self: Conn) !void {
        try self.execNoArgs("commit");
    }

    pub fn rollback(self: Conn) void {
        self.execNoArgs("rollback") catch {};
    }

    pub fn lastError(self: Conn) [*:0]const u8 {
        return @as([*:0]const u8, c.sqlite3_errmsg(self.conn));
    }
};

pub const Stmt = struct {
    conn: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    pub fn deinit(self: Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn deinitErr(self: Stmt) !void {
        const rc = c.sqlite3_finalize(self.stmt);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn bind(self: Stmt, values: anytype) !void {
        const stmt = self.stmt;
        inline for (values, 0..) |value, i| {
            try _bind(@TypeOf(value), stmt, value, i + 1);
        }
    }

    pub fn bindValue(self: Stmt, value: anytype, index: usize) !void {
        try _bind(@TypeOf(value), self.stmt, value, @intCast(index + 1));
    }

    pub fn step(self: Stmt) !bool {
        const s = self.stmt;
        const rc = c.sqlite3_step(s);
        if (rc == c.SQLITE_DONE) {
            return false;
        }
        if (rc != c.SQLITE_ROW) {
            return errorFromCode(rc);
        }
        return true;
    }

    pub fn stepToCompletion(self: Stmt) !void {
        const stmt = self.stmt;
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_DONE => return,
                c.SQLITE_ROW => continue,
                else => |rc| return errorFromCode(rc),
            }
        }
    }

    pub fn reset(self: Stmt) !void {
        switch (c.sqlite3_reset(self.stmt)) {
            c.SQLITE_OK => return,
            else => |rc| return errorFromCode(rc),
        }
    }

    pub fn clearBindings(self: Stmt) !void {
        switch (c.sqlite3_clear_bindings(self.stmt)) {
            c.SQLITE_OK => return,
            else => |rc| return errorFromCode(rc),
        }
    }

    pub fn expandedSql(self: Stmt, allocator: std.mem.Allocator) ![]u8 {
        const c_str = c.sqlite3_expanded_sql(self.stmt) orelse return error.NoMem;
        defer c.sqlite3_free(c_str);
        const len = std.mem.len(c_str);
        const result = try allocator.alloc(u8, len);
        @memcpy(result, c_str[0..len]);
        return result;
    }

    pub fn boolean(self: Stmt, index: usize) bool {
        return self.int(index) == 1;
    }
    pub fn nullableBoolean(self: Stmt, index: usize) ?bool {
        const n = self.nullableInt(index) orelse return null;
        return n == 1;
    }

    pub fn int(self: Stmt, index: usize) i64 {
        return @intCast(c.sqlite3_column_int64(self.stmt, @intCast(index)));
    }
    pub fn nullableInt(self: Stmt, index: usize) ?i64 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.int(index);
    }

    pub fn float(self: Stmt, index: usize) f64 {
        return @floatCast(c.sqlite3_column_double(self.stmt, @intCast(index)));
    }
    pub fn nullableFloat(self: Stmt, index: usize) ?f64 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.float(index);
    }

    pub fn text(self: Stmt, index: usize) []const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        const data = c.sqlite3_column_text(stmt, c_index);
        const len = c.sqlite3_column_bytes(stmt, c_index);
        if (len == 0) {
            return "";
        }
        return @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    }
    pub fn nullableText(self: Stmt, index: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.text(index);
    }

    pub fn cString(self: Stmt, index: usize) [:0]const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        const data = c.sqlite3_column_text(stmt, c_index);
        const len = c.sqlite3_column_bytes(stmt, c_index);
        if (len == 0) {
            return "";
        }
        return @as([*c]const u8, @ptrCast(data))[0..@intCast(len) :0];
    }
    pub fn nullableCString(self: Stmt, index: usize) ?[:0]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.cString(index);
    }

    pub fn textZ(self: Stmt, index: usize) [*:0]const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        return c.sqlite3_column_text(stmt, c_index);
    }
    pub fn nullableTextZ(self: Stmt, index: usize) ?[*:0]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.textZ(index);
    }

    pub fn columnBytes(self: Stmt, index: usize) usize {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        return @intCast(c.sqlite3_column_bytes(stmt, c_index));
    }

    pub fn blob(self: Stmt, index: usize) []const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);

        const data = c.sqlite3_column_blob(stmt, c_index);
        if (data == null) {
            return "";
        }

        const len = c.sqlite3_column_bytes(stmt, c_index);
        return @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    }
    pub fn nullableBlob(self: Stmt, index: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.blob(index);
    }

    pub fn columnCount(self: Stmt) i32 {
        return c.sqlite3_data_count(self.stmt);
    }

    pub fn columnName(self: Stmt, index: usize) [*:0]const u8 {
        return c.sqlite3_column_name(self.stmt, @intCast(index));
    }

    pub fn columnType(self: Stmt, index: usize) ColumnType {
        return switch (c.sqlite3_column_type(self.stmt, @intCast(index))) {
            1 => .int,
            2 => .float,
            3 => .text,
            4 => .blob,
            5 => .null,
            else => .unknown,
        };
    }

    fn _bind(comptime T: type, stmt: *c.sqlite3_stmt, value: anytype, bind_index: c_int) !void {
        var rc: c_int = 0;

        switch (@typeInfo(T)) {
            .null => rc = c.sqlite3_bind_null(stmt, bind_index),
            .int, .comptime_int => rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(value)),
            .float, .comptime_float => rc = c.sqlite3_bind_double(stmt, bind_index, value),
            .bool => {
                if (value) {
                    rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(1));
                } else {
                    rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(0));
                }
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |arr| {
                            if (arr.child == u8) {
                                rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC);
                            } else {
                                bindError(T);
                            }
                        },
                        else => bindError(T),
                    },
                    .slice => switch (ptr.child) {
                        u8 => rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC),
                        else => bindError(T),
                    },
                    else => bindError(T),
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    @compileError("Pass a string slice, rather than an array, to bind a text/blob. String arrays will be supported when https://github.com/ziglang/zig/issues/15893#issuecomment-1925092582 is fixed");
                    // const data: []const u8 = value[0..arr.len];
                    // rc = c.sqlite3_bind_text(stmt, bind_index, data.ptr, @intCast(data.len), c.SQLITE_TRANSIENT);
                } else {
                    bindError(T);
                }
            },
            .optional => |opt| {
                if (value) |v| {
                    return _bind(opt.child, stmt, v, bind_index);
                } else {
                    rc = c.sqlite3_bind_null(stmt, bind_index);
                }
            },
            .@"struct" => {
                if (T == Blob) {
                    const inner = value.value;
                    rc = c.sqlite3_bind_blob(stmt, bind_index, @ptrCast(inner), @intCast(inner.len), c.SQLITE_STATIC);
                } else {
                    bindError(T);
                }
            },
            else => bindError(T),
        }

        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    fn bindError(comptime T: type) void {
        @compileError("cannot bind value of type " ++ @typeName(T));
    }
};

pub const ColumnType = enum { int, float, text, blob, null, unknown };

pub const Row = struct {
    stmt: Stmt,

    pub fn deinit(self: Row) void {
        self.stmt.deinit();
    }

    pub fn deinitErr(self: Row) !void {
        return self.stmt.deinitErr();
    }

    pub fn columnCount(self: Row) i32 {
        return self.stmt.columnCount();
    }

    pub fn columnName(self: Row, col: usize) []const u8 {
        return std.mem.span(self.stmt.columnName(col));
    }

    pub fn columnType(self: Row, index: usize) ColumnType {
        return self.stmt.columnType(index);
    }

    pub fn get(self: Row, comptime T: type, col: usize) GetReturnType(T) {
        switch (T) {
            i64 => return self.int(col),
            ?i64 => return self.nullableInt(col),
            bool => return self.boolean(col),
            ?bool => return self.nullableBoolean(col),
            ?[]const u8 => return self.nullableText(col),
            []const u8 => return self.text(col),
            ?[:0]const u8 => return self.nullableCString(col),
            [:0]const u8 => return self.cString(col),
            ?Blob => return self.nullableBlob(col),
            Blob => return self.blob(col),
            f64 => return self.float(col),
            ?f64 => return self.nullableFloat(col),
            else => @compileError("unsupport column type: " ++ @typeName(T)),
        }
    }

    fn GetReturnType(comptime T: type) type {
        switch (T) {
            Blob => return []const u8,
            ?Blob => return ?[]const u8,
            else => return T,
        }
    }

    pub fn boolean(self: Row, col: usize) bool {
        return self.stmt.boolean(col);
    }
    pub fn nullableBoolean(self: Row, col: usize) ?bool {
        return self.stmt.nullableBoolean(col);
    }

    pub fn int(self: Row, col: usize) i64 {
        return self.stmt.int(col);
    }
    pub fn nullableInt(self: Row, col: usize) ?i64 {
        return self.stmt.nullableInt(col);
    }

    pub fn float(self: Row, col: usize) f64 {
        return self.stmt.float(col);
    }
    pub fn nullableFloat(self: Row, col: usize) ?f64 {
        return self.stmt.nullableFloat(col);
    }

    pub fn text(self: Row, col: usize) []const u8 {
        return self.stmt.text(col);
    }
    pub fn nullableText(self: Row, col: usize) ?[]const u8 {
        return self.stmt.nullableText(col);
    }

    pub fn cString(self: Row, col: usize) [:0]const u8 {
        return self.stmt.cString(col);
    }
    pub fn nullableCString(self: Row, col: usize) ?[:0]const u8 {
        return self.stmt.nullableCString(col);
    }

    pub fn textZ(self: Row, col: usize) [*:0]const u8 {
        return self.stmt.textZ(col);
    }
    pub fn nullableTextZ(self: Row, col: usize) ?[*:0]const u8 {
        return self.stmt.nullableTextZ(col);
    }
    pub fn columnBytes(self: Row, col: usize) usize {
        return self.stmt.columnBytes(col);
    }

    pub fn blob(self: Row, col: usize) []const u8 {
        return self.stmt.blob(col);
    }
    pub fn nullableBlob(self: Row, col: usize) ?[]const u8 {
        return self.stmt.nullableBlob(col);
    }
};

pub const Rows = struct {
    stmt: Stmt,
    err: ?Error,

    pub fn deinit(self: Rows) void {
        self.stmt.deinit();
    }

    pub fn deinitErr(self: Rows) !void {
        return self.stmt.deinitErr();
    }

    pub fn next(self: *Rows) ?Row {
        if (self.err != null) {
            return null;
        }

        const stmt = self.stmt;
        const has_data = stmt.step() catch |err| {
            self.err = err;
            return null;
        };

        if (!has_data) {
            return null;
        }

        return .{ .stmt = stmt };
    }
};

fn errorFromCode(result: c_int) Error {
    return switch (result) {
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

        // extended codes:
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

        else => std.debug.panic("{s} {d}", .{ c.sqlite3_errstr(result), result }),
    };
}

const t = std.testing;
test "init: path does not exist" {
    try t.expectError(error.CantOpen, Conn.init("does_not_exist", 0));
}

test "exec and scan" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\  insert into test (cint, creal, ctext, cblob)
        \\  values (?1, ?2, ?3, ?4)
    , .{ -3, 2.2, "three", "four" }) catch unreachable;

    try t.expectEqual(@as(usize, 1), conn.changes());

    const lastId = conn.lastInsertedRowId();
    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(lastId, row.id);
    try t.expectEqual(@as(i64, -3), row.int);
    try t.expectEqual(@as(f64, 2.2), row.real);
    try t.expectEqualStrings("three", row.text);
    try t.expectEqualStrings("four", row.blob);
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);

    try conn.exec("delete from test where id = ?", .{lastId});
    try t.expectEqual(@as(usize, 1), conn.changes());
    try t.expectEqual(@as(?TestRow, null), queryLast(conn));

    try conn.exec("delete from test where id = ?", .{lastId});
    try t.expectEqual(@as(usize, 0), conn.changes());
    try t.expectEqual(@as(?TestRow, null), queryLast(conn));
}

test "bind null" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\ insert into test (cintn, crealn, ctextn, cblobn)
        \\ values (?1, ?2, ?3, ?4)
    , .{ null, null, null, null }) catch unreachable;
    try t.expectEqual(@as(usize, 1), conn.changes());

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);
}

test "bind null optionals" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    const empty = TestRow{};

    conn.exec(
        \\
        \\ insert into test (cintn, crealn, ctextn, cblobn)
        \\ values (?1, ?2, ?3, ?4)
    , .{ empty.intn, empty.realn, empty.textn, empty.blobn }) catch unreachable;
    try t.expectEqual(@as(usize, 1), conn.changes());

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);
}

test "boolean" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        conn.exec("insert into test (cint, cintn) values (?, ?)", .{ true, true }) catch unreachable;
        const row = (try conn.row("select cint, cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
        try t.expectEqual(true, row.nullableBoolean(1).?);

        try t.expectEqual(true, row.get(bool, 0));
        try t.expectEqual(true, row.get(?bool, 1).?);
    }

    {
        conn.execNoArgs("update test set cint = false, cintn = false") catch unreachable;
        const row = (try conn.row("select cint, cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(false, row.boolean(0));
        try t.expectEqual(false, row.nullableBoolean(1).?);

        try t.expectEqual(false, row.get(bool, 0));
        try t.expectEqual(false, row.get(?bool, 1).?);
    }

    {
        conn.execNoArgs("update test set cintn = null") catch unreachable;
        const row = (try conn.row("select cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(@as(?bool, null), row.nullableBoolean(0));
        try t.expectEqual(@as(?bool, null), row.get(?bool, 0));
    }
}

test "blob/text" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        const d1 = [_]u8{ 5, 1, 2, 3 };
        const d2 = [_]u8{ 9, 10, 11, 12, 13 };
        conn.exec("insert into test (cblob, cblobn, ctext, ctextn) values (?1, ?2, ?1, ?2)", .{ &d1, &d2 }) catch unreachable;
        const row = (try conn.row("select cblob, cblobn, ctext, ctextn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqualStrings(&d1, row.blob(0));
        try t.expectEqualStrings(&d2, row.nullableBlob(1).?);

        try t.expectEqualStrings(&d1, row.get(Blob, 0));
        try t.expectEqualStrings(&d2, row.get(?Blob, 1).?);

        try t.expectEqualStrings(&d1, row.text(2));
        try t.expectEqualStrings(&d2, row.nullableText(3).?);

        try t.expectEqualStrings(&d1, row.get([]const u8, 2));
        try t.expectEqualStrings(&d2, row.get(?[]const u8, 3).?);

        try t.expectEqualStrings(&d1, std.mem.span(row.textZ(2)));
        try t.expectEqualStrings(&d2, std.mem.span(row.nullableTextZ(3).?));
        try t.expectEqual(@as(usize, 4), row.columnBytes(2));
        try t.expectEqual(@as(usize, 5), row.columnBytes(3));
    }
}

test "explicit blob type" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        const d1 = [_]u8{ 0, 1, 2, 3 };
        conn.exec("insert into test (cblob) values (?1)", .{zqlite.blob(&d1)}) catch unreachable;
        const row = (try conn.row("select 1 from test where cblob = ?1", .{zqlite.blob(&d1)})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
    }

    {
        conn.exec("insert into test (cblob) values (?1)", .{zqlite.blob("hello")}) catch unreachable;
        const row = (try conn.row("select 1 from test where cblob = ?1", .{zqlite.blob("hello")})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
    }
}

test "empty string/blob" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\ insert into test (ctext, ctextn, cblob, cblobn) values
        \\ (?1, ?1, ?1, ?1)
    , .{""}) catch unreachable;

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqualStrings("", row.text);
    try t.expectEqualStrings("", row.textn.?);
    try t.expectEqualStrings("", row.blob);
    try t.expectEqualStrings("", row.blobn.?);
}

test "transaction commit" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    var id1: i64 = 0;
    var id2: i64 = 0;
    {
        try conn.transaction();
        errdefer conn.rollback();

        conn.exec("insert into test (ctext) values (?)", .{"hello"}) catch unreachable;
        id1 = conn.lastInsertedRowId();

        conn.exec("insert into test (ctext) values (?)", .{"world"}) catch unreachable;
        id2 = conn.lastInsertedRowId();

        try conn.commit();
    }

    const row1 = queryId(conn, id1).?;
    defer row1.row.deinit();
    const row2 = queryId(conn, id2).?;
    defer row2.row.deinit();

    try t.expectEqualStrings("hello", row1.text);
    try t.expectEqualStrings("world", row2.text);
}

test "transaction rollback" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    var id1: i64 = 0;
    var id2: i64 = 0;
    {
        try conn.transaction();
        defer conn.rollback();

        conn.exec("insert into test (ctext) values (?)", .{"hello"}) catch unreachable;
        id1 = conn.lastInsertedRowId();

        conn.exec("insert into test (ctext) values (?)", .{"world"}) catch unreachable;
        id2 = conn.lastInsertedRowId();
    }

    // make sure the insert actually happened before we rolledback
    try t.expectEqual(true, id2 > id1);
    try t.expectEqual(@as(?TestRow, null), queryId(conn, id1));
    try t.expectEqual(@as(?TestRow, null), queryId(conn, id2));
}

test "rows" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\ insert into test (cint, ctext)
        \\ values (?1, ?2), (?3, ?4)
    , .{ 1, "two", 3, "four" }) catch unreachable;
    try t.expectEqual(@as(usize, 2), conn.changes());

    var rows = conn.rows("select cint, ctext from test order by cint", .{}) catch unreachable;
    defer rows.deinit();

    const r1 = rows.next().?;
    try t.expectEqual(@as(i64, 1), r1.int(0));
    try t.expectEqualStrings("two", r1.text(1));

    const r2 = rows.next().?;
    try t.expectEqual(@as(i64, 3), r2.int(0));
    try t.expectEqualStrings("four", r2.text(1));

    try t.expectEqual(@as(?Row, null), rows.next());
    try t.expectEqual(@as(?Error, null), rows.err);
}

test "row query error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectError(error.Error, conn.row("select invalid from test", .{}));
    try t.expectEqualStrings("no such column: invalid", std.mem.span(conn.lastError()));
}

test "rows query error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectError(error.Error, conn.rows("select invalid from test", .{}));
    try t.expectEqualStrings("no such column: invalid", std.mem.span(conn.lastError()));
}

test "lastError without error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectEqualStrings("not an error", std.mem.span(conn.lastError()));
}

test "isUnique" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.execNoArgs("insert into test (uniq) values (1)") catch unreachable;

    var is_unique = false;
    conn.execNoArgs("insert into test (uniq) values (1)") catch |err| {
        is_unique = zqlite.isUnique(err);
    };
    try t.expectEqual(true, is_unique);
}

test "statement meta" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    const row = (conn.row("select 1 as id, 'leto' as name, null as other", .{}) catch unreachable) orelse unreachable;
    defer row.deinit();

    try t.expectEqual(@as(i32, 3), row.stmt.columnCount());
    try t.expectEqualStrings("id", std.mem.span(row.stmt.columnName(0)));
    try t.expectEqualStrings("name", std.mem.span(row.stmt.columnName(1)));
    try t.expectEqualStrings("other", std.mem.span(row.stmt.columnName(2)));

    try t.expectEqual(@as(i32, 3), row.columnCount());
    try t.expectEqualStrings("id", row.columnName(0));
    try t.expectEqualStrings("name", row.columnName(1));
    try t.expectEqualStrings("other", row.columnName(2));

    try t.expectEqual(ColumnType.int, row.stmt.columnType(0));
    try t.expectEqual(ColumnType.text, row.stmt.columnType(1));
    try t.expectEqual(ColumnType.null, row.stmt.columnType(2));

    try t.expectEqual(ColumnType.int, row.columnType(0));
    try t.expectEqual(ColumnType.text, row.columnType(1));
    try t.expectEqual(ColumnType.null, row.columnType(2));
}

test "preparing multiple statements" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    try conn.exec("--test\nSELECT 1 FROM test; ", .{});

    try conn.exec("SELECT 1 FROM test;--test", .{});

    try t.expectError(
        error.MultipleStatements,
        conn.exec(
            \\SELECT 1 FROM test;
            \\SELECT 2 FROM test;
        , .{}),
    );
}

fn testDB() Conn {
    var conn = zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode) catch unreachable;
    conn.execNoArgs(
        \\
        \\ create table test (
        \\  id integer primary key not null,
        \\  cint integer not null default(0),
        \\  cintn integer null,
        \\  creal real not null default(0.0),
        \\  crealn real null,
        \\  ctext text not null default(''),
        \\  ctextn text null,
        \\  cblob blob not null default(''),
        \\  cblobn blob null,
        \\  uniq int unique null
        \\ )
    ) catch unreachable;
    return conn;
}

const TestRow = struct {
    row: Row = undefined,
    id: i64 = 0,
    int: i64 = 0,
    intn: ?i64 = null,
    real: f64 = 0.0,
    realn: ?f64 = null,
    text: []const u8 = "",
    textn: ?[]const u8 = null,
    blob: []const u8 = "",
    blobn: ?[]const u8 = null,
};

fn queryLast(conn: Conn) ?TestRow {
    return queryId(conn, conn.lastInsertedRowId());
}

fn queryId(conn: Conn, id: i64) ?TestRow {
    const row = (conn.row(
        \\
        \\ select id, cint, cintn, creal, crealn,
        \\   ctext, ctextn, cblob, cblobn
        \\ from test where id = ?
    , .{id}) catch unreachable) orelse return null;

    return .{
        .row = row,
        .id = row.get(i64, 0),
        .int = row.get(i64, 1),
        .intn = row.get(?i64, 2),
        .real = row.get(f64, 3),
        .realn = row.get(?f64, 4),
        .text = row.get([]const u8, 5),
        .textn = row.get(?[]const u8, 6),
        .blob = row.get(Blob, 7),
        .blobn = row.get(?Blob, 8),
    };
}
