// SMTP (RFC 5321) with AUTH PLAIN / CRAM-MD5 and STARTTLS, shaped like Go's net/smtp.
const Smtp = @This();

const std = @import("std");
const builtin = @import("builtin");
const Email = @import("../Email.zig");
const Io = std.Io;
const tls = std.crypto.tls;

const is_wasm = builtin.cpu.arch.isWasm();
const buf_len = tls.Client.min_buffer_len;
const b64 = std.base64.standard;
const log = std.log.scoped(.zx_email);

io: Io,
host: []const u8 = "",
port: u16 = default_port,
username: ?[]const u8 = null,
password: ?[]const u8 = null,
tls_mode: Tls = .starttls,
local_name: []const u8 = "localhost",
// Skip host / CA checks. Prefer only for tests and local relays.
insecure: bool = false,

pub const default_port: u16 = 587;

pub const Env = enum {
    SMTP_HOST,
    SMTP_PORT,
    SMTP_USERNAME,
    SMTP_PASSWORD,
    SMTP_TLS,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const host = Env.SMTP_HOST;
    pub const port = Env.SMTP_PORT;
    pub const username = Env.SMTP_USERNAME;
    pub const password = Env.SMTP_PASSWORD;
    pub const tls = Env.SMTP_TLS;
};

pub const Tls = enum { none, starttls, tls };

pub fn email(s: *Smtp) Email {
    return .{ .userdata = s, .vtable = &.{ .send = &send } };
}

pub fn parseTls(name: []const u8) ?Tls {
    return std.meta.stringToEnum(Tls, name);
}

fn send(userdata: ?*anyopaque, gpa: std.mem.Allocator, m: Email.Message) Email.Error!Email.Sent {
    if (comptime is_wasm) return error.Unavailable;
    const s: *Smtp = @ptrCast(@alignCast(userdata));
    if (s.host.len == 0) return error.Unavailable;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try encodeMessage(arena, m);
    const rcpts = try recipients(arena, m);

    const auth: ?Auth = if (s.username) |user| .{
        .plain = .{
            .identity = "",
            .username = user,
            .password = s.password orelse "",
            .host = s.host,
        },
    } else null;

    try sendMail(gpa, s.io, .{
        .host = s.host,
        .port = s.port,
        .tls_mode = s.tls_mode,
        .local_name = s.local_name,
        .insecure = s.insecure,
        .auth = auth,
        .from = m.from.email,
        .to = rcpts,
        .msg = raw,
    });
    return .{};
}

// --- Go-shaped Client --- //

pub const Auth = union(enum) {
    plain: Plain,
    cram_md5: CramMd5,

    pub const Plain = struct {
        identity: []const u8 = "",
        username: []const u8,
        password: []const u8,
        host: []const u8,
    };

    pub const CramMd5 = struct {
        username: []const u8,
        secret: []const u8,
    };
};

pub const SendOptions = struct {
    host: []const u8,
    port: u16 = default_port,
    tls_mode: Tls = .starttls,
    local_name: []const u8 = "localhost",
    insecure: bool = false,
    auth: ?Auth = null,
    from: []const u8,
    to: []const []const u8,
    msg: []const u8,
};

