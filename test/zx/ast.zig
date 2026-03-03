test "tests:beforeAll" {
    gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.?.allocator();
    test_file_cache = try TestFileCache.init(gpa);
}

test "tests:afterAll" {
    if (test_file_cache) |*cache| {
        cache.deinit();
        test_file_cache = null;
    }
    if (gpa_state) |*gpa| {
        _ = gpa.deinit();
        gpa_state = null;
    }
}

// Control Flow
// === If ===
test "if" {
    try test_transpile("control_flow/if");
    try test_render("control_flow/if", @import("./../data/control_flow/if.zig").Page);
}
test "if_error" {
    try test_transpile("control_flow/if_error");
    try test_render("control_flow/if_error", @import("./../data/control_flow/if_error.zig").Page);
}
test "if_block" {
    try test_transpile("control_flow/if_block");
    try test_render("control_flow/if_block", @import("./../data/control_flow/if_block.zig").Page);
}
test "if_if_only" {
    try test_transpile("control_flow/if_if_only");
    try test_render("control_flow/if_if_only", @import("./../data/control_flow/if_if_only.zig").Page);
}
test "if_if_only_block" {
    try test_transpile("control_flow/if_if_only_block");
    try test_render("control_flow/if_if_only_block", @import("./../data/control_flow/if_if_only_block.zig").Page);
}
test "if_only" {
    try test_transpile("control_flow/if_only");
    try test_render("control_flow/if_only", @import("./../data/control_flow/if_only.zig").Page);
}
test "if_only_block" {
    try test_transpile("control_flow/if_only_block");
    try test_render("control_flow/if_only_block", @import("./../data/control_flow/if_only_block.zig").Page);
}
test "if_while" {
    try test_transpile("control_flow/if_while");
    try test_render("control_flow/if_while", @import("./../data/control_flow/if_while.zig").Page);
}
test "if_if" {
    try test_transpile("control_flow/if_if");
    try test_render("control_flow/if_if", @import("./../data/control_flow/if_if.zig").Page);
}
test "if_for" {
    try test_transpile("control_flow/if_for");
    try test_render("control_flow/if_for", @import("./../data/control_flow/if_for.zig").Page);
}
test "if_switch" {
    try test_transpile("control_flow/if_switch");
    try test_render("control_flow/if_switch", @import("./../data/control_flow/if_switch.zig").Page);
}
test "if_else_if" {
    try test_transpile("control_flow/if_else_if");
    try test_render("control_flow/if_else_if", @import("./../data/control_flow/if_else_if.zig").Page);
}
test "if_capture" {
    try test_transpile("control_flow/if_capture");
    try test_render("control_flow/if_capture", @import("./../data/control_flow/if_capture.zig").Page);
}

// === For ===
test "for" {
    try test_transpile("control_flow/for");
    try test_render("control_flow/for", @import("./../data/control_flow/for.zig").Page);
}
test "for_capture" {
    try test_render("control_flow/for_capture", @import("./../data/control_flow/for.zig").StructCapture);
}
test "for_range" {
    try test_transpile("control_flow/for_range");
    try test_render("control_flow/for_range", @import("./../data/control_flow/for_range.zig").Page);
}
test "for_extra_capture" {
    try test_render("control_flow/for_extra_capture", @import("./../data/control_flow/for.zig").StructExtraCapture);
}
test "for_complex_param" {
    try test_render("control_flow/for_complex_param", @import("./../data/control_flow/for.zig").StructComplexParam);
}
test "for_capture_to_component" {
    try test_render("control_flow/for_capture_to_component", @import("./../data/control_flow/for.zig").StructCaptureToComponent);
}
test "for_block" {
    try test_transpile("control_flow/for_block");
    try test_render("control_flow/for_block", @import("./../data/control_flow/for_block.zig").Page);
}
test "for_if" {
    try test_transpile("control_flow/for_if");
    try test_render("control_flow/for_if", @import("./../data/control_flow/for_if.zig").Page);
}
test "for_for" {
    try test_transpile("control_flow/for_for");
    try test_render("control_flow/for_for", @import("./../data/control_flow/for_for.zig").Page);
}
test "for_switch" {
    try test_transpile("control_flow/for_switch");
    try test_render("control_flow/for_switch", @import("./../data/control_flow/for_switch.zig").Page);
}
test "for_while" {
    try test_transpile("control_flow/for_while");
    try test_render("control_flow/for_while", @import("./../data/control_flow/for_while.zig").Page);
}

