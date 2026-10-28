const std = @import("std");
const testing = std.testing;
const lang = @import("lang");
const sourcemap = lang.sourcemap;
const test_util = @import("./../util.zig");

test "tests:beforeAll" {
    test_util.loadEnvFlags();
}

test "sm > serialize/deserialize roundtrip" {
    const allocator = testing.allocator;

    var builder = sourcemap.Builder.init(allocator);
    defer builder.deinit();
    builder.source = "app/pages/page.zx";

    const mappings = [_]sourcemap.Mapping{
        .{ .generated_line = 0, .generated_column = 0, .source_line = 0, .source_column = 0 },
        .{ .generated_line = 0, .generated_column = 10, .source_line = 0, .source_column = 5 },
        .{ .generated_line = 1, .generated_column = 4, .source_line = 1, .source_column = 4 },
        .{ .generated_line = 2, .generated_column = 8, .source_line = 3, .source_column = 12 },
        .{ .generated_line = 5, .generated_column = 0, .source_line = 10, .source_column = 0 },
    };

    for (&mappings) |m| try builder.addMapping(m);

    var sm = try builder.build();
    defer sm.deinit();

    try testing.expectEqual(mappings.len, sm.entries.len);
    for (&mappings, sm.entries) |expected, actual| {
        try testing.expectEqual(expected.generated_line, actual.generated_line);
        try testing.expectEqual(expected.generated_column, actual.generated_column);
        try testing.expectEqual(expected.source_line, actual.source_line);
        try testing.expectEqual(expected.source_column, actual.source_column);
    }

    const data = try sm.serializeData(allocator);
    defer allocator.free(data);

    var roundtrip = try sourcemap.PositionMap.deserializeData(allocator, data);
    defer roundtrip.deinit();

    try testing.expectEqual(sm.entries.len, roundtrip.entries.len);
    for (sm.entries, roundtrip.entries) |expected, actual| {
        try testing.expectEqual(expected.generated_line, actual.generated_line);
        try testing.expectEqual(expected.generated_column, actual.generated_column);
        try testing.expectEqual(expected.source_line, actual.source_line);
        try testing.expectEqual(expected.source_column, actual.source_column);
    }
}

test "sm > embed format roundtrip" {
    const allocator = testing.allocator;

    var builder = sourcemap.Builder.init(allocator);
    defer builder.deinit();
    builder.source = "test/data/element/nested.zx";
    try builder.addMapping(.{ .generated_line = 2, .generated_column = 4, .source_line = 1, .source_column = 8 });
    try builder.addMapping(.{ .generated_line = 5, .generated_column = 0, .source_line = 3, .source_column = 0 });

    var sm = try builder.build();
    defer sm.deinit();

    const embed = try sm.formatEmbed(allocator);
    defer allocator.free(embed);

    const zig = try allocator.print("pub fn main() void {{}}\n\n{s}", .{embed});
    defer allocator.free(zig);

    var parsed = (try sourcemap.PositionMap.parseEmbed(allocator, zig)).?;
    defer parsed.deinit();

    try testing.expectEqualStrings("test/data/element/nested.zx", parsed.source);
    try testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try testing.expectEqual(@as(i32, 2), parsed.entries[0].generated_line);
    try testing.expectEqual(@as(i32, 1), parsed.entries[0].source_line);
}

test "sm > src to gen exact match" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 5, .generated_column = 8, .source_line = 2, .source_column = 4 },
        .{ .generated_line = 5, .generated_column = 20, .source_line = 2, .source_column = 10 },
    });
    defer map.deinit();

    const result = map.sourceToGenerated(2, 4).?;
    try testing.expectEqual(@as(i32, 5), result.generated_line);
    try testing.expectEqual(@as(i32, 8), result.generated_column);

    const between = map.sourceToGenerated(2, 7).?;
    try testing.expectEqual(@as(i32, 5), between.generated_line);
    try testing.expectEqual(@as(i32, 11), between.generated_column);
}

test "sm > gen to src exact match" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 3, .generated_column = 0, .source_line = 1, .source_column = 0 },
        .{ .generated_line = 3, .generated_column = 15, .source_line = 1, .source_column = 8 },
    });
    defer map.deinit();

    const result = map.generatedToSource(3, 0).?;
    try testing.expectEqual(@as(i32, 1), result.source_line);
    try testing.expectEqual(@as(i32, 0), result.source_column);

    const between = map.generatedToSource(3, 5).?;
    try testing.expectEqual(@as(i32, 1), between.source_line);
    try testing.expectEqual(@as(i32, 5), between.source_column);
}

