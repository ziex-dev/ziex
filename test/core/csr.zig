const std = @import("std");
const zx = @import("zx");
const testing = std.testing;
const test_util = @import("./../util.zig");

const VDOMTree = zx.util.vdom.VDOMTree;
const Patch = zx.util.vdom.Patch;

const ROW_COUNT: usize = 1000;
/// Multiplier over local baseline (same style as SSR perf tests).
const BUDGET_MULT: f64 = 12.0;
// Baselines (M-series, Debug): create ~3ms, update ~3ms, clear ~0.05ms, swap ~4ms, append ~7ms.

const Item = struct {
    id: u32,
    label: []const u8,
};

test "flaky: performance > csr" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const items = try buildItems(gpa, ROW_COUNT, 1);
    defer freeItems(gpa, items);

    // --- create (VDOMTree.init of full table) ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var tree = VDOMTree.init(a, root);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer tree.deinit(a);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr create > {d:.2}ms | {f} ({d} rows, ~{d} bytes)",
            .{ ms, rate, ROW_COUNT, bytes },
        );
        try expectLessThan(3.5 * BUDGET_MULT, ms);
    }

    // --- update every 10th row ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        var updated = try gpa.alloc(Item, items.len);
        defer gpa.free(updated);
        @memcpy(updated, items);
        var i: usize = 0;
        while (i < updated.len) : (i += 10) {
            updated[i].label = try a.print("{s} !!!", .{items[i].label});
        }
        const next = try buildTable(a, updated);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr update > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(4.0 * BUDGET_MULT, ms);
        try testing.expect(patches.items.len >= ROW_COUNT / 10);
    }

    // --- clear ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        const empty = try buildTable(a, &[_]Item{});
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, empty);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr clear > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(0.5 * BUDGET_MULT, ms);
        try testing.expectEqual(@as(usize, ROW_COUNT), patches.items.len);
    }

    // --- swap rows 1 and 998 ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        var swapped = try gpa.alloc(Item, items.len);
        defer gpa.free(swapped);
        @memcpy(swapped, items);
        const tmp = swapped[1];
        swapped[1] = swapped[998];
        swapped[998] = tmp;
        const next = try buildTable(a, swapped);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr swap > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(5.0 * BUDGET_MULT, ms);
        try testing.expect(patches.items.len > 0);
    }

    // --- append 1000 onto 1000 ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        const more = try buildItems(gpa, ROW_COUNT, @as(u32, @intCast(ROW_COUNT + 1)));
        defer freeItems(gpa, more);
        var combined = try gpa.alloc(Item, ROW_COUNT * 2);
        defer gpa.free(combined);
        @memcpy(combined[0..ROW_COUNT], items);
        @memcpy(combined[ROW_COUNT..], more);
        const next = try buildTable(a, combined);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(combined);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr append > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(8.0 * BUDGET_MULT, ms);
        try testing.expectEqual(@as(usize, ROW_COUNT), patches.items.len);
    }
}

const LARGE_ROW_COUNT: usize = 10_000;
// Baselines (M-series, Debug): create ~35ms, update ~35ms, clear ~0.5ms, swap ~45ms, append ~15ms.

test "flaky: performance > csr extreme" {
    if (!test_util.shouldRunSlowTest()) return;

    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const items = try buildItems(gpa, LARGE_ROW_COUNT, 1);
    defer freeItems(gpa, items);

    // --- create 10k ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var tree = VDOMTree.init(a, root);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer tree.deinit(a);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr create 10k > {d:.2}ms | {f} ({d} rows, ~{d} bytes)",
            .{ ms, rate, LARGE_ROW_COUNT, bytes },
        );
        try expectLessThan(40.0 * BUDGET_MULT, ms);
    }

    // --- update every 10th on 10k ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        var updated = try gpa.alloc(Item, items.len);
        defer gpa.free(updated);
        @memcpy(updated, items);
        var i: usize = 0;
        while (i < updated.len) : (i += 10) {
            updated[i].label = try a.print("{s} !!!", .{items[i].label});
        }
        const next = try buildTable(a, updated);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr update 10k > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(45.0 * BUDGET_MULT, ms);
        try testing.expect(patches.items.len >= LARGE_ROW_COUNT / 10);
    }

    // --- clear 10k ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        const empty = try buildTable(a, &[_]Item{});
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, empty);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr clear 10k > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(5.0 * BUDGET_MULT, ms);
        try testing.expectEqual(@as(usize, LARGE_ROW_COUNT), patches.items.len);
    }

    // --- swap on 10k ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        var swapped = try gpa.alloc(Item, items.len);
        defer gpa.free(swapped);
        @memcpy(swapped, items);
        const tmp = swapped[1];
        swapped[1] = swapped[998];
        swapped[998] = tmp;
        const next = try buildTable(a, swapped);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(items);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr swap 10k > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(55.0 * BUDGET_MULT, ms);
        try testing.expect(patches.items.len > 0);
    }

    // --- append 1k onto 10k ---
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try buildTable(a, items);
        var tree = VDOMTree.init(a, root);
        defer tree.deinit(a);

        const more = try buildItems(gpa, ROW_COUNT, @as(u32, @intCast(LARGE_ROW_COUNT + 1)));
        defer freeItems(gpa, more);
        var combined = try gpa.alloc(Item, LARGE_ROW_COUNT + ROW_COUNT);
        defer gpa.free(combined);
        @memcpy(combined[0..LARGE_ROW_COUNT], items);
        @memcpy(combined[LARGE_ROW_COUNT..], more);
        const next = try buildTable(a, combined);

        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var patches = try tree.diffWithComponent(a, next);
        const end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer deinitPatches(a, &patches);

        const elapsed_ns: u64 = @intCast(end - start);
        const ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        const bytes = approxTreeBytes(combined);
        const rate = test_util.Throughput.init(bytes, elapsed_ns);
        test_util.perf(
            "csr append 1k→10k > {d:.2}ms | {f} ({d} patches)",
            .{ ms, rate, patches.items.len },
        );
        try expectLessThan(20.0 * BUDGET_MULT, ms);
        try testing.expectEqual(@as(usize, ROW_COUNT), patches.items.len);
    }
}

