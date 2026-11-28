// One Postgres server connection over std.Io (plain TCP or std.crypto.tls).
const Conn = @This();

const std = @import("std");
const Io = std.Io;
const tls = std.crypto.tls;
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const uri = @import("uri.zig");
const types = @import("types.zig");

const log = std.log.scoped(.postgres);
const buf_len = tls.Client.min_buffer_len;

gpa: std.mem.Allocator,
io: Io,
stream: Io.net.Stream,
stream_reader: Io.net.Stream.Reader,
stream_writer: Io.net.Stream.Writer,
tls_client: ?tls.Client = null,
buffers: []u8,
msg_buf: std.ArrayList(u8) = .empty,
w: protocol.Writer,
/// 'I' idle, 'T' in transaction, 'E' failed transaction.
tx_status: u8 = 'I',
broken: bool = false,
pending_error: ?anyerror = null,
// Last ErrorResponse, handed to the caller's `Db.Diagnostics` on release
last_error: ?LastError = null,

// Named prepared statements, keyed by param OIDs + SQL; LRU-evicted at `cache_cap`.
cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
cache_cap: usize = 0,
cache_clock: u64 = 0,
next_stmt_id: u32 = 0,
key_buf: std.ArrayList(u8) = .empty,
/// Statement parsed in the in-flight batch; cached only once the batch succeeds.
pending_stmt: ?PendingStmt = null,
/// Result columns of the cached statement bound in the in-flight batch (no Describe sent).
/// Their known-type columns are requested in binary; see `types.binaryResult`.
batch_columns: ?[]const protocol.Column = null,
result_formats: std.ArrayList(u16) = .empty,
/// Per-query scratch memory for callers holding this connection; reset by `resetScratch`.
scratch: std.heap.ArenaAllocator,
/// Set when the server reports a stale cached statement.
invalidate_cache: bool = false,
/// The in-flight batch bound a cached statement.
batch_hit: bool = false,

const CacheEntry = struct {
    id: u32,
    used: u64,
    /// Owned copy of the statement's RowDescription, so hits skip Describe.
    columns: []protocol.Column,
};

const PendingStmt = struct {
    key: []u8,
    id: u32,
    columns: ?[]protocol.Column = null,
};

/// CA bundle shared by every connection of a pool, loaded on first verified connect.
pub const TlsContext = struct {
    gpa: std.mem.Allocator,
    lock: Io.RwLock = .init,
    bundle: std.crypto.Certificate.Bundle = .empty,
    loaded: bool = false,

    pub fn deinit(self: *TlsContext) void {
        self.bundle.deinit(self.gpa);
    }

    fn ensureLoaded(self: *TlsContext, io: Io) !void {
        {
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            if (self.loaded) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(self.gpa);
        bundle.rescan(self.gpa, io, Io.Clock.real.now(io)) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.CertificateBundleLoadFailure,
        };
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        if (self.loaded) return;
        std.mem.swap(std.crypto.Certificate.Bundle, &self.bundle, &bundle);
        self.loaded = true;
    }
};

pub const Event = union(enum) {
    /// RowDescription body.
    columns: []const u8,
    /// DataRow body.
    row: []const u8,
    /// ParameterDescription body.
    params: []const u8,
    no_data,
    /// CommandComplete tag.
    complete: []const u8,
    ready,
};

// --- Lifecycle --- //

pub fn open(gpa: std.mem.Allocator, io: Io, config: *const uri.Config, tls_ctx: *TlsContext) !*Conn {
    // send SNI by default; std ties SNI to host checks, so retry without it where checks aren't wanted
    return openAttempt(gpa, io, config, tls_ctx, true) catch |err| switch (err) {
        error.CertificateHostMismatch => if (config.sslmode != .verify_full)
            openAttempt(gpa, io, config, tls_ctx, false)
        else
            err,
        else => err,
    };
}

fn openAttempt(gpa: std.mem.Allocator, io: Io, config: *const uri.Config, tls_ctx: *TlsContext, sni: bool) !*Conn {
    const stream = try connectTcp(io, config.host, config.port);
    errdefer stream.close(io);

    const buffers = try gpa.alloc(u8, buf_len * 4);
    errdefer gpa.free(buffers);

    const self = try gpa.create(Conn);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .stream_reader = stream.reader(io, buffers[0..buf_len]),
        .stream_writer = stream.writer(io, buffers[buf_len..][0..buf_len]),
        .buffers = buffers,
        .w = .init(gpa),
        .cache_cap = config.statement_cache_size,
        .scratch = .init(gpa),
    };
    errdefer {
        self.msg_buf.deinit(gpa);
        self.w.deinit();
        self.scratch.deinit();
    }

    if (config.sslmode != .disable) try self.negotiateTls(config, tls_ctx, sni);
    try self.startup(config);
    return self;
}