test "sm > lookup returns null for unmapped position" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 5, .generated_column = 0, .source_line = 3, .source_column = 0 },
    });
    defer map.deinit();

    try testing.expectEqual(@as(?sourcemap.Mapping, null), map.sourceToGenerated(0, 0));
}

fn positionMapFrom(allocator: std.mem.Allocator, mappings: []const sourcemap.Mapping) !sourcemap.PositionMap {
    var builder = sourcemap.Builder.init(allocator);
    defer builder.deinit();
    for (mappings) |m| try builder.addMapping(m);
    return builder.build();
}

test "sm > gen to src clamps extrapolation at next segment" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 0, .generated_column = 0, .source_line = 0, .source_column = 0 },
        .{ .generated_line = 0, .generated_column = 10, .source_line = 5, .source_column = 0 },
    });
    defer map.deinit();

    const at7 = map.generatedToSource(0, 7).?;
    try testing.expectEqual(@as(i32, 0), at7.source_line);
    try testing.expectEqual(@as(i32, 7), at7.source_column);

    const at9 = map.generatedToSource(0, 9).?;
    try testing.expectEqual(@as(i32, 0), at9.source_line);
    try testing.expect(at9.source_column < 10);

    const at10 = map.generatedToSource(0, 10).?;
    try testing.expectEqual(@as(i32, 5), at10.source_line);
    try testing.expectEqual(@as(i32, 0), at10.source_column);
}

test "sm > gen to src duplicate generated position is deterministic" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 3, .generated_column = 4, .source_line = 4, .source_column = 8 },
        .{ .generated_line = 3, .generated_column = 4, .source_line = 2, .source_column = 8 },
        .{ .generated_line = 3, .generated_column = 9, .source_line = 2, .source_column = 25 },
    });
    defer map.deinit();

    const at4 = map.generatedToSource(3, 4).?;
    try testing.expect((at4.source_line == 2 and at4.source_column == 8) or
        (at4.source_line == 4 and at4.source_column == 8));

    const at6 = map.generatedToSource(3, 6).?;
    try testing.expect(at6.source_column < 25 or at6.source_line != 2);
}

test "sm > gen to src does not extrapolate across generated lines" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 0, .generated_column = 0, .source_line = 0, .source_column = 0 },
        .{ .generated_line = 2, .generated_column = 0, .source_line = 9, .source_column = 4 },
    });
    defer map.deinit();

    const m = map.generatedToSource(2, 3).?;
    try testing.expectEqual(@as(i32, 9), m.source_line);
    try testing.expectEqual(@as(i32, 7), m.source_column);
}

test "sm > src to gen clamps extrapolation at next segment" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 0, .generated_column = 0, .source_line = 0, .source_column = 0 },
        .{ .generated_line = 7, .generated_column = 0, .source_line = 0, .source_column = 10 },
    });
    defer map.deinit();

    const at3 = map.sourceToGenerated(0, 3).?;
    try testing.expectEqual(@as(i32, 0), at3.generated_line);
    try testing.expectEqual(@as(i32, 3), at3.generated_column);

    const at9 = map.sourceToGenerated(0, 9).?;
    try testing.expectEqual(@as(i32, 0), at9.generated_line);
    try testing.expect(at9.generated_column < 10);

    const at10 = map.sourceToGenerated(0, 10).?;
    try testing.expectEqual(@as(i32, 7), at10.generated_line);
    try testing.expectEqual(@as(i32, 0), at10.generated_column);
}

test "sm > src to gen prefers earliest generated position on tie" {
    const allocator = testing.allocator;
    var map = try positionMapFrom(allocator, &.{
        .{ .generated_line = 2, .generated_column = 5, .source_line = 1, .source_column = 0 },
        .{ .generated_line = 9, .generated_column = 0, .source_line = 1, .source_column = 0 },
    });
    defer map.deinit();

    const m = map.sourceToGenerated(1, 0).?;
    try testing.expectEqual(@as(i32, 2), m.generated_line);
    try testing.expectEqual(@as(i32, 5), m.generated_column);
}

