// MySQL client/server protocol: packet framing, length-encoded values, handshake, OK/ERR, columns.
// Packet layouts adapted from Bun's Zig MySQL client (MIT), see NOTICE.
const std = @import("std");
const Io = std.Io;

pub const Error = error{ ProtocolViolation, TooManyParameters };

/// Payload length that signals "another packet follows".
pub const max_payload: u32 = 0xFFFFFF;
pub const max_message_len: usize = 1 << 30;

pub const Command = enum(u8) {
    quit = 0x01,
    query = 0x03,
    ping = 0x0e,
    stmt_prepare = 0x16,
    stmt_execute = 0x17,
    stmt_close = 0x19,
};

pub const Cap = struct {
    pub const long_password: u32 = 1 << 0;
    pub const found_rows: u32 = 1 << 1;
    pub const long_flag: u32 = 1 << 2;
    pub const connect_with_db: u32 = 1 << 3;
    pub const protocol_41: u32 = 1 << 9;
    pub const ssl: u32 = 1 << 11;
    pub const transactions: u32 = 1 << 13;
    pub const secure_connection: u32 = 1 << 15;
    pub const multi_statements: u32 = 1 << 16;
    pub const multi_results: u32 = 1 << 17;
    pub const ps_multi_results: u32 = 1 << 18;
    pub const plugin_auth: u32 = 1 << 19;
    pub const plugin_auth_lenenc_client_data: u32 = 1 << 21;
    pub const deprecate_eof: u32 = 1 << 24;
};

pub const Status = struct {
    pub const in_trans: u16 = 0x0001;
    pub const autocommit: u16 = 0x0002;
    pub const more_results: u16 = 0x0008;
};

pub const Charset = struct {
    pub const utf8mb4_general_ci: u8 = 45;
};

pub const Param = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    boolean: bool,
};

// Parameter wire types for COM_STMT_EXECUTE.
const wire_tiny: u8 = 0x01;
const wire_double: u8 = 0x05;
const wire_null: u8 = 0x06;
const wire_longlong: u8 = 0x08;
const wire_blob: u8 = 0xfc;
const wire_var_string: u8 = 0xfd;

// --- Reading --- //

pub const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn rest(self: *const Cursor) []const u8 {
        return self.data[self.pos..];
    }

    pub fn atEnd(self: *const Cursor) bool {
        return self.pos >= self.data.len;
    }

    pub fn peek(self: *const Cursor) ?u8 {
        return if (self.pos < self.data.len) self.data[self.pos] else null;
    }

    pub fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (self.data.len - self.pos < n) return Error.ProtocolViolation;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    pub fn skip(self: *Cursor, n: usize) Error!void {
        _ = try self.take(n);
    }

    pub fn int1(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn int2(self: *Cursor) Error!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    pub fn int3(self: *Cursor) Error!u24 {
        return std.mem.readInt(u24, (try self.take(3))[0..3], .little);
    }

    pub fn int4(self: *Cursor) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    pub fn int8(self: *Cursor) Error!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    /// Length-encoded integer; `0xFB` (NULL) and `0xFF` are not valid here.
    pub fn lenenc(self: *Cursor) Error!u64 {
        const first = try self.int1();
        return switch (first) {
            0...0xfa => first,
            0xfc => try self.int2(),
            0xfd => try self.int3(),
            0xfe => try self.int8(),
            else => Error.ProtocolViolation,
        };
    }

    pub fn lenencStr(self: *Cursor) Error![]const u8 {
        const len = try self.lenenc();
        if (len > self.data.len - self.pos) return Error.ProtocolViolation;
        return self.take(@intCast(len));
    }

    /// NUL-terminated string without the terminator.
    pub fn cstr(self: *Cursor) Error![]const u8 {
        const end = std.mem.findScalarPos(u8, self.data, self.pos, 0) orelse return Error.ProtocolViolation;
        defer self.pos = end + 1;
        return self.data[self.pos..end];
    }
};

/// Read one logical packet (continuations of 16 MiB packets are joined); `seq` is the
/// expected sequence id and is advanced. The body stays valid until the next read from `reader`.
/// Packets that fit the reader's buffer are returned in place; larger ones go through `buf`.
pub fn readPacket(reader: *Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), seq: *u8) ![]const u8 {
    const first = try readHeader(reader, seq);
    if (first < max_payload and first <= reader.buffer.len) return reader.take(first);

    buf.clearRetainingCapacity();
    var len = first;
    while (true) {
        if (buf.items.len + len > max_message_len) return Error.ProtocolViolation;
        const start = buf.items.len;
        try buf.resize(gpa, start + len);
        try reader.readSliceAll(buf.items[start..]);
        if (len < max_payload) return buf.items;
        len = try readHeader(reader, seq);
    }
}

