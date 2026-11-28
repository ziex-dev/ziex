// Native MySQL/MariaDB backend for `zx.Db`, on std.Io and std.crypto.tls.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Conn = @import("Conn.zig");
pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const types = @import("types.zig");
pub const uri = @import("uri.zig");
pub const placeholders = @import("placeholders.zig");

const log = std.log.scoped(.mysql);

pub fn Backend(Db: type) type {
    return struct {
        const Mysql = @This();

        allocator: std.mem.Allocator,
        io: Io,
        shared: *Shared,
        /// Set on the handle passed to a transaction callback; all work runs on this connection.
        tx_conn: ?*Conn = null,
        owns_resources: bool = true,

        /// `readonly` makes sessions read-only; `create` has no meaning for MySQL.
        pub const OpenOptions = Db.OpenOptions;

        const Shared = struct {
            config: uri.Config,
            tls_ctx: Conn.TlsContext,
            mutex: Io.Mutex = .init,
            cond: Io.Condition = .init,
            idle: std.ArrayList(*Conn) = .empty,
            open_count: usize = 0,
            max: usize,

            fn deinit(self: *Shared, gpa: std.mem.Allocator) void {
                for (self.idle.items) |conn| conn.close();
                self.idle.deinit(gpa);
                self.tls_ctx.deinit();
                self.config.deinit();
            }
        };

        // --- Constructors --- //

        pub fn open(allocator: std.mem.Allocator, io: Io, location: []const u8, options: OpenOptions) !Db {
            if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return Db.Error.Unsupported;
            const self = openState(allocator, io, location, options) catch |err| {
                // the URL may hold a password; don't log it
                log.err("Failed to open MySQL database: {s}", .{@errorName(err)});
                return err;
            };
            return self.db();
        }

        fn openState(allocator: std.mem.Allocator, io: Io, location: []const u8, options: OpenOptions) !*Mysql {
            var config = uri.parse(allocator, location) catch return Db.Error.OpenFailed;
            errdefer config.deinit();
            config.readonly = options.readonly;

            const max = @max(options.max_pool_size, 1);
            const shared = try allocator.create(Shared);
            errdefer allocator.destroy(shared);
            shared.* = .{ .config = config, .tls_ctx = .{ .gpa = allocator }, .max = max };
            errdefer {
                shared.idle.deinit(allocator);
                shared.tls_ctx.deinit();
            }
            try shared.idle.ensureTotalCapacity(allocator, max);

            const self = try allocator.create(Mysql);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .io = io, .shared = shared };

            // connect once so bad URLs and credentials fail here
            const conn = try self.acquire();
            self.release(conn, null);
            return self;
        }

        pub fn deserialize(allocator: std.mem.Allocator, io: Io, bytes: []const u8, options: OpenOptions) !Db {
            _ = allocator;
            _ = io;
            _ = bytes;
            _ = options;
            return Db.Error.Unsupported;
        }

        pub fn db(self: *Mysql) Db {
            return .{ .userdata = self, .vtable = &database_vtable };
        }

        pub fn from(database: Db) !*Mysql {
            if (database.vtable != &database_vtable) return Db.Error.WrongBackend;
            return @ptrCast(@alignCast(database.userdata orelse return Db.Error.InvalidState));
        }

        // --- Pool --- //

        fn acquire(self: *Mysql) !*Conn {
            if (self.tx_conn) |conn| return conn;
            const s = self.shared;
            try s.mutex.lock(self.io);
            while (true) {
                if (s.idle.pop()) |conn| {
                    s.mutex.unlock(self.io);
                    return conn;
                }
                if (s.open_count < s.max) {
                    s.open_count += 1;
                    s.mutex.unlock(self.io);
                    return Conn.open(self.allocator, self.io, &s.config, &s.tls_ctx) catch |err| {
                        s.mutex.lockUncancelable(self.io);
                        s.open_count -= 1;
                        s.mutex.unlock(self.io);
                        s.cond.signal(self.io);
                        return err;
                    };
                }
                s.cond.wait(self.io, &s.mutex) catch |err| {
                    s.mutex.unlock(self.io);
                    return err;
                };
            }
        }

        // Hands the error `conn` recorded during the caller's call to its `diagnostics`.
        fn release(self: *Mysql, conn: *Conn, diagnostics: ?*Db.Diagnostics) void {
            if (conn.last_error) |e| if (diagnostics) |d| d.set(e.message(), e.offset);
            conn.last_error = null;
            if (self.tx_conn != null) return;
            const s = self.shared;
            // a connection left mid-transaction, mid-result or desynced is not reusable
            const reusable = !conn.broken and conn.state == .idle and !conn.inTransaction();
            if (!reusable) conn.close();
            s.mutex.lockUncancelable(self.io);
            if (reusable) s.idle.appendAssumeCapacity(conn) else s.open_count -= 1;
            s.mutex.unlock(self.io);
            s.cond.signal(self.io);
        }

        // --- Execution --- //

        const Column = protocol.Column;

        /// One in-flight query; holds its connection until `finish`.
        const Exec = struct {
            owner: *Mysql,
            conn: *Conn,
            diagnostics: ?*Db.Diagnostics = null,
            /// The connection's scratch arena; params and result column names live here.
            scratch: std.mem.Allocator,
            sql: []const u8,
            /// Empty for the text protocol.
            params: []const protocol.Param,
            binary: bool,
            columns: []const Column = &.{},
            /// Decoder per column.
            kinds: []const types.Kind = &.{},
            changes: u64 = 0,
            last_insert_id: u64 = 0,
            done: bool = false,
            rows_seen: bool = false,
            retried: bool = false,
            set_seen: bool = false,

            /// Text protocol (COM_QUERY) without bindings, prepared statement with them.
            fn start(owner: *Mysql, sql: []const u8, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings, diagnostics: ?*Db.Diagnostics) !Exec {
                const conn = try owner.acquire();
                errdefer owner.release(conn, diagnostics);
                const scratch = conn.resetScratch();
                var exec: Exec = .{ .owner = owner, .conn = conn, .scratch = scratch, .sql = sql, .params = &.{}, .binary = bindings != .none, .diagnostics = diagnostics };
                if (exec.binary) {
                    exec.params = try encodeBindings(scratch, rewritten, bindings);
                    try conn.sendExecute(sql, exec.params);
                } else {
                    try conn.sendQuery(sql);
                }
                return exec;
            }

            fn setColumns(self: *Exec, cols: []const Column) !void {
                const kinds = try self.scratch.alloc(types.Kind, cols.len);
                for (kinds, cols) |*k, col| k.* = types.kindOf(col, self.binary);
                self.columns = cols;
                self.kinds = kinds;
            }

            /// Next row packet (valid until the next call), or null when the command is complete.
            fn nextRow(self: *Exec) anyerror!?[]const u8 {
                if (self.done) return null;
                errdefer self.done = true;
                while (true) switch (self.conn.next() catch |err| return self.retryStale(err)) {
                    .columns => |cols| {
                        // only the first result set is exposed; the rest are drained
                        if (self.set_seen) {
                            self.conn.discard();
                            self.done = true;
                            return null;
                        }
                        self.set_seen = true;
                        try self.setColumns(cols);
                    },
                    .row => |body| {
                        self.rows_seen = true;
                        return body;
                    },
                    .complete => |ok| {
                        self.changes = ok.affected_rows;
                        self.last_insert_id = ok.last_insert_id;
                    },
                    .ready => {
                        self.done = true;
                        return null;
                    },
                };
            }

            /// A stale cached statement fails before executing, so re-send once after dropping the cache.
            fn retryStale(self: *Exec, err: anyerror) anyerror!?[]const u8 {
                if (err != error.StaleStatement or self.retried or self.rows_seen) return err;
                self.retried = true;
                self.columns = &.{};
                self.kinds = &.{};
                self.conn.clearCache(true);
                try self.conn.sendExecute(self.sql, self.params);
                return self.nextRow();
            }

            fn finish(self: *Exec) void {
                if (!self.done) self.conn.discard();
                self.owner.release(self.conn, self.diagnostics);
            }

            fn reader(self: *const Exec, body: []const u8) !types.RowReader {
                return types.RowReader.init(body, self.binary, self.columns.len);
            }

            /// Column names copied once, to be shared by every row of one result.
            fn sharedNames(self: *const Exec, allocator: std.mem.Allocator) ![]const []const u8 {
                const names = try allocator.alloc([]const u8, self.columns.len);
                var filled: usize = 0;
                errdefer freeNames(allocator, names[0..filled], names);
                for (names, self.columns) |*n, col| {
                    n.* = try allocator.dupe(u8, col.name);
                    filled += 1;
                }
                return names;
            }

            /// Row with shared `names` and values owned by `allocator`.
            fn cloneRow(self: *const Exec, allocator: std.mem.Allocator, names: []const []const u8, body: []const u8) !Db.Row {
                var row = try self.reader(body);
                const fields = try allocator.alloc(Db.Field, self.columns.len);
                var filled: usize = 0;
                errdefer freeOwnedFields(allocator, fields, filled);
                for (fields, self.kinds, names) |*field, kind, name| {
                    field.* = .{ .name = name, .value = try row.next(Db.Value, true, allocator, kind) };
                    filled += 1;
                }
                return .{ .fields = fields };
            }

            /// Row that borrows names, text, blobs and `fields`; valid until the next read on the connection.
            /// Values formatted from several bytes (dates, large unsigned integers) go to `scratch_values`.
            fn borrowRow(self: *const Exec, fields: []Db.Field, scratch_values: std.mem.Allocator, body: []const u8) !Db.Row {
                var row = try self.reader(body);
                if (fields.len != self.columns.len) return error.ProtocolViolation;
                for (fields, self.columns, self.kinds) |*field, col, kind| {
                    field.* = .{ .name = col.name, .value = try row.next(Db.Value, false, scratch_values, kind) };
                }
                return .{ .fields = fields };
            }

            fn cloneValues(self: *const Exec, allocator: std.mem.Allocator, body: []const u8) ![]const Db.Value {
                var row = try self.reader(body);
                const out = try allocator.alloc(Db.Value, self.columns.len);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |v| freeValue(allocator, v);
                    allocator.free(out);
                }
                for (out, self.kinds) |*v, kind| {
                    v.* = try row.next(Db.Value, true, allocator, kind);
                    filled += 1;
                }
                return out;
            }
        };

        fn encodeBindings(arena: std.mem.Allocator, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings) ![]const protocol.Param {
            switch (bindings) {
                .none => return &.{},
                .positional => |values| {
                    const params = try arena.alloc(protocol.Param, values.len);
                    for (values, params) |v, *p| p.* = encodeValue(v);
                    return params;
                },
                .named => |entries| {
                    const r = rewritten orelse return Db.Error.InvalidBindings;
                    // unbound names are NULL, as with SQLite
                    const by_name = try arena.alloc(protocol.Param, r.names.len);
                    @memset(by_name, .null);
                    for (entries) |entry| {
                        const index = r.indexOf(entry.name) orelse return Db.Error.InvalidBindings;
                        by_name[index] = encodeValue(entry.value);
                    }
                    // `?` is positional, so a name used twice is sent twice
                    const params = try arena.alloc(protocol.Param, r.slots.len);
                    for (params, r.slots) |*p, slot| p.* = by_name[slot];
                    return params;
                },
            }
        }

        fn encodeValue(value: Db.Value) protocol.Param {
            return switch (value) {
                .null => .null,
                .integer => |v| .{ .int = v },
                .float => |v| .{ .float = v },
                .text => |v| .{ .text = v },
                .blob => |v| .{ .blob = v },
                .boolean => |v| .{ .boolean = v },
            };
        }

        fn freeValue(allocator: std.mem.Allocator, value: Db.Value) void {
            switch (value) {
                .text => |v| allocator.free(v),
                .blob => |v| allocator.free(v),
                else => {},
            }
        }

        /// Frees a row's values and field array; names are shared and freed with `freeNames`.
        fn freeOwnedFields(allocator: std.mem.Allocator, fields: []const Db.Field, filled: usize) void {
            for (fields[0..filled]) |field| freeValue(allocator, field.value);
            allocator.free(fields);
        }

        fn freeNames(allocator: std.mem.Allocator, filled: []const []const u8, all: []const []const u8) void {
            for (filled) |n| allocator.free(n);
            allocator.free(all);
        }

        fn rewriteSql(allocator: std.mem.Allocator, sql: []const u8) !?placeholders.Rewritten {
            return placeholders.rewrite(allocator, sql) catch |err| switch (err) {
                error.MixedPlaceholders => Db.Error.InvalidQuery,
                else => err,
            };
        }

        // --- Connection vtable impls --- //

        const StatementCtx = struct {
            allocator: std.mem.Allocator,
            owner: *Mysql,
            sql: []u8,
            /// Named-placeholder form, used with named bindings.
            rewritten: ?placeholders.Rewritten,
            diagnostics: ?*Db.Diagnostics,
            /// `?` mixed with `:name`/`@name`: only positional bindings are valid.
            mixed: bool = false,
            /// Filled by `describe` on first metadata access.
            column_names: [][]const u8 = &.{},
            column_types: []Db.ColumnType = &.{},
            param_count: usize = 0,
            described: bool = false,

            const Resolved = struct {
                sql: []const u8,
                rewritten: ?placeholders.Rewritten,
            };

            /// `@name` is also a MySQL user variable, so the named form only applies to named bindings.
            fn resolve(self: *const StatementCtx, bindings: Db.Bindings) !Resolved {
                if (bindings != .named) return .{ .sql = self.sql, .rewritten = null };
                const r = self.rewritten orelse return if (self.mixed) Db.Error.InvalidQuery else Db.Error.InvalidBindings;
                return .{ .sql = r.sql, .rewritten = r };
            }

            fn deinit(self: *StatementCtx) void {
                for (self.column_names) |name| self.allocator.free(name);
                self.allocator.free(self.column_names);
                self.allocator.free(self.column_types);
                if (self.rewritten) |r| r.deinit(self.allocator);
                self.allocator.free(self.sql);
            }
        };

        fn prepare(ud: ?*anyopaque, sql: []const u8, diagnostics: ?*Db.Diagnostics) !Db.Statement {
            const self: *Mysql = @ptrCast(@alignCast(ud));
            const allocator = self.allocator;

            const ctx = try allocator.create(StatementCtx);
            errdefer allocator.destroy(ctx);
            ctx.* = .{
                .allocator = allocator,
                .owner = self,
                .sql = try allocator.dupe(u8, sql),
                .rewritten = null,
                .diagnostics = diagnostics,
            };
            errdefer ctx.deinit();
            ctx.rewritten = placeholders.rewrite(allocator, sql) catch |err| switch (err) {
                error.MixedPlaceholders => blk: {
                    ctx.mixed = true;
                    break :blk null;
                },
                else => return err,
            };
            // no round trip here: one-shot helpers (get/all/row) prepare then execute immediately,
            // and SQL errors surface on first execution
            return .{ .db = self.db(), .userdata = ctx };
        }

        /// COM_STMT_PREPARE (cached on the connection) to learn column names/types and the parameter count.
        fn describe(ctx: *StatementCtx) !void {
            if (ctx.described) return;
            const allocator = ctx.allocator;
            const conn = try ctx.owner.acquire();
            defer ctx.owner.release(conn, ctx.diagnostics);

            const stmt = try conn.getStmt(if (ctx.rewritten) |r| r.sql else ctx.sql);
            defer conn.closeEphemeral();
            const names = try allocator.alloc([]const u8, stmt.columns.len);
            @memset(names, "");
            errdefer {
                for (names) |n| allocator.free(n);
                allocator.free(names);
            }
            const col_types = try allocator.alloc(Db.ColumnType, stmt.columns.len);
            errdefer allocator.free(col_types);
            for (stmt.columns, 0..) |col, i| {
                names[i] = try allocator.dupe(u8, col.name);
                col_types[i] = types.columnType(Db.ColumnType, col);
            }
            ctx.column_names = names;
            ctx.column_types = col_types;
            ctx.param_count = if (ctx.rewritten) |r| r.names.len else stmt.param_count;
            ctx.described = true;
        }

        fn run(ud: ?*anyopaque, sql: []const u8, bindings: Db.Bindings) !Db.RunResult {
            const self: *Mysql = @ptrCast(@alignCast(ud));

            // without parameters, the text protocol also allows multi-statement scripts
            if (bindings == .none) {
                const conn = try self.acquire();
                defer self.release(conn, null);
                const ok = try conn.query(sql);
                return .{ .changes = @intCast(ok.affected_rows), .last_insert_id = @bitCast(ok.last_insert_id) };
            }

            const rewritten = if (bindings == .named) try rewriteSql(self.allocator, sql) else null;
            defer if (rewritten) |r| r.deinit(self.allocator);
            return runExec(self, if (rewritten) |r| r.sql else sql, rewritten, bindings);
        }

        fn runExec(self: *Mysql, sql: []const u8, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings) !Db.RunResult {
            var exec = try Exec.start(self, sql, rewritten, bindings, null);
            defer exec.finish();
            while (try exec.nextRow()) |_| {}
            return .{ .changes = @intCast(exec.changes), .last_insert_id = @bitCast(exec.last_insert_id) };
        }

        fn transaction(ud: ?*anyopaque, mode: Db.TransactionMode, cb_ctx: *anyopaque, callback: Db.TransactionCallback) !void {
            const self: *Mysql = @ptrCast(@alignCast(ud));
            if (self.tx_conn != null) return Db.Error.InvalidState;

            const conn = try self.acquire();
            defer self.release(conn, null);

            _ = try conn.query(switch (mode) {
                .deferred, .immediate => "START TRANSACTION",
                // applies to the next transaction only
                .exclusive => "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; START TRANSACTION",
            });

            var tx: Mysql = .{
                .allocator = self.allocator,
                .io = self.io,
                .shared = self.shared,
                .tx_conn = conn,
                .owns_resources = false,
            };
            var handle = tx.db();

            callback(cb_ctx, &handle) catch |err| {
                _ = conn.query("ROLLBACK") catch {};
                return err;
            };
            _ = try conn.query("COMMIT");
        }

        fn close(ud: ?*anyopaque, _: bool) !void {
            const self: *Mysql = @ptrCast(@alignCast(ud));
            if (!self.owns_resources) return;
            const allocator = self.allocator;
            self.shared.deinit(allocator);
            allocator.destroy(self.shared);
            allocator.destroy(self);
        }

        // --- Statement vtable impls --- //

        fn startExec(ctx: *StatementCtx, bindings: Db.Bindings) !Exec {
            const resolved = try ctx.resolve(bindings);
            return Exec.start(ctx.owner, resolved.sql, resolved.rewritten, bindings, ctx.diagnostics);
        }

        fn stmtAll(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const Db.Row {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try startExec(ctx, bindings);
            defer exec.finish();

            var names: ?[]const []const u8 = null;
            var rows: std.ArrayList(Db.Row) = .empty;
            errdefer {
                for (rows.items) |row| freeOwnedFields(allocator, row.fields, row.fields.len);
                rows.deinit(allocator);
                if (names) |n| freeNames(allocator, n, n);
            }
            while (try exec.nextRow()) |body| {
                if (names == null) names = try exec.sharedNames(allocator);
                try rows.append(allocator, try exec.cloneRow(allocator, names.?, body));
            }
            return rows.toOwnedSlice(allocator);
        }

        fn stmtGet(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) !?Db.Row {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try startExec(ctx, bindings);
            defer exec.finish();

            const body = try exec.nextRow() orelse return null;
            const names = try exec.sharedNames(allocator);
            errdefer freeNames(allocator, names, names);
            const row = try exec.cloneRow(allocator, names, body);
            errdefer freeOwnedFields(allocator, row.fields, row.fields.len);
            // read to completion so a late server error still surfaces
            while (try exec.nextRow()) |_| {}
            return row;
        }

        fn stmtRun(ud: ?*anyopaque, bindings: Db.Bindings) !Db.RunResult {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const resolved = try ctx.resolve(bindings);
            return runExec(ctx.owner, resolved.sql, resolved.rewritten, bindings);
        }

        fn stmtValues(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const []const Db.Value {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try startExec(ctx, bindings);
            defer exec.finish();

            var rows: std.ArrayList([]const Db.Value) = .empty;
            errdefer {
                for (rows.items) |row| {
                    for (row) |v| freeValue(allocator, v);
                    allocator.free(row);
                }
                rows.deinit(allocator);
            }
            while (try exec.nextRow()) |body| {
                try rows.append(allocator, try exec.cloneValues(allocator, body));
            }
            return rows.toOwnedSlice(allocator);
        }

        const IteratorCtx = struct {
            allocator: std.mem.Allocator,
            exec: Exec,
            /// Reused for every row; rows borrow from the connection buffer.
            fields: []Db.Field = &.{},
            /// Formatted values of the current row; only reset when a column needs it.
            formatted: std.heap.ArenaAllocator,
            needs_format: bool = false,
        };

        fn stmtIterate(ud: ?*anyopaque, bindings: Db.Bindings) !Db.Statement.Iterator {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const allocator = ctx.allocator;
            const iter = try allocator.create(IteratorCtx);
            errdefer allocator.destroy(iter);
            iter.* = .{
                .allocator = allocator,
                .exec = try startExec(ctx, bindings),
                .formatted = .init(allocator),
            };
            return .{ .userdata = iter, .next_fn = &iterateNext, .deinit_fn = &iterateDeinit };
        }

        fn iterateNext(raw: *anyopaque) !?Db.Row {
            const iter: *IteratorCtx = @ptrCast(@alignCast(raw));
            const body = try iter.exec.nextRow() orelse return null;
            const n = iter.exec.columns.len;
            if (iter.fields.len != n) {
                iter.allocator.free(iter.fields);
                iter.fields = &.{};
                iter.fields = try iter.allocator.alloc(Db.Field, n);
                iter.needs_format = for (iter.exec.kinds) |kind| switch (kind) {
                    .date, .datetime, .time, .ulonglong => break true,
                    else => {},
                } else false;
            }
            if (iter.needs_format) _ = iter.formatted.reset(.retain_capacity);
            return try iter.exec.borrowRow(iter.fields, iter.formatted.allocator(), body);
        }

        fn iterateDeinit(raw: *anyopaque) void {
            const iter: *IteratorCtx = @ptrCast(@alignCast(raw));
            const allocator = iter.allocator;
            allocator.free(iter.fields);
            iter.formatted.deinit();
            iter.exec.finish();
            allocator.destroy(iter);
        }

        fn stmtDeinit(ud: ?*anyopaque) void {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const allocator = ctx.allocator;
            ctx.deinit();
            allocator.destroy(ctx);
        }

        fn stmtToString(ud: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            return allocator.dupe(u8, ctx.sql);
        }

        fn stmtColumnNames(ud: ?*anyopaque) ![]const []const u8 {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            try describe(ctx);
            return ctx.column_names;
        }

        fn stmtColumnTypes(ud: ?*anyopaque) ![]const Db.ColumnType {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            try describe(ctx);
            return ctx.column_types;
        }

        fn stmtParamCount(ud: ?*anyopaque) !usize {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            try describe(ctx);
            return ctx.param_count;
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

test {
    _ = Conn;
    _ = protocol;
    _ = auth;
    _ = types;
    _ = uri;
    _ = placeholders;
}