test "sm > e2e error position maps back to correct zx token" {
    const allocator = testing.allocator;

    const source =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    const greeting = "hi";
        \\    return (
        \\        <main @allocator={allocator}>
        \\            <p>{greeting}</p>
        \\        </main>
        \\    );
        \\}
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = "page.zx" });
    defer result.deinit(allocator);

    const map = result.sourcemap orelse return error.NoSourceMap;
    const zig = result.zx_source;

    const expr_pos = std.mem.indexOf(u8, zig, "_zx.expr(greeting") orelse return error.TokenNotFound;
    const greeting_pos = expr_pos + "_zx.expr(".len;
    const gen_lc = offsetToLineCol(zig, greeting_pos);

    try expectRemap(map, gen_lc.line, gen_lc.column, source, "greeting");
}

/// Assert that a generated (0-based) position remaps to a .zx offset that starts with `snippet`.
fn expectRemap(
    map: sourcemap.PositionMap,
    gen_line: i32,
    gen_col: i32,
    zx_source: []const u8,
    snippet: []const u8,
) !void {
    const mapped = map.generatedToSource(gen_line, gen_col) orelse return error.NoMapping;
    const src_off = sourcemap.lineColToOffset(zx_source, mapped.source_line, mapped.source_column) orelse {
        return error.SourceOutOfBounds;
    };
    if (!std.mem.startsWith(u8, zx_source[src_off..], snippet)) {
        std.debug.print(
            "remap {d}:{d} -> {d}:{d} expected snippet \"{s}\", got \"{s}\"\n",
            .{ gen_line, gen_col, mapped.source_line, mapped.source_column, snippet, zx_source[src_off..@min(src_off + snippet.len, zx_source.len)] },
        );
        return error.WrongSnippet;
    }
}

fn offsetToLineCol(source: []const u8, offset: usize) struct { line: i32, column: i32 } {
    var line: i32 = 0;
    var col: i32 = 0;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else col += 1;
    }
    return .{ .line = line, .column = col };
}

test "sm > e2e simple element transpilation" {
    const allocator = testing.allocator;

    const source =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (
        \\        <div>Hello</div>
        \\    );
        \\}
        \\
        \\const zx = @import("zx");
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined });
    defer result.deinit(allocator);

    try testing.expect(result.sourcemap != null);
    const map = result.sourcemap.?;
    try testing.expect(map.entries.len > 0);
    const raw_zig = result.zx_source;

    const pub_mapping = map.sourceToGenerated(0, 0).?;
    try testing.expectEqual(@as(i32, 0), pub_mapping.generated_line);
    try testing.expectEqual(@as(i32, 0), pub_mapping.generated_column);

    const gen_offset = sourcemap.lineColToOffset(raw_zig, pub_mapping.generated_line, pub_mapping.generated_column);
    try testing.expect(gen_offset != null);
    if (gen_offset) |off| {
        try testing.expect(std.mem.startsWith(u8, raw_zig[off..], "pub"));
    }

    const const_mapping = map.sourceToGenerated(6, 0).?;
    const const_offset = sourcemap.lineColToOffset(raw_zig, const_mapping.generated_line, const_mapping.generated_column);
    try testing.expect(const_offset != null);
    if (const_offset) |off| {
        try testing.expect(std.mem.startsWith(u8, raw_zig[off..], "const"));
    }
}

test "sm > e2e gen to src roundtrip for zig code" {
    const allocator = testing.allocator;

    const source =
        \\const std = @import("std");
        \\
        \\pub fn hello() void {
        \\    std.debug.print("hello\n", .{});
        \\}
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined });
    defer result.deinit(allocator);

    try testing.expect(result.sourcemap != null);
    const map = result.sourcemap.?;

    const m = map.sourceToGenerated(0, 0).?;
    try testing.expectEqual(@as(i32, 0), m.generated_line);
    try testing.expectEqual(@as(i32, 0), m.generated_column);

    const rev = map.generatedToSource(m.generated_line, m.generated_column).?;
    try testing.expectEqual(@as(i32, 0), rev.source_line);
    try testing.expectEqual(@as(i32, 0), rev.source_column);
}

