const std = @import("std");

var id_counter: usize = 1;

const adjectives = [_][]const u8{
    "pretty", "large",  "big",       "small",    "tall",      "short",       "long",  "handsome",
    "plain",  "quaint", "clean",     "elegant",  "easy",      "angry",       "crazy", "helpful",
    "mushy",  "odd",    "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive",
    "fancy",
};

const colours = [_][]const u8{
    "red",   "yellow", "blue",  "green",  "pink", "brown", "purple",
    "brown", "white",  "black", "orange",
};

const nouns = [_][]const u8{
    "table",    "chair",  "house", "bbq",   "desk",     "car", "pony", "cookie",
    "sandwich", "burger", "pizza", "mouse", "keyboard",
};

pub const Row = struct {
    id: usize,
    label: []const u8,

    pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

fn random(max: usize) usize {
    const io = zx.Io.default();
    var buffer: [1]u8 = undefined;
    std.Io.random(io, &buffer);
    return @mod(buffer[0], max);
}

pub fn buildData(allocator: std.mem.Allocator, count: usize) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    errdefer {
        for (rows.items) |row| {
            row.deinit(allocator);
        }
        rows.deinit(allocator);
    }

    var i: usize = 0;
    std.debug.print("buildData: count={d}, start_id={d}\n", .{ count, id_counter });
    while (i < count) : (i += 1) {
        const adj = adjectives[random(adjectives.len)];
        const colour = colours[random(colours.len)];
        const noun = nouns[random(nouns.len)];

        const label = try allocator.print("{s} {s} {s}", .{ adj, colour, noun });

        try rows.append(allocator, .{
            .id = id_counter,
            .label = label,
        });
        id_counter += 1;
    }

    return rows;
}

pub fn resetIdCounter() void {
    id_counter = 1;
}

const zx = @import("zx");
