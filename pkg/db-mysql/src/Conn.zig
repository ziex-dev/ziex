// One MySQL server connection over std.Io (plain TCP or std.crypto.tls).
const Conn = @This();

const std = @import("std");
const Io = std.Io;
const tls = std.crypto.tls;
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const uri = @import("uri.zig");

const log = std.log.scoped(.mysql);
const buf_len = tls.Client.min_buffer_len;
const max_columns = 4096;

gpa: std.mem.Allocator,
io: Io,
stream: Io.net.Stream,
stream_reader: Io.net.Stream.Reader,
stream_writer: Io.net.Stream.Writer,
tls_client: ?tls.Client = null,
buffers: []u8,
msg_buf: std.ArrayList(u8) = .empty,
w: protocol.Writer,
/// Sequence id expected on the next packet read (and used for the next handshake write).
seq: u8 = 0,
/// Negotiated client capabilities.
caps: u32 = 0,
/// Server status flags from the last OK/EOF packet; see `inTransaction`.
status: u16 = 0,
broken: bool = false,
// Last ERR packet, handed to the caller's `Db.Diagnostics` on release
last_error: ?LastError = null,
state: State = .idle,
/// Rows of the current result set use the binary protocol (prepared statements).
binary: bool = false,

// Prepared statements keyed by SQL; LRU-evicted at `cache_cap`.
cache: std.StringHashMapUnmanaged(Stmt) = .empty,
cache_cap: usize = 0,
cache_clock: u64 = 0,
/// With no cache, the statement prepared for the in-flight execution; closed when it ends.
ephemeral: ?Stmt = null,
/// The in-flight execution bound a cached statement.
batch_hit: bool = false,
/// Per-query scratch memory for callers holding this connection; reset by `resetScratch`.
scratch: std.heap.ArenaAllocator,

const State = enum {
    idle,
    /// Command sent; the next packet is OK, ERR or a result set header.
    head,
    rows,
    /// Last OK/EOF seen; the next `next` call reports `.ready`.
    finishing,
};

pub const Stmt = struct {
    id: u32,
    param_count: u16,
    /// Owned by the connection's allocator.
    columns: []protocol.Column,
    used: u64 = 0,
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
    /// Result set header; names live in the connection's scratch arena.
    columns: []const protocol.Column,
    /// Row packet body.
    row: []const u8,
    /// A statement finished: its OK packet, or the end of its rows.
    complete: protocol.Ok,
    /// Every result of the command has been read.
    ready,
};

// --- Lifecycle --- //

pub fn open(gpa: std.mem.Allocator, io: Io, config: *const uri.Config, tls_ctx: *TlsContext) !*Conn {
    // send SNI by default; std ties SNI to host checks, so retry without it where checks aren't wanted.
    // sslmode=prefer: MySQL often asks for a client certificate during TLS 1.3; std.crypto.tls does
    // not answer CertificateRequest, so fall back to a fresh plaintext connection.
    return openAttempt(gpa, io, config, tls_ctx, .{ .sni = true, .allow_tls = true }) catch |err| switch (err) {
        error.CertificateHostMismatch => if (config.sslmode != .verify_full)
            openAttempt(gpa, io, config, tls_ctx, .{ .sni = false, .allow_tls = true })
        else
            err,
        error.TlsOptionalUnavailable => openAttempt(gpa, io, config, tls_ctx, .{ .sni = true, .allow_tls = false }),
        else => err,
    };
}

const OpenFlags = struct { sni: bool, allow_tls: bool };

fn openAttempt(gpa: std.mem.Allocator, io: Io, config: *const uri.Config, tls_ctx: *TlsContext, flags: OpenFlags) !*Conn {
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

    try self.startup(config, tls_ctx, flags);
    return self;
}

pub fn close(self: *Conn) void {
    if (!self.broken) {
        self.w.reset();
        if (self.w.command(.quit, "")) |_| self.flushOut() catch {} else |_| {}
    }
    self.stream.close(self.io);
    self.clearCache(false);
    self.cache.deinit(self.gpa);
    if (self.ephemeral) |s| self.freeColumns(s.columns);
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
    // the server speaks only after our ClientHello; anything buffered would be injected plaintext
    if (sr.bufferedLen() != 0) return error.ProtocolViolation;

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
        // MySQL commonly sends CertificateRequest; std has no answer for that yet.
        else => |e| if (config.sslmode == .prefer) return error.TlsOptionalUnavailable else return e,
    };
}

fn isIpLiteral(host: []const u8) bool {
    _ = Io.net.IpAddress.parse(host, 0) catch return false;
    return true;
}

