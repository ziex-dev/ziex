const std = @import("std");
const builtin = @import("builtin");

const jetzig = @import("jetzig");
const zmd = @import("zmd");

pub const routes = @import("routes");
pub const static = @import("static");

pub fn init(app: *jetzig.App) !void {
    _ = app;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    defer if (builtin.mode == .Debug) std.debug.assert(gpa.deinit() == .ok);

    var app = try jetzig.init(allocator);
    defer app.deinit();

    try app.start(routes, .{});
}