// === Switch ===
test "switch" {
    try test_transpile("control_flow/switch");
    try test_render("control_flow/switch", @import("./../data/control_flow/switch.zig").Page);
}

test "switch_capture" {
    try test_transpile("control_flow/switch_capture");
    try test_render("control_flow/switch_capture", @import("./../data/control_flow/switch_capture.zig").Page);
}

test "switch_multicaseval" {
    try test_transpile("control_flow/switch_multicaseval");
    try test_render("control_flow/switch_multicaseval", @import("./../data/control_flow/switch_multicaseval.zig").Page);
}

test "switch_caseranges" {
    try test_transpile("control_flow/switch_caseranges");
    try test_render("control_flow/switch_caseranges", @import("./../data/control_flow/switch_caseranges.zig").Page);
}

test "switch_block" {
    try test_transpile("control_flow/switch_block");
    try test_render("control_flow/switch_block", @import("./../data/control_flow/switch_block.zig").Page);
}
test "switch_if" {
    try test_transpile("control_flow/switch_if");
    try test_render("control_flow/switch_if", @import("./../data/control_flow/switch_if.zig").Page);
}
test "switch_for" {
    try test_transpile("control_flow/switch_for");
    try test_render("control_flow/switch_for", @import("./../data/control_flow/switch_for.zig").Page);
}
test "switch_switch" {
    try test_transpile("control_flow/switch_switch");
    try test_render("control_flow/switch_switch", @import("./../data/control_flow/switch_switch.zig").Page);
}
test "switch_while" {
    try test_transpile("control_flow/switch_while");
    try test_render("control_flow/switch_while", @import("./../data/control_flow/switch_while.zig").Page);
}

// === While ===
test "while" {
    try test_transpile("control_flow/while");
    try test_render("control_flow/while", @import("./../data/control_flow/while.zig").Page);
}
test "while_block" {
    try test_transpile("control_flow/while_block");
    try test_render("control_flow/while_block", @import("./../data/control_flow/while_block.zig").Page);
}
test "while_while" {
    try test_transpile("control_flow/while_while");
    try test_render("control_flow/while_while", @import("./../data/control_flow/while_while.zig").Page);
}
test "while_if" {
    try test_transpile("control_flow/while_if");
    try test_render("control_flow/while_if", @import("./../data/control_flow/while_if.zig").Page);
}
test "while_for" {
    try test_transpile("control_flow/while_for");
    try test_render("control_flow/while_for", @import("./../data/control_flow/while_for.zig").Page);
}
test "while_switch" {
    try test_transpile("control_flow/while_switch");
    try test_render("control_flow/while_switch", @import("./../data/control_flow/while_switch.zig").Page);
}
test "while_capture" {
    try test_transpile("control_flow/while_capture");
    try test_render("control_flow/while_capture", @import("./../data/control_flow/while_capture.zig").Page);
}
test "while_else" {
    try test_transpile("control_flow/while_else");
    try test_render("control_flow/while_else", @import("./../data/control_flow/while_else.zig").Page);
}
test "while_error" {
    try test_transpile("control_flow/while_error");
    try test_render("control_flow/while_error", @import("./../data/control_flow/while_error.zig").Page);
}

// === Deeply Nested Control Flow (3-level) ===
test "if_for_if" {
    try test_transpile("control_flow/if_for_if");
    try test_render("control_flow/if_for_if", @import("./../data/control_flow/if_for_if.zig").Page);
}

test "if_while_if" {
    try test_transpile("control_flow/if_while_if");
    try test_render("control_flow/if_while_if", @import("./../data/control_flow/if_while_if.zig").Page);
}