// Dial, optional STARTTLS, optional AUTH, then MAIL/RCPT/DATA/QUIT.
pub fn sendMail(gpa: std.mem.Allocator, io: Io, opts: SendOptions) Email.Error!void {
    if (hasLineBreak(opts.from)) return error.InvalidAddress;
    for (opts.to) |a| if (hasLineBreak(a)) return error.InvalidAddress;

    var c = try Client.dial(gpa, io, opts.host, opts.port, .{
        .tls_mode = opts.tls_mode,
        .local_name = opts.local_name,
        .insecure = opts.insecure,
    });
    defer c.close();

    try c.hello();

    if (opts.tls_mode == .starttls) {
        if (!c.extension("STARTTLS")) return error.Unavailable;
        try c.startTls();
    }

    if (opts.auth) |a| {
        if (!c.extension("AUTH")) return error.Unauthorized;
        try c.auth(a);
    }

    try c.mail(opts.from);
    for (opts.to) |to| try c.rcpt(to);
    try c.data(opts.msg);
    try c.quit();
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    stream_reader: Io.net.Stream.Reader,
    stream_writer: Io.net.Stream.Writer,
    tls_client: ?tls.Client = null,
    buffers: []u8,
    server_name: []const u8,
    local_name: []const u8,
    insecure: bool,
    tls_on: bool = false,
    did_hello: bool = false,
    hello_err: ?Email.Error = null,
    // Uppercased extension name → params (empty string when none).
    ext: std.StringHashMapUnmanaged([]const u8) = .empty,
    auth_mechs: []const u8 = "",
    // Scratch for the last multiline reply; valid until the next response.
    last_msg: []u8 = &.{},

    pub const DialOptions = struct {
        tls_mode: Tls = .none,
        local_name: []const u8 = "localhost",
        insecure: bool = false,
    };

    pub fn dial(gpa: std.mem.Allocator, io: Io, host: []const u8, port: u16, opts: DialOptions) Email.Error!*Client {
        const stream = connectTcp(io, host, port) catch return error.NetworkError;
        errdefer stream.close(io);

        const c = open(gpa, io, stream, host, opts) catch |err| {
            stream.close(io);
            return err;
        };
        errdefer c.destroy();

        if (opts.tls_mode == .tls) try c.negotiateTls();
        try c.expect(220);
        return c;
    }

    // Own an already-connected stream; for `tls_mode == .tls` call `negotiateTls` then `expect(220)`.
    pub fn open(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream, host: []const u8, opts: DialOptions) Email.Error!*Client {
        const buffers = gpa.alloc(u8, buf_len * 4) catch return error.OutOfMemory;
        errdefer gpa.free(buffers);

        const server_name = gpa.dupe(u8, host) catch return error.OutOfMemory;
        errdefer gpa.free(server_name);
        const local_name = gpa.dupe(u8, opts.local_name) catch return error.OutOfMemory;
        errdefer gpa.free(local_name);

        const c = gpa.create(Client) catch return error.OutOfMemory;
        c.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .stream_reader = stream.reader(io, buffers[0..buf_len]),
            .stream_writer = stream.writer(io, buffers[buf_len..][0..buf_len]),
            .buffers = buffers,
            .server_name = server_name,
            .local_name = local_name,
            .insecure = opts.insecure,
            .tls_on = opts.tls_mode == .tls,
        };
        return c;
    }

    pub fn close(c: *Client) void {
        c.stream.close(c.io);
        c.destroy();
    }

    fn destroy(c: *Client) void {
        var it = c.ext.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            c.gpa.free(e.value_ptr.*);
        }
        c.ext.deinit(c.gpa);
        if (c.last_msg.len > 0) c.gpa.free(c.last_msg);
        c.gpa.free(c.server_name);
        c.gpa.free(c.local_name);
        c.gpa.free(c.buffers);
        c.gpa.destroy(c);
    }

    pub fn hello(c: *Client) Email.Error!void {
        if (c.did_hello) {
            if (c.hello_err) |e| return e;
            return;
        }
        c.did_hello = true;
        c.ehlo() catch {
            c.helo() catch |err| {
                c.hello_err = err;
                return err;
            };
        };
    }

    // Must be called before other commands when overriding the default local name.
    pub fn setLocalName(c: *Client, name: []const u8) Email.Error!void {
        if (hasLineBreak(name)) return error.InvalidMessage;
        if (c.did_hello) return error.InvalidMessage;
        const copy = c.gpa.dupe(u8, name) catch return error.OutOfMemory;
        c.gpa.free(c.local_name);
        c.local_name = copy;
    }

    pub fn startTls(c: *Client) Email.Error!void {
        try c.hello();
        try c.cmd(220, "STARTTLS");
        try c.negotiateTls();
        try c.ehlo();
    }

    pub fn auth(c: *Client, a: Auth) Email.Error!void {
        try c.hello();
        switch (a) {
            .plain => |p| try c.authPlain(p),
            .cram_md5 => |p| try c.authCramMd5(p),
        }
    }

    pub fn mail(c: *Client, from: []const u8) Email.Error!void {
        if (hasLineBreak(from)) return error.InvalidAddress;
        try c.hello();
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        fbs.print("MAIL FROM:<{s}>", .{from}) catch return error.InvalidAddress;
        if (c.ext.contains("8BITMIME")) fbs.writeAll(" BODY=8BITMIME") catch return error.InvalidAddress;
        if (c.ext.contains("SMTPUTF8")) fbs.writeAll(" SMTPUTF8") catch return error.InvalidAddress;
        try c.cmd(250, fbs.buffered());
    }

    pub fn rcpt(c: *Client, to: []const u8) Email.Error!void {
        if (hasLineBreak(to)) return error.InvalidAddress;
        var buf: [320]u8 = undefined;
        const line = std.mem.print(&buf, "RCPT TO:<{s}>", .{to}) catch return error.InvalidAddress;
        // 250 or 251
        try c.cmd(25, line);
    }

    pub fn data(c: *Client, msg: []const u8) Email.Error!void {
        try c.cmd(354, "DATA");
        try c.writeData(msg);
        try c.expect(250);
    }

    pub fn extension(c: *Client, name: []const u8) bool {
        c.hello() catch return false;
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return false;
        const key = std.ascii.upperString(&buf, name);
        return c.ext.contains(key);
    }

    pub fn extensionParam(c: *Client, name: []const u8) ?[]const u8 {
        c.hello() catch return null;
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return null;
        const key = std.ascii.upperString(&buf, name);
        return c.ext.get(key);
    }

    pub fn reset(c: *Client) Email.Error!void {
        try c.hello();
        try c.cmd(250, "RSET");
    }

    pub fn noop(c: *Client) Email.Error!void {
        try c.hello();
        try c.cmd(250, "NOOP");
    }

    pub fn quit(c: *Client) Email.Error!void {
        c.hello() catch {};
        try c.cmd(221, "QUIT");
    }

    fn authPlain(c: *Client, p: Auth.Plain) Email.Error!void {
        if (!c.tls_on and !isLocalhost(c.server_name)) return error.Unauthorized;
        if (!std.mem.eql(u8, c.server_name, p.host) and !isLocalhost(c.server_name)) return error.Unauthorized;

        var cred_buf: [512]u8 = undefined;
        const cred = std.mem.print(&cred_buf, "{s}\x00{s}\x00{s}", .{ p.identity, p.username, p.password }) catch
            return error.InvalidMessage;
        var enc_buf: [b64.Encoder.calcSize(cred_buf.len)]u8 = undefined;
        const enc = b64.Encoder.encode(&enc_buf, cred);

        var line_buf: [640]u8 = undefined;
        const line = std.mem.print(&line_buf, "AUTH PLAIN {s}", .{enc}) catch return error.InvalidMessage;
        const code = try c.cmdCode(0, line);
        if (code != 235) return mapReply(code);
    }

    fn authCramMd5(c: *Client, p: Auth.CramMd5) Email.Error!void {
        const code, const challenge64 = try c.cmdMsg(0, "AUTH CRAM-MD5");
        if (code != 334) return mapReply(code);

        var challenge_buf: [256]u8 = undefined;
        const challenge_len = b64.Decoder.calcSizeForSlice(challenge64) catch return error.InvalidResponse;
        if (challenge_len > challenge_buf.len) return error.InvalidResponse;
        b64.Decoder.decode(challenge_buf[0..challenge_len], challenge64) catch return error.InvalidResponse;

        var mac: [std.crypto.auth.hmac.HmacMd5.mac_length]u8 = undefined;
        std.crypto.auth.hmac.HmacMd5.create(&mac, challenge_buf[0..challenge_len], p.secret);

        var resp_buf: [320]u8 = undefined;
        const resp = std.mem.print(&resp_buf, "{s} {x}", .{ p.username, &mac }) catch return error.InvalidMessage;
        var enc_buf: [b64.Encoder.calcSize(resp_buf.len)]u8 = undefined;
        const enc = b64.Encoder.encode(&enc_buf, resp);

        const done = try c.cmdCode(0, enc);
        if (done != 235) return mapReply(done);
    }

    fn ehlo(c: *Client) Email.Error!void {
        c.clearExt();
        var buf: [320]u8 = undefined;
        const line = std.mem.print(&buf, "EHLO {s}", .{c.local_name}) catch return error.InvalidMessage;
        const code, const msg = try c.cmdMsg(250, line);
        _ = code;
        try c.parseEhlo(msg);
    }

    fn helo(c: *Client) Email.Error!void {
        c.clearExt();
        var buf: [320]u8 = undefined;
        const line = std.mem.print(&buf, "HELO {s}", .{c.local_name}) catch return error.InvalidMessage;
        try c.cmd(250, line);
    }

    fn parseEhlo(c: *Client, msg: []const u8) Email.Error!void {
        var lines = std.mem.splitScalar(u8, msg, '\n');
        _ = lines.next(); // greeting line
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const sp = std.mem.findScalar(u8, line, ' ') orelse line.len;
            var key_buf: [64]u8 = undefined;
            if (sp > key_buf.len) continue;
            const key = try c.gpa.dupe(u8, std.ascii.upperString(key_buf[0..sp], line[0..sp]));
            errdefer c.gpa.free(key);
            const param = try c.gpa.dupe(u8, if (sp < line.len) line[sp + 1 ..] else "");
            errdefer c.gpa.free(param);
            const gop = c.ext.getOrPut(c.gpa, key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                c.gpa.free(key);
                c.gpa.free(gop.value_ptr.*);
                gop.value_ptr.* = param;
            } else {
                gop.key_ptr.* = key;
                gop.value_ptr.* = param;
            }
            if (std.mem.eql(u8, gop.key_ptr.*, "AUTH")) c.auth_mechs = gop.value_ptr.*;
        }
    }

    fn clearExt(c: *Client) void {
        var it = c.ext.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            c.gpa.free(e.value_ptr.*);
        }
        c.ext.clearRetainingCapacity();
        c.auth_mechs = "";
    }

    fn negotiateTls(c: *Client) Email.Error!void {
        const sr = &c.stream_reader.interface;
        const sw = &c.stream_writer.interface;
        if (sr.bufferedLen() != 0) return error.InvalidResponse;

        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(c.gpa);
        var lock: Io.RwLock = .init;
        if (!c.insecure) {
            bundle.rescan(c.gpa, c.io, Io.Clock.real.now(c.io)) catch return error.NetworkError;
        }

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        const tls_read = c.buffers[buf_len * 2 ..][0..buf_len];
        const tls_write = c.buffers[buf_len * 3 ..][0..buf_len];
        c.tls_client = tls.Client.init(sr, sw, .{
            .host = if (c.insecure or isIpLiteral(c.server_name)) .no_verification else .{ .explicit = c.server_name },
            .ca = if (c.insecure) .no_verification else .{ .bundle = .{
                .gpa = c.gpa,
                .io = c.io,
                .lock = &lock,
                .bundle = &bundle,
            } },
            .read_buffer = tls_read,
            .write_buffer = tls_write,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(c.io),
        }) catch return error.NetworkError;
        c.tls_on = true;
    }

    fn cmd(c: *Client, expect_code: u16, line: []const u8) Email.Error!void {
        _ = try c.cmdCode(expect_code, line);
    }

    fn cmdCode(c: *Client, expect_code: u16, line: []const u8) Email.Error!u16 {
        const code, _ = try c.cmdMsg(expect_code, line);
        return code;
    }

    fn cmdMsg(c: *Client, expect_code: u16, line: []const u8) Email.Error!struct { u16, []const u8 } {
        try c.writeLine(line);
        return c.readResponse(expect_code);
    }

    fn expect(c: *Client, expect_code: u16) Email.Error!void {
        _ = try c.readResponse(expect_code);
    }

    fn writeLine(c: *Client, line: []const u8) Email.Error!void {
        const w = c.out();
        w.writeAll(line) catch return error.NetworkError;
        w.writeAll("\r\n") catch return error.NetworkError;
        w.flush() catch return error.NetworkError;
        if (c.tls_client != null) c.stream_writer.interface.flush() catch return error.NetworkError;
    }

    fn writeData(c: *Client, msg: []const u8) Email.Error!void {
        const w = c.out();
        var i: usize = 0;
        var line_start: usize = 0;
        while (i < msg.len) : (i += 1) {
            if (msg[i] == '\n') {
                var line = msg[line_start .. i + 1];
                if (line.len >= 1 and line[0] == '.') w.writeByte('.') catch return error.NetworkError;
                // Normalize bare LF to CRLF; leave existing CRLF alone.
                if (line.len >= 2 and line[line.len - 2] == '\r') {
                    w.writeAll(line) catch return error.NetworkError;
                } else {
                    w.writeAll(line[0 .. line.len - 1]) catch return error.NetworkError;
                    w.writeAll("\r\n") catch return error.NetworkError;
                }
                line_start = i + 1;
            }
        }
        if (line_start < msg.len) {
            const line = msg[line_start..];
            if (line[0] == '.') w.writeByte('.') catch return error.NetworkError;
            w.writeAll(line) catch return error.NetworkError;
            if (line[line.len - 1] != '\n') w.writeAll("\r\n") catch return error.NetworkError;
        }
        w.writeAll(".\r\n") catch return error.NetworkError;
        w.flush() catch return error.NetworkError;
        if (c.tls_client != null) c.stream_writer.interface.flush() catch return error.NetworkError;
    }

    fn readResponse(c: *Client, expect_code: u16) Email.Error!struct { u16, []const u8 } {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(c.gpa);

        var code: u16 = 0;
        while (true) {
            const line = c.in().takeDelimiterInclusive('\n') catch return error.NetworkError;
            if (line.len < 4) return error.InvalidResponse;
            const parsed = std.fmt.parseInt(u16, line[0..3], 10) catch return error.InvalidResponse;
            if (code == 0) code = parsed else if (parsed != code) return error.InvalidResponse;

            const text = if (line.len > 4) blk: {
                var t = line[4..];
                if (std.mem.endsWith(u8, t, "\r\n")) t = t[0 .. t.len - 2] else if (std.mem.endsWith(u8, t, "\n")) t = t[0 .. t.len - 1];
                break :blk t;
            } else "";

            if (msg.items.len > 0) msg.append(c.gpa, '\n') catch return error.OutOfMemory;
            msg.appendSlice(c.gpa, text) catch return error.OutOfMemory;

            if (line[3] == ' ') break;
            if (line[3] != '-') return error.InvalidResponse;
        }

        if (expect_code != 0 and !codeMatches(expect_code, code)) {
            log.warn("smtp {d}: {s}", .{ code, msg.items });
            return mapReply(code);
        }

        const owned = msg.toOwnedSlice(c.gpa) catch return error.OutOfMemory;
        return .{ code, c.takeMsg(owned) };
    }

    fn takeMsg(c: *Client, owned: []u8) []const u8 {
        if (c.last_msg.len > 0) c.gpa.free(c.last_msg);
        c.last_msg = owned;
        return owned;
    }

    fn in(c: *Client) *Io.Reader {
        return if (c.tls_client) |*t| &t.reader else &c.stream_reader.interface;
    }

    fn out(c: *Client) *Io.Writer {
        return if (c.tls_client) |*t| &t.writer else &c.stream_writer.interface;
    }
};