fn readHeader(reader: *Io.Reader, seq: *u8) !usize {
    const header = try reader.takeArray(4);
    if (header[3] != seq.*) return Error.ProtocolViolation;
    seq.* +%= 1;
    return std.mem.readInt(u24, header[0..3], .little);
}

// --- Writing --- //

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    packet_start: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
    }

    pub fn reset(self: *Writer) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    /// Start a packet; its header is filled in by `end`.
    pub fn begin(self: *Writer) !void {
        self.packet_start = self.buf.items.len;
        try self.buf.appendSlice(self.gpa, &.{ 0, 0, 0, 0 });
    }

    /// Finish the packet with sequence id `seq` (advanced), splitting payloads of 16 MiB or more.
    pub fn end(self: *Writer, seq: *u8) !void {
        var remaining = self.buf.items.len - self.packet_start - 4;
        var at = self.packet_start;
        while (true) {
            const chunk: u32 = @intCast(@min(remaining, max_payload));
            if (at != self.packet_start) try self.buf.insertSlice(self.gpa, at, &.{ 0, 0, 0, 0 });
            std.mem.writeInt(u24, self.buf.items[at..][0..3], @intCast(chunk), .little);
            self.buf.items[at + 3] = seq.*;
            seq.* +%= 1;
            at += 4 + chunk;
            remaining -= chunk;
            if (chunk < max_payload) break;
        }
    }

    pub fn int1(self: *Writer, value: u8) !void {
        try self.buf.append(self.gpa, value);
    }

    pub fn int2(self: *Writer, value: u16) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, value)));
    }

    pub fn int4(self: *Writer, value: u32) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    }

    pub fn int8(self: *Writer, value: u64) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }

    pub fn lenenc(self: *Writer, value: u64) !void {
        if (value < 0xfb) {
            try self.int1(@intCast(value));
        } else if (value <= 0xffff) {
            try self.int1(0xfc);
            try self.int2(@intCast(value));
        } else if (value <= 0xffffff) {
            try self.int1(0xfd);
            try self.raw(&.{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16) });
        } else {
            try self.int1(0xfe);
            try self.int8(value);
        }
    }

    pub fn raw(self: *Writer, value: []const u8) !void {
        try self.buf.appendSlice(self.gpa, value);
    }

    pub fn lenencStr(self: *Writer, value: []const u8) !void {
        try self.lenenc(value.len);
        try self.raw(value);
    }

    pub fn cstr(self: *Writer, value: []const u8) !void {
        // an embedded NUL would truncate the field on the server
        if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidNul;
        try self.raw(value);
        try self.int1(0);
    }

    /// First 32 bytes shared by SSLRequest and HandshakeResponse41.
    fn clientHeader(self: *Writer, caps: u32, max_packet: u32, charset: u8) !void {
        try self.int4(caps);
        try self.int4(max_packet);
        try self.int1(charset);
        try self.buf.appendNTimes(self.gpa, 0, 23);
    }

    pub fn sslRequest(self: *Writer, seq: *u8, caps: u32, charset: u8) !void {
        try self.begin();
        try self.clientHeader(caps, max_payload, charset);
        try self.end(seq);
    }

    pub const Login = struct {
        caps: u32,
        charset: u8 = Charset.utf8mb4_general_ci,
        user: []const u8,
        auth_response: []const u8,
        database: ?[]const u8,
        plugin: []const u8,
    };

    pub fn handshakeResponse(self: *Writer, seq: *u8, login: Login) !void {
        try self.begin();
        try self.clientHeader(login.caps, max_payload, login.charset);
        try self.cstr(login.user);
        if (login.caps & Cap.plugin_auth_lenenc_client_data != 0) {
            try self.lenencStr(login.auth_response);
        } else {
            if (login.auth_response.len > 0xff) return error.AuthResponseTooLong;
            try self.int1(@intCast(login.auth_response.len));
            try self.raw(login.auth_response);
        }
        if (login.caps & Cap.connect_with_db != 0) try self.cstr(login.database orelse "");
        if (login.caps & Cap.plugin_auth != 0) try self.cstr(login.plugin);
        try self.end(seq);
    }

    /// Raw payload (auth continuation data).
    pub fn packet(self: *Writer, seq: *u8, payload: []const u8) !void {
        try self.begin();
        try self.raw(payload);
        try self.end(seq);
    }

    /// Command packet with a string argument; always starts a new sequence.
    /// Returns the sequence id the response will use.
    pub fn command(self: *Writer, cmd: Command, arg: []const u8) !u8 {
        var seq: u8 = 0;
        try self.begin();
        try self.int1(@intFromEnum(cmd));
        try self.raw(arg);
        try self.end(&seq);
        return seq;
    }

    pub fn stmtClose(self: *Writer, stmt_id: u32) !u8 {
        var seq: u8 = 0;
        try self.begin();
        try self.int1(@intFromEnum(Command.stmt_close));
        try self.int4(stmt_id);
        try self.end(&seq);
        return seq;
    }

    pub fn stmtExecute(self: *Writer, stmt_id: u32, params: []const Param) !u8 {
        if (params.len > std.math.maxInt(u16)) return Error.TooManyParameters;
        var seq: u8 = 0;
        try self.begin();
        try self.int1(@intFromEnum(Command.stmt_execute));
        try self.int4(stmt_id);
        try self.int1(0); // no cursor
        try self.int4(1); // iteration count
        if (params.len > 0) {
            const bitmap_len = (params.len + 7) / 8;
            const bitmap_at = self.buf.items.len;
            try self.buf.appendNTimes(self.gpa, 0, bitmap_len);
            for (params, 0..) |p, i| {
                if (p == .null) self.buf.items[bitmap_at + i / 8] |= @as(u8, 1) << @intCast(i % 8);
            }
            try self.int1(1); // types follow
            for (params) |p| {
                try self.int1(switch (p) {
                    .null => wire_null,
                    .int => wire_longlong,
                    .float => wire_double,
                    .text => wire_var_string,
                    .blob => wire_blob,
                    .boolean => wire_tiny,
                });
                try self.int1(0); // signed
            }
            for (params) |p| switch (p) {
                .null => {},
                .int => |v| try self.int8(@bitCast(v)),
                .float => |v| try self.int8(@bitCast(v)),
                .text, .blob => |v| try self.lenencStr(v),
                .boolean => |v| try self.int1(@intFromBool(v)),
            };
        }
        try self.end(&seq);
        return seq;
    }
};

