const std = @import("std");
const data = @import("data.zig");

// Global state to store current rows
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub var rows: std.ArrayList(data.Row) = undefined;
pub var mutex = std.Thread.Mutex{};

pub fn init() !void {
    rows = std.ArrayList(data.Row).initCapacity(arena.allocator(), 0) catch |err| {
        return err;
    };
}

pub fn renderRows(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    var html = std.ArrayList(u8).init(allocator);
    errdefer html.deinit();

    for (rows.items) |row| {
        try html.writer().print(
            \\<tr data-id="{d}">
            \\  <td class="col-md-1">{d}</td>
            \\  <td class="col-md-4">
            \\    <a class="select-link">{s}</a>
            \\  </td>
            \\  <td class="col-md-1">
            \\    <a class="remove-link">
            \\      <span class="glyphicon glyphicon-remove" aria-hidden="true"></span>
            \\    </a>
            \\  </td>
            \\  <td class="col-md-6"></td>
            \\</tr>
            \\
        , .{ row.id, row.id, row.label });
    }

    return html.toOwnedSlice();
}

pub fn run(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Clear existing rows
    for (rows.items) |row| {
        row.deinit(arena.allocator());
    }
    rows.clearRetainingCapacity();

    // Create 1000 rows
    const new_rows = try data.buildData(arena.allocator(), 1000);
    try rows.appendSlice(new_rows.items);
    new_rows.deinit();

    return try renderRows(allocator);
}

pub fn runLots(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Clear existing rows
    for (rows.items) |row| {
        row.deinit(arena.allocator());
    }
    rows.clearRetainingCapacity();

    // Create 10000 rows
    const new_rows = try data.buildData(arena.allocator(), 10000);
    try rows.appendSlice(new_rows.items);
    new_rows.deinit();

    return try renderRows(allocator);
}

pub fn add(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Append 1000 rows
    const new_rows = try data.buildData(arena.allocator(), 1000);
    try rows.appendSlice(new_rows.items);
    new_rows.deinit();

    return try renderRows(allocator);
}

pub fn update(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Update every 10th row
    var i: usize = 0;
    while (i < rows.items.len) : (i += 10) {
        const old_label = rows.items[i].label;
        const new_label = try arena.allocator().print("{s} !!!", .{old_label});
        arena.allocator().free(old_label);
        rows.items[i].label = new_label;
    }

    return try renderRows(allocator);
}

pub fn clear(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Clear all rows
    for (rows.items) |row| {
        row.deinit(arena.allocator());
    }
    rows.clearRetainingCapacity();

    return try renderRows(allocator);
}

pub fn swapRows(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();

    // Swap rows 1 and 998
    if (rows.items.len > 998) {
        const tmp = rows.items[1];
        rows.items[1] = rows.items[998];
        rows.items[998] = tmp;
    }

    return try renderRows(allocator);
}

pub fn remove(_: std.mem.Allocator, id: usize) !void {
    mutex.lock();
    defer mutex.unlock();

    // Find and remove row with given id
    for (rows.items, 0..) |row, idx| {
        if (row.id == id) {
            row.deinit(arena.allocator());
            _ = rows.orderedRemove(idx);
            break;
        }
    }
}