// === Miscellaneous ===
test "attribute_builtin" {
    try test_transpile("attribute/builtin");
    try test_render("attribute/builtin", @import("./../data/attribute/builtin.zig").Page);
}
test "attribute_component" {
    try test_transpile("attribute/component");
    try test_render("attribute/component", @import("./../data/attribute/component.zig").Page);
}
test "attribute_builtin_escaping" {
    try test_transpile("attribute/builtin_escaping");
    try test_render("attribute/builtin_escaping", @import("./../data/attribute/builtin_escaping.zig").Page);
}
test "attribute_dynamic" {
    try test_transpile("attribute/dynamic");
    try test_render("attribute/dynamic", @import("./../data/attribute/dynamic.zig").Page);
}
test "attribute_types" {
    try test_transpile("attribute/types");
    try test_render("attribute/types", @import("./../data/attribute/types.zig").Page);
}
test "attribute_shorthand" {
    try test_transpile("attribute/shorthand");
    try test_render("attribute/shorthand", @import("./../data/attribute/shorthand.zig").Page);
}
test "attribute_spread" {
    try test_transpile("attribute/spread");
    try test_render("attribute/spread", @import("./../data/attribute/spread.zig").Page);
}
test "attribute_event_handler" {
    try test_transpile("attribute/event_handler");
    try test_render("attribute/event_handler", @import("./../data/attribute/event_handler.zig").Page);
}

// === Element ===
test "element_void" {
    try test_transpile("element/void");
    try test_render("element/void", @import("./../data/element/void.zig").Page);
}
test "element_empty" {
    try test_transpile("element/empty");
    try test_render("element/empty", @import("./../data/element/empty.zig").Page);
}
test "element_nested" {
    try test_transpile("element/nested");
    try test_render("element/nested", @import("./../data/element/nested.zig").Page);
}
test "element_fragment" {
    try test_transpile("element/fragment");
    try test_render("element/fragment", @import("./../data/element/fragment.zig").Page);
}
test "element_fragment_root" {
    try test_transpile("element/fragment_root");
    try test_render("element/fragment_root", @import("./../data/element/fragment_root.zig").Page);
}

test "escaping_pre" {
    try test_transpile("escaping/pre");
    try test_render("escaping/pre", @import("./../data/escaping/pre.zig").Page);
}
test "escaping_quotes" {
    try test_transpile("escaping/quotes");
    try test_render("escaping/quotes", @import("./../data/escaping/quotes.zig").Page);
}

test "expression_text" {
    try test_transpile("expression/text");
    try test_render("expression/text", @import("./../data/expression/text.zig").Page);
}
test "expression_format" {
    try test_transpile("expression/format");
    try test_render("expression/format", @import("./../data/expression/format.zig").Page);
}
test "expression_template" {
    try test_transpile("expression/template");
    try test_render("expression/template", @import("./../data/expression/template.zig").Page);
}
test "expression_component" {
    try test_transpile("expression/component");
    try test_render("expression/component", @import("./../data/expression/component.zig").Page);
}
test "expression_mixed" {
    try test_transpile("expression/mixed");
    try test_render("expression/mixed", @import("./../data/expression/mixed.zig").Page);
}
test "expression_optional" {
    try test_transpile("expression/optional");
    try test_render("expression/optional", @import("./../data/expression/optional.zig").Page);
}
test "expression_struct_access" {
    try test_transpile("expression/struct_access");
    try test_render("expression/struct_access", @import("./../data/expression/struct_access.zig").Page);
}
test "expression_function_call" {
    try test_transpile("expression/function_call");
    try test_render("expression/function_call", @import("./../data/expression/function_call.zig").Page);
}

test "expression_multiline_string" {
    try test_transpile("expression/multiline_string");
    try test_render("expression/multiline_string", @import("./../data/expression/multiline_string.zig").Page);
}