pub fn close(self: *Conn) void {
    if (!self.broken) {
        self.w.reset();
        if (self.w.terminate()) |_| self.flushOut() catch {} else |_| {}
    }
    self.stream.close(self.io);
    self.clearCache();
    self.cache.deinit(self.gpa);
    self.key_buf.deinit(self.gpa);
    self.dropPending();
    self.result_formats.deinit(self.gpa);
    self.scratch.deinit();
    self.msg_buf.deinit(self.gpa);
    self.w.deinit();
    self.gpa.free(self.buffers);
    self.gpa.destroy(self);
}

fn connectTcp(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream });
    } else |_| {
        const name = try Io.net.HostName.init(host);
        return name.connect(io, port, .{ .mode = .stream });
    }
}

fn negotiateTls(self: *Conn, config: *const uri.Config, tls_ctx: *TlsContext, sni: bool) !void {
    const sr = &self.stream_reader.interface;
    const sw = &self.stream_writer.interface;
    sw.writeAll(&protocol.ssl_request) catch return self.writeFailed();
    sw.flush() catch return self.writeFailed();

    switch (sr.takeByte() catch return self.readFailed()) {
        'S' => {
            // bytes before the handshake would be injected plaintext (CVE-2021-23214)
            if (sr.bufferedLen() != 0) return error.ProtocolViolation;
        },
        'N' => {
            if (config.sslmode.requiresTls()) return error.TlsUnavailable;
            return;
        },
        else => return error.ProtocolViolation,
    }

    const verify_chain = config.sslmode == .verify_ca or config.sslmode == .verify_full;
    if (verify_chain) try tls_ctx.ensureLoaded(self.io);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    self.io.random(&entropy);
    const tls_read = self.buffers[buf_len * 2 ..][0..buf_len];
    const tls_write = self.buffers[buf_len * 3 ..][0..buf_len];
    self.tls_client = tls.Client.init(sr, sw, .{
        .host = if (sni and !isIpLiteral(config.host)) .{ .explicit = config.host } else .no_verification,
        .ca = if (verify_chain) .{ .bundle = .{
            .gpa = tls_ctx.gpa,
            .io = self.io,
            .lock = &tls_ctx.lock,
            .bundle = &tls_ctx.bundle,
        } } else .no_verification,
        .read_buffer = tls_read,
        .write_buffer = tls_write,
        .entropy = &entropy,
        .realtime_now = Io.Clock.real.now(self.io),
    }) catch |err| switch (err) {
        error.WriteFailed => return self.writeFailed(),
        error.ReadFailed => return self.readFailed(),
        else => |e| return e,
    };
}

fn isIpLiteral(host: []const u8) bool {
    _ = Io.net.IpAddress.parse(host, 0) catch return false;
    return true;
}

fn startup(self: *Conn, config: *const uri.Config) !void {
    self.w.reset();
    try self.w.startup(&.{
        .{ "user", config.user },
        .{ "database", config.database },
        .{ "client_encoding", "UTF8" },
        .{ "application_name", config.application_name },
        .{ "default_transaction_read_only", if (config.readonly) "on" else "off" },
    });
    try self.flushOut();

    var scram: ?auth.Scram = null;
    while (true) {
        const msg = try self.readMessage();
        switch (msg.tag) {
            'R' => try self.handleAuth(config, &scram, try protocol.Auth.decode(msg.body)),
            'E' => {
                const err = self.serverError(msg.body);
                self.broken = true;
                return if (err == error.InvalidQuery or err == error.QueryFailed) error.OpenFailed else err;
            },
            'S', 'K', 'N', 'v' => {},
            'Z' => {
                if (msg.body.len > 0) self.tx_status = msg.body[0];
                return;
            },
            else => return self.protocolViolation(),
        }
    }
}

