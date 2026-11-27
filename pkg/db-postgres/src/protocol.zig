// Postgres wire protocol v3 encoding and decoding.
// Message layouts adapted from Bun's Zig client (MIT), see NOTICE.
const std = @import("std");

pub const protocol_version: u32 = 196608; // 3.0
pub const ssl_request = [_]u8{ 0x00, 0x00, 0x00, 0x08, 0x04, 0xD2, 0x16, 0x2F };
pub const max_message_len: u32 = 1 << 30;

pub const Error = error{ProtocolViolation};

// --- Frontend --- //

pub const Param = union(enum) {
    null,
    text: []const u8,
    binary: []const u8,
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    msg_start: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
    }

    pub fn reset(self: *Writer) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn bytes(self: *Writer) []const u8 {
        return self.buf.items;
    }

    fn begin(self: *Writer, tag: ?u8) !void {
        if (tag) |code| try self.buf.append(self.gpa, code);
        self.msg_start = self.buf.items.len;
        try self.int4(0);
    }

    fn end(self: *Writer) void {
        const len: u32 = @intCast(self.buf.items.len - self.msg_start);
        std.mem.writeInt(u32, self.buf.items[self.msg_start..][0..4], len, .big);
    }

    fn byte(self: *Writer, value: u8) !void {
        try self.buf.append(self.gpa, value);
    }

    fn int2(self: *Writer, value: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .big);
        try self.buf.appendSlice(self.gpa, &b);
    }

    fn int4(self: *Writer, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .big);
        try self.buf.appendSlice(self.gpa, &b);
    }

    fn sint4(self: *Writer, value: i32) !void {
        try self.int4(@bitCast(value));
    }

    fn raw(self: *Writer, value: []const u8) !void {
        try self.buf.appendSlice(self.gpa, value);
    }

    fn cstr(self: *Writer, value: []const u8) !void {
        // an embedded NUL would truncate the field on the server
        if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidNul;
        try self.raw(value);
        try self.byte(0);
    }

    pub fn startup(self: *Writer, params: []const [2][]const u8) !void {
        try self.begin(null);
        try self.int4(protocol_version);
        for (params) |kv| {
            try self.cstr(kv[0]);
            try self.cstr(kv[1]);
        }
        try self.byte(0);
        self.end();
    }

    pub fn password(self: *Writer, value: []const u8) !void {
        try self.begin('p');
        try self.cstr(value);
        self.end();
    }

    pub fn saslInitial(self: *Writer, mechanism: []const u8, data: []const u8) !void {
        try self.begin('p');
        try self.cstr(mechanism);
        try self.sint4(@intCast(data.len));
        try self.raw(data);
        self.end();
    }

    pub fn saslResponse(self: *Writer, data: []const u8) !void {
        try self.begin('p');
        try self.raw(data);
        self.end();
    }

    pub fn query(self: *Writer, sql: []const u8) !void {
        try self.begin('Q');
        try self.cstr(sql);
        self.end();
    }

    pub fn parse(self: *Writer, name: []const u8, sql: []const u8, param_oids: []const u32) !void {
        if (param_oids.len > std.math.maxInt(u16)) return error.TooManyParameters;
        try self.begin('P');
        try self.cstr(name);
        try self.cstr(sql);
        try self.int2(@intCast(param_oids.len));
        for (param_oids) |oid| try self.int4(oid);
        self.end();
    }

    /// `result_formats`: one code per result column (0 text, 1 binary), or empty for all text.
    pub fn bind(self: *Writer, portal: []const u8, statement: []const u8, params: []const Param, result_formats: []const u16) !void {
        if (params.len > std.math.maxInt(u16)) return error.TooManyParameters;
        try self.begin('B');
        try self.cstr(portal);
        try self.cstr(statement);
        try self.int2(@intCast(params.len));
        for (params) |p| try self.int2(if (p == .binary) 1 else 0);
        try self.int2(@intCast(params.len));
        for (params) |p| switch (p) {
            .null => try self.sint4(-1),
            .text, .binary => |v| {
                try self.int4(@intCast(v.len));
                try self.raw(v);
            },
        };
        try self.int2(@intCast(result_formats.len));
        for (result_formats) |f| try self.int2(f);
        self.end();
    }

    pub fn describe(self: *Writer, kind: u8, name: []const u8) !void {
        try self.begin('D');
        try self.byte(kind);
        try self.cstr(name);
        self.end();
    }

    pub fn close(self: *Writer, kind: u8, name: []const u8) !void {
        try self.begin('C');
        try self.byte(kind);
        try self.cstr(name);
        self.end();
    }

    pub fn execute(self: *Writer, portal: []const u8, max_rows: u32) !void {
        try self.begin('E');
        try self.cstr(portal);
        try self.int4(max_rows);
        self.end();
    }

    pub fn sync(self: *Writer) !void {
        try self.begin('S');
        self.end();
    }

    pub fn terminate(self: *Writer) !void {
        try self.begin('X');
        self.end();
    }
};

// --- Backend --- //