test "component_basic" {
    try test_transpile("component/basic");
    try test_render("component/basic", @import("./../data/component/basic.zig").Page);
}
test "component_namespace" {
    try test_transpile("component/namespace");
    try test_render("component/namespace", @import("./../data/component/namespace.zig").Page);
}
test "component_multiple" {
    try test_transpile("component/multiple");
    try test_render("component/multiple", @import("./../data/component/multiple.zig").Page);
}
test "component_nested" {
    try test_transpile("component/nested");
    try test_render("component/nested", @import("./../data/component/nested.zig").Page);
}
test "component_children_only" {
    try test_transpile("component/children_only");
    try test_render("component/children_only", @import("./../data/component/children_only.zig").Page);
}
test "component_contexted" {
    try test_transpile("component/contexted");
    try test_render("component/contexted", @import("./../data/component/contexted.zig").Page);
}
test "component_contexted_props" {
    try test_transpile("component/contexted_props");
    try test_render("component/contexted_props", @import("./../data/component/contexted_props.zig").Page);
}
test "component_csr_react" {
    try test_transpile("component/react");
    try test_render("component/react", @import("./../data/component/react.zig").Page);
}
test "component_csr_react_multiple" {
    try test_transpile("component/csr_react_multiple");
    try test_render("component/csr_react_multiple", @import("./../data/component/csr_react_multiple.zig").Page);
}

test "component_csr_zig" {
    try test_transpile("component/csr_zig");
    try test_render("component/csr_zig", @import("./../data/component/csr_zig.zig").Page);
}

test "component_import" {
    try test_transpile("component/import");
    try test_render("component/import", @import("./../data/component/import.zig").Page);
}

test "component_root_cmp" {
    try test_transpile("component/root_cmp");
    try test_render("component/root_cmp", @import("./../data/component/root_cmp.zig").Page);
}

test "component_caching" {
    try test_transpile("component/caching");
    try test_render("component/caching", @import("./../data/component/caching.zig").Page);
}

test "component_optional" {
    try test_transpile("component/optional");
    try test_render("component/optional", @import("./../data/component/optional.zig").Page);
}

test "component_csr_zig_props" {
    try test_transpile("component/csr_zig_props");
    try test_render("component/csr_zig_props", @import("./../data/component/csr_zig_props.zig").Page);
}

test "component_error" {
    try test_transpile("component/error_component");
    try test_render("component/error_component", @import("./../data/component/error_component.zig").Page);
}

test "component_optional_error" {
    try test_transpile("component/optional_error");
    try test_render("component/optional_error", @import("./../data/component/optional_error.zig").Page);
}

test "flaky: performance > transpile" {
    if (!test_util.shouldRunSlowTest()) return;
    const MAX_TIME_MS = 50.0 * 9; // 50ms is on M1 Pro
    const MAX_TIME_PER_FILE_MS = 8.0 * 10; // 5ms is on M1 Pro

    var total_time_ns: f64 = 0.0;
    inline for (TestFileCache.test_files) |comptime_path| {
        const start_time = std.time.nanoTimestamp();
        try test_transpile_inner(comptime_path, true);
        const end_time = std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(end_time - start_time));
        total_time_ns += duration;
        const duration_ms = duration / std.time.ns_per_ms;
        try expectLessThan(MAX_TIME_PER_FILE_MS, duration_ms);
    }

    const total_time_ms = total_time_ns / std.time.ns_per_ms;
    const average_time_ms = total_time_ms / TestFileCache.test_files.len;
    std.debug.print("\x1b[33m⏲\x1b[0m ast \x1b[90m>\x1b[0m {d:.2}ms | Avg: {d:.2}ms\n", .{ total_time_ms, average_time_ms });

    try expectLessThan(MAX_TIME_MS, total_time_ms);
    try expectLessThan(MAX_TIME_PER_FILE_MS, average_time_ms);
}

test "flaky: performance > render" {
    const MAX_TIME_MS = 5.0 * 8; // 3.5ms is on M1 Pro
    const MAX_TIME_PER_FILE_MS = 0.10 * 10; // 0.06ms is on M1 Pro

    var total_time_ns: f64 = 0.0;
    inline for (TestFileCache.test_files) |comptime_path| {
        const start_time = std.time.nanoTimestamp();
        try test_render_inner(comptime_path, true);
        const end_time = std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(end_time - start_time));
        total_time_ns += duration;
        const duration_ms = duration / std.time.ns_per_ms;
        try expectLessThan(MAX_TIME_PER_FILE_MS, duration_ms);
    }

    const total_time_ms = total_time_ns / std.time.ns_per_ms;
    const average_time_ms = total_time_ms / TestFileCache.test_files.len;
    std.debug.print("\x1b[33m⏲\x1b[0m render \x1b[90m>\x1b[0m {d:.2}ms | Avg: {d:.2}ms\n", .{ total_time_ms, average_time_ms });

    try expectLessThan(MAX_TIME_MS, total_time_ms);
    try expectLessThan(MAX_TIME_PER_FILE_MS, average_time_ms);
}