fn handleAuth(self: *Conn, config: *const uri.Config, scram: *?auth.Scram, req: protocol.Auth) !void {
    const password = config.password orelse "";
    self.w.reset();
    switch (req) {
        .ok => return,
        .cleartext => try self.w.password(password),
        .md5 => |salt| try self.w.password(&auth.md5Password(config.user, password, salt)),
        .sasl => |mechanisms| {
            if (!protocol.Auth.offersMechanism(mechanisms, "SCRAM-SHA-256")) return error.UnsupportedAuthentication;
            var nonce_buf: [24]u8 = undefined;
            scram.* = try auth.Scram.init("*", auth.Scram.randomNonce(self.io, &nonce_buf));
            var first_buf: [256]u8 = undefined;
            try self.w.saslInitial("SCRAM-SHA-256", try scram.*.?.clientFirst(&first_buf));
        },
        .sasl_continue => |server_first| {
            const s = if (scram.*) |*s| s else return self.protocolViolation();
            const final = try s.clientFinal(self.gpa, password, server_first);
            defer {
                std.crypto.secureZero(u8, final);
                self.gpa.free(final);
            }
            try self.w.saslResponse(final);
        },
        .sasl_final => |server_final| {
            const s = if (scram.*) |*s| s else return self.protocolViolation();
            try s.verifyServerFinal(server_final);
            return;
        },
        .unsupported => |code| {
            log.err("unsupported authentication method {d}", .{code});
            return error.UnsupportedAuthentication;
        },
    }
    try self.flushOut();
}

// --- I/O --- //

fn input(self: *Conn) *Io.Reader {
    return if (self.tls_client) |*c| &c.reader else &self.stream_reader.interface;
}

fn flushOut(self: *Conn) !void {
    defer self.w.reset();
    if (self.tls_client) |*c| {
        c.writer.writeAll(self.w.bytes()) catch return self.writeFailed();
        c.writer.flush() catch return self.writeFailed();
    } else {
        self.stream_writer.interface.writeAll(self.w.bytes()) catch return self.writeFailed();
    }
    self.stream_writer.interface.flush() catch return self.writeFailed();
}

fn readMessage(self: *Conn) !protocol.Raw {
    return protocol.readRaw(self.input(), self.gpa, &self.msg_buf) catch |err| switch (err) {
        error.ReadFailed, error.EndOfStream => self.readFailed(),
        error.ProtocolViolation => self.protocolViolation(),
        else => |e| {
            self.broken = true;
            return e;
        },
    };
}

fn readFailed(self: *Conn) anyerror {
    self.broken = true;
    if (self.stream_reader.err) |e| if (e == error.Canceled) return error.Canceled;
    return error.Closed;
}

fn writeFailed(self: *Conn) anyerror {
    self.broken = true;
    if (self.stream_writer.err) |e| if (e == error.Canceled) return error.Canceled;
    return error.Closed;
}

fn protocolViolation(self: *Conn) anyerror {
    self.broken = true;
    return error.ProtocolViolation;
}

pub const LastError = struct {
    offset: ?usize,
    len: usize,
    buf: [512]u8,

    fn init(msg: []const u8, offset: ?usize) LastError {
        var e: LastError = .{ .offset = offset, .len = @min(msg.len, 512), .buf = undefined };
        @memcpy(e.buf[0..e.len], msg[0..e.len]);
        return e;
    }

    pub fn message(self: *const LastError) []const u8 {
        return self.buf[0..self.len];
    }
};

fn serverError(self: *Conn, body: []const u8) anyerror {
    const fields = protocol.ErrorFields.decode(body) catch return self.protocolViolation();
    log.debug("{s} {s}: {s}{s}{s}", .{
        fields.severity,
        fields.code,
        fields.message,
        if (fields.detail.len > 0) " - " else "",
        fields.detail,
    });
    const err = self.classify(fields);
    const position = std.fmt.parseInt(usize, fields.position, 10) catch 0;
    // a stale statement is retried transparently; it's not the caller's error
    if (err != error.StaleStatement) self.last_error = .init(fields.message, if (position > 0) position - 1 else null);
    return err;
}

// Map an ErrorResponse onto the error names shared with the SQLite backend.
fn classify(self: *Conn, fields: protocol.ErrorFields) anyerror {
    const code = fields.code;
    // statement gone (e.g. DEALLOCATE ALL), or its result type changed after DDL
    if (self.batch_hit and (std.mem.eql(u8, code, "26000") or
        (std.mem.eql(u8, code, "0A000") and std.mem.eql(u8, fields.routine, "RevalidateCachedQuery"))))
    {
        self.invalidate_cache = true;
        return error.StaleStatement;
    }
    if (std.mem.eql(u8, code, "23505")) return error.ConstraintUnique;
    if (std.mem.eql(u8, code, "23503")) return error.ConstraintForeignKey;
    if (std.mem.eql(u8, code, "23502")) return error.ConstraintNotNull;
    if (std.mem.eql(u8, code, "23514")) return error.ConstraintCheck;
    if (std.mem.startsWith(u8, code, "23")) return error.Constraint;
    if (std.mem.eql(u8, code, "40001") or std.mem.eql(u8, code, "40P01") or std.mem.eql(u8, code, "55P03"))
        return error.Busy;
    if (std.mem.startsWith(u8, code, "42")) return error.InvalidQuery;
    if (std.mem.startsWith(u8, code, "28")) {
        log.err("authentication failed: {s}", .{fields.message});
        return error.OpenFailed;
    }
    if (std.mem.startsWith(u8, code, "08") or std.mem.startsWith(u8, code, "57P")) {
        self.broken = true;
        return error.Closed;
    }
    return error.QueryFailed;
}