pub const Raw = struct {
    tag: u8,
    body: []const u8,
};

/// Read one message; `body` stays valid until the next read from `reader`.
/// Messages that fit the reader's buffer are returned in place (no copy); larger ones go through `buf`.
pub fn readRaw(reader: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !Raw {
    const header = try reader.takeArray(5);
    const tag = header[0];
    const len = std.mem.readInt(u32, header[1..5], .big);
    if (len < 4 or len > max_message_len) return Error.ProtocolViolation;
    if (len - 4 <= reader.buffer.len) return .{ .tag = tag, .body = try reader.take(len - 4) };
    try buf.resize(gpa, len - 4);
    try reader.readSliceAll(buf.items);
    return .{ .tag = tag, .body = buf.items };
}

pub const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Cursor) []const u8 {
        return self.data[self.pos..];
    }

    pub fn byte(self: *Cursor) Error!u8 {
        if (self.pos >= self.data.len) return Error.ProtocolViolation;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    pub fn int2(self: *Cursor) Error!u16 {
        const b = try self.take(2);
        return std.mem.readInt(u16, b[0..2], .big);
    }

    pub fn int4(self: *Cursor) Error!u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    pub fn sint4(self: *Cursor) Error!i32 {
        return @bitCast(try self.int4());
    }

    pub fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (self.data.len - self.pos < n) return Error.ProtocolViolation;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    pub fn cstr(self: *Cursor) Error![]const u8 {
        const rest = self.remaining();
        const end = std.mem.findScalar(u8, rest, 0) orelse return Error.ProtocolViolation;
        self.pos += end + 1;
        return rest[0..end];
    }
};

pub const Auth = union(enum) {
    ok,
    cleartext,
    md5: [4]u8,
    sasl: []const u8, // NUL-separated mechanism list
    sasl_continue: []const u8,
    sasl_final: []const u8,
    unsupported: u32,

    pub fn decode(body: []const u8) Error!Auth {
        var c: Cursor = .{ .data = body };
        return switch (try c.int4()) {
            0 => .ok,
            3 => .cleartext,
            5 => .{ .md5 = (try c.take(4))[0..4].* },
            10 => .{ .sasl = c.remaining() },
            11 => .{ .sasl_continue = c.remaining() },
            12 => .{ .sasl_final = c.remaining() },
            else => |code| .{ .unsupported = code },
        };
    }

    pub fn offersMechanism(list: []const u8, name: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, list, 0);
        while (it.next()) |m| if (std.mem.eql(u8, m, name)) return true;
        return false;
    }
};

/// Fields of an ErrorResponse / NoticeResponse; slices borrow the message body.
pub const ErrorFields = struct {
    severity: []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    hint: []const u8 = "",
    /// Server source routine, e.g. `RevalidateCachedQuery`; never translated.
    routine: []const u8 = "",

    pub fn decode(body: []const u8) Error!ErrorFields {
        var out: ErrorFields = .{};
        var c: Cursor = .{ .data = body };
        while (true) {
            const kind = try c.byte();
            if (kind == 0) break;
            const value = try c.cstr();
            switch (kind) {
                'V' => out.severity = value,
                'S' => if (out.severity.len == 0) {
                    out.severity = value;
                },
                'C' => out.code = value,
                'M' => out.message = value,
                'D' => out.detail = value,
                'H' => out.hint = value,
                'R' => out.routine = value,
                else => {},
            }
        }
        return out;
    }
};

pub const Column = struct {
    name: []const u8,
    type_oid: u32,
};

pub const RowDescription = struct {
    count: u16,
    cursor: Cursor,

    pub fn init(body: []const u8) Error!RowDescription {
        var c: Cursor = .{ .data = body };
        return .{ .count = try c.int2(), .cursor = c };
    }

    pub fn next(self: *RowDescription) Error!Column {
        const name = try self.cursor.cstr();
        _ = try self.cursor.take(4 + 2); // table oid, attribute number
        const oid = try self.cursor.int4();
        _ = try self.cursor.take(2 + 4 + 2); // typlen, typmod, format
        return .{ .name = name, .type_oid = oid };
    }
};

pub const DataRow = struct {
    count: u16,
    cursor: Cursor,

    pub fn init(body: []const u8) Error!DataRow {
        var c: Cursor = .{ .data = body };
        return .{ .count = try c.int2(), .cursor = c };
    }

    /// null for SQL NULL.
    pub inline fn next(self: *DataRow) Error!?[]const u8 {
        const c = &self.cursor;
        if (c.data.len - c.pos < 4) return Error.ProtocolViolation;
        const len = std.mem.readInt(i32, c.data[c.pos..][0..4], .big);
        c.pos += 4;
        if (len < 0) return null;
        const n: usize = @intCast(len);
        if (c.data.len - c.pos < n) return Error.ProtocolViolation;
        defer c.pos += n;
        return c.data[c.pos..][0..n];
    }
};

