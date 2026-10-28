const std = @import("std");
const plugin_system = @import("plugin_system");
const Options = @import("util.zig").Options;

const EventType = enum { start, result, end, @"error" };
const BuildEvent = struct {
    id: u32,
    name: []const u8,
    type: EventType,
    success: ?bool = null,
    @"error": ?[]const u8 = null,
    dependencies: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var node_path: []const u8 = "node";
    var output_path: ?[]const u8 = null;
    var dep_file_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var base_path: ?[]const u8 = null;
    var name: []const u8 = "tailwindcss";
    var sources: std.ArrayList([]const u8) = .empty;
    const runner_script = @embedFile("builder.js");

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--node-path")) {
            node_path = args.next() orelse return error.MissingNodePath;
        } else if (std.mem.eql(u8, arg, "--bun-path")) {
            node_path = args.next() orelse return error.MissingNodePath;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next() orelse return error.MissingOutputPath;
        } else if (std.mem.eql(u8, arg, "--dep-file")) {
            dep_file_path = args.next() orelse return error.MissingDepFilePath;
        } else if (std.mem.eql(u8, arg, "--input")) {
            input_path = args.next() orelse return error.MissingInputPath;
        } else if (std.mem.eql(u8, arg, "--base")) {
            base_path = args.next() orelse return error.MissingBasePath;
        } else if (std.mem.eql(u8, arg, "--source")) {
            try sources.append(allocator, args.next() orelse return error.MissingSourcePath);
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = args.next() orelse return error.MissingName;
        }
    }

    const input = input_path orelse return error.MissingInputPath;
    const output = output_path orelse return error.MissingOutputPath;

    // Read stdin Options JSON
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdin_writer = std.Io.Writer.Allocating.init(allocator);
    defer stdin_writer.deinit();
    _ = try stdin_reader.interface.streamRemaining(&stdin_writer.writer);
    const input_json = try stdin_writer.toOwnedSlice();
    defer allocator.free(input_json);

    const options_json = if (input_json.len == 0) "{}" else input_json;
    const parsed = try std.json.parseFromSlice(Options, allocator, options_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const opts = parsed.value;

    // Assemble the Node runner payload from CLI paths + typed Options.
    const js_payload = try buildJsPayload(allocator, name, input, output, base_path, sources.items, opts);
    defer allocator.free(js_payload);

    const suppress_warnings = init.environ_map.get("NO_COLOR") != null and init.environ_map.get("FORCE_COLOR") != null;
    const argv = if (suppress_warnings)
        &[_][]const u8{ node_path, "--no-warnings", "-e", runner_script }
    else
        &[_][]const u8{ node_path, "-e", runner_script };

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    defer if (child.id != null) {
        _ = child.wait(init.io) catch {};
    };

    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(init.io, js_payload);
        stdin_file.close(init.io);
        child.stdin = null;
    }

    var progress = std.Progress.start(init.io, .{
        .root_name = "tailwindcss",
        .estimated_total_items = 1,
    });
    defer progress.end();

    const NodeMap = std.StringHashMap(std.Progress.Node);
    var nodes = NodeMap.init(allocator);
    defer {
        var it = nodes.valueIterator();
        while (it.next()) |n| n.end();
        nodes.deinit();
    }

    var failed: usize = 0;

    var all_deps = std.ArrayList([]const u8).empty;
    defer all_deps.deinit(allocator);

    if (child.stdout) |stdout_file| {
        var stdout_buffer: [4096]u8 = undefined;
        var streaming_reader = stdout_file.readerStreaming(init.io, &stdout_buffer);
        const io_reader = &streaming_reader.interface;
        var line_writer = std.Io.Writer.Allocating.init(allocator);
        defer line_writer.deinit();

        var aa = std.heap.ArenaAllocator.init(allocator);
        const arena = aa.allocator();
        defer aa.deinit();
        while (io_reader.streamDelimiter(&line_writer.writer, '\n')) |_| {
            const line = line_writer.written();
            _ = io_reader.takeByte() catch break;

            const ev_parsed = std.json.parseFromSlice(BuildEvent, allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer ev_parsed.deinit();
            const ev = ev_parsed.value;

            try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);

            const ev_name = try arena.print("{s} ({d})", .{ ev.name, ev.id });

            switch (ev.type) {
                .start => {
                    const node = progress.start(ev_name, 0);
                    try nodes.put(ev_name, node);
                },
                .result => {
                    if (ev.success == false) failed += 1;
                    for (ev.dependencies) |dep| {
                        try all_deps.append(allocator, try arena.dupe(u8, dep));
                    }
                },
                .@"error" => {
                    failed += 1;
                    if (ev.@"error") |msg| {
                        std.debug.print("tailwindcss [{s}] error: {s}\n", .{ ev.name, msg });
                    }
                },
                .end => {
                    if (nodes.fetchRemove(ev_name)) |kv| {
                        kv.value.end();
                    }
                    progress.completeOne();
                },
            }

            line_writer.clearRetainingCapacity();
        } else |err| {
            if (err == error.EndOfStream) {}
        }
    }

    if (dep_file_path) |dfp| {
        plugin_system.writeDepFile(allocator, init.io, dfp, output, all_deps.items) catch |err| {
            std.debug.print("Failed to write dep file: {any}\n", .{err});
        };
    }

    const term = child.wait(init.io) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Failed to execute JS runtime: executable not found at '{s}'\n", .{node_path});
            return error.NodeNotFound;
        }
        std.debug.print("Failed to wait for JS runtime process: {any}\n", .{err});
        return error.WaitFailed;
    };
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    if (exit_code != 0 or failed > 0) {
        std.debug.print("tailwindcss: build failed\n", .{});
        std.process.exit(1);
    }
}

fn buildJsPayload(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    output: []const u8,
    base: ?[]const u8,
    sources: []const []const u8,
    opts: Options,
) ![]const u8 {
    var config = std.json.ObjectMap.empty;
    try config.put(allocator, "input", .{ .string = input });
    try config.put(allocator, "output", .{ .string = output });
    try config.put(allocator, "minify", .{ .bool = opts.minify });
    try config.put(allocator, "optimize", .{ .bool = opts.optimize });
    try config.put(allocator, "map", .{ .bool = opts.map });

    if (base) |b| {
        try config.put(allocator, "base", .{ .string = b });
    }
    if (sources.len > 0) {
        var arr = try std.json.Array.initCapacity(allocator, sources.len);
        for (sources) |source| {
            arr.appendAssumeCapacity(.{ .string = source });
        }
        try config.put(allocator, "sources", .{ .array = arr });
    }

    var build_obj = std.json.ObjectMap.empty;
    try build_obj.put(allocator, "name", .{ .string = name });
    try build_obj.put(allocator, "config", .{ .object = config });

    var builds = try std.json.Array.initCapacity(allocator, 1);
    builds.appendAssumeCapacity(.{ .object = build_obj });

    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = builds }, .{});
}