fn buildItems(allocator: std.mem.Allocator, count: usize, start_id: u32) ![]Item {
    const items = try allocator.alloc(Item, count);
    errdefer allocator.free(items);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const id = start_id + @as(u32, @intCast(i));
        items[i] = .{
            .id = id,
            .label = try allocator.print("pretty yellow {d}", .{id}),
        };
    }
    return items;
}

fn freeItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |item| allocator.free(item.label);
    allocator.free(items);
}

fn approxTreeBytes(items: []const Item) u64 {
    var n: u64 = 0;
    for (items) |item| n += item.label.len + 8;
    return n;
}

/// Build `<table><tbody>{rows}</tbody></table>` with keyed `<tr>` rows
/// shaped like the js-framework-benchmark CSR page.
fn buildTable(allocator: std.mem.Allocator, items: []const Item) !zx.Component {
    const tbody_children: ?[]const zx.Component = if (items.len == 0) null else blk: {
        const rows = try allocator.alloc(zx.Component, items.len);
        for (items, 0..) |item, i| {
            rows[i] = try buildRow(allocator, item);
        }
        break :blk rows;
    };
    const tbody = zx.Component{ .element = .{
        .tag = .tbody,
        .children = tbody_children,
    } };
    const tbody_owned = try allocator.alloc(zx.Component, 1);
    tbody_owned[0] = tbody;

    return .{ .element = .{
        .tag = .table,
        .attributes = try attrs(allocator, &.{.{ "class", "table" }}),
        .children = tbody_owned,
    } };
}

fn buildRow(allocator: std.mem.Allocator, item: Item) !zx.Component {
    const id_str = try allocator.print("{d}", .{item.id});

    const id_text = try allocator.alloc(zx.Component, 1);
    id_text[0] = .{ .text = id_str };
    const td_id = zx.Component{ .element = .{
        .tag = .td,
        .attributes = try attrs(allocator, &.{.{ "class", "col-md-1" }}),
        .children = id_text,
    } };

    const label_text = try allocator.alloc(zx.Component, 1);
    label_text[0] = .{ .text = item.label };
    const a_label = zx.Component{ .element = .{
        .tag = .a,
        .children = label_text,
    } };
    const a_label_owned = try allocator.alloc(zx.Component, 1);
    a_label_owned[0] = a_label;
    const td_label = zx.Component{ .element = .{
        .tag = .td,
        .attributes = try attrs(allocator, &.{.{ "class", "col-md-4" }}),
        .children = a_label_owned,
    } };

    const span = zx.Component{ .element = .{
        .tag = .span,
        .attributes = try attrs(allocator, &.{
            .{ "class", "glyphicon glyphicon-remove" },
            .{ "aria-hidden", "true" },
        }),
    } };
    const span_owned = try allocator.alloc(zx.Component, 1);
    span_owned[0] = span;
    const a_remove = zx.Component{ .element = .{
        .tag = .a,
        .children = span_owned,
    } };
    const a_remove_owned = try allocator.alloc(zx.Component, 1);
    a_remove_owned[0] = a_remove;
    const td_remove = zx.Component{ .element = .{
        .tag = .td,
        .attributes = try attrs(allocator, &.{.{ "class", "col-md-1" }}),
        .children = a_remove_owned,
    } };

    const td_empty = zx.Component{ .element = .{
        .tag = .td,
        .attributes = try attrs(allocator, &.{.{ "class", "col-md-6" }}),
    } };

    const tr_children = try allocator.alloc(zx.Component, 4);
    tr_children[0] = td_id;
    tr_children[1] = td_label;
    tr_children[2] = td_remove;
    tr_children[3] = td_empty;

    return .{ .element = .{
        .tag = .tr,
        .attributes = try attrs(allocator, &.{
            .{ "key", id_str },
            .{ "class", "" },
        }),
        .children = tr_children,
    } };
}

fn attrs(allocator: std.mem.Allocator, pairs: []const struct { []const u8, []const u8 }) ![]zx.Element.Attribute {
    const out = try allocator.alloc(zx.Element.Attribute, pairs.len);
    for (pairs, 0..) |pair, i| {
        out[i] = .{ .name = pair[0], .value = pair[1] };
    }
    return out;
}

fn deinitPatches(allocator: std.mem.Allocator, patches: *std.ArrayList(Patch)) void {
    for (patches.items) |*patch| {
        switch (patch.data) {
            .UPDATE => |*u| {
                u.attributes.deinit();
                u.removed_attributes.deinit(allocator);
            },
            .PLACEMENT => |p| p.vnode.deinit(allocator),
            .REPLACE => |r| r.new_vnode.deinit(allocator),
            else => {},
        }
    }
    patches.deinit(allocator);
}

fn expectLessThan(expected: f64, actual: f64) !void {
    if (actual > expected) {
        std.debug.print("\x1b[31m✗\x1b[0m Expected < {d:.2}ms, got {d:.2}ms\n", .{ expected, actual });
        return error.TestExpectedLessThan;
    }
}
