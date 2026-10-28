//! Downloads the bench-results artifact from the latest successful Benchmark
//! CI run (or a specific run) and regenerates bench.zon from it.
//!
//! Usage (from the repo root):
//!   zig run site/app/pages/bench.zig                    # latest successful run
//!   zig run site/app/pages/bench.zig -- <run-id>        # specific run
//!   zig run site/app/pages/bench.zig -- --csv <path>    # local CSV file
//!
//! Requires the GitHub CLI (`gh`) to be installed and authenticated (except --csv mode).

const std = @import("std");

const zon_path = "site/app/pages/bench.zon";
const workflow = "bench.yml";

const RunInfo = struct {
    id: []const u8,
    url: []const u8,
    date: []const u8,
    commit: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.skip(); // program name
    const first_arg = args.next();

    const zon = zon: {
        if (first_arg != null and std.mem.eql(u8, first_arg.?, "--csv")) {
            const csv_path = args.next() orelse {
                std.log.err("--csv requires a path argument", .{});
                return error.MissingArgument;
            };
            const csv = std.Io.Dir.cwd().readFileAlloc(io, csv_path, arena, .limited(1 << 20)) catch |err| {
                std.log.err("failed to read {s}: {t}", .{ csv_path, err });
                return err;
            };
            const run_info = RunInfo{
                .id = "",
                .url = "",
                .date = "",
                .commit = "",
            };
            break :zon try csvToZon(arena, csv, run_info);
        }

        const run_info = if (first_arg) |id|
            try runById(arena, io, id)
        else
            try latestRun(arena, io);
        std.log.info("benchmark run: {s} ({s})", .{ run_info.url, run_info.date });

        const csv = try downloadResults(arena, io, run_info);
        break :zon try csvToZon(arena, csv, run_info);
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zon_path, .data = zon }) catch |err| {
        std.log.err("failed to write {s}: {t} (run this from the repo root)", .{ zon_path, err });
        return err;
    };
    std.log.info("wrote {s}", .{zon_path});
}

/// Queries the latest successful run of the benchmark workflow via the gh CLI.
fn latestRun(arena: std.mem.Allocator, io: std.Io) !RunInfo {
    const result = try gh(arena, io, &.{
        "gh",       "run",
        "list",     "--workflow=" ++ workflow,
        "--status", "success",
        "--limit",  "1",
        "--json",   "databaseId,url,updatedAt,headSha",
        "--jq",     ".[0] | \"\\(.databaseId)\\n\\(.url)\\n\\(.updatedAt)\\n\\(.headSha)\"",
    });

    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    const id = lines.next() orelse return error.NoBenchmarkRunFound;
    const url = lines.next() orelse return error.NoBenchmarkRunFound;
    const updated_at = lines.next() orelse return error.NoBenchmarkRunFound;
    const commit = lines.next() orelse return error.NoBenchmarkRunFound;
    if (updated_at.len < 10) return error.InvalidRunDate;

    return .{
        .id = id,
        .url = url,
        .date = updated_at[0..10],
        .commit = commit,
    };
}

/// Queries a specific workflow run by id via the gh CLI.
fn runById(arena: std.mem.Allocator, io: std.Io, id: []const u8) !RunInfo {
    const result = try gh(arena, io, &.{
        "gh",     "run",
        "view",   id,
        "--json", "url,updatedAt,headSha",
        "--jq",   "\"\\(.url)\\n\\(.updatedAt)\\n\\(.headSha)\"",
    });

    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    const url = lines.next() orelse return error.RunNotFound;
    const updated_at = lines.next() orelse return error.RunNotFound;
    const commit = lines.next() orelse return error.RunNotFound;
    if (updated_at.len < 10) return error.InvalidRunDate;

    return .{
        .id = id,
        .url = url,
        .date = updated_at[0..10],
        .commit = commit,
    };
}

/// Downloads the bench-results artifact (result.csv) for the given run,
/// caching it in /tmp keyed by run id.
fn downloadResults(arena: std.mem.Allocator, io: std.Io, run_info: RunInfo) ![]u8 {
    const dir = try arena.print("/tmp/ziex-bench-results-{s}", .{run_info.id});
    const csv_path = try arena.print("{s}/result.csv", .{dir});

    if (std.Io.Dir.cwd().readFileAlloc(io, csv_path, arena, .limited(1 << 20))) |cached| {
        std.log.info("using cached artifact at {s}", .{csv_path});
        return cached;
    } else |_| {}

    std.log.info("downloading bench-results artifact for run {s}...", .{run_info.id});
    _ = try gh(arena, io, &.{
        "gh",     "run",           "download", run_info.id,
        "--name", "bench-results", "--dir",    dir,
    });

    return std.Io.Dir.cwd().readFileAlloc(io, csv_path, arena, .limited(1 << 20));
}

/// Runs a gh CLI command and returns its stdout, failing on non-zero exit.
fn gh(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("the GitHub CLI (gh) is required: https://cli.github.com", .{});
        }
        return err;
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("gh exited with code {d}: {s}", .{ code, std.mem.trim(u8, result.stderr, " \n") });
            return error.GhCommandFailed;
        },
        else => return error.GhCommandFailed,
    }
    return result.stdout;
}

fn getLabel(id: []const u8) []const u8 {
    const labels = [_][2][]const u8{
        .{ "ziex", "Ziex" },
        .{ "jetzig", "Jetzig" },
        .{ "leptos", "Leptos" },
        .{ "dioxus", "Dioxus" },
        .{ "solidjs", "SolidStart" },
        .{ "nextjs", "Next.js" },
    };
    for (labels) |entry| {
        if (std.mem.eql(u8, id, entry[0])) return entry[1];
    }
    return id;
}

/// Converts the result.csv contents into the bench.zon structure.
///
/// CSV columns: framework,idle_mb,peak_mb,build_time_s,image_mb,binary_mb,
///              cold_start_ms,cpu_avg_pct,cpu_peak_pct,rps,p50_ms,p99_ms
fn csvToZon(arena: std.mem.Allocator, csv: []const u8, run_info: RunInfo) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.print(
        \\// Auto-generated by `zig run site/app/pages/bench.zig` - do not edit
        \\.{{
        \\    .run = .{{
        \\        .url = "{s}",
        \\        .date = "{s}",
        \\        .commit = "{s}",
        \\    }},
        \\    .results = .{{
        \\
    , .{ run_info.url, run_info.date, run_info.commit });

    const zon_fields = [_][]const u8{
        "idle_memory_mb", "peak_memory_mb", "build_time_s",
        "image_mb",       "binary_mb",      "cold_start_ms",
        "cpu_avg_pct",    "cpu_peak_pct",   "requests_per_sec",
        "p50_latency_ms", "p99_latency_ms",
    };

    var rows: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    _ = lines.next() orelse return error.EmptyCsv; // header
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var cols = std.mem.splitScalar(u8, line, ',');
        const id = cols.next() orelse return error.MalformedCsv;
        try w.print("        .{{\n            .id = \"{s}\",\n            .label = \"{s}\",\n", .{ id, getLabel(id) });
        for (zon_fields) |field| {
            const value = cols.next() orelse return error.MalformedCsv;
            _ = std.fmt.parseFloat(f64, value) catch return error.MalformedCsv;
            try w.print("            .{s} = {s},\n", .{ field, value });
        }
        try w.writeAll("        },\n");
        rows += 1;
    }
    if (rows == 0) return error.EmptyCsv;

    try w.writeAll(
        \\    },
        \\}
        \\
    );

    std.log.info("parsed {d} framework results", .{rows});
    return out.written();
}
