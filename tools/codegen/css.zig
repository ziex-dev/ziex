const std = @import("std");
const astgen = @import("astgen.zig");
const helper = @import("helper.zig");

const TypeMap = std.array_hash_map.String([]const u8);

const UnitSupport = struct {
    length: bool = false,
    angle: bool = false,
    time: bool = false,
    percentage: bool = false,
    color: bool = false,
    shorthand: bool = false,
};

const PropMeta = struct {
    keywords: std.array_hash_map.String([]const u8),
    units: UnitSupport,
    href: []const u8,
    prose: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    try writeFile(init.io, init.gpa, "src/style/generated.zig");
    std.debug.print("Successfully generated src/style/generated.zig using AST-Driven engine.\n", .{});
}

pub fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const source = generate(io, allocator) catch |err| {
        if (err == error.InvalidGeneratedSource) {
            // We can't easily get the raw buffer from File here without changes,
            // but we can try to catch it in generate() or just look at what's happening.
        }
        return err;
    };
    defer allocator.free(source);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, source);
}

pub fn generate(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const main_content = try std.Io.Dir.cwd().readFileAlloc(io, "vendor/webref/ed/css.json", a, .unlimited);
    const main_parsed = try std.json.parseFromSlice(std.json.Value, a, main_content, .{});
    defer main_parsed.deinit();

    const root = main_parsed.value.object;
    const properties = root.get("properties").?.array;
    const types_json = root.get("types").?.array;
    const selectors = root.get("selectors").?.array;

    var type_map: TypeMap = .empty;
    defer type_map.deinit(a);
    for (types_json.items) |t| {
        const name = t.object.get("name").?.string;
        const syntax = if (t.object.get("syntax")) |s| s.string else "";
        try type_map.put(a, name, syntax);
    }

    var prose_map = std.StringHashMap([]const u8).init(a);
    defer prose_map.deinit();
    var kw_prose_map = std.StringHashMap(std.StringHashMap([]const u8)).init(a);
    defer kw_prose_map.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, "vendor/webref/ed/css/", .{ .iterate = true });
    defer dir.close(io);
    var dir_it = dir.iterate();
    while (try dir_it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const fc = try dir.readFileAlloc(io, entry.name, a, .unlimited);
        const p = std.json.parseFromSlice(std.json.Value, a, fc, .{}) catch continue;
        defer p.deinit();
        if (p.value.object.get("properties")) |props| {
            for (props.array.items) |prop| {
                const name = prop.object.get("name").?.string;
                if (prop.object.get("prose")) |pr| {
                    if (!prose_map.contains(name)) try prose_map.put(name, pr.string);
                }
                if (prop.object.get("values")) |vals| {
                    var kmap = kw_prose_map.get(name) orelse std.StringHashMap([]const u8).init(a);
                    for (vals.array.items) |val| {
                        const kname = val.object.get("name").?.string;
                        if (val.object.get("prose")) |pr| {
                            if (!kmap.contains(kname)) try kmap.put(kname, pr.string);
                        }
                    }
                    try kw_prose_map.put(name, kmap);
                }
            }
        }
    }

    var prop_data: std.array_hash_map.String(PropMeta) = .empty;
    defer prop_data.deinit(a);
    for (properties.items) |prop| {
        const name = prop.object.get("name").?.string;
        const syntax = if (prop.object.get("syntax")) |s| s.string else "";
        const href = if (prop.object.get("href")) |h| h.string else "";
        var keywords: std.array_hash_map.String([]const u8) = .empty;
        try keywords.put(a, "none", "");
        const globals = [_][]const u8{ "inherit", "initial", "revert", "revert-layer", "unset" };
        for (globals) |g| {
            if (!keywords.contains(g)) try keywords.put(a, g, "");
        }
        var units = UnitSupport{};
        try resolveMetaEnriched(a, syntax, &type_map, &keywords, &units, 0, kw_prose_map.get(name));
        try prop_data.put(a, name, .{ .keywords = keywords, .units = units, .href = href, .prose = prose_map.get(name) orelse "" });
    }

    var file = astgen.File.init(allocator);
    defer file.deinit();
    const fa = file.arena.allocator();

    try file.addRaw("//! Generated from @webref/css (W3C Specifications)\n//! Do not edit manually.");
    try file.addImport("std", "std");
    try file.addImport("core", "core.zig");
    try file.addRaw(try helper.calcExprSource(fa));
    _ = try file.addConst("CssColor", "", "core.Color");

    var prop_it = prop_data.iterator();
    while (prop_it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const data = entry.value_ptr.*;
        const type_name_raw = try cleanName(a, prop_name, .pascal);
        const final_type_name = if (std.mem.eql(u8, type_name_raw, "Color")) "CssColor" else type_name_raw;

        if (std.mem.eql(u8, final_type_name, "CssColor")) continue;

        const prop_doc = try docText(fa, prop_name, data.prose, data.href);
        const prop_union = try file.addUnion(final_type_name, "enum");
        try prop_union.setDoc(fa, prop_doc);

        var tags: std.array_hash_map.String(void) = .empty;
        var k_it = data.keywords.iterator();
        while (k_it.next()) |k_entry| {
            const clean_kw = try cleanName(a, k_entry.key_ptr.*, .snake);
            if (clean_kw.len > 0 and !tags.contains(clean_kw)) {
                const kw_doc = if (k_entry.value_ptr.*.len > 0) try docText(fa, null, k_entry.value_ptr.*, null) else "";
                try prop_union.addField(fa, kw_doc, clean_kw, "", null);
                try tags.put(a, clean_kw, {});
            }
        }

        if (data.units.length) {
            try prop_union.addField(fa, "", "px_", "[4]f32", null);
            try prop_union.addField(fa, "", "em_", "[4]f32", null);
            try prop_union.addField(fa, "", "rem_", "[4]f32", null);
            try prop_union.addField(fa, "", "vh_", "f32", null);
            try prop_union.addField(fa, "", "vw_", "f32", null);
            try prop_union.addField(fa, "", "vmin_", "f32", null);
            try prop_union.addField(fa, "", "vmax_", "f32", null);
        }
        if (data.units.percentage) try prop_union.addField(fa, "", "percent_", "[4]f32", null);
        if (data.units.color) try prop_union.addField(fa, "", "hex_", "u32", null);
        const has_calc = data.units.length or data.units.percentage or data.units.angle or data.units.time;
        if (has_calc) {
            try prop_union.addField(fa, "", "calc_", "CalcExpr", null);
            const calc_sig = try fa.print("(expr: CalcExpr) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "calc", calc_sig, "return .{ .calc_ = expr };");
        }

        if (data.units.length) {
            const px_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "px", px_sig, "return .{ .px_ = .{ v, v, v, v } };");

            const px2_sig = try fa.print("(v1: f32, v2: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "px2", px2_sig, "return .{ .px_ = .{ v1, v2, v1, v2 } };");

            const px4_sig = try fa.print("(v1: f32, v2: f32, v3: f32, v4: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "px4", px4_sig, "return .{ .px_ = .{ v1, v2, v3, v4 } };");

            const em_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "em", em_sig, "return .{ .em_ = .{ v, v, v, v } };");

            const em2_sig = try fa.print("(v1: f32, v2: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "em2", em2_sig, "return .{ .em_ = .{ v1, v2, v1, v2 } };");

            const rem_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "rem", rem_sig, "return .{ .rem_ = .{ v, v, v, v } };");

            const rem2_sig = try fa.print("(v1: f32, v2: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "rem2", rem2_sig, "return .{ .rem_ = .{ v1, v2, v1, v2 } };");

            const vh_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "vh", vh_sig, "return .{ .vh_ = v };");

            const vw_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "vw", vw_sig, "return .{ .vw_ = v };");

            const vmin_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "vmin", vmin_sig, "return .{ .vmin_ = v };");

            const vmax_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "vmax", vmax_sig, "return .{ .vmax_ = v };");
        }
        if (data.units.percentage) {
            const pct_sig = try fa.print("(v: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "percent", pct_sig, "return .{ .percent_ = .{ v, v, v, v } };");

            const pct2_sig = try fa.print("(v1: f32, v2: f32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "percent2", pct2_sig, "return .{ .percent_ = .{ v1, v2, v1, v2 } };");
        }
        if (data.units.color) {
            const hex_sig = try fa.print("(v: u32) {s}", .{final_type_name});
            _ = try prop_union.addMethod(fa, "", "hex", hex_sig, "return .{ .hex_ = v };");
        }

        const format_sig = try fa.print("(self: {s}, w: anytype) std.Io.Writer.Error!void", .{final_type_name});
        _ = try prop_union.addMethod(fa, "", "format", format_sig, "return core.formatValue(self, w);");
    }

    const style_struct = try file.addStruct("Style");
    for (properties.items) |prop| {
        const name = prop.object.get("name").?.string;
        const type_name_raw = try cleanName(a, name, .pascal);
        const final_type_name = if (std.mem.eql(u8, type_name_raw, "Color")) "CssColor" else type_name_raw;
        const clean_p = try cleanName(a, name, .snake);
        if (clean_p.len == 0) continue;
        try style_struct.addField(fa, "", clean_p, final_type_name, ".none");
    }

    var selector_tags: std.array_hash_map.String(void) = .empty;
    defer selector_tags.deinit(a);
    for (selectors.items) |sel| {
        const name = sel.object.get("name").?.string;
        if (std.mem.indexOf(u8, name, "(") != null) continue;
        const clean_s = try cleanName(a, name, .snake);
        if (clean_s.len == 0) continue;
        if (selector_tags.contains(clean_s)) continue;

        var is_duplicate = false;
        var p_it = prop_data.iterator();
        while (p_it.next()) |p_entry| {
            const p_clean = try cleanName(a, p_entry.key_ptr.*, .snake);
            if (std.mem.eql(u8, p_clean, clean_s)) {
                is_duplicate = true;
                break;
            }
        }
        if (is_duplicate) continue;

        try selector_tags.put(a, clean_s, {});
        try style_struct.addField(fa, "", clean_s, "?*const Style", "null");
    }

    try style_struct.addField(fa, "", "sm", "?*const Style", "null");
    try style_struct.addField(fa, "", "md", "?*const Style", "null");
    try style_struct.addField(fa, "", "lg", "?*const Style", "null");
    try style_struct.addField(fa, "", "xl", "?*const Style", "null");
    try style_struct.addField(fa, "", "extra", "?[]const u8", "null");

    _ = try style_struct.addMethod(fa, "", "format", "(self: Style, w: anytype) std.Io.Writer.Error!void",
        \\inline for (std.meta.fieldNames(Style)) |field_name| {
        \\    try @import("core.zig").formatProperty(field_name, @field(self, field_name), w);
        \\}
    );

    // Compatibility exports
    _ = try file.addConst("Calc", "", "CalcExpr");
    _ = try file.addConst("StyleUnit", "", "core.Unit");
    _ = try file.addConst("StyleDimension", "", "core.Dimension");
    _ = try file.addConst("StyleColor", "", "core.Color");

    return try file.finish();
}

