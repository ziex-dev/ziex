const std = @import("std");

pub const Unit = enum {
    px,
    em,
    rem,
    vh,
    vw,
    vmin,
    vmax,
    @"%",
    pt,
    pc,
    in,
    cm,
    mm,
    deg,
    rad,
    grad,
    turn,
    s,
    ms,
    Hz,
    kHz,
    dpi,
    dpcm,
    dppx,

    pub fn toString(self: Unit) []const u8 {
        return switch (self) {
            .@"%" => "%",
            else => @tagName(self),
        };
    }
};

pub const Dimension = struct {
    value: f32,
    unit: Unit,
};

pub const Color = union(enum) {
    none,
    hex_: u32,
    rgb_: struct { r: u8, g: u8, b: u8 },
    rgba_: struct { r: u8, g: u8, b: u8, a: f32 },
    keyword_: []const u8,

    pub fn hex(val: u32) Color {
        return .{ .hex_ = val };
    }
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb_ = .{ .r = r, .g = g, .b = b } };
    }
    pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
        return .{ .rgba_ = .{ .r = r, .g = g, .b = b, .a = a } };
    }
    pub fn kw(k: []const u8) Color {
        return .{ .keyword_ = k };
    }

    pub fn format(self: Color, w: anytype) std.Io.Writer.Error!void {
        switch (self) {
            .none => {},
            .hex_ => |h| try w.print("#{x:0>6}", .{h}),
            .keyword_ => |k| try w.writeAll(k),
            .rgb_ => |c| try w.print("rgb({d},{d},{d})", .{ c.r, c.g, c.b }),
            .rgba_ => |c| try w.print("rgba({d},{d},{d},{d})", .{ c.r, c.g, c.b, c.a }),
        }
    }
};

pub fn formatKebab(name: []const u8, w: anytype) std.Io.Writer.Error!void {
    const prefixes = [_][]const u8{ "webkit", "moz", "ms", "apple", "epub", "hp", "atsc", "rim", "ro", "tc", "xhtml" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p) and name.len > p.len and (name[p.len] == '_' or std.ascii.isUpper(name[p.len]))) {
            try w.writeByte('-');
            break;
        }
    }

    for (name, 0..) |c, i| {
        if (c == '_') {
            if (i == name.len - 1) continue; // Skip trailing _ (Zig keyword escape)
            try w.writeByte('-');
        } else if (std.ascii.isUpper(c)) {
            try w.writeByte('-');
            try w.writeByte(std.ascii.toLower(c));
        } else {
            try w.writeByte(c);
        }
    }
}

fn formatShorthand(v: [4]f32, unit: []const u8, w: anytype) std.Io.Writer.Error!void {
    if (v[0] == v[1] and v[1] == v[2] and v[2] == v[3]) {
        try w.print("{d}{s}", .{ v[0], unit });
    } else if (v[0] == v[2] and v[1] == v[3]) {
        try w.print("{d}{s} {d}{s}", .{ v[0], unit, v[1], unit });
    } else {
        try w.print("{d}{s} {d}{s} {d}{s} {d}{s}", .{ v[0], unit, v[1], unit, v[2], unit, v[3], unit });
    }
}

pub fn formatValue(value: anytype, w: anytype) std.Io.Writer.Error!void {
    @setEvalBranchQuota(100000);
    const T = @TypeOf(value);
    const ti = @typeInfo(T);

    if (ti == .pointer) {
        if (ti.pointer.size == .slice) {
            // Strings/slices
            if (T == []const u8 or T == []u8) {
                try w.writeAll(value);
                return;
            }
        } else {
            return formatValue(value.*, w);
        }
    }

    if (ti == .optional) {
        if (value) |v| return formatValue(v, w);
        return;
    }

    if (ti == .@"union") {
        const info = ti.@"union";
        const tag = @as(info.tag_type.?, value);

        if (comptime @hasField(info.tag_type.?, "none")) {
            if (tag == .none) return;
        }

        inline for (
            comptime info.field_names,
        ) |field_name| {
            if (tag == @field(info.tag_type.?, field_name)) {
                if (comptime std.mem.eql(u8, field_name, "hex_")) {
                    try w.print("#{x:0>6}", .{@field(value, field_name)});
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "raw_")) {
                    try w.writeAll(@field(value, field_name));
                    return;
                }

                if (comptime std.mem.eql(u8, field_name, "percent_")) {
                    try formatShorthand(@field(value, field_name), "%", w);
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "px_")) {
                    try formatShorthand(@field(value, field_name), "px", w);
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "em_")) {
                    try formatShorthand(@field(value, field_name), "em", w);
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "rem_")) {
                    try formatShorthand(@field(value, field_name), "rem", w);
                    return;
                }

                if (comptime std.mem.eql(u8, field_name, "calc_")) {
                    try w.writeAll("calc(");
                    try @field(value, field_name).format(w);
                    try w.writeAll(")");
                    return;
                }

                if (comptime std.mem.eql(u8, field_name, "vh_")) {
                    try w.print("{d}vh", .{@field(value, field_name)});
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "vw_")) {
                    try w.print("{d}vw", .{@field(value, field_name)});
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "vmin_")) {
                    try w.print("{d}vmin", .{@field(value, field_name)});
                    return;
                }
                if (comptime std.mem.eql(u8, field_name, "vmax_")) {
                    try w.print("{d}vmax", .{@field(value, field_name)});
                    return;
                }

                // Keywords
                try formatKebab(field_name, w);
                return;
            }
        }
    }
}

pub fn formatProperty(name: []const u8, val: anytype, w: anytype) std.Io.Writer.Error!void {
    @setEvalBranchQuota(100000);
    const T = @TypeOf(val);
    const ti = @typeInfo(T);

    if (ti == .optional) {
        if (val) |v| return formatProperty(name, v, w);
        return;
    }

    if (ti == .pointer) {
        if (ti.pointer.size == .one) {
            // Check if child has format (like nested Style)
            if (comptime @hasDecl(ti.pointer.child, "format")) {
                try formatKebab(name, w);
                try w.writeAll(" { ");
                try val.format(w);
                try w.writeAll("} ");
                return;
            }
            return formatProperty(name, val.*, w);
        }
    }

    // Check if it's .none
    if (ti == .@"union") {
        const info = ti.@"union";
        if (comptime @hasField(info.tag_type.?, "none")) {
            if (val == .none) return;
        }
    }

    if (std.mem.eql(u8, name, "extra")) {
        if (comptime T == []const u8 or T == []u8) {
            try w.writeAll(val);
        } else if (comptime T == ?[]const u8 or T == ?[]u8) {
            if (val) |v| try w.writeAll(v);
        }
        return;
    }

    try formatKebab(name, w);
    try w.writeAll(": ");
    switch (ti) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (comptime @hasDecl(T, "format")) {
                try val.format(w);
            } else {
                try formatValue(val, w);
            }
        },
        else => try formatValue(val, w),
    }
    try w.writeAll("; ");
}
