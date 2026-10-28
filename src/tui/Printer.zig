const std = @import("std");
const builtin = @import("builtin");
const Colors = @import("Colors.zig");

pub const Printer = @This();

// Helper to conditionally return emoji or empty string based on OS
pub fn emoji(comptime emoji_str: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) "" else emoji_str;
}

arena: std.heap.ArenaAllocator,
printed_dirs: std.StringHashMap(void),
options: PrinterOptions,

pub const DisplayMode = enum {
    tree,
    flat,
};

pub const PrinterOptions = struct {
    file_path_mode: DisplayMode = .tree,
    file_tree_max_depth: ?usize = null,
};

pub fn init(allocator: std.mem.Allocator, options: PrinterOptions) Printer {
    return Printer{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .printed_dirs = std.StringHashMap(void).init(allocator),
        .options = options,
    };
}

pub fn deinit(self: *Printer) void {
    self.printed_dirs.deinit();
    self.arena.deinit();
}

pub const FilePathKind = enum {
    /// Statically exported file
    static,
    /// Dynamic page skipped during export (no static HTML)
    dynamic,
    /// Dynamic route pattern that expands via static params
    param_route,
    /// Path generated from a param route's static params
    param_child,

    fn marker(self: FilePathKind) []const u8 {
        return switch (self) {
            .static, .param_child => "+",
            .dynamic => if (emoji("∞").len == 0) "~" else emoji("∞"),
            .param_route => "*",
        };
    }

    /// Number of 4-space indent levels before the marker.
    fn depth(self: FilePathKind) usize {
        return switch (self) {
            .param_child => 2,
            else => 1,
        };
    }
};

pub fn filepath(self: *Printer, file_path: []const u8) void {
    self.filepathKind(file_path, .static);
}

pub fn filepathKind(self: *Printer, file_path: []const u8, kind: FilePathKind) void {
    const marker = kind.marker();
    switch (self.options.file_path_mode) {
        .flat => {
            var i: usize = 0;
            while (i < kind.depth()) : (i += 1) {
                std.debug.print("    ", .{});
            }
            std.debug.print("{s} \x1b[90m{s}\x1b[0m\n", .{ marker, file_path });
            return;
        },
        .tree => {
            // Show as tree structure
            const arena = self.arena.allocator();

            // Split path into components
            var components = std.array_list.Managed([]const u8).init(arena);
            defer components.deinit();

            var it = std.mem.splitScalar(u8, file_path, '/');
            while (it.next()) |component| {
                if (component.len > 0) {
                    components.append(component) catch return;
                }
            }

            if (components.items.len == 0) return;

            // Print directories leading to the file
            var current_path = std.array_list.Managed(u8).init(arena);
            defer current_path.deinit();

            for (components.items[0 .. components.items.len - 1], 0..) |dir, depth| {
                if (self.options.file_tree_max_depth) |max_depth| {
                    if (depth >= max_depth) break;
                }

                if (current_path.items.len > 0) {
                    current_path.append('/') catch return;
                }
                current_path.appendSlice(dir) catch return;

                const dir_path = current_path.items;
                const key = arena.dupe(u8, dir_path) catch return;

                if (self.printed_dirs.contains(key)) {
                    // Key already exists, skip
                } else {
                    // Print indent (4 spaces per depth level)
                    var i: usize = 0;
                    while (i < depth + 1) : (i += 1) {
                        std.debug.print("    ", .{});
                    }
                    std.debug.print("- \x1b[90m{s}\x1b[0m\n", .{dir});
                    self.printed_dirs.put(key, {}) catch return;
                }
            }

            // Print the file
            var i: usize = 0;
            while (i < components.items.len) : (i += 1) {
                std.debug.print("    ", .{});
            }
            const filename = components.items[components.items.len - 1];
            std.debug.print("{s} \x1b[90m{s}\x1b[0m\n", .{ marker, filename });
        },
    }
}

pub fn header(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    const is_windows = builtin.os.tag == .windows;

    if (is_windows) {
        std.debug.print("{s}", .{Colors.cyan});
        std.debug.print(fmt, args);
        std.debug.print("{s}\n\n", .{Colors.reset});
    } else {
        std.debug.print(fmt, args);
        std.debug.print("\n\n", .{});
    }
}

pub fn footer(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    std.debug.print("\n", .{});
    std.debug.print(fmt, args);
    std.debug.print("\n\n", .{});
}

pub fn warning(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    const is_windows = builtin.os.tag == .windows;

    if (is_windows) {
        std.debug.print("{s}Warning:{s} ", .{ Colors.yellow, Colors.reset });
    } else {
        std.debug.print("{s}{s} Warning:{s} ", .{ Colors.yellow, "⚠", Colors.reset });
    }
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn info(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    std.debug.print("  - {s}", .{Colors.gray});
    std.debug.print(fmt, args);
    std.debug.print("{s}\n", .{Colors.reset});
}