fn cleanName(allocator: std.mem.Allocator, name: []const u8, case: enum { pascal, camel, snake }) ![]const u8 {
    if (name.len == 0) return "";
    var start: usize = 0;
    while (start < name.len and (name[start] == '-' or name[start] == ':')) : (start += 1) {}
    if (start >= name.len) return "";

    if (!std.ascii.isAlphabetic(name[start]) and !std.ascii.isDigit(name[start])) {
        return "";
    }

    var list: std.ArrayList(u8) = .empty;
    var next_upper = (case == .pascal);

    for (name[start..]) |c| {
        if (c == '-' or c == ':') {
            if (case == .snake) {
                try list.append(allocator, '_');
            } else {
                next_upper = true;
            }
        } else {
            if (next_upper) {
                try list.append(allocator, std.ascii.toUpper(c));
                next_upper = false;
            } else {
                try list.append(allocator, c);
            }
        }
    }
    const result = try list.toOwnedSlice(allocator);
    if (std.ascii.isDigit(result[0])) {
        return try std.mem.concat(allocator, u8, &.{ "_", result });
    }
    if (isZigKeyword(result) or std.mem.eql(u8, result, "add") or std.mem.eql(u8, result, "sub") or std.mem.eql(u8, result, "mul") or std.mem.eql(u8, result, "div")) {
        return try std.mem.concat(allocator, u8, &.{ result, "_" });
    }
    return result;
}