// --- Handshake --- //

fn startup(self: *Conn, config: *const uri.Config, tls_ctx: *TlsContext, flags: OpenFlags) !void {
    self.seq = 0;
    const first = try self.readPacket();
    if (first[0] == 0xff) return self.startupError(first);
    const hs = protocol.decodeHandshake(first) catch return self.protocolViolation();
    log.debug("server {s}, auth plugin {s}", .{ hs.server_version, hs.plugin });
    // the handshake borrows the read buffer; take what's needed before reading again
    var plugin = auth.Plugin.fromName(hs.plugin) orelse .mysql_native_password;
    var nonce = hs.nonce;
    const server_caps = hs.capabilities;
    if (server_caps & protocol.Cap.protocol_41 == 0) return error.UnsupportedProtocol;

    const Cap = protocol.Cap;
    var caps: u32 = Cap.long_password | Cap.found_rows | Cap.long_flag | Cap.protocol_41 | Cap.transactions |
        Cap.secure_connection | Cap.multi_statements | Cap.multi_results | Cap.ps_multi_results |
        Cap.plugin_auth | Cap.plugin_auth_lenenc_client_data | Cap.deprecate_eof;
    if (config.database != null) caps |= Cap.connect_with_db;
    caps &= server_caps;

    const use_tls = flags.allow_tls and config.sslmode != .disable and server_caps & Cap.ssl != 0;
    if (!use_tls and config.sslmode.requiresTls()) return error.TlsUnavailable;
    if (use_tls) {
        caps |= Cap.ssl;
        self.w.reset();
        try self.w.sslRequest(&self.seq, caps, protocol.Charset.utf8mb4_general_ci);
        try self.flushOut();
        try self.negotiateTls(config, tls_ctx, flags.sni);
    }
    self.caps = caps;

    const password = config.password orelse "";
    var response_buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_buf);
    const response = try auth.initialResponse(&response_buf, plugin, password, &nonce, use_tls);
    self.w.reset();
    try self.w.handshakeResponse(&self.seq, .{
        .caps = caps,
        .user = config.user,
        .auth_response = response,
        .database = config.database,
        .plugin = plugin.name(),
    });
    try self.flushOut();

    while (true) {
        const body = try self.readPacket();
        switch (body[0]) {
            0x00 => {
                const ok = protocol.decodeOk(body) catch return self.protocolViolation();
                self.status = ok.status;
                break;
            },
            0xff => return self.startupError(body),
            // AuthSwitchRequest: plugin name, then its scramble
            0xfe => {
                if (body.len == 1) return error.UnsupportedAuthentication;
                var c: protocol.Cursor = .{ .data = body[1..] };
                const name = c.cstr() catch return self.protocolViolation();
                const data = std.mem.trimEnd(u8, c.rest(), &.{0});
                plugin = auth.Plugin.fromName(name) orelse {
                    log.err("unsupported authentication plugin {s}", .{name});
                    return error.UnsupportedAuthentication;
                };
                if (data.len < nonce.len) return self.protocolViolation();
                @memcpy(&nonce, data[0..nonce.len]);
                const next_response = try auth.initialResponse(&response_buf, plugin, password, &nonce, use_tls);
                self.w.reset();
                try self.w.packet(&self.seq, next_response);
                try self.flushOut();
            },
            0x01 => try self.authMoreData(config, plugin, &nonce, password, use_tls, body[1..]),
            else => return self.protocolViolation(),
        }
    }

    if (config.readonly) _ = try self.query("SET SESSION TRANSACTION READ ONLY");
}

fn authMoreData(self: *Conn, config: *const uri.Config, plugin: auth.Plugin, nonce: *const [20]u8, password: []const u8, tls_on: bool, data: []const u8) !void {
    switch (plugin) {
        .caching_sha2_password => {
            // fast auth succeeded; the OK packet follows
            if (data.len == 1 and data[0] == 3) return;
            if (data.len != 1 or data[0] != 4) return self.protocolViolation();
            if (tls_on) return self.sendCleartext(password);
            try self.requestPublicKey(config, 2, password, nonce);
        },
        .sha256_password => try self.sendEncrypted(data, password, nonce),
        .mysql_native_password => return self.protocolViolation(),
    }
}

fn sendCleartext(self: *Conn, password: []const u8) !void {
    self.w.reset();
    try self.w.begin();
    try self.w.raw(password);
    try self.w.int1(0);
    try self.w.end(&self.seq);
    try self.flushSecret();
}