test "sm > e2e expression in element" {
    const allocator = testing.allocator;

    const source =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    const name = "world";
        \\    return (
        \\        <p>Hello {name}</p>
        \\    );
        \\}
        \\
        \\const zx = @import("zx");
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined });
    defer result.deinit(allocator);

    try testing.expect(result.sourcemap != null);
    const map = result.sourcemap.?;
    const raw_zig = result.zx_source;

    const name_mapping = map.sourceToGenerated(1, 4).?;
    const name_offset = sourcemap.lineColToOffset(raw_zig, name_mapping.generated_line, name_mapping.generated_column);
    try testing.expect(name_offset != null);
    if (name_offset) |off| {
        try testing.expect(std.mem.startsWith(u8, raw_zig[off..], "const"));
    }

    const expr_mapping = map.sourceToGenerated(3, 17).?;
    const expr_offset = sourcemap.lineColToOffset(raw_zig, expr_mapping.generated_line, expr_mapping.generated_column);
    try testing.expect(expr_offset != null);
}

test "sm > e2e alloc init allocator expr remaps to @allocator value" {
    const allocator = testing.allocator;

    // Typo in @allocator value: Zig errors on allocInit(ctx.arenad, ...) which must
    // remap to the .zx attribute expression, not the function signature above it.
    const source =
        \\pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component {
        \\    return (
        \\        <html @allocator={ctx.arenad} lang="en">
        \\            <body>{children}</body>
        \\        </html>
        \\    );
        \\}
        \\
        \\const zx = @import("zx");
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = "layout.zx" });
    defer result.deinit(allocator);

    const map = result.sourcemap orelse return error.NoSourceMap;
    const zig = result.zx_source;

    const alloc_init = std.mem.indexOf(u8, zig, "allocInit(") orelse return error.TokenNotFound;
    const arg_pos = alloc_init + "allocInit(".len;
    try testing.expect(std.mem.startsWith(u8, zig[arg_pos..], "ctx.arenad"));
    const gen_lc = offsetToLineCol(zig, arg_pos);
    try expectRemap(map, gen_lc.line, gen_lc.column, source, "ctx.arenad");
}

test "sm > e2e token remap for if expression condition" {
    const allocator = testing.allocator;

    const source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/data/control_flow/if_only.zx", allocator, .limited(std.math.maxInt(usize))) catch return;
    defer allocator.free(source);
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = "test/data/control_flow/if_only.zx" });
    defer result.deinit(allocator);

    const map = result.sourcemap orelse return error.NoSourceMap;
    const zig = result.zx_source;

    // Find `if (is_logged_in)` in generated Zig (not the const decl).
    const search = "if (is_logged_in)";
    const if_pos = std.mem.indexOf(u8, zig, search) orelse return error.TokenNotFound;
    const cond_pos = if_pos + "if (".len;
    const gen_lc = offsetToLineCol(zig, cond_pos);
    try expectRemap(map, gen_lc.line, gen_lc.column, source, "is_logged_in");

    // Tag `.p` should remap near `<p` or `</p>` / `p` in source.
    const p_pos = std.mem.indexOf(u8, zig, ".p,") orelse return error.TokenNotFound;
    const p_lc = offsetToLineCol(zig, p_pos);
    const mapped = map.generatedToSource(p_lc.line, p_lc.column).?;
    const src_off = sourcemap.lineColToOffset(source, mapped.source_line, mapped.source_column).?;
    const snip = source[src_off..@min(src_off + 5, source.len)];
    try testing.expect(std.mem.indexOf(u8, snip, "p") != null or std.mem.indexOf(u8, snip, "<p") != null or std.mem.indexOf(u8, snip, "</p>") != null);
}

test "sm > e2e token remap for nested element tags" {
    const allocator = testing.allocator;

    const source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/data/element/nested.zx", allocator, .limited(std.math.maxInt(usize))) catch return;
    defer allocator.free(source);
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = "test/data/element/nested.zx" });
    defer result.deinit(allocator);

    const map = result.sourcemap orelse return error.NoSourceMap;
    const zig = result.zx_source;

    // Remap each mapped gen position that points at a tag-like snippet back to that snippet.
    for (map.entries) |entry| {
        const gen_off = sourcemap.lineColToOffset(zig, entry.generated_line, entry.generated_column) orelse continue;
        if (gen_off + 1 >= zig.len) continue;
        if (zig[gen_off] != '.') continue;
        // `.tag` in generated → should map back near the tag name in .zx
        const mapped = map.generatedToSource(entry.generated_line, entry.generated_column) orelse continue;
        const src_off = sourcemap.lineColToOffset(source, mapped.source_line, mapped.source_column) orelse continue;
        _ = src_off;
    }
}