// --- Server packets --- //

pub const Handshake = struct {
    /// Borrowed from the packet body; copy before the next read.
    server_version: []const u8,
    connection_id: u32,
    capabilities: u32,
    status: u16,
    /// Scramble: 8 bytes of part 1 and the first 12 of part 2.
    nonce: [20]u8,
    /// Borrowed from the packet body; copy before the next read.
    plugin: []const u8,
};

pub fn decodeHandshake(body: []const u8) Error!Handshake {
    var c: Cursor = .{ .data = body };
    if (try c.int1() != 10) return Error.ProtocolViolation;
    var h: Handshake = undefined;
    h.server_version = try c.cstr();
    h.connection_id = try c.int4();
    @memcpy(h.nonce[0..8], try c.take(8));
    try c.skip(1);
    var caps: u32 = try c.int2();
    try c.skip(1); // charset
    h.status = try c.int2();
    caps |= @as(u32, try c.int2()) << 16;
    h.capabilities = caps;
    const auth_data_len = try c.int1();
    try c.skip(10);
    if (caps & Cap.secure_connection != 0) {
        const part2_len = @max(13, @as(usize, auth_data_len) -| 8);
        const part2 = try c.take(@min(part2_len, c.rest().len));
        if (part2.len < 12) return Error.ProtocolViolation;
        @memcpy(h.nonce[8..20], part2[0..12]);
    } else {
        return Error.ProtocolViolation;
    }
    h.plugin = if (caps & Cap.plugin_auth != 0) c.cstr() catch c.rest() else "";
    return h;
}

pub const Ok = struct {
    affected_rows: u64 = 0,
    last_insert_id: u64 = 0,
    status: u16 = 0,
    warnings: u16 = 0,
};