fn connectTcp(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream });
    } else |_| {
        const name = try Io.net.HostName.init(host);
        return name.connect(io, port, .{ .mode = .stream });
    }
}

fn isIpLiteral(host: []const u8) bool {
    _ = Io.net.IpAddress.parse(host, 0) catch return false;
    return true;
}

fn isLocalhost(name: []const u8) bool {
    return std.mem.eql(u8, name, "localhost") or
        std.mem.eql(u8, name, "127.0.0.1") or
        std.mem.eql(u8, name, "::1");
}

fn codeMatches(expect: u16, code: u16) bool {
    if (expect == code) return true;
    if (expect < 10) return code / 100 == expect;
    if (expect < 100) return code / 10 == expect;
    return false;
}

fn mapReply(code: u16) Email.Error {
    return switch (code / 100) {
        4 => error.Unavailable,
        5 => switch (code) {
            535, 530, 454 => error.Unauthorized,
            550, 551, 552, 553, 554 => error.Rejected,
            else => error.Rejected,
        },
        else => error.ApiError,
    };
}

fn hasLineBreak(s: []const u8) bool {
    return std.mem.findAny(u8, s, "\r\n") != null;
}

fn recipients(arena: std.mem.Allocator, m: Email.Message) Email.Error![]const []const u8 {
    const n = m.to.len + m.cc.len + m.bcc.len;
    const out = try arena.alloc([]const u8, n);
    var i: usize = 0;
    for ([_][]const Email.Address{ m.to, m.cc, m.bcc }) |list| {
        for (list) |a| {
            out[i] = a.email;
            i += 1;
        }
    }
    return out;
}