fn test_transpile(comptime file_path: []const u8) !void {
    try test_transpile_inner(file_path, false);
}

fn test_transpile_inner(comptime file_path: []const u8, comptime no_expect: bool) !void {
    const allocator = std.testing.allocator;
    const cache = if (test_file_cache) |*c| c else return error.CacheNotInitialized;

    // Construct paths for .zx and .zig files
    const source_path = file_path ++ ".zx";
    const expected_source_path = file_path ++ ".zig";
    const full_file_path = "test/data/" ++ file_path ++ ".zx";
    const output_zig_path = "test/data/" ++ file_path ++ ".zig";

    // Get pre-loaded source file
    const source = try cache.get(source_path) orelse return error.FileNotFound;
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse and transpile with file path for Client support
    var result = try zx.Ast.parse(allocator, source_z, .{ .path = full_file_path });
    defer result.deinit(allocator);

    // Check for SNAPSHOT=1 environment variable
    if (isSnapshotMode()) {
        // Save the transpiled output to .zig file
        const file = std.fs.cwd().createFile(output_zig_path, .{}) catch |err| {
            std.log.err("Failed to create snapshot file {s}: {}\n", .{ output_zig_path, err });
            return err;
        };
        defer file.close();
        file.writeAll(result.zig_source) catch |err| {
            std.log.err("Failed to write snapshot file {s}: {}\n", .{ output_zig_path, err });
            return err;
        };
        return; // Skip comparison in snapshot mode
    }

    // Get pre-loaded expected file
    const expected_source = try cache.get(expected_source_path) orelse {
        std.log.err("Expected file not found: {s}\n", .{expected_source_path});
        return error.FileNotFound;
    };
    const expected_source_z = try allocator.dupeZ(u8, expected_source);
    defer allocator.free(expected_source_z);

    if (!no_expect) {
        // try testing.expectEqualStrings(expected_source_z, result.zig_source);
        try testing.expectEqualStrings(expected_source_z, result.zig_source);
    }
}

fn test_render(comptime file_path: []const u8, comptime cmp: fn (allocator: std.mem.Allocator) zx.Component) !void {
    try test_render_inner_with_cmp(file_path, cmp, false);
}

fn test_render_inner(comptime file_path: []const u8, comptime no_expect: bool) !void {
    const cmp_opt = comptime getPageFn(file_path);
    if (cmp_opt) |cmp| {
        try test_render_inner_with_cmp(file_path, cmp, no_expect);
    }
}

