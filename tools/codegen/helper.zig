const std = @import("std");

pub fn calcExprSource(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8,
        \\pub const CalcExpr = struct {
        \\    const Self = @This();
        \\    pub const Unit = enum {
        \\        px,
        \\        em,
        \\        rem,
        \\        percent,
        \\        pub fn toString(self: Unit) []const u8 {
        \\            return switch (self) {
        \\                .percent => "%",
        \\                else => @tagName(self),
        \\            };
        \\        }
        \\    };
        \\
        \\    pub const Op = enum {
        \\        add,
        \\        sub,
        \\        mul,
        \\        div,
        \\        pub fn toString(self: Op) []const u8 {
        \\            return switch (self) {
        \\                .add => "+",
        \\                .sub => "-",
        \\                .mul => "*",
        \\                .div => "/",
        \\            };
        \\        }
        \\    };
        \\
        \\    buf: [64]u8 = undefined,
        \\    len: u8 = 0,
        \\
        \\    fn init(t: []const u8) Self {
        \\        var self: Self = undefined;
        \\        if (t.len > self.buf.len) @panic("calc expression too complex");
        \\        @memmove(self.buf[0..t.len], t);
        \\        self.len = @intCast(t.len);
        \\        return self;
        \\    }
        \\
        \\    fn text(self: *const Self) []const u8 {
        \\        return self.buf[0..self.len];
        \\    }
        \\
        \\    fn leaf(value: []const u8) Self {
        \\        return Self.init(value);
        \\    }
        \\
        \\    fn unitLeaf(unit: Unit, value: f32) Self {
        \\        var temp: [64]u8 = undefined;
        \\        const written = std.mem.print(&temp, "{d}{s}", .{ value, unit.toString() }) catch @panic("calc expression too complex");
        \\        return Self.leaf(written);
        \\    }
        \\
        \\    fn numberLeaf(value: f32) Self {
        \\        var temp: [64]u8 = undefined;
        \\        const written = std.mem.print(&temp, "{d}", .{value}) catch @panic("calc expression too complex");
        \\        return Self.leaf(written);
        \\    }
        \\
        \\    fn rawLeaf(value: []const u8) Self {
        \\        return Self.leaf(value);
        \\    }
        \\
        \\    pub fn px(value: f32) Self {
        \\        return Self.unitLeaf(.px, value);
        \\    }
        \\
        \\    pub fn em(value: f32) Self {
        \\        return Self.unitLeaf(.em, value);
        \\    }
        \\
        \\    pub fn rem(value: f32) Self {
        \\        return Self.unitLeaf(.rem, value);
        \\    }
        \\
        \\    pub fn percent(value: f32) Self {
        \\        return Self.unitLeaf(.percent, value);
        \\    }
        \\
        \\    pub fn raw(value: []const u8) Self {
        \\        return Self.rawLeaf(value);
        \\    }
        \\
        \\    pub fn number(value: f32) Self {
        \\        return Self.numberLeaf(value);
        \\    }
        \\
        \\    fn combine(self: Self, other: Self, op: Op) Self {
        \\        var temp: [128]u8 = undefined;
        \\        const lhs = self.text();
        \\        const rhs = other.text();
        \\        const op_text = op.toString();
        \\        const needed = lhs.len + rhs.len + op_text.len + 4;
        \\        if (needed > temp.len) @panic("calc expression too complex");
        \\
        \\        var i: usize = 0;
        \\        temp[i] = '(';
        \\        i += 1;
        \\        @memmove(temp[i..][0..lhs.len], lhs);
        \\        i += lhs.len;
        \\        temp[i] = ' ';
        \\        i += 1;
        \\        @memmove(temp[i..][0..op_text.len], op_text);
        \\        i += op_text.len;
        \\        temp[i] = ' ';
        \\        i += 1;
        \\        @memmove(temp[i..][0..rhs.len], rhs);
        \\        i += rhs.len;
        \\        temp[i] = ')';
        \\        i += 1;
        \\
        \\        return Self.init(temp[0..i]);
        \\    }
        \\
        \\    pub fn add(self: Self, other: Self) Self {
        \\        return self.combine(other, .add);
        \\    }
        \\
        \\    pub fn sub(self: Self, other: Self) Self {
        \\        return self.combine(other, .sub);
        \\    }
        \\
        \\    pub fn mul(self: Self, factor: f32) Self {
        \\        return self.combine(Self.numberLeaf(factor), .mul);
        \\    }
        \\
        \\    pub fn div(self: Self, factor: f32) Self {
        \\        return self.combine(Self.numberLeaf(factor), .div);
        \\    }
        \\
        \\    pub fn format(self: *const Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        \\        try w.writeAll(self.text());
        \\    }
        \\};
    );
}