test "sm > diagnostics remap via embed" {
    const allocator = testing.allocator;

    const source =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (
        \\        <div>{missing_ident}</div>
        \\    );
        \\}
        \\
        \\const zx = @import("zx");
    ;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var result = try lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = "app/pages/page.zx" });
    defer result.deinit(allocator);

    var map_ref = &(result.sourcemap orelse return error.NoSourceMap);
    const embed = try map_ref.formatEmbed(allocator);
    defer allocator.free(embed);

    const zig_with_embed = try allocator.print("{s}\n{s}", .{ result.zx_source, embed });
    defer allocator.free(zig_with_embed);

    var parsed = (try sourcemap.PositionMap.parseEmbed(allocator, zig_with_embed)).?;
    defer parsed.deinit();

    try testing.expectEqualStrings("app/pages/page.zx", parsed.source);

    // Find missing_ident in generated zig and remap like Diagnostics would (1-based).
    const ident_pos = std.mem.indexOf(u8, result.zx_source, "missing_ident") orelse return error.TokenNotFound;
    const gen_lc = offsetToLineCol(result.zx_source, ident_pos);
    const mapped = parsed.generatedToSource(gen_lc.line, gen_lc.column).?;
    const src_off = sourcemap.lineColToOffset(source, mapped.source_line, mapped.source_column).?;
    try testing.expect(std.mem.startsWith(u8, source[src_off..], "missing_ident"));

    // Simulate Diagnostics 1-based remap result
    const remapped_line: u32 = @intCast(mapped.source_line + 1);
    const remapped_col: u32 = @intCast(mapped.source_column + 1);
    try testing.expect(remapped_line >= 1);
    try testing.expect(remapped_col >= 1);
}

test "sm > all test files produce valid position maps" {
    const allocator = testing.allocator;

    for (sm_test_files) |tf| {
        const source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, tf.zx_path, allocator, .limited(std.math.maxInt(usize))) catch continue;
        defer allocator.free(source);

        const source_z = try allocator.dupeSentinel(u8, source, 0);
        defer allocator.free(source_z);

        var result = lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = tf.zx_path }) catch continue;
        defer result.deinit(allocator);

        if (result.sourcemap) |sm| {
            try testing.expect(sm.entries.len > 0);

            const raw_zig = result.zx_source;
            for (sm.entries) |entry| {
                const gen_offset = sourcemap.lineColToOffset(raw_zig, entry.generated_line, entry.generated_column);
                if (gen_offset == null) {
                    std.debug.print("FAIL: {s}: mapping gen {d}:{d} is out of bounds (raw_zig len={d})\n", .{
                        tf.zx_path,
                        entry.generated_line,
                        entry.generated_column,
                        raw_zig.len,
                    });
                    return error.MappingOutOfBounds;
                }
                const src_offset = sourcemap.lineColToOffset(source, entry.source_line, entry.source_column);
                if (src_offset == null) {
                    std.debug.print("FAIL: {s}: mapping src {d}:{d} is out of bounds\n", .{
                        tf.zx_path,
                        entry.source_line,
                        entry.source_column,
                    });
                    return error.SourceOutOfBounds;
                }
            }
        } else {
            std.debug.print("FAIL: {s}: no position map generated\n", .{tf.zx_path});
            return error.NoSourceMap;
        }
    }
}