/// OK packet, or the OK-formatted result set terminator (header 0xFE) with CLIENT_DEPRECATE_EOF.
pub fn decodeOk(body: []const u8) Error!Ok {
    var c: Cursor = .{ .data = body };
    try c.skip(1);
    return .{
        .affected_rows = try c.lenenc(),
        .last_insert_id = try c.lenenc(),
        .status = try c.int2(),
        .warnings = try c.int2(),
    };
}

/// Legacy EOF packet.
pub fn decodeEof(body: []const u8) Error!Ok {
    var c: Cursor = .{ .data = body };
    try c.skip(1);
    const warnings = try c.int2();
    return .{ .warnings = warnings, .status = try c.int2() };
}

pub const ErrPacket = struct {
    code: u16,
    /// 5 characters, or empty when the server sent none.
    sqlstate: []const u8,
    message: []const u8,
};

pub fn decodeErr(body: []const u8) Error!ErrPacket {
    var c: Cursor = .{ .data = body };
    try c.skip(1);
    const code = try c.int2();
    var state: []const u8 = "";
    if (c.peek() == '#') {
        try c.skip(1);
        state = try c.take(5);
    }
    return .{ .code = code, .sqlstate = state, .message = c.rest() };
}

pub const Column = struct {
    name: []const u8,
    charset: u16,
    length: u32,
    type: u8,
    flags: u16,
    decimals: u8,
};

/// `name` borrows `body`.
pub fn decodeColumn(body: []const u8) Error!Column {
    var c: Cursor = .{ .data = body };
    // catalog, schema, table, org_table
    for (0..4) |_| _ = try c.lenencStr();
    const name = try c.lenencStr();
    _ = try c.lenencStr(); // org_name
    _ = try c.lenenc(); // length of the fixed fields (0x0c)
    return .{
        .name = name,
        .charset = try c.int2(),
        .length = try c.int4(),
        .type = try c.int1(),
        .flags = try c.int2(),
        .decimals = try c.int1(),
    };
}

pub const PrepareOk = struct {
    stmt_id: u32,
    num_columns: u16,
    num_params: u16,
};

pub fn decodePrepareOk(body: []const u8) Error!PrepareOk {
    var c: Cursor = .{ .data = body };
    try c.skip(1);
    return .{
        .stmt_id = try c.int4(),
        .num_columns = try c.int2(),
        .num_params = try c.int2(),
    };
}

// --- Tests --- //

const t = std.testing;

test "length-encoded integers round trip" {
    const cases = [_]u64{ 0, 250, 251, 0xffff, 0x10000, 0xffffff, 0x1000000, std.math.maxInt(u64) };
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    for (cases) |v| try w.lenenc(v);
    var c: Cursor = .{ .data = w.bytes() };
    for (cases) |v| try t.expectEqual(v, try c.lenenc());
    try t.expect(c.atEnd());

    // encodings are minimal
    w.reset();
    try w.lenenc(250);
    try w.lenenc(251);
    try t.expectEqualSlices(u8, &.{ 250, 0xfc, 251, 0 }, w.bytes());
}

test "lenenc rejects NULL marker and truncation" {
    var c: Cursor = .{ .data = &.{0xfb} };
    try t.expectError(Error.ProtocolViolation, c.lenenc());
    var short: Cursor = .{ .data = &.{ 0xfc, 1 } };
    try t.expectError(Error.ProtocolViolation, short.lenenc());
    var s: Cursor = .{ .data = &.{ 5, 'a', 'b' } };
    try t.expectError(Error.ProtocolViolation, s.lenencStr());
}

test "packet header and sequence ids" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    var seq: u8 = 3;
    try w.packet(&seq, "abc");
    try t.expectEqual(@as(u8, 4), seq);
    try t.expectEqualSlices(u8, &.{ 3, 0, 0, 3, 'a', 'b', 'c' }, w.bytes());

    var r: Io.Reader = .fixed(w.bytes());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    var expect: u8 = 3;
    try t.expectEqualStrings("abc", try readPacket(&r, t.allocator, &buf, &expect));
    try t.expectEqual(@as(u8, 4), expect);

    var bad: Io.Reader = .fixed(w.bytes());
    var wrong: u8 = 0;
    try t.expectError(Error.ProtocolViolation, readPacket(&bad, t.allocator, &buf, &wrong));
}