// --- RFC 5322 message --- //

fn encodeMessage(arena: std.mem.Allocator, m: Email.Message) Email.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    try writeHeader(&w.writer, "From", try fmtAddress(arena, m.from));
    if (m.to.len > 0) try writeHeader(&w.writer, "To", try fmtList(arena, m.to));
    if (m.cc.len > 0) try writeHeader(&w.writer, "Cc", try fmtList(arena, m.cc));
    if (m.reply_to.len > 0) try writeHeader(&w.writer, "Reply-To", try fmtList(arena, m.reply_to));
    try writeHeader(&w.writer, "Subject", m.subject);
    try writeHeader(&w.writer, "MIME-Version", "1.0");
    for (m.headers) |h| try writeHeader(&w.writer, h.name, h.value);

    if (m.attachments.len == 0) {
        try writeBody(&w.writer, arena, m.text, m.html);
    } else {
        const boundary = try randomBoundary(arena);
        try writeHeader(&w.writer, "Content-Type", try arena.print("multipart/mixed; boundary=\"{s}\"", .{boundary}));
        try writeAll(&w.writer, "\r\n");
        try print(&w.writer, "--{s}\r\n", .{boundary});
        try writeBody(&w.writer, arena, m.text, m.html);
        for (m.attachments) |a| {
            try print(&w.writer, "--{s}\r\n", .{boundary});
            const ctype = a.content_type orelse "application/octet-stream";
            if (a.content_id) |cid| {
                try writeHeader(&w.writer, "Content-Type", ctype);
                try writeHeader(&w.writer, "Content-Transfer-Encoding", "base64");
                try writeHeader(&w.writer, "Content-Disposition", try arena.print("inline; filename=\"{s}\"", .{a.filename}));
                try writeHeader(&w.writer, "Content-ID", try arena.print("<{s}>", .{cid}));
            } else {
                try writeHeader(&w.writer, "Content-Type", ctype);
                try writeHeader(&w.writer, "Content-Transfer-Encoding", "base64");
                try writeHeader(&w.writer, "Content-Disposition", try arena.print("attachment; filename=\"{s}\"", .{a.filename}));
            }
            try writeAll(&w.writer, "\r\n");
            try writeBase64(&w.writer, a.content);
            try writeAll(&w.writer, "\r\n");
        }
        try print(&w.writer, "--{s}--\r\n", .{boundary});
    }

    return try w.toOwnedSlice();
}