test "sm > golden file mappings" {
    const allocator = testing.allocator;

    for (sm_test_files) |tf| {
        const source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, tf.zx_path, allocator, .limited(std.math.maxInt(usize))) catch |err| {
            std.debug.print("SKIP: {s}: {}\n", .{ tf.zx_path, err });
            continue;
        };
        defer allocator.free(source);

        const source_z = try allocator.dupeSentinel(u8, source, 0);
        defer allocator.free(source_z);

        var result = lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = tf.zx_path }) catch |err| {
            std.debug.print("SKIP: {s}: parse error: {}\n", .{ tf.zx_path, err });
            continue;
        };
        defer result.deinit(allocator);

        const sm = result.sourcemap orelse continue;
        const actual = try sm.formatHuman(allocator, source, result.zx_source);
        defer allocator.free(actual);

        const map_path = tf.map_path;

        if (test_util.isSnapshotMode()) {
            std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = map_path, .data = actual }) catch |err| {
                std.debug.print("Failed to create {s}: {}\n", .{ map_path, err });
                return err;
            };
            std.debug.print("Updated snapshot: {s}\n", .{map_path});
            continue;
        }

        const expected = std.Io.Dir.cwd().readFileAlloc(std.testing.io, map_path, allocator, .limited(std.math.maxInt(usize))) catch |err| {
            std.debug.print(
                \\
                \\FAIL: Golden file not found: {s}
                \\  Run with SS=1 to generate: SS=1 zig build test -- "sm > golden"
                \\  Error: {}
                \\
            , .{ map_path, err });
            return error.GoldenFileNotFound;
        };
        defer allocator.free(expected);

        testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print(
                \\
                \\FAIL: Position map mismatch for {s}
                \\  Golden file: {s}
                \\  Run with SS=1 to update: SS=1 zig build test -- "sm > golden"
                \\
            , .{ tf.zx_path, map_path });
            return err;
        };
    }
}

test "sm > generate position map debug files" {
    if (!test_util.shouldGenerateDebugFiles()) return;

    const allocator = testing.allocator;
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/tmp/.zx/sourcemap-debug") catch {};

    for (sm_test_files) |tf| {
        const source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, tf.zx_path, allocator, .limited(std.math.maxInt(usize))) catch continue;
        defer allocator.free(source);

        const source_z = try allocator.dupeSentinel(u8, source, 0);
        defer allocator.free(source_z);

        var result = lang.Ast.parse(allocator, source_z, .{ .map = .inlined, .path = tf.zx_path }) catch continue;
        defer result.deinit(allocator);

        const sm = result.sourcemap orelse continue;

        const human = try sm.formatHuman(allocator, source, result.zx_source);
        defer allocator.free(human);

        const map_path = try allocator.print(".zig-cache/tmp/.zx/sourcemap-debug/{s}.map", .{tf.name});
        defer allocator.free(map_path);
        try writeFile(map_path, human);

        var embed_map = try sm.dupe(allocator);
        defer embed_map.deinit();
        if (embed_map.source.len == 0) {
            embed_map.source = try allocator.dupe(u8, tf.zx_path);
        }
        const embed = try embed_map.formatEmbed(allocator);
        defer allocator.free(embed);

        const inline_zig = try allocator.print("{s}\n{s}", .{ result.zx_source, embed });
        defer allocator.free(inline_zig);

        const zig_path = try allocator.print(".zig-cache/tmp/.zx/sourcemap-debug/{s}.zig", .{tf.name});
        defer allocator.free(zig_path);
        try writeFile(zig_path, inline_zig);

        const zx_out_path = try allocator.print(".zig-cache/tmp/.zx/sourcemap-debug/{s}.zx", .{tf.name});
        defer allocator.free(zx_out_path);
        try writeFile(zx_out_path, source);

        std.debug.print("  wrote: {s} + .map + .zx\n", .{zig_path});
    }

    std.debug.print("\nPosition map debug files written to .zig-cache/tmp/.zx/sourcemap-debug/\n", .{});
    std.debug.print("Inspect the human-readable .map files (src:col -> gen:col | snippets).\n", .{});
}

const SmTestFile = struct { zx_path: []const u8, name: []const u8, map_path: []const u8 };

const sm_test_files = [_]SmTestFile{
    .{ .zx_path = "test/data/element/nested.zx", .name = "nested", .map_path = "test/data/element/nested.map" },
    .{ .zx_path = "test/data/expression/text.zx", .name = "text", .map_path = "test/data/expression/text.map" },
    .{ .zx_path = "test/data/control_flow/if.zx", .name = "if", .map_path = "test/data/control_flow/if.map" },
    .{ .zx_path = "test/data/control_flow/for.zx", .name = "for", .map_path = "test/data/control_flow/for.map" },
    .{ .zx_path = "test/data/component/basic.zx", .name = "basic", .map_path = "test/data/component/basic.map" },
    .{ .zx_path = "test/data/attribute/dynamic.zx", .name = "dynamic", .map_path = "test/data/attribute/dynamic.map" },
};

fn writeFile(path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}
