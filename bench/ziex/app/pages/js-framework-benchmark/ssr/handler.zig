const std = @import("std");
const zx = @import("zx");
const root_mod = @import("lib/root.zig");
const data = root_mod.data;

pub const Row = data.Row;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var rows: std.ArrayList(Row) = .empty;
var selected_id: ?usize = null;
var mutex = std.Io.Mutex.init;

pub const BenchState = struct {
    rows: std.ArrayList(Row),
    selected_id: ?usize,
};

fn clearRows() void {
    for (rows.items) |row| {
        row.deinit(arena.allocator());
    }
    rows.clearRetainingCapacity();
    selected_id = null;
    // data.resetIdCounter();
}

fn createRows(count: usize, clear_first: bool) void {
    std.debug.print("createRows: count={d}, clear_first={}\n", .{ count, clear_first });
    if (clear_first) clearRows();
    var new_rows = data.buildData(arena.allocator(), count) catch @panic("OOM");
    rows.appendSlice(arena.allocator(), new_rows.items) catch @panic("OOM");
    new_rows.deinit(arena.allocator());
}

fn redirect(ctx: zx.PageContext) void {
    ctx.response.headers.set("Location", "/js-framework-benchmark/ssr");
    ctx.response.setStatus(.found);
}

pub fn handleRequest(ctx: zx.PageContext) BenchState {
    const io = zx.Io.default();
    // Add CORS headers to allow requests from the benchmark server
    ctx.response.headers.set("Access-Control-Allow-Origin", "*");
    ctx.response.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    ctx.response.headers.set("Access-Control-Allow-Headers", "Content-Type");

    const qs = ctx.request.query;

    const action = qs.get("action");
    if (action) |a| {
        std.debug.print("Action: {s}\n", .{a});
    }
    const select_id_str = qs.get("select");
    const remove_id_str = qs.get("remove");
    const api_mode = qs.get("api"); // Check if this is an API call

    mutex.lock(io) catch {};
    defer mutex.unlock(io);

    if (ctx.request.method == .OPTIONS) {
        return BenchState{
            .rows = .empty,
            .selected_id = null,
        };
    }

    var should_redirect = false;

    if (action) |act| {
        should_redirect = true;
        if (std.mem.eql(u8, act, "run")) createRows(1000, true) else if (std.mem.eql(u8, act, "runlots")) createRows(10000, true) else if (std.mem.eql(u8, act, "add")) createRows(1000, false) else if (std.mem.eql(u8, act, "update")) handleUpdate() else if (std.mem.eql(u8, act, "clear")) clearRows() else if (std.mem.eql(u8, act, "swaprows")) handleSwapRows() else if (std.mem.eql(u8, act, "reset")) {
            clearRows();
            data.resetIdCounter();
        }
    } else if (select_id_str) |id_str| {
        selected_id = std.fmt.parseInt(usize, id_str, 10) catch 0;
        should_redirect = true;
    } else if (remove_id_str) |id_str| {
        handleRemove(std.fmt.parseInt(usize, id_str, 10) catch 0);
        should_redirect = true;
    }

    // Don't redirect if api=1 is set (for AJAX requests)
    if (should_redirect and api_mode == null) redirect(ctx);

    // Copy current state for rendering
    var rows_copy = std.ArrayList(Row).empty;
    for (rows.items) |row| {
        const label_copy = ctx.arena.dupe(u8, row.label) catch @panic("OOM");
        rows_copy.append(ctx.arena, Row{ .id = row.id, .label = label_copy }) catch @panic("OOM");
    }

    return BenchState{
        .rows = rows_copy,
        .selected_id = selected_id,
    };
}

fn handleUpdate() void {
    // Update every 10th row
    var i: usize = 0;
    while (i < rows.items.len) : (i += 10) {
        const old_label = rows.items[i].label;
        const new_label = arena.allocator().print("{s} !!!", .{old_label}) catch @panic("OOM");
        arena.allocator().free(old_label);
        rows.items[i].label = new_label;
    }
}

fn handleSwapRows() void {
    // Swap rows 1 and 998
    if (rows.items.len > 998) {
        const tmp = rows.items[1];
        rows.items[1] = rows.items[998];
        rows.items[998] = tmp;
    }
}

fn handleRemove(id: usize) void {
    // Find and remove row with given id
    for (rows.items, 0..) |row, idx| {
        if (row.id == id) {
            row.deinit(arena.allocator());
            _ = rows.orderedRemove(idx);
            if (selected_id != null and selected_id.? == id) {
                selected_id = null;
            }
            break;
        }
    }
}
