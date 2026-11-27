// Hand-written text parsers and escapers.
const std = @import("std");
const zx = @import("zx");
const Smith = std.testing.Smith;
const util = @import("util.zig");

const html = zx.util.html;
const xml = zx.Bucket.S3.xml;

test "fuzz: html escape/unescape roundtrip" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const input = util.bytes(s, &buf);
            var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer w.deinit();
            var back: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer back.deinit();

            try html.escapeAttr(&w.writer, input);
            for (w.written()) |c| try std.testing.expect(std.mem.indexOfScalar(u8, "<>\"'", c) == null);
            try html.unescape(&back.writer, w.written());
            try std.testing.expectEqualSlices(u8, input, back.written());

            w.clearRetainingCapacity();
            back.clearRetainingCapacity();
            try html.escapeText(&w.writer, input);
            for (w.written()) |c| try std.testing.expect(c != '<' and c != '>');
            try html.unescape(&back.writer, w.written());
            try std.testing.expectEqualSlices(u8, input, back.written());
        }
    }.run, .{ .corpus = util.seeds(&.{ "a<b>&c", "\"'&amp;", "&lt;&#x27;&" }) });
}

test "fuzz: s3 xml decode and dates" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const input = util.bytes(s, &buf);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();

            const decoded = try xml.decode(arena.allocator(), input);
            try std.testing.expect(decoded.len <= input.len);
            _ = try xml.decodedText(arena.allocator(), input, "Key");
            _ = xml.errorBody(input);
            _ = xml.parseIsoDate(input);
            _ = xml.parseHttpDate(input);
        }
    }.run, .{ .corpus = util.seeds(&.{
        "<Error><Code>NoSuchKey</Code><Message>a &amp; b</Message></Error>",
        "<Key>a&#x1F600;&#65;&lt;</Key>",
        "2009-10-12T17:50:30.123Z",
        "Wed, 12 Oct 2009 17:50:00 GMT",
    }) });
}

test "fuzz: dotenv parse" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const input = util.bytes(s, &buf);
            var base: std.process.Environ.Map = .init(std.testing.allocator);
            defer base.deinit();
            try base.put("HOME", "/home/me");
            var map: std.process.Environ.Map = .init(std.testing.allocator);
            defer map.deinit();
            try zx.Secrets.dotenv.parse(&map, input, &base);
        }
    }.run, .{ .corpus = util.seeds(&.{
        "A=1\nexport B=\"x\\ny $A\"\nC: 'raw $A'\nD=${HOME}/x\nE=${MISSING:-dflt}\n# c\nF=`t`",
        "K=\"unterminated\nL=${A",
    }) });
}

test "fuzz: email address parse" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [256]u8 = undefined;
            const input = util.bytes(s, &buf);
            const addr = zx.Email.Address.parse(input) catch return;
            // Anything accepted must be safe to put in a header.
            for (addr.email) |c| try std.testing.expect(c > ' ' and c != 0x7f);
            if (addr.name) |n| try std.testing.expect(std.mem.indexOfAny(u8, n, "\r\n") == null);
        }
    }.run, .{ .corpus = util.seeds(&.{ "a@b.com", "Name <a@b.com>", "\"Q\" <x@y>", "<>" }) });
}

test "fuzz: route pattern matching" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var pat_buf: [128]u8 = undefined;
            var path_buf: [128]u8 = undefined;
            const alphabet: []const Smith.Weight = &.{
                .value(u8, '/', 6), .value(u8, ':', 2), .value(u8, '*', 2),
                .value(u8, 'a', 4), .value(u8, 'b', 4), .rangeAtMost(u8, 0, 255, 1),
            };
            const pattern = pat_buf[0..s.sliceWeightedBytes(&pat_buf, alphabet)];
            const path = path_buf[0..s.sliceWeightedBytes(&path_buf, alphabet)];

            var m: zx.Router.RouteMatch = .{ .route = undefined };
            _ = zx.Router.patternMatchScore(pattern);
            if (!zx.Router.tryExtractParams(pattern, path, &m)) return;
            try std.testing.expect(m.param_count <= m.params.len);
            for (m.params[0..m.param_count]) |p| {
                try std.testing.expect(std.mem.indexOfScalar(u8, p.value, '/') == null);
                try std.testing.expect(std.mem.indexOf(u8, path, p.value) != null);
            }
            // A static pattern only matches itself (modulo the edge slashes). Route
            // patterns come from the file tree, so they never contain empty segments.
            if (std.mem.indexOfAny(u8, pattern, ":*") == null and std.mem.indexOf(u8, pattern, "//") == null) {
                try std.testing.expectEqualStrings(trimOne(pattern), trimOne(path));
            }
        }

        fn trimOne(p: []const u8) []const u8 {
            var out = p;
            if (out.len > 0 and out[0] == '/') out = out[1..];
            if (out.len > 0 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
            return out;
        }
    }.run, .{});
}