pub fn parameterOids(gpa: std.mem.Allocator, body: []const u8) ![]u32 {
    var c: Cursor = .{ .data = body };
    const n = try c.int2();
    const oids = try gpa.alloc(u32, n);
    errdefer gpa.free(oids);
    for (oids) |*oid| oid.* = try c.int4();
    return oids;
}

/// Affected-row count from a CommandComplete tag such as `INSERT 0 3` or `UPDATE 2`.
pub fn commandRows(tag: []const u8) u64 {
    const counted = [_][]const u8{ "INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY" };
    const space = std.mem.findScalar(u8, tag, ' ') orelse return 0;
    const word = tag[0..space];
    for (counted) |name| {
        if (std.mem.eql(u8, word, name)) {
            const last = std.mem.findScalarLast(u8, tag, ' ').?;
            return std.fmt.parseInt(u64, tag[last + 1 ..], 10) catch 0;
        }
    }
    return 0;
}

// --- Tests --- //

const t = std.testing;

test "startup message layout" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    try w.startup(&.{.{ "user", "pg" }});
    const expected = [_]u8{ 0, 0, 0, 17, 0, 3, 0, 0 } ++ "user\x00pg\x00\x00".*;
    try t.expectEqualSlices(u8, &expected, w.bytes());
}

test "parse/bind/execute/sync layout" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    try w.parse("", "SELECT $1", &.{0});
    try t.expectEqualSlices(u8, "P\x00\x00\x00\x15\x00SELECT $1\x00\x00\x01\x00\x00\x00\x00", w.bytes());

    w.reset();
    try w.bind("", "", &.{ .{ .text = "42" }, .null, .{ .binary = "\x01" } }, &.{});
    try t.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x21\x00\x00" ++ "\x00\x03\x00\x00\x00\x00\x00\x01" ++
            "\x00\x03" ++ "\x00\x00\x00\x0242" ++ "\xff\xff\xff\xff" ++ "\x00\x00\x00\x01\x01" ++ "\x00\x00",
        w.bytes(),
    );

    w.reset();
    try w.execute("", 0);
    try w.sync();
    try t.expectEqualSlices(u8, "E\x00\x00\x00\x09\x00\x00\x00\x00\x00S\x00\x00\x00\x04", w.bytes());
}

test "cstr rejects embedded NUL" {
    var w: Writer = .init(t.allocator);
    defer w.deinit();
    try t.expectError(error.InvalidNul, w.query("SELECT 1\x00; DROP"));
}

test "readRaw frames messages" {
    var r: std.Io.Reader = .fixed("Z\x00\x00\x00\x05IC\x00\x00\x00\x0fINSERT 0 3\x00");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);

    const ready = try readRaw(&r, t.allocator, &buf);
    try t.expectEqual(@as(u8, 'Z'), ready.tag);
    try t.expectEqualSlices(u8, "I", ready.body);

    const done = try readRaw(&r, t.allocator, &buf);
    try t.expectEqual(@as(u8, 'C'), done.tag);
    var c: Cursor = .{ .data = done.body };
    try t.expectEqual(@as(u64, 3), commandRows(try c.cstr()));
}

test "decode auth, error, row description and data row" {
    try t.expectEqual(Auth.ok, try Auth.decode("\x00\x00\x00\x00"));
    const md5 = try Auth.decode("\x00\x00\x00\x05abcd");
    try t.expectEqualSlices(u8, "abcd", &md5.md5);
    const sasl = try Auth.decode("\x00\x00\x00\x0aSCRAM-SHA-256-PLUS\x00SCRAM-SHA-256\x00\x00");
    try t.expect(Auth.offersMechanism(sasl.sasl, "SCRAM-SHA-256"));
    try t.expect(!Auth.offersMechanism(sasl.sasl, "SCRAM-SHA-1"));

    const err = try ErrorFields.decode("SERROR\x00VERROR\x00C23505\x00Mduplicate key\x00\x00");
    try t.expectEqualStrings("23505", err.code);
    try t.expectEqualStrings("duplicate key", err.message);

    var desc = try RowDescription.init("\x00\x01id\x00" ++ "\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x17" ++ "\x00\x04\xff\xff\xff\xff\x00\x00");
    try t.expectEqual(@as(u16, 1), desc.count);
    const col = try desc.next();
    try t.expectEqualStrings("id", col.name);
    try t.expectEqual(@as(u32, 23), col.type_oid);

    var row = try DataRow.init("\x00\x02\x00\x00\x00\x017\xff\xff\xff\xff");
    try t.expectEqualStrings("7", (try row.next()).?);
    try t.expectEqual(@as(?[]const u8, null), try row.next());
    try t.expectError(error.ProtocolViolation, row.next());
}

test "command tag row counts" {
    try t.expectEqual(@as(u64, 2), commandRows("UPDATE 2"));
    try t.expectEqual(@as(u64, 5), commandRows("SELECT 5"));
    try t.expectEqual(@as(u64, 0), commandRows("CREATE TABLE"));
    try t.expectEqual(@as(u64, 0), commandRows("BEGIN"));
}