fn getPageFn(comptime path: []const u8) ?fn (std.mem.Allocator) zx.Component {
    const imports = .{
        .{ "control_flow/if", @import("./../data/control_flow/if.zig") },
        .{ "control_flow/if_block", @import("./../data/control_flow/if_block.zig") },
        .{ "control_flow/if_only", @import("./../data/control_flow/if_only.zig") },
        .{ "control_flow/if_only_block", @import("./../data/control_flow/if_only_block.zig") },
        .{ "control_flow/for", @import("./../data/control_flow/for.zig") },
        .{ "control_flow/for_block", @import("./../data/control_flow/for_block.zig") },
        .{ "control_flow/switch", @import("./../data/control_flow/switch.zig") },
        .{ "control_flow/switch_capture", @import("./../data/control_flow/switch_capture.zig") },
        .{ "control_flow/for_range", @import("./../data/control_flow/for_range.zig") },
        .{ "control_flow/switch_multicaseval", @import("./../data/control_flow/switch_multicaseval.zig") },
        .{ "control_flow/switch_block", @import("./../data/control_flow/switch_block.zig") },
        .{ "control_flow/while", @import("./../data/control_flow/while.zig") },
        .{ "control_flow/while_block", @import("./../data/control_flow/while_block.zig") },
        .{ "control_flow/while_capture", @import("./../data/control_flow/while_capture.zig") },
        .{ "control_flow/while_else", @import("./../data/control_flow/while_else.zig") },
        .{ "control_flow/while_error", @import("./../data/control_flow/while_error.zig") },
        .{ "control_flow/if_if", @import("./../data/control_flow/if_if.zig") },
        .{ "control_flow/if_for", @import("./../data/control_flow/if_for.zig") },
        .{ "control_flow/if_switch", @import("./../data/control_flow/if_switch.zig") },
        .{ "control_flow/if_while", @import("./../data/control_flow/if_while.zig") },
        .{ "control_flow/if_if_only", @import("./../data/control_flow/if_if_only.zig") },
        .{ "control_flow/if_if_only_block", @import("./../data/control_flow/if_if_only_block.zig") },
        .{ "control_flow/if_else_if", @import("./../data/control_flow/if_else_if.zig") },
        .{ "control_flow/if_capture", @import("./../data/control_flow/if_capture.zig") },
        .{ "control_flow/if_error", @import("./../data/control_flow/if_error.zig") },
        .{ "control_flow/for_if", @import("./../data/control_flow/for_if.zig") },
        .{ "control_flow/for_for", @import("./../data/control_flow/for_for.zig") },
        .{ "control_flow/for_switch", @import("./../data/control_flow/for_switch.zig") },
        .{ "control_flow/for_while", @import("./../data/control_flow/for_while.zig") },
        .{ "control_flow/switch_if", @import("./../data/control_flow/switch_if.zig") },
        .{ "control_flow/switch_for", @import("./../data/control_flow/switch_for.zig") },
        .{ "control_flow/switch_switch", @import("./../data/control_flow/switch_switch.zig") },
        .{ "control_flow/switch_while", @import("./../data/control_flow/switch_while.zig") },
        .{ "control_flow/switch_caseranges", @import("./../data/control_flow/switch_caseranges.zig") },
        .{ "control_flow/while_if", @import("./../data/control_flow/while_if.zig") },
        .{ "control_flow/while_for", @import("./../data/control_flow/while_for.zig") },
        .{ "control_flow/while_switch", @import("./../data/control_flow/while_switch.zig") },
        .{ "control_flow/while_while", @import("./../data/control_flow/while_while.zig") },
        .{ "control_flow/if_for_if", @import("./../data/control_flow/if_for_if.zig") },
        .{ "expression/text", @import("./../data/expression/text.zig") },
        .{ "expression/format", @import("./../data/expression/format.zig") },
        .{ "expression/component", @import("./../data/expression/component.zig") },
        .{ "expression/mixed", @import("./../data/expression/mixed.zig") },
        .{ "expression/struct_access", @import("./../data/expression/struct_access.zig") },
        .{ "expression/function_call", @import("./../data/expression/function_call.zig") },
        .{ "expression/multiline_string", @import("./../data/expression/multiline_string.zig") },
        .{ "expression/optional", @import("./../data/expression/optional.zig") },
        .{ "expression/template", @import("./../data/expression/template.zig") },
        .{ "component/basic", @import("./../data/component/basic.zig") },
        .{ "component/namespace", @import("./../data/component/namespace.zig") },
        .{ "component/multiple", @import("./../data/component/multiple.zig") },
        .{ "component/nested", @import("./../data/component/nested.zig") },
        .{ "component/children_only", @import("./../data/component/children_only.zig") },
        .{ "component/contexted", @import("./../data/component/contexted.zig") },
        .{ "component/contexted_props", @import("./../data/component/contexted_props.zig") },
        .{ "component/react", @import("./../data/component/react.zig") },
        .{ "component/csr_react_multiple", @import("./../data/component/csr_react_multiple.zig") },
        .{ "component/csr_zig", @import("./../data/component/csr_zig.zig") },
        .{ "component/import", @import("./../data/component/import.zig") },
        .{ "component/root_cmp", @import("./../data/component/root_cmp.zig") },
        .{ "component/caching", @import("./../data/component/caching.zig") },
        .{ "component/optional", @import("./../data/component/optional.zig") },
        .{ "attribute/builtin", @import("./../data/attribute/builtin.zig") },
        .{ "attribute/component", @import("./../data/attribute/component.zig") },
        .{ "attribute/builtin_escaping", @import("./../data/attribute/builtin_escaping.zig") },
        .{ "attribute/dynamic", @import("./../data/attribute/dynamic.zig") },
        .{ "attribute/types", @import("./../data/attribute/types.zig") },
        .{ "attribute/shorthand", @import("./../data/attribute/shorthand.zig") },
        .{ "attribute/spread", @import("./../data/attribute/spread.zig") },
        .{ "element/void", @import("./../data/element/void.zig") },
        .{ "element/empty", @import("./../data/element/empty.zig") },
        .{ "element/nested", @import("./../data/element/nested.zig") },
        .{ "element/fragment", @import("./../data/element/fragment.zig") },
        .{ "element/fragment_root", @import("./../data/element/fragment_root.zig") },
        .{ "escaping/pre", @import("./../data/escaping/pre.zig") },
        .{ "escaping/quotes", @import("./../data/escaping/quotes.zig") },
        .{ "control_flow/if_while_if", @import("./../data/control_flow/if_while_if.zig") },
        .{ "attribute/event_handler", @import("./../data/attribute/event_handler.zig") },
        .{ "component/csr_zig_props", @import("./../data/component/csr_zig_props.zig") },
        .{ "component/error_component", @import("./../data/component/error_component.zig") },
        .{ "component/optional_error", @import("./../data/component/optional_error.zig") },
    };

    inline for (imports) |entry| {
        if (std.mem.eql(u8, entry[0], path)) {
            return entry[1].Page;
        }
    }
    return null;
}