// --- Queries --- //

/// Parse/Bind/(Describe)/Execute/Sync in one round trip; read results with `next`.
/// Arena for per-query data; valid until the next reset.
pub fn resetScratch(self: *Conn) std.mem.Allocator {
    _ = self.scratch.reset(.retain_capacity);
    return self.scratch.allocator();
}

/// Parse/Bind/Describe/Execute/Sync in one round trip. A cached statement skips Parse and Describe;
/// its columns are then in `batch_columns` instead of a `.columns` event.
pub fn sendExtended(self: *Conn, sql: []const u8, oids: []const u32, params: []const protocol.Param) !void {
    if (self.broken) return error.Closed;
    self.w.reset();
    self.batch_hit = false;
    self.batch_columns = null;
    var name_buf: [16]u8 = undefined;
    var name: []const u8 = "";
    if (self.cache_cap > 0) {
        const key = try self.cacheKey(sql, oids);
        self.cache_clock += 1;
        if (self.cache.getPtr(key)) |entry| {
            entry.used = self.cache_clock;
            name = stmtName(&name_buf, entry.id);
            self.batch_hit = true;
            self.batch_columns = entry.columns;
        } else {
            if (self.cache.count() >= self.cache_cap) try self.evictOldest();
            const id = self.next_stmt_id;
            self.next_stmt_id +%= 1;
            name = stmtName(&name_buf, id);
            try self.w.parse(name, sql, oids);
            self.dropPending();
            self.pending_stmt = .{ .key = try self.gpa.dupe(u8, key), .id = id };
        }
    } else {
        try self.w.parse("", sql, oids);
    }
    self.result_formats.clearRetainingCapacity();
    if (self.batch_columns) |cols| for (cols) |col| {
        try self.result_formats.append(self.gpa, @intFromBool(types.binaryResult(col.type_oid)));
    };
    try self.w.bind("", name, params, self.result_formats.items);
    if (!self.batch_hit) try self.w.describe('P', "");
    try self.w.execute("", 0);
    try self.w.sync();
    try self.flushOut();
}

/// Parse/Describe(statement)/Sync; yields `.params`, then `.columns` or `.no_data`.
pub fn sendDescribe(self: *Conn, sql: []const u8) !void {
    if (self.broken) return error.Closed;
    self.w.reset();
    self.batch_hit = false;
    self.batch_columns = null;
    try self.w.parse("", sql, &.{});
    try self.w.describe('S', "");
    try self.w.sync();
    try self.flushOut();
}

/// Next result event. Payload slices are valid until the following call.
/// A server error is reported once the command reaches ReadyForQuery, so the connection stays in sync.
pub fn next(self: *Conn) !Event {
    while (true) {
        const msg = try self.readMessage();
        switch (msg.tag) {
            'T' => {
                if (self.pending_stmt) |*p| if (p.columns == null) {
                    p.columns = try self.copyColumns(msg.body);
                };
                return .{ .columns = msg.body };
            },
            'D' => return .{ .row = msg.body },
            't' => return .{ .params = msg.body },
            'n' => {
                if (self.pending_stmt) |*p| if (p.columns == null) {
                    p.columns = &.{};
                };
                return .no_data;
            },
            'C' => {
                var c: protocol.Cursor = .{ .data = msg.body };
                return .{ .complete = c.cstr() catch return self.protocolViolation() };
            },
            'Z' => {
                if (msg.body.len > 0) self.tx_status = msg.body[0];
                if (self.invalidate_cache) {
                    self.invalidate_cache = false;
                    self.clearCache();
                }
                if (self.pending_error) |err| {
                    self.pending_error = null;
                    self.dropPending();
                    return err;
                }
                try self.commitPending();
                return .ready;
            },
            'E' => {
                const err = self.serverError(msg.body);
                if (self.broken) return err;
                if (self.pending_error == null) self.pending_error = err;
            },
            // ParseComplete, BindComplete, CloseComplete, EmptyQuery, PortalSuspended, notices, status, notifications
            '1', '2', '3', 'I', 's', 'N', 'S', 'A', 'K' => {},
            else => return self.protocolViolation(),
        }
    }
}