test "payloads of 16 MiB are split and rejoined" {
    const len = max_payload + 10;
    const payload = try t.allocator.alloc(u8, len);
    defer t.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31);

    var w: Writer = .init(t.allocator);
    defer w.deinit();
    var seq: u8 = 0;
    try w.packet(&seq, payload);
    try t.expectEqual(@as(u8, 2), seq);
    // 4 + 0xFFFFFF, then 4 + 10
    try t.expectEqual(@as(usize, 8 + len), w.bytes().len);
    try t.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0 }, w.bytes()[0..4]);

    var r: Io.Reader = .fixed(w.bytes());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    var expect: u8 = 0;
    const got = try readPacket(&r, t.allocator, &buf, &expect);
    try t.expectEqual(@as(u8, 2), expect);
    try t.expectEqualSlices(u8, payload, got);
}

test "exact multiple of 16 MiB ends with an empty packet" {
    const payload = try t.allocator.alloc(u8, max_payload);
    defer t.allocator.free(payload);
    @memset(payload, 7);
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    var seq: u8 = 0;
    try w.packet(&seq, payload);
    try t.expectEqual(@as(u8, 2), seq);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 1 }, w.bytes()[w.bytes().len - 4 ..]);

    var r: Io.Reader = .fixed(w.bytes());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    var expect: u8 = 0;
    try t.expectEqual(@as(usize, max_payload), (try readPacket(&r, t.allocator, &buf, &expect)).len);
}

test "decode handshake v10" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    try w.int1(10);
    try w.cstr("8.4.0");
    try w.int4(77);
    try w.raw("abcdefgh");
    try w.int1(0);
    const caps: u32 = Cap.protocol_41 | Cap.secure_connection | Cap.plugin_auth | Cap.ssl | Cap.deprecate_eof;
    try w.int2(@truncate(caps));
    try w.int1(255);
    try w.int2(Status.autocommit);
    try w.int2(@truncate(caps >> 16));
    try w.int1(21);
    try w.buf.appendNTimes(t.allocator, 0, 10);
    try w.raw("ijklmnopqrst\x00");
    try w.cstr("caching_sha2_password");

    const h = try decodeHandshake(w.bytes());
    try t.expectEqualStrings("8.4.0", h.server_version);
    try t.expectEqual(@as(u32, 77), h.connection_id);
    try t.expectEqual(caps, h.capabilities);
    try t.expectEqualStrings("abcdefghijklmnopqrst", &h.nonce);
    try t.expectEqualStrings("caching_sha2_password", h.plugin);
    try t.expectEqual(Status.autocommit, h.status);

    try t.expectError(Error.ProtocolViolation, decodeHandshake(w.bytes()[0..20]));
    try t.expectError(Error.ProtocolViolation, decodeHandshake("\x09rest"));
}

test "decode OK, EOF and ERR packets" {
    const ok = try decodeOk(&.{ 0, 3, 0xfc, 0x00, 0x01, 0x0a, 0x00, 0x02, 0x00 });
    try t.expectEqual(@as(u64, 3), ok.affected_rows);
    try t.expectEqual(@as(u64, 256), ok.last_insert_id);
    try t.expectEqual(@as(u16, 10), ok.status);
    try t.expectEqual(@as(u16, 2), ok.warnings);

    const eof = try decodeEof(&.{ 0xfe, 1, 0, 8, 0 });
    try t.expectEqual(Status.more_results, eof.status);
    try t.expectEqual(@as(u16, 1), eof.warnings);

    const err = try decodeErr("\xff\x26\x04#23000Duplicate entry");
    try t.expectEqual(@as(u16, 1062), err.code);
    try t.expectEqualStrings("23000", err.sqlstate);
    try t.expectEqualStrings("Duplicate entry", err.message);

    const bare = try decodeErr("\xff\x15\x04too many");
    try t.expectEqual(@as(u16, 1045), bare.code);
    try t.expectEqualStrings("", bare.sqlstate);
    try t.expectEqualStrings("too many", bare.message);
}

test "decode column definition" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    for ([_][]const u8{ "def", "db", "users", "users", "name", "name" }) |s| try w.lenencStr(s);
    try w.lenenc(0x0c);
    try w.int2(255);
    try w.int4(1020);
    try w.int1(0xfd);
    try w.int2(0x1001);
    try w.int1(0);
    try w.int2(0);

    const col = try decodeColumn(w.bytes());
    try t.expectEqualStrings("name", col.name);
    try t.expectEqual(@as(u16, 255), col.charset);
    try t.expectEqual(@as(u32, 1020), col.length);
    try t.expectEqual(@as(u8, 0xfd), col.type);
    try t.expectEqual(@as(u16, 0x1001), col.flags);
}