fn test_render_inner_with_cmp(comptime file_path: []const u8, comptime cmp: fn (allocator: std.mem.Allocator) zx.Component, comptime no_expect: bool) !void {
    const gpa = std.testing.allocator;
    var aa = std.heap.ArenaAllocator.init(gpa);
    defer aa.deinit();
    const allocator = aa.allocator();

    const component = cmp(allocator);
    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try component.render(&aw.writer);
    const rendered = aw.written();
    try testing.expect(rendered.len > 0);

    if (no_expect) return;

    const html_path = "test/data/" ++ file_path ++ ".html";

    // Check for SNAPSHOT=1 environment variable
    if (isSnapshotMode()) {
        // Save the rendered output to .html file
        const file = std.fs.cwd().createFile(html_path, .{}) catch |err| {
            std.log.err("Failed to create snapshot file {s}: {}\n", .{ html_path, err });
            return err;
        };
        defer file.close();
        file.writeAll(rendered) catch |err| {
            std.log.err("Failed to write snapshot file {s}: {}\n", .{ html_path, err });
            return err;
        };
        return; // Skip comparison in snapshot mode
    }

    // Read expected HTML file directly
    const expected_html = std.fs.cwd().readFileAlloc(allocator, html_path, std.math.maxInt(usize)) catch |err| {
        std.log.err("Expected HTML file not found: {s}\n", .{html_path});
        return err;
    };

    try testing.expectEqualStrings(expected_html, rendered);
}

fn expectLessThan(expected: f64, actual: f64) !void {
    if (actual > expected) {
        std.debug.print("\x1b[31m✗\x1b[0m Expected < {d:.2}ms, got {d:.2}ms\n", .{ expected, actual });
        return error.TestExpectedLessThan;
    }
}

fn isSnapshotMode() bool {
    // Cross-platform environment variable check
    if (native_os == .windows) {
        const val = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("SS"));
        return val != null;
    } else {
        return std.posix.getenv("SS") != null;
    }
}

var test_file_cache: ?TestFileCache = null;
var gpa_state: ?std.heap.GeneralPurposeAllocator(.{}) = null;

const native_os = @import("builtin").os.tag;
const test_util = @import("./../test_util.zig");
const TestFileCache = test_util.TestFileCache;

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
