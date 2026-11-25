// Just enough XML for S3 responses, after Bun's `list_objects.zig` scanner:
// elements are found by name, which is unambiguous for the fields read here.
// Unlike Bun, entities are decoded, so keys with `&` or `<` come back intact.
const std = @import("std");

// Text of the first `<name>…</name>`, still entity-encoded; "" for `<name/>`.
pub fn text(xml: []const u8, name: []const u8) ?[]const u8 {
    var it: Iterator = .{ .xml = xml, .name = name };
    return it.next();
}

// Each `<name>…</name>` in order, entity-encoded.
pub const Iterator = struct {
    xml: []const u8,
    name: []const u8,
    pos: usize = 0,

    pub fn next(it: *Iterator) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, it.xml, it.pos, '<')) |lt| {
            it.pos = lt + 1;
            const rest = it.xml[lt + 1 ..];
            if (!std.mem.startsWith(u8, rest, it.name)) continue;
            const after = rest[it.name.len..];
            if (after.len == 0) return null;
            switch (after[0]) {
                '>' => {},
                '/' => if (after.len > 1 and after[1] == '>') {
                    it.pos = lt + 1 + it.name.len + 2;
                    return "";
                } else continue,
                ' ', '\t', '\r', '\n' => {},
                else => continue,
            }
            const gt = std.mem.indexOfScalarPos(u8, it.xml, lt + 1 + it.name.len, '>') orelse return null;
            if (it.xml[gt - 1] == '/') {
                it.pos = gt + 1;
                return "";
            }
            const start = gt + 1;
            const end = closing(it.xml, start, it.name) orelse return null;
            it.pos = end + it.name.len + 3;
            return it.xml[start..end];
        }
        return null;
    }
};

// Index of `</name>` after `start`.
fn closing(xml: []const u8, start: usize, name: []const u8) ?usize {
    var pos = start;
    while (std.mem.indexOfPos(u8, xml, pos, "</")) |i| {
        const rest = xml[i + 2 ..];
        if (std.mem.startsWith(u8, rest, name) and rest.len > name.len and rest[name.len] == '>') return i;
        pos = i + 2;
    }
    return null;
}

// Decodes the five named entities and numeric references into a copy.
pub fn decode(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return arena.dupe(u8, raw);
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            out.appendAssumeCapacity(raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            out.appendAssumeCapacity('&');
            i += 1;
            continue;
        };
        const entity = raw[i + 1 .. semi];
        var buf: [4]u8 = undefined;
        const replacement: ?[]const u8 = if (std.mem.eql(u8, entity, "amp"))
            "&"
        else if (std.mem.eql(u8, entity, "lt"))
            "<"
        else if (std.mem.eql(u8, entity, "gt"))
            ">"
        else if (std.mem.eql(u8, entity, "quot"))
            "\""
        else if (std.mem.eql(u8, entity, "apos"))
            "'"
        else if (entity.len > 1 and entity[0] == '#') blk: {
            const cp = if (entity[1] == 'x' or entity[1] == 'X')
                std.fmt.parseInt(u21, entity[2..], 16)
            else
                std.fmt.parseInt(u21, entity[1..], 10);
            const n = std.unicode.utf8Encode(cp catch break :blk null, &buf) catch break :blk null;
            break :blk buf[0..n];
        } else null;
        if (replacement) |r| {
            out.appendSliceAssumeCapacity(r);
            i = semi + 1;
        } else {
            out.appendAssumeCapacity('&');
            i += 1;
        }
    }
    return out.items;
}

pub fn decodedText(arena: std.mem.Allocator, xml: []const u8, name: []const u8) error{OutOfMemory}!?[]const u8 {
    return try decode(arena, text(xml, name) orelse return null);
}

pub const ErrorBody = struct { code: []const u8, message: []const u8 };

// `<Error><Code>…</Code><Message>…</Message></Error>`, as Bun's `errorWithBody` reads it.
pub fn errorBody(body: []const u8) ?ErrorBody {
    const err = text(body, "Error") orelse return null;
    return .{ .code = text(err, "Code") orelse "UnknownError", .message = text(err, "Message") orelse "" };
}

// ISO 8601 as S3 lists it, e.g. `2009-10-12T17:50:30.000Z`, to Unix milliseconds.
pub fn parseIsoDate(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    if (s.len > 20 and s[19] == '.') {
        var end: usize = 20;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        const frac = s[20..@min(end, 23)];
        ms = std.fmt.parseInt(i64, frac, 10) catch 0;
        var scale = 3 - frac.len;
        while (scale > 0) : (scale -= 1) ms *= 10;
    }
    const base = unixMillis(y, mo, d, h, mi, sec) orelse return null;
    return base + ms;
}

// RFC 7231 IMF-fixdate, e.g. `Wed, 12 Oct 2009 17:50:00 GMT`, to Unix milliseconds.
pub fn parseHttpDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,");
    _ = it.next() orelse return null;
    const d = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const mon = it.next() orelse return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const time = it.next() orelse return null;
    if (time.len != 8 or time[2] != ':' or time[5] != ':') return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const mo: u8 = for (months, 1..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, mon)) break @intCast(i);
    } else return null;
    const h = std.fmt.parseInt(u8, time[0..2], 10) catch return null;
    const mi = std.fmt.parseInt(u8, time[3..5], 10) catch return null;
    const sec = std.fmt.parseInt(u8, time[6..8], 10) catch return null;
    return unixMillis(y, mo, d, h, mi, sec);
}

fn unixMillis(y: i32, mo: u8, d: u8, h: u8, mi: u8, s: u8) ?i64 {
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60) return null;
    // Days from civil, Howard Hinnant's algorithm.
    const yy: i64 = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const m: i64 = mo;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60 * 1000 + @as(i64, s) * 1000;
}
