const std = @import("std");

// A fuzzer-chosen byte string, at most `buf.len` long.
pub fn bytes(s: *std.testing.Smith, buf: []u8) []u8 {
    return buf[0..s.slice(buf)];
}

// Corpus entry for a test whose first draw is `bytes`: Smith reads a u32 LE length prefix.
pub inline fn seed(comptime s: []const u8) []const u8 {
    comptime {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, s.len, .little);
        const out = len ++ s[0..s.len].*;
        return &out;
    }
}

pub inline fn seeds(comptime list: []const []const u8) []const []const u8 {
    comptime {
        var out: [list.len][]const u8 = undefined;
        for (list, &out) |s, *o| o.* = seed(s);
        const final = out;
        return &final;
    }
}