fn writeBody(w: *std.Io.Writer, arena: std.mem.Allocator, text: ?[]const u8, html: ?[]const u8) Email.Error!void {
    if (text != null and html != null) {
        const boundary = try randomBoundary(arena);
        try writeHeader(w, "Content-Type", try arena.print("multipart/alternative; boundary=\"{s}\"", .{boundary}));
        try writeAll(w, "\r\n");
        try print(w, "--{s}\r\n", .{boundary});
        try writeHeader(w, "Content-Type", "text/plain; charset=utf-8");
        try writeHeader(w, "Content-Transfer-Encoding", "8bit");
        try writeAll(w, "\r\n");
        try writeCrLf(w, text.?);
        try print(w, "\r\n--{s}\r\n", .{boundary});
        try writeHeader(w, "Content-Type", "text/html; charset=utf-8");
        try writeHeader(w, "Content-Transfer-Encoding", "8bit");
        try writeAll(w, "\r\n");
        try writeCrLf(w, html.?);
        try print(w, "\r\n--{s}--\r\n", .{boundary});
    } else if (html) |h| {
        try writeHeader(w, "Content-Type", "text/html; charset=utf-8");
        try writeHeader(w, "Content-Transfer-Encoding", "8bit");
        try writeAll(w, "\r\n");
        try writeCrLf(w, h);
    } else {
        try writeHeader(w, "Content-Type", "text/plain; charset=utf-8");
        try writeHeader(w, "Content-Transfer-Encoding", "8bit");
        try writeAll(w, "\r\n");
        try writeCrLf(w, text.?);
    }
}