fn requestPublicKey(self: *Conn, config: *const uri.Config, request: u8, password: []const u8, nonce: *const [20]u8) !void {
    if (!config.allow_public_key_retrieval) return error.PublicKeyRetrievalNotAllowed;
    self.w.reset();
    try self.w.packet(&self.seq, &.{request});
    try self.flushOut();
    const body = try self.readPacket();
    if (body[0] == 0xff) return self.startupError(body);
    if (body[0] != 0x01) return self.protocolViolation();
    try self.sendEncrypted(body[1..], password, nonce);
}

fn sendEncrypted(self: *Conn, pem: []const u8, password: []const u8, nonce: *const [20]u8) !void {
    var seed: [20]u8 = undefined;
    self.io.random(&seed);
    var out: [auth.max_rsa_bytes]u8 = undefined;
    const cipher = try auth.encryptPassword(&out, pem, password, nonce, seed);
    self.w.reset();
    try self.w.packet(&self.seq, cipher);
    try self.flushOut();
}

fn startupError(self: *Conn, body: []const u8) anyerror {
    self.broken = true;
    const err = protocol.decodeErr(body) catch return self.protocolViolation();
    log.err("connection rejected ({d}): {s}", .{ err.code, err.message });
    return error.OpenFailed;
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

/// Like `flushOut` for packets carrying a password; the buffer is wiped.
fn flushSecret(self: *Conn) !void {
    defer std.crypto.secureZero(u8, self.w.buf.items);
    return self.flushOut();
}

/// Next packet body, valid until the following read; never empty.
fn readPacket(self: *Conn) ![]const u8 {
    const body = protocol.readPacket(self.input(), self.gpa, &self.msg_buf, &self.seq) catch |err| switch (err) {
        error.ReadFailed, error.EndOfStream => return self.readFailed(),
        error.ProtocolViolation => return self.protocolViolation(),
        else => |e| {
            self.broken = true;
            return e;
        },
    };
    if (body.len == 0) return self.protocolViolation();
    return body;
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

// --- Errors --- //

/// Map a server error onto the error names shared with the other backends.
pub fn classify(code: u16, sqlstate: []const u8) anyerror {
    return switch (code) {
        1062, 1586 => error.ConstraintUnique,
        1451, 1452, 1216, 1217 => error.ConstraintForeignKey,
        1048, 1364, 1263 => error.ConstraintNotNull,
        3819, 4025 => error.ConstraintCheck,
        1205, 1213 => error.Busy,
        1044, 1045, 1049, 1130, 1251, 1698 => error.OpenFailed,
        1053, 1152, 1927, 2006, 2013 => error.Closed,
        1054, 1064, 1065, 1109, 1146, 1149, 1295 => error.InvalidQuery,
        else => if (std.mem.startsWith(u8, sqlstate, "23"))
            error.Constraint
        else if (std.mem.startsWith(u8, sqlstate, "42"))
            error.InvalidQuery
        else
            error.QueryFailed,
    };
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

/// ERR packet in command phase: the command is over and the connection stays in sync.
fn serverError(self: *Conn, body: []const u8) anyerror {
    const err = protocol.decodeErr(body) catch return self.protocolViolation();
    log.debug("{d} {s}: {s}", .{ err.code, err.sqlstate, err.message });
    self.setIdle();
    // statement gone (e.g. server restart behind a proxy) or needing a re-prepare
    if (self.batch_hit and (err.code == 1243 or err.code == 1615)) return error.StaleStatement;
    const mapped = classify(err.code, err.sqlstate);
    if (mapped == error.Closed) self.broken = true;
    // MySQL reports no position; the message usually quotes the offending text
    self.last_error = .init(err.message, null);
    return mapped;
}

// --- Commands --- //

pub fn inTransaction(self: *const Conn) bool {
    return self.status & protocol.Status.in_trans != 0;
}

/// Arena for per-query data; valid until the next reset.
pub fn resetScratch(self: *Conn) std.mem.Allocator {
    _ = self.scratch.reset(.retain_capacity);
    return self.scratch.allocator();
}

/// COM_QUERY (text protocol; may hold several statements); read results with `next`.
pub fn sendQuery(self: *Conn, sql: []const u8) !void {
    if (self.broken) return error.Closed;
    self.batch_hit = false;
    self.binary = false;
    self.w.reset();
    const next_seq = try self.w.command(.query, sql);
    try self.flushOut();
    self.seq = next_seq;
    self.state = .head;
}

/// Prepare `sql` if it isn't cached, then COM_STMT_EXECUTE; read results with `next`.
pub fn sendExecute(self: *Conn, sql: []const u8, params: []const protocol.Param) !void {
    if (self.broken) return error.Closed;
    self.binary = true;
    const stmt = try self.getStmt(sql);
    if (stmt.param_count != params.len) {
        self.closeEphemeral();
        return error.InvalidBindings;
    }
    self.w.reset();
    const next_seq = self.w.stmtExecute(stmt.id, params) catch |err| {
        self.closeEphemeral();
        return err;
    };
    try self.flushOut();
    self.seq = next_seq;
    self.state = .head;
}

/// Run `sql` as text, discarding rows; returns the last statement's OK.
pub fn query(self: *Conn, sql: []const u8) !protocol.Ok {
    try self.sendQuery(sql);
    var last: protocol.Ok = .{};
    while (true) switch (try self.next()) {
        .complete => |ok| last = ok,
        .ready => return last,
        else => {},
    };
}

/// Next result event. Payload slices are valid until the following call.
/// A server error ends the command, leaving the connection ready for the next one.
pub fn next(self: *Conn) !Event {
    switch (self.state) {
        .idle => return .ready,
        .finishing => {
            self.setIdle();
            return .ready;
        },
        .head => {
            const body = try self.readPacket();
            switch (body[0]) {
                0x00 => return self.finishResult(protocol.decodeOk(body) catch return self.protocolViolation()),
                0xff => return self.serverError(body),
                // LOCAL INFILE was not negotiated
                0xfb => return self.protocolViolation(),
                else => {
                    var c: protocol.Cursor = .{ .data = body };
                    const count = c.lenenc() catch return self.protocolViolation();
                    if (count == 0 or count > max_columns or !c.atEnd()) return self.protocolViolation();
                    return .{ .columns = try self.readColumns(@intCast(count)) };
                },
            }
        },
        .rows => {
            const body = try self.readPacket();
            if (body[0] == 0xfe and body.len < protocol.max_payload) {
                const done = if (self.caps & protocol.Cap.deprecate_eof != 0) protocol.decodeOk(body) else protocol.decodeEof(body);
                return self.finishResult(done catch return self.protocolViolation());
            }
            if (body[0] == 0xff) return self.serverError(body);
            return .{ .row = body };
        },
    }
}

fn finishResult(self: *Conn, ok: protocol.Ok) Event {
    self.status = ok.status;
    self.state = if (ok.status & protocol.Status.more_results != 0) .head else .finishing;
    return .{ .complete = ok };
}

fn readColumns(self: *Conn, count: usize) ![]const protocol.Column {
    const arena = self.scratch.allocator();
    const cols = try arena.alloc(protocol.Column, count);
    for (cols) |*col| {
        const body = try self.readPacket();
        if (body[0] == 0xff) return self.serverError(body);
        col.* = protocol.decodeColumn(body) catch return self.protocolViolation();
        col.name = try arena.dupe(u8, col.name);
    }
    if (self.caps & protocol.Cap.deprecate_eof == 0) try self.expectEof();
    self.state = .rows;
    return cols;
}

fn expectEof(self: *Conn) !void {
    const body = try self.readPacket();
    if (body[0] != 0xfe) return self.protocolViolation();
}

/// Read to the end of the command, discarding results; returns the command's error if any.
pub fn drain(self: *Conn) !void {
    while (true) {
        if (try self.next() == .ready) return;
    }
}

/// Like `drain` but swallows errors; used when abandoning a result early.
/// An error ends the command, so any error means we're done.
pub fn discard(self: *Conn) void {
    while (true) {
        const event = self.next() catch return;
        if (event == .ready) return;
    }
}

fn setIdle(self: *Conn) void {
    self.state = .idle;
    self.closeEphemeral();
}

// --- Prepared statements --- //

/// Cached statement for `sql`, preparing it if needed. The pointer is valid until the next
/// cache change. Sets `batch_hit`.
pub fn getStmt(self: *Conn, sql: []const u8) !*Stmt {
    self.batch_hit = false;
    if (self.cache_cap > 0) {
        self.cache_clock += 1;
        if (self.cache.getPtr(sql)) |stmt| {
            stmt.used = self.cache_clock;
            self.batch_hit = true;
            return stmt;
        }
    }

    var stmt = try self.prepare(sql);
    errdefer {
        self.sendClose(stmt.id);
        self.freeColumns(stmt.columns);
    }
    if (self.cache_cap == 0) {
        self.closeEphemeral();
        self.ephemeral = stmt;
        return &self.ephemeral.?;
    }
    if (self.cache.count() >= self.cache_cap) self.evictOldest();
    stmt.used = self.cache_clock;
    const key = try self.gpa.dupe(u8, sql);
    errdefer self.gpa.free(key);
    const slot = try self.cache.getOrPut(self.gpa, key);
    slot.value_ptr.* = stmt;
    return slot.value_ptr;
}

/// COM_STMT_PREPARE round trip.
fn prepare(self: *Conn, sql: []const u8) !Stmt {
    self.w.reset();
    self.seq = try self.w.command(.stmt_prepare, sql);
    try self.flushOut();

    const body = try self.readPacket();
    if (body[0] == 0xff) return self.serverError(body);
    if (body[0] != 0x00) return self.protocolViolation();
    const ok = protocol.decodePrepareOk(body) catch return self.protocolViolation();
    // unread packets would desync the connection
    errdefer self.broken = true;

    const deprecate_eof = self.caps & protocol.Cap.deprecate_eof != 0;
    for (0..ok.num_params) |_| _ = try self.readPacket();
    if (ok.num_params > 0 and !deprecate_eof) try self.expectEof();

    const cols = try self.gpa.alloc(protocol.Column, ok.num_columns);
    var filled: usize = 0;
    errdefer {
        for (cols[0..filled]) |col| self.gpa.free(col.name);
        self.gpa.free(cols);
    }
    for (cols) |*col| {
        col.* = protocol.decodeColumn(try self.readPacket()) catch return self.protocolViolation();
        col.name = try self.gpa.dupe(u8, col.name);
        filled += 1;
    }
    if (ok.num_columns > 0 and !deprecate_eof) try self.expectEof();
    return .{ .id = ok.stmt_id, .param_count = ok.num_params, .columns = cols };
}

/// COM_STMT_CLOSE has no reply.
fn sendClose(self: *Conn, id: u32) void {
    if (self.broken) return;
    self.w.reset();
    if (self.w.stmtClose(id)) |_| self.flushOut() catch {} else |_| {}
}

pub fn closeEphemeral(self: *Conn) void {
    const stmt = self.ephemeral orelse return;
    self.ephemeral = null;
    self.sendClose(stmt.id);
    self.freeColumns(stmt.columns);
}

fn evictOldest(self: *Conn) void {
    var oldest: ?[]const u8 = null;
    var oldest_used: u64 = 0;
    var it = self.cache.iterator();
    while (it.next()) |kv| {
        if (oldest == null or kv.value_ptr.used < oldest_used) {
            oldest = kv.key_ptr.*;
            oldest_used = kv.value_ptr.used;
        }
    }
    const key = oldest orelse return;
    const stmt = self.cache.get(key).?;
    self.sendClose(stmt.id);
    _ = self.cache.remove(key);
    self.gpa.free(key);
    self.freeColumns(stmt.columns);
}

fn freeColumns(self: *Conn, cols: []const protocol.Column) void {
    for (cols) |col| self.gpa.free(col.name);
    self.gpa.free(cols);
}

/// Forget every cached statement, closing them on the server unless the connection is going away.
pub fn clearCache(self: *Conn, close_on_server: bool) void {
    var it = self.cache.iterator();
    while (it.next()) |kv| {
        if (close_on_server) self.sendClose(kv.value_ptr.id);
        self.gpa.free(kv.key_ptr.*);
        self.freeColumns(kv.value_ptr.columns);
    }
    self.cache.clearRetainingCapacity();
}

// --- Tests --- //

const t = std.testing;

test "server errors map onto shared error names" {
    try t.expectEqual(error.ConstraintUnique, classify(1062, "23000"));
    try t.expectEqual(error.ConstraintForeignKey, classify(1452, "23000"));
    try t.expectEqual(error.ConstraintForeignKey, classify(1451, "23000"));
    try t.expectEqual(error.ConstraintNotNull, classify(1048, "23000"));
    try t.expectEqual(error.ConstraintCheck, classify(3819, "HY000"));
    try t.expectEqual(error.Constraint, classify(9999, "23999"));
    try t.expectEqual(error.Busy, classify(1213, "40001"));
    try t.expectEqual(error.Busy, classify(1205, "HY000"));
    try t.expectEqual(error.InvalidQuery, classify(1064, "42000"));
    try t.expectEqual(error.InvalidQuery, classify(1146, "42S02"));
    try t.expectEqual(error.InvalidQuery, classify(9999, "42000"));
    try t.expectEqual(error.OpenFailed, classify(1045, "28000"));
    try t.expectEqual(error.Closed, classify(1053, "08S01"));
    try t.expectEqual(error.QueryFailed, classify(1105, "HY000"));
    try t.expectEqual(error.QueryFailed, classify(1105, ""));
}