test "decode prepare OK" {
    const p = try decodePrepareOk(&.{ 0, 9, 0, 0, 0, 2, 0, 3, 0, 0, 0, 0, 0 });
    try t.expectEqual(@as(u32, 9), p.stmt_id);
    try t.expectEqual(@as(u16, 2), p.num_columns);
    try t.expectEqual(@as(u16, 3), p.num_params);
}

test "handshake response layout" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    var seq: u8 = 1;
    const caps = Cap.protocol_41 | Cap.plugin_auth | Cap.plugin_auth_lenenc_client_data | Cap.connect_with_db;
    try w.handshakeResponse(&seq, .{
        .caps = caps,
        .user = "root",
        .auth_response = "\x01\x02",
        .database = "test",
        .plugin = "mysql_native_password",
    });
    const b = w.bytes();
    try t.expectEqual(@as(u8, 1), b[3]);
    var c: Cursor = .{ .data = b[4..] };
    try t.expectEqual(caps, try c.int4());
    try t.expectEqual(max_payload, try c.int4());
    try t.expectEqual(Charset.utf8mb4_general_ci, try c.int1());
    try c.skip(23);
    try t.expectEqualStrings("root", try c.cstr());
    try t.expectEqualStrings("\x01\x02", try c.lenencStr());
    try t.expectEqualStrings("test", try c.cstr());
    try t.expectEqualStrings("mysql_native_password", try c.cstr());
    try t.expect(c.atEnd());
    try t.expectEqual(@as(usize, b.len - 4), std.mem.readInt(u24, b[0..3], .little));
}

test "ssl request is the 32 byte client header" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    var seq: u8 = 1;
    try w.sslRequest(&seq, Cap.protocol_41 | Cap.ssl, Charset.utf8mb4_general_ci);
    try t.expectEqual(@as(usize, 36), w.bytes().len);
    try t.expectEqual(@as(u24, 32), std.mem.readInt(u24, w.bytes()[0..3], .little));
}

test "execute packet encodes null bitmap, types and values" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    const params = [_]Param{ .{ .int = -2 }, .null, .{ .text = "hi" }, .{ .float = 1.5 }, .{ .boolean = true }, .{ .blob = "\x00\xff" } };
    _ = try w.stmtExecute(7, &params);
    const b = w.bytes();
    try t.expectEqual(@as(u8, 0), b[3]); // new command, sequence 0
    var c: Cursor = .{ .data = b[4..] };
    try t.expectEqual(@as(u8, 0x17), try c.int1());
    try t.expectEqual(@as(u32, 7), try c.int4());
    try t.expectEqual(@as(u8, 0), try c.int1());
    try t.expectEqual(@as(u32, 1), try c.int4());
    try t.expectEqual(@as(u8, 0b10), try c.int1()); // only param 1 is NULL
    try t.expectEqual(@as(u8, 1), try c.int1());
    const types_expected = [_]u8{ 0x08, 0x06, 0xfd, 0x05, 0x01, 0xfc };
    for (types_expected) |ty| {
        try t.expectEqual(ty, try c.int1());
        try t.expectEqual(@as(u8, 0), try c.int1());
    }
    try t.expectEqual(@as(u64, @bitCast(@as(i64, -2))), try c.int8());
    try t.expectEqualStrings("hi", try c.lenencStr());
    try t.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), try c.int8());
    try t.expectEqual(@as(u8, 1), try c.int1());
    try t.expectEqualStrings("\x00\xff", try c.lenencStr());
    try t.expect(c.atEnd());
}

test "execute without params has no bitmap" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    _ = try w.stmtExecute(1, &.{});
    try t.expectEqual(@as(usize, 4 + 1 + 4 + 1 + 4), w.bytes().len);
}

test "commands start a new sequence" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    _ = try w.command(.query, "SELECT 1");
    try t.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 3, 'S', 'E', 'L', 'E', 'C', 'T', ' ', '1' }, w.bytes());
    w.reset();
    _ = try w.stmtClose(5);
    try t.expectEqualSlices(u8, &.{ 5, 0, 0, 0, 0x19, 5, 0, 0, 0 }, w.bytes());
}