fn resolveMetaEnriched(allocator: std.mem.Allocator, syntax: []const u8, type_map: *TypeMap, keywords: *std.array_hash_map.String([]const u8), units: *UnitSupport, depth: usize, kprose: ?std.StringHashMap([]const u8)) !void {
    if (depth > 10) return;

    const is_shorthand = std.mem.indexOf(u8, syntax, "{1,4}") != null or std.mem.indexOf(u8, syntax, "{1,2}") != null;
    if (is_shorthand) units.shorthand = true;

    var it = std.mem.tokenizeAny(u8, syntax, " |[]\t\r\n&");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        var cleaned = token;
        if (std.mem.indexOfAny(u8, cleaned, "+*?#{")) |idx| cleaned = cleaned[0..idx];
        if (cleaned.len == 0) continue;

        if (std.mem.startsWith(u8, cleaned, "<'")) {
            const ref_name = cleaned[2 .. cleaned.len - 2];
            if (std.mem.indexOf(u8, ref_name, "padding") != null or
                std.mem.indexOf(u8, ref_name, "margin") != null or
                std.mem.indexOf(u8, ref_name, "border") != null)
            {
                units.length = true;
            }
            continue;
        }

        if (std.mem.startsWith(u8, cleaned, "<")) {
            var type_name = cleaned[1..];
            if (std.mem.indexOfAny(u8, type_name, ">[ ")) |idx| type_name = type_name[0..idx];
            if (std.mem.endsWith(u8, type_name, ">")) type_name = type_name[0 .. type_name.len - 1];

            const is_length = std.mem.indexOf(u8, type_name, "length") != null;
            const is_percent = std.mem.indexOf(u8, type_name, "percentage") != null;

            if (is_length) units.length = true;
            if (is_percent) units.percentage = true;
            if (std.mem.indexOf(u8, type_name, "angle") != null) units.angle = true;
            if (std.mem.indexOf(u8, type_name, "time") != null) units.time = true;
            if (std.mem.indexOf(u8, type_name, "color") != null) units.color = true;

            if (type_map.get(type_name)) |sub_syntax| try resolveMetaEnriched(allocator, sub_syntax, type_map, keywords, units, depth + 1, kprose);
            continue;
        }

        var is_valid = true;
        if (!std.ascii.isAlphabetic(cleaned[0]) and cleaned[0] != '-' and cleaned[0] != '_') {
            if (cleaned.len == 1 and std.ascii.isDigit(cleaned[0])) {} else is_valid = false;
        }
        if (is_valid) {
            for (cleaned) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                    is_valid = false;
                    break;
                }
            }
        }
        if (is_valid and cleaned.len > 0 and !keywords.contains(cleaned)) {
            const pr = blk: {
                if (kprose) |kp| if (kp.get(cleaned)) |p| break :blk p;
                if (std.mem.eql(u8, cleaned, "inherit")) break :blk "The inherit CSS keyword causes the element to take the computed value of the property from its parent element.";
                if (std.mem.eql(u8, cleaned, "initial")) break :blk "The initial CSS keyword applies the initial (or default) value of a property to an element.";
                if (std.mem.eql(u8, cleaned, "unset")) break :blk "The unset CSS keyword resets a property to its inherited value if the property naturally inherits from its parent, and to its initial value otherwise.";
                break :blk "";
            };
            try keywords.put(allocator, try allocator.dupe(u8, cleaned), try allocator.dupe(u8, pr));
        }
    }
}

fn docText(allocator: std.mem.Allocator, title: ?[]const u8, prose: []const u8, href: ?[]const u8) ![]const u8 {
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    const w = &list.writer;
    var first = true;
    if (title) |t| {
        try w.print("{s}", .{t});
        first = false;
    }
    if (prose.len > 0) {
        if (!first) try w.writeAll("\n\n");
        try w.writeAll(prose);
        first = false;
    }
    if (href) |h| {
        if (!first) try w.writeAll("\n\n");
        try w.print("- **W3C**: {s}", .{h});
    }
    return try allocator.dupe(u8, list.written());
}

fn isZigKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace", "align",       "and",   "asm",    "async",       "await",          "break",     "catch",    "comptime",
        "const",     "continue",    "defer", "else",   "enum",        "errdefer",       "error",     "export",   "extern",
        "fn",        "for",         "if",    "inline", "noalias",     "noinline",       "nosuspend", "opaque",   "or",
        "orelse",    "packed",      "pub",   "resume", "return",      "linksection",    "struct",    "suspend",  "switch",
        "test",      "threadlocal", "try",   "union",  "unreachable", "usingnamespace", "var",       "volatile", "while",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}