fn writeHeader(w: *std.Io.Writer, name: []const u8, value: []const u8) Email.Error!void {
    w.print("{s}: {s}\r\n", .{ name, value }) catch return error.OutOfMemory;
}

fn writeCrLf(w: *std.Io.Writer, body: []const u8) Email.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\n') {
            const line = body[start..i];
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            w.writeAll(trimmed) catch return error.OutOfMemory;
            w.writeAll("\r\n") catch return error.OutOfMemory;
            start = i + 1;
        }
    }
    if (start < body.len) w.writeAll(body[start..]) catch return error.OutOfMemory;
}

fn writeBase64(w: *std.Io.Writer, bytes: []const u8) Email.Error!void {
    var i: usize = 0;
    var line: [76]u8 = undefined;
    while (i < bytes.len) {
        const chunk = bytes[i..@min(i + 57, bytes.len)];
        const encoded = b64.Encoder.encode(&line, chunk);
        try writeAll(w, encoded);
        try writeAll(w, "\r\n");
        i += chunk.len;
    }
}

fn writeAll(w: *std.Io.Writer, bytes: []const u8) Email.Error!void {
    w.writeAll(bytes) catch return error.OutOfMemory;
}

fn print(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Email.Error!void {
    w.print(fmt, args) catch return error.OutOfMemory;
}

fn randomBoundary(arena: std.mem.Allocator) Email.Error![]const u8 {
    const n = boundary_seq.fetchAdd(1, .monotonic);
    return arena.print("zx_{x}", .{n}) catch return error.OutOfMemory;
}

var boundary_seq: std.atomic.Value(u64) = .init(1);

fn fmtAddress(arena: std.mem.Allocator, a: Email.Address) Email.Error![]const u8 {
    return arena.print("{f}", .{a}) catch return error.OutOfMemory;
}

fn fmtList(arena: std.mem.Allocator, list: []const Email.Address) Email.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    for (list, 0..) |a, i| {
        if (i > 0) w.writer.writeAll(", ") catch return error.OutOfMemory;
        w.writer.print("{f}", .{a}) catch return error.OutOfMemory;
    }
    return w.toOwnedSlice() catch return error.OutOfMemory;
}
