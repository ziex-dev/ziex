// Wasm hosts (the playground) watch, build and serve; each run renders one ZIEX_DEV_EVENT.
// errors: compiler stderr on stdin, with generated .zig and .zx sources in cwd for remapping.

const std = @import("std");
const zx_info = @import("zx_info");

const context = @import("../shared/context.zig");
const tui = @import("../../tui/main.zig");
const Diagnostics = @import("Diagnostics.zig");
const dev = @import("../dev.zig");

const CommandContext = context.CommandContext;
const Colors = tui.Colors;

const Event = enum { start, rebuilding, unchanged, errors, restart, stop };

const clear_line = "\r\x1b[K";

pub fn run(ctx: CommandContext, args: anytype) !void {
    const env = ctx.app.environ_map;
    const w = ctx.writer;

    const event_name = env.get("ZIEX_DEV_EVENT") orelse {
        std.log.err("zx dev needs a native host to watch and serve the app", .{});
        std.process.exit(1);
    };
    const event = std.meta.stringToEnum(Event, event_name) orelse {
        std.log.err("unknown dev event '{s}'", .{event_name});
        std.process.exit(1);
    };

    switch (event) {
        .start => try status(w, "Building..."),
        .rebuilding => try status(w, "Rebuilding..."),
        .unchanged => try w.writeAll(clear_line),
        .errors => try errors(ctx),
        .restart => try restart(ctx, args),
        .stop => try w.print("{s}\n{s}Stopping dev server...{s}\n", .{ clear_line, Colors.gray, Colors.reset }),
    }
}

fn status(w: *std.Io.Writer, message: []const u8) !void {
    try w.print("{s}{s}↺ {s}{s}{s}{s}{s}", .{ clear_line, Colors.cyan, Colors.reset, Colors.cyan, Colors.bold, message, Colors.reset });
}

fn errors(ctx: CommandContext) !void {
    const allocator = ctx.allocator;
    const w = ctx.writer;

    const stderr = try ctx.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr);

    try w.print("{s}{s}✖ {s}Error building{s}\n", .{ clear_line, Colors.red, Colors.bold, Colors.reset });

    var reader: std.Io.Reader = .fixed(stderr);
    if (try Diagnostics.formatFromReader(allocator, &reader, .{ .transpile_dir = "" })) |formatted| {
        defer allocator.free(formatted);
        try w.writeAll(formatted);
    } else {
        const enhanced = try Diagnostics.enhanceGeneric(allocator, stderr);
        defer allocator.free(enhanced);
        try w.writeAll(enhanced);
        if (enhanced.len > 0 and enhanced[enhanced.len - 1] != '\n') try w.writeByte('\n');
    }
}

fn restart(ctx: CommandContext, args: anytype) !void {
    const env = ctx.app.environ_map;
    const w = ctx.writer;

    const build_ms = std.fmt.parseInt(u64, env.get("ZIEX_DEV_BUILD_MS") orelse "0", 10) catch 0;
    const build_s = @as(f64, @floatFromInt(build_ms)) / 1000.0;
    const is_first_run = isSet(env, "ZIEX_DEV_FIRST");

    try w.writeAll(clear_line);
    if (isSet(env, "ZIEX_DEV_RESOLVED")) {
        try w.print("{s}✓ {s}All build errors have been resolved!{s}\n", .{ Colors.green, Colors.bold, Colors.reset });
    }
    if (args.@"tui-clear") try w.writeAll("\x1b[2J\x1b[H");

    if (is_first_run) {
        if (args.@"tui-init-time-report") {
            try w.print("{s}✓ {s}Built {s}({d:.2}s){s}\n\n", .{ Colors.green, Colors.bold, Colors.gray, build_s, Colors.reset });
        }
    } else {
        try w.writeByte('\n');
        try w.flush();
        dev.printAppLogsBanner(build_s);
    }

    // Natively the app prints this itself
    const url = env.get("ZIEX_DEV_URL") orelse "http://localhost:3000";
    try w.print("{s}Ziex{s} {s}- v{s}{s} | {s}\n", .{ Colors.bold, Colors.reset, Colors.dim, zx_info.version, Colors.reset, url });
}

fn isSet(env: *std.process.Environ.Map, key: []const u8) bool {
    const value = env.get(key) orelse return false;
    return std.mem.eql(u8, value, "1");
}
