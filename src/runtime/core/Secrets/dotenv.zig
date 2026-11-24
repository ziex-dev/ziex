// `.env` parser, ported from Bun's env_loader.zig.
const std = @import("std");

const Map = std.process.Environ.Map;

// Parses `src` into `map`; later keys override earlier ones. `$NAME`, `${NAME}` and
// `${NAME:-default}` in unquoted and double-quoted values resolve from `base`, then `map`.
pub fn parse(map: *Map, src: []const u8, base: ?*const Map) !void {
    const gpa = map.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(gpa);

    var p: Parser = .{ .src = src };
    while (p.pos < src.len) {
        const key = p.key() orelse {
            p.skipLine();
            continue;
        };
        raw.clearRetainingCapacity();
        const quote = try p.value(gpa, &raw);

        var value = raw.items;
        if (quote != '\'' and std.mem.findScalar(u8, value, '$') != null) {
            expanded.clearRetainingCapacity();
            try expand(gpa, &expanded, value, map, base);
            value = expanded.items;
        }
        try map.put(key, value);
    }
}

const whitespace = " \t\x0B\x0C\r\n";
const blank = " \t";

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn skip(p: *Parser, chars: []const u8) usize {
        const start = p.pos;
        while (p.pos < p.src.len and std.mem.findScalar(u8, chars, p.src[p.pos]) != null) p.pos += 1;
        return p.pos - start;
    }

    fn skipLine(p: *Parser) void {
        p.pos = if (std.mem.findAnyPos(u8, p.src, p.pos, "\r\n")) |i| i + 1 else p.src.len;
    }

    fn word(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) switch (p.src[p.pos]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => break,
        };
        return p.src[start..p.pos];
    }

    // `KEY=`, `KEY: ` or `export KEY=`; null rewinds so the line can be skipped.
    fn key(p: *Parser) ?[]const u8 {
        _ = p.skip(whitespace);
        const start = p.pos;
        var name = p.word();
        if (std.mem.eql(u8, name, "export") and p.skip(blank) > 0) {
            const next = p.word();
            if (next.len > 0) name = next;
        }
        _ = p.skip(blank);
        if (name.len > 0 and p.pos < p.src.len) switch (p.src[p.pos]) {
            '=' => {
                p.pos += 1;
                return name;
            },
            ':' => if (p.pos + 1 < p.src.len and isBlank(p.src[p.pos + 1])) {
                p.pos += 2;
                return name;
            },
            else => {},
        };
        p.pos = start;
        return null;
    }

    // Appends the decoded value to `out`; returns its quote, or 0 when unquoted.
    fn value(p: *Parser, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !u8 {
        _ = p.skip(blank);
        if (p.pos < p.src.len) switch (p.src[p.pos]) {
            inline '"', '\'', '`' => |q| if (p.quoted(q)) |inner| {
                try unescape(gpa, out, inner, q);
                return q;
            },
            else => {},
        };
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) switch (p.src[p.pos]) {
            '\r', '\n' => break,
            '#' => if (p.pos == start or isBlank(p.src[p.pos - 1])) break,
            else => {},
        };
        try out.appendSlice(gpa, std.mem.trim(u8, p.src[start..p.pos], blank));
        return 0;
    }

    // Text between matching quotes, if only blanks or a comment follow on that line.
    fn quoted(p: *Parser, q: u8) ?[]const u8 {
        var i = p.pos + 1;
        while (i < p.src.len) : (i += 1) {
            if (p.src[i] == '\\') {
                i += 1;
                continue;
            }
            if (p.src[i] != q) continue;
            var end = i + 1;
            while (end < p.src.len and isBlank(p.src[end])) end += 1;
            if (end == p.src.len or std.mem.findScalar(u8, "#\r\n", p.src[end]) != null) {
                const inner = p.src[p.pos + 1 .. i];
                p.pos = end;
                return inner;
            }
        }
        return null;
    }
};

fn unescape(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, q: u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\r' => if (i + 1 >= s.len or s[i + 1] != '\n') try out.append(gpa, '\n'),
        '\\' => if (q == '"' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.append(gpa, '\n'),
                'r' => try out.append(gpa, '\r'),
                't' => try out.append(gpa, '\t'),
                '"', '\\' => |c| try out.append(gpa, c),
                else => |c| try out.appendSlice(gpa, &.{ '\\', c }),
            }
        } else try out.append(gpa, '\\'),
        else => |c| try out.append(gpa, c),
    };
}

fn expand(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, map: *const Map, base: ?*const Map) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '$') {
            try out.append(gpa, '$');
            i += 2;
            continue;
        }
        if (s[i] != '$') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }

        const braced = i + 1 < s.len and s[i + 1] == '{';
        var end = i + 1 + @intFromBool(braced);
        const name_start = end;
        while (end < s.len) : (end += 1) switch (s[end]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => break,
        };
        const name = s[name_start..end];
        if (name.len == 0) {
            try out.append(gpa, '$');
            i += 1;
            continue;
        }

        var fallback: []const u8 = "";
        if (braced) {
            if (std.mem.startsWith(u8, s[end..], ":-")) {
                const start = end + 2;
                end = std.mem.findScalarPos(u8, s, start, '}') orelse s.len;
                fallback = s[start..end];
            }
            if (end < s.len and s[end] == '}') end += 1;
        }

        const found = (if (base) |b| b.get(name) else null) orelse map.get(name) orelse "";
        try out.appendSlice(gpa, if (found.len > 0) found else fallback);
        i = end;
    }
}
