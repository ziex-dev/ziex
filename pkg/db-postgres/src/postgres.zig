// Native Postgres backend for `zx.Db`, on std.Io and std.crypto.tls.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Conn = @import("Conn.zig");
pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const types = @import("types.zig");
pub const uri = @import("uri.zig");
pub const placeholders = @import("placeholders.zig");

const log = std.log.scoped(.postgres);

pub fn Backend(Db: type) type {
    return struct {
        const Postgres = @This();

        allocator: std.mem.Allocator,
        io: Io,
        shared: *Shared,
        /// Set on the handle passed to a transaction callback; all work runs on this connection.
        tx_conn: ?*Conn = null,
        owns_resources: bool = true,

        /// `readonly` sets `default_transaction_read_only`; `create` has no meaning for Postgres.
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
                log.err("Failed to open Postgres database: {s}", .{@errorName(err)});
                return err;
            };
            return self.db();
        }

        fn openState(allocator: std.mem.Allocator, io: Io, location: []const u8, options: OpenOptions) !*Postgres {
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

            const self = try allocator.create(Postgres);
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

        pub fn db(self: *Postgres) Db {
            return .{ .userdata = self, .vtable = &database_vtable };
        }

        pub fn from(database: Db) !*Postgres {
            if (database.vtable != &database_vtable) return Db.Error.WrongBackend;
            return @ptrCast(@alignCast(database.userdata orelse return Db.Error.InvalidState));
        }

        // --- Pool --- //

        fn acquire(self: *Postgres) !*Conn {
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
        fn release(self: *Postgres, conn: *Conn, diagnostics: ?*Db.Diagnostics) void {
            if (conn.last_error) |e| if (diagnostics) |d| d.set(e.message(), e.offset);
            conn.last_error = null;
            if (self.tx_conn != null) return;
            const s = self.shared;
            // a connection left mid-transaction or desynced is not reusable
            const reusable = !conn.broken and conn.tx_status == 'I';
            if (!reusable) conn.close();
            s.mutex.lockUncancelable(self.io);
            if (reusable) s.idle.appendAssumeCapacity(conn) else s.open_count -= 1;
            s.mutex.unlock(self.io);
            s.cond.signal(self.io);
        }

        // --- Execution --- //

        const Column = protocol.Column;

        /// One in-flight extended query; holds its connection until `finish`.
        const Exec = struct {
            owner: *Postgres,
            conn: *Conn,
            diagnostics: ?*Db.Diagnostics = null,
            /// The connection's scratch arena; params and uncached columns live here.
            scratch: std.mem.Allocator,
            sql: []const u8,
            params: Params,
            columns: []const Column = &.{},
            /// Decoder per column; cached statements get binary results for known types.
            kinds: []const types.Kind = &.{},
            changes: u64 = 0,
            done: bool = false,
            rows_seen: bool = false,
            retried: bool = false,

            fn start(owner: *Postgres, sql: []const u8, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings, diagnostics: ?*Db.Diagnostics) !Exec {
                const conn = try owner.acquire();
                errdefer owner.release(conn, diagnostics);
                const scratch = conn.resetScratch();
                const params = try encodeBindings(scratch, rewritten, bindings);
                try conn.sendExtended(sql, params.oids, params.values);
                var exec: Exec = .{ .owner = owner, .conn = conn, .scratch = scratch, .sql = sql, .params = params, .diagnostics = diagnostics };
                if (conn.batch_columns) |cols| try exec.setColumns(cols, true);
                return exec;
            }

            fn setColumns(self: *Exec, cols: []const Column, binary: bool) !void {
                const kinds = try self.scratch.alloc(types.Kind, cols.len);
                for (kinds, cols) |*k, col| k.* = types.kindOf(col.type_oid, binary);
                self.columns = cols;
                self.kinds = kinds;
            }

            /// Next DataRow body (valid until the next call), or null when the command is complete.
            fn nextRow(self: *Exec) anyerror!?[]const u8 {
                if (self.done) return null;
                errdefer self.done = true;
                while (true) switch (self.conn.next() catch |err| return self.retryStale(err)) {
                    .columns => |body| try self.setColumns(try parseColumns(self.scratch, body), false),
                    .row => |body| {
                        self.rows_seen = true;
                        return body;
                    },
                    .complete => |tag| self.changes = protocol.commandRows(tag),
                    .ready => {
                        self.done = true;
                        return null;
                    },
                    .params, .no_data => {},
                };
            }

            /// A stale cached statement fails before executing, so re-send once (the cache is now
            /// cleared). Not inside a transaction: the error has already aborted it.
            fn retryStale(self: *Exec, err: anyerror) anyerror!?[]const u8 {
                if (err != error.StaleStatement or self.retried or self.rows_seen or self.conn.tx_status != 'I') return err;
                self.retried = true;
                self.columns = &.{};
                self.kinds = &.{};
                try self.conn.sendExtended(self.sql, self.params.oids, self.params.values);
                if (self.conn.batch_columns) |cols| try self.setColumns(cols, true);
                return self.nextRow();
            }

            fn finish(self: *Exec) void {
                if (!self.done) self.conn.discard();
                self.owner.release(self.conn, self.diagnostics);
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
                var data = try protocol.DataRow.init(body);
                if (data.count != self.columns.len) return error.ProtocolViolation;
                const fields = try allocator.alloc(Db.Field, data.count);
                var filled: usize = 0;
                errdefer freeOwnedFields(allocator, fields, filled);
                for (fields, self.kinds, names) |*field, kind, name| {
                    field.* = .{ .name = name, .value = try types.decodeKind(Db.Value, true, allocator, kind, try data.next()) };
                    filled += 1;
                }
                return .{ .fields = fields };
            }

            /// Row that borrows names, text and `fields`; valid until the next read on the connection.
            fn borrowRow(self: *const Exec, fields: []Db.Field, blobs: std.mem.Allocator, body: []const u8) !Db.Row {
                var data = try protocol.DataRow.init(body);
                if (data.count != self.columns.len or fields.len != data.count) return error.ProtocolViolation;
                for (fields, self.columns, self.kinds) |*field, col, kind| {
                    field.* = .{ .name = col.name, .value = try types.decodeKind(Db.Value, false, blobs, kind, try data.next()) };
                }
                return .{ .fields = fields };
            }

            fn cloneValues(self: *const Exec, allocator: std.mem.Allocator, body: []const u8) ![]const Db.Value {
                var data = try protocol.DataRow.init(body);
                if (data.count != self.columns.len) return error.ProtocolViolation;
                const out = try allocator.alloc(Db.Value, data.count);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |v| freeValue(allocator, v);
                    allocator.free(out);
                }
                for (out, self.kinds) |*v, kind| {
                    v.* = try types.decodeKind(Db.Value, true, allocator, kind, try data.next());
                    filled += 1;
                }
                return out;
            }
        };

        fn parseColumns(arena: std.mem.Allocator, body: []const u8) ![]Column {
            var desc = try protocol.RowDescription.init(body);
            const cols = try arena.alloc(Column, desc.count);
            for (cols) |*col| {
                const c = try desc.next();
                col.* = .{ .name = try arena.dupe(u8, c.name), .type_oid = c.type_oid };
            }
            return cols;
        }

        const Params = struct {
            oids: []const u32,
            values: []const protocol.Param,
        };

        fn encodeBindings(arena: std.mem.Allocator, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings) !Params {
            switch (bindings) {
                .none => return .{ .oids = &.{}, .values = &.{} },
                .positional => |values| {
                    const oids = try arena.alloc(u32, values.len);
                    const params = try arena.alloc(protocol.Param, values.len);
                    for (values, oids, params) |v, *oid, *p| try encodeValue(arena, v, oid, p);
                    return .{ .oids = oids, .values = params };
                },
                .named => |entries| {
                    const r = rewritten orelse return Db.Error.InvalidBindings;
                    const oids = try arena.alloc(u32, r.names.len);
                    const params = try arena.alloc(protocol.Param, r.names.len);
                    // unbound names are NULL, as with SQLite
                    @memset(oids, types.Oid.unspecified);
                    @memset(params, .null);
                    for (entries) |entry| {
                        const index = r.indexOf(entry.name) orelse return Db.Error.InvalidBindings;
                        try encodeValue(arena, entry.value, &oids[index], &params[index]);
                    }
                    return .{ .oids = oids, .values = params };
                },
            }
        }

        // Values go as text with unspecified type so the server infers it from context.
        fn encodeValue(arena: std.mem.Allocator, value: Db.Value, oid: *u32, param: *protocol.Param) !void {
            oid.* = types.Oid.unspecified;
            param.* = switch (value) {
                .null => .null,
                .integer => |v| .{ .text = try arena.print("{d}", .{v}) },
                .float => |v| blk: {
                    var buf: [64]u8 = undefined;
                    break :blk .{ .text = try arena.dupe(u8, try types.formatFloat(&buf, v)) };
                },
                .text => |v| .{ .text = v },
                .boolean => |v| .{ .text = if (v) "true" else "false" },
                .blob => |v| blk: {
                    oid.* = types.Oid.bytea;
                    break :blk .{ .binary = v };
                },
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
            owner: *Postgres,
            sql: []u8,
            rewritten: ?placeholders.Rewritten,
            diagnostics: ?*Db.Diagnostics,
            /// Filled by `describe` on first metadata access.
            column_names: [][]const u8 = &.{},
            column_types: []Db.ColumnType = &.{},
            param_count: usize = 0,
            described: bool = false,

            fn execSql(self: *const StatementCtx) []const u8 {
                return if (self.rewritten) |r| r.sql else self.sql;
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
            const self: *Postgres = @ptrCast(@alignCast(ud));
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
            ctx.rewritten = try rewriteSql(allocator, sql);
            // no round trip here: one-shot helpers (get/all/row) prepare then execute immediately,
            // and SQL errors surface on first execution as with other Postgres drivers
            return .{ .db = self.db(), .userdata = ctx };
        }

        /// Parse/Describe/Sync once to learn column names/types and the parameter count.
        fn describe(ctx: *StatementCtx) !void {
            if (ctx.described) return;
            const allocator = ctx.allocator;
            const conn = try ctx.owner.acquire();
            defer ctx.owner.release(conn, ctx.diagnostics);
            try conn.sendDescribe(ctx.execSql());

            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            var columns: []Column = &.{};
            var param_count: usize = 0;
            while (true) switch (try conn.next()) {
                .params => |body| {
                    var c: protocol.Cursor = .{ .data = body };
                    param_count = try c.int2();
                },
                .columns => |body| columns = try parseColumns(arena.allocator(), body),
                .ready => break,
                else => {},
            };

            const names = try allocator.alloc([]const u8, columns.len);
            @memset(names, "");
            errdefer {
                for (names) |n| allocator.free(n);
                allocator.free(names);
            }
            const col_types = try allocator.alloc(Db.ColumnType, columns.len);
            for (columns, 0..) |col, i| {
                names[i] = try allocator.dupe(u8, col.name);
                col_types[i] = types.columnType(Db.ColumnType, col.type_oid);
            }
            ctx.column_names = names;
            ctx.column_types = col_types;
            ctx.param_count = param_count;
            ctx.described = true;
        }

        fn run(ud: ?*anyopaque, sql: []const u8, bindings: Db.Bindings) !Db.RunResult {
            const self: *Postgres = @ptrCast(@alignCast(ud));

            // without parameters, the simple protocol also allows multi-statement scripts
            if (bindings == .none) {
                const conn = try self.acquire();
                defer self.release(conn, null);
                return .{ .changes = @intCast(try conn.simpleQuery(sql)) };
            }

            const rewritten = try rewriteSql(self.allocator, sql);
            defer if (rewritten) |r| r.deinit(self.allocator);
            return runExec(self, if (rewritten) |r| r.sql else sql, rewritten, bindings);
        }

        fn runExec(self: *Postgres, sql: []const u8, rewritten: ?placeholders.Rewritten, bindings: Db.Bindings) !Db.RunResult {
            var exec = try Exec.start(self, sql, rewritten, bindings, null);
            defer exec.finish();
            while (try exec.nextRow()) |_| {}
            // Postgres has no last-insert id; use RETURNING
            return .{ .changes = @intCast(exec.changes) };
        }

        fn transaction(ud: ?*anyopaque, mode: Db.TransactionMode, cb_ctx: *anyopaque, callback: Db.TransactionCallback) !void {
            const self: *Postgres = @ptrCast(@alignCast(ud));
            if (self.tx_conn != null) return Db.Error.InvalidState;

            const conn = try self.acquire();
            defer self.release(conn, null);

            _ = try conn.simpleQuery(switch (mode) {
                .deferred, .immediate => "BEGIN",
                .exclusive => "BEGIN ISOLATION LEVEL SERIALIZABLE",
            });

            var tx: Postgres = .{
                .allocator = self.allocator,
                .io = self.io,
                .shared = self.shared,
                .tx_conn = conn,
                .owns_resources = false,
            };
            var handle = tx.db();

            callback(cb_ctx, &handle) catch |err| {
                _ = conn.simpleQuery("ROLLBACK") catch {};
                return err;
            };
            // a swallowed error leaves the transaction aborted; COMMIT would silently roll back
            if (conn.tx_status == 'E') {
                _ = conn.simpleQuery("ROLLBACK") catch {};
                return Db.Error.QueryFailed;
            }
            _ = try conn.simpleQuery("COMMIT");
        }

        fn close(ud: ?*anyopaque, _: bool) !void {
            const self: *Postgres = @ptrCast(@alignCast(ud));
            if (!self.owns_resources) return;
            const allocator = self.allocator;
            self.shared.deinit(allocator);
            allocator.destroy(self.shared);
            allocator.destroy(self);
        }

        // --- Statement vtable impls --- //

        fn stmtAll(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const Db.Row {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try Exec.start(ctx.owner, ctx.execSql(), ctx.rewritten, bindings, ctx.diagnostics);
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
            var exec = try Exec.start(ctx.owner, ctx.execSql(), ctx.rewritten, bindings, ctx.diagnostics);
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
            return runExec(ctx.owner, ctx.execSql(), ctx.rewritten, bindings);
        }

        fn stmtValues(ud: ?*anyopaque, allocator: std.mem.Allocator, bindings: Db.Bindings) ![]const []const Db.Value {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            var exec = try Exec.start(ctx.owner, ctx.execSql(), ctx.rewritten, bindings, ctx.diagnostics);
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
            /// Decoded bytea for the current row; only reset when a column is bytea.
            blobs: std.heap.ArenaAllocator,
            has_bytea: bool = false,
        };

        fn stmtIterate(ud: ?*anyopaque, bindings: Db.Bindings) !Db.Statement.Iterator {
            const ctx: *StatementCtx = @ptrCast(@alignCast(ud));
            const allocator = ctx.allocator;
            const iter = try allocator.create(IteratorCtx);
            errdefer allocator.destroy(iter);
            iter.* = .{
                .allocator = allocator,
                .exec = try Exec.start(ctx.owner, ctx.execSql(), ctx.rewritten, bindings, ctx.diagnostics),
                .blobs = .init(allocator),
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
                iter.has_bytea = for (iter.exec.columns) |col| {
                    if (col.type_oid == types.Oid.bytea) break true;
                } else false;
            }
            if (iter.has_bytea) _ = iter.blobs.reset(.retain_capacity);
            return try iter.exec.borrowRow(iter.fields, iter.blobs.allocator(), body);
        }

        fn iterateDeinit(raw: *anyopaque) void {
            const iter: *IteratorCtx = @ptrCast(@alignCast(raw));
            const allocator = iter.allocator;
            allocator.free(iter.fields);
            iter.blobs.deinit();
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
    _ = protocol;
    _ = auth;
    _ = types;
    _ = uri;
    _ = placeholders;
}