/// Read until ReadyForQuery, discarding results; returns the command's error if any.
pub fn drain(self: *Conn) !void {
    while (true) {
        if (try self.next() == .ready) return;
    }
}

/// Like `drain` but swallows errors; used when abandoning a result early.
/// A server error is only reported at ReadyForQuery, so any error means we're done.
pub fn discard(self: *Conn) void {
    while (true) {
        const event = self.next() catch return;
        if (event == .ready) return;
    }
}

/// Simple-protocol query (may hold several statements); returns the last command's row count.
pub fn simpleQuery(self: *Conn, sql: []const u8) !u64 {
    if (self.broken) return error.Closed;
    self.w.reset();
    self.batch_hit = false;
    try self.w.query(sql);
    try self.flushOut();
    var rows: u64 = 0;
    while (true) switch (try self.next()) {
        .complete => |tag| rows = protocol.commandRows(tag),
        .ready => return rows,
        else => {},
    };
}

// --- Statement cache --- //

fn stmtName(buf: *[16]u8, id: u32) []const u8 {
    return std.mem.print(buf, "zx_{d}", .{id}) catch unreachable;
}

/// Key = param count, param OIDs, SQL; built in a reused buffer.
fn cacheKey(self: *Conn, sql: []const u8, oids: []const u32) ![]const u8 {
    self.key_buf.clearRetainingCapacity();
    try self.key_buf.appendSlice(self.gpa, std.mem.asBytes(&@as(u32, @intCast(oids.len))));
    try self.key_buf.appendSlice(self.gpa, std.mem.sliceAsBytes(oids));
    try self.key_buf.appendSlice(self.gpa, sql);
    return self.key_buf.items;
}

fn evictOldest(self: *Conn) !void {
    var oldest: ?[]const u8 = null;
    var oldest_entry: CacheEntry = undefined;
    var it = self.cache.iterator();
    while (it.next()) |kv| {
        if (oldest == null or kv.value_ptr.used < oldest_entry.used) {
            oldest = kv.key_ptr.*;
            oldest_entry = kv.value_ptr.*;
        }
    }
    const key = oldest orelse return;
    var name_buf: [16]u8 = undefined;
    // sent ahead of this batch's Parse; the server runs it before any later error
    try self.w.close('S', stmtName(&name_buf, oldest_entry.id));
    _ = self.cache.remove(key);
    self.gpa.free(key);
    self.freeColumns(oldest_entry.columns);
}

fn commitPending(self: *Conn) !void {
    const pending = self.pending_stmt orelse return;
    self.pending_stmt = null;
    const columns = pending.columns orelse {
        // no RowDescription/NoData seen; don't cache what we can't describe
        self.gpa.free(pending.key);
        return;
    };
    errdefer {
        self.gpa.free(pending.key);
        self.freeColumns(columns);
    }
    try self.cache.put(self.gpa, pending.key, .{ .id = pending.id, .used = self.cache_clock, .columns = columns });
}

fn dropPending(self: *Conn) void {
    if (self.pending_stmt) |p| {
        self.gpa.free(p.key);
        if (p.columns) |c| self.freeColumns(c);
    }
    self.pending_stmt = null;
}

fn copyColumns(self: *Conn, body: []const u8) ![]protocol.Column {
    var desc = try protocol.RowDescription.init(body);
    const cols = try self.gpa.alloc(protocol.Column, desc.count);
    var filled: usize = 0;
    errdefer {
        for (cols[0..filled]) |col| self.gpa.free(col.name);
        self.gpa.free(cols);
    }
    for (cols) |*col| {
        const c = try desc.next();
        col.* = .{ .name = try self.gpa.dupe(u8, c.name), .type_oid = c.type_oid };
        filled += 1;
    }
    return cols;
}

fn freeColumns(self: *Conn, cols: []const protocol.Column) void {
    for (cols) |col| self.gpa.free(col.name);
    self.gpa.free(cols);
}

/// Forget every cached statement. Server-side copies that still exist are harmless
/// because names are never reused on a connection.
fn clearCache(self: *Conn) void {
    var it = self.cache.iterator();
    while (it.next()) |kv| {
        self.gpa.free(kv.key_ptr.*);
        self.freeColumns(kv.value_ptr.columns);
    }
    self.cache.clearRetainingCapacity();
    self.batch_columns = null;
}
