const std = @import("std");

const REPO = "ziex-dev/ziex";
const CODE_EXTS = [_][]const u8{ ".zig", ".zx", ".ts", ".css", ".md" };

pub const Language = struct {
    name: []const u8,
    lines: u64,
};

pub const MonthCount = struct { month: []const u8, count: u64 };

pub const TimelineEntry = struct {
    month: []const u8,
    commits: u64,
    contributors: u64,
    lines: u64,
    files: u64,
    size_kb: u64,
};

pub const StarEntry = struct {
    month: []const u8,
    stars: u64,
};

pub const Stats = struct {
    commits: u64,
    contributors: u64,
    lines: u64,
    files: u64,
    todos: u64,
    size_kb: u64,
    stars: u64,
    age_years: f64,
    first_commit: []const u8,
    last_commit: []const u8,
    languages: []const Language,
    commits_per_month: []const MonthCount,
    timeline: []const TimelineEntry,
    stars_per_month: []const StarEntry,
};

/// Gather all project stats. All returned slices are allocated from `a`.
pub fn collect(a: std.mem.Allocator, io: std.Io) !Stats {
    const root = try gitOut(a, io, &.{ "rev-parse", "--show-toplevel" });
    const repo_root = std.mem.trim(u8, root, " \n\r");

    const commits = try countLines(a, io, repo_root, &.{ "rev-list", "--count", "HEAD" });
    const contributors = blk: {
        const s = try gitOutAt(a, io, repo_root, &.{ "shortlog", "-sne", "--all" });
        break :blk countNonEmptyLines(s);
    };
    const first_commit = std.mem.trim(u8, try firstLine(a, try gitOutAt(a, io, repo_root, &.{ "log", "--reverse", "--format=%aI" })), " \n\r");
    const last_commit = std.mem.trim(u8, try gitOutAt(a, io, repo_root, &.{ "log", "-1", "--format=%aI" }), " \n\r");

    const tracked = try lsFiles(a, io, repo_root);
    var total_lines: u64 = 0;
    var total_bytes: u64 = 0;
    var file_count: u64 = 0;
    var lang_lines: [CODE_EXTS.len]u64 = @splat(0);
    for (tracked) |rel| {
        const ext = std.fs.path.extension(rel);
        const li = extIndex(ext) orelse continue;
        file_count += 1;
        const full = try std.fs.path.join(a, &.{ repo_root, rel });
        const stat = statFile(io, full) orelse continue;
        total_bytes += stat.size;
        const lines = stat.lines;
        total_lines += lines;
        lang_lines[li] += lines;
    }

    const todos = try countMatches(a, io, repo_root);
    const stars = fetchStarCount(a, io) catch 0;
    const age_years = ageYears(first_commit, last_commit);

    var languages = std.ArrayList(Language).empty;
    for (CODE_EXTS, 0..) |ext, i| {
        if (lang_lines[i] == 0) continue;
        try languages.append(a, .{ .name = ext[1..], .lines = lang_lines[i] });
    }

    const commits_per_month = blk: {
        const log = try gitOutAt(a, io, repo_root, &.{ "log", "--format=%ad", "--date=format:%Y-%m" });
        var counts = std.array_list.Managed(MonthCount).init(a);
        try tallyMonths(a, log, &counts);
        break :blk counts.items;
    };

    const timeline = try getTimeline(a, io, repo_root);
    const stars_per_month = getStarTimeline(a, io) catch &.{};

    return Stats{
        .commits = commits,
        .contributors = contributors,
        .lines = total_lines,
        .files = file_count,
        .todos = todos,
        .size_kb = total_bytes / 1024,
        .stars = stars,
        .age_years = age_years,
        .first_commit = first_commit,
        .last_commit = last_commit,
        .languages = languages.items,
        .commits_per_month = commits_per_month,
        .timeline = timeline,
        .stars_per_month = stars_per_month,
    };
}

const Acc = struct {
    commits: u64 = 0,
    contributors: u64 = 0,
    lines: i64 = 0,
    files: u64 = 0,
};

fn getTimeline(a: std.mem.Allocator, io: std.Io, repo_root: []const u8) ![]const TimelineEntry {
    var args = std.array_list.Managed([]const u8).init(a);
    try args.appendSlice(&.{ "log", "--reverse", "--format=__C__%ad %aE", "--date=format:%Y-%m", "--numstat", "--" });
    for (CODE_EXTS) |ext| try args.append(try a.print("*{s}", .{ext}));

    const log = try gitOutAt(a, io, repo_root, args.items);

    var seen_authors = std.StringHashMap(void).init(a);
    var seen_files = std.StringHashMap(void).init(a);
    var acc = Acc{};
    var cur: ?[]const u8 = null;
    const avg_bytes: i64 = 40; // rough bytes/line for size estimate

    var list = std.ArrayList(TimelineEntry).empty;

    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "__C__")) {
            acc.commits += 1;
            const rest = line["__C__".len..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const ym = rest[0..sp]; // YYYY-MM
            const email = rest[sp + 1 ..];
            if (cur == null) cur = try a.dupe(u8, ym);
            if (!std.mem.eql(u8, cur.?, ym)) {
                try appendAcc(a, &list, cur.?, acc, avg_bytes);
                cur = try a.dupe(u8, ym);
            }
            if (!seen_authors.contains(email)) {
                try seen_authors.put(try a.dupe(u8, email), {});
                acc.contributors += 1;
            }
        } else if (line.len > 0 and std.ascii.isDigit(line[0])) {
            // "add\tdel\tpath"
            var parts = std.mem.splitScalar(u8, line, '\t');
            const add_s = parts.next() orelse continue;
            const del_s = parts.next() orelse continue;
            const path = parts.next() orelse continue;
            const add = std.fmt.parseInt(i64, add_s, 10) catch continue;
            const del = std.fmt.parseInt(i64, del_s, 10) catch 0;
            acc.lines += add - del;
            if (!seen_files.contains(path)) {
                try seen_files.put(try a.dupe(u8, path), {});
                acc.files += 1;
            }
        }
    }
    if (cur) |m| try appendAcc(a, &list, m, acc, avg_bytes);
    return list.items;
}

fn appendAcc(a: std.mem.Allocator, list: *std.ArrayList(TimelineEntry), month: []const u8, acc: Acc, avg_bytes: i64) !void {
    const lines: u64 = if (acc.lines < 0) 0 else @intCast(acc.lines);
    const size_kb: u64 = @intCast(@divTrunc(@as(i64, @intCast(lines)) * avg_bytes, 1024));
    try list.append(a, .{
        .month = month,
        .commits = acc.commits,
        .contributors = acc.contributors,
        .lines = lines,
        .files = acc.files,
        .size_kb = size_kb,
    });
}

fn fetchStarCount(a: std.mem.Allocator, io: std.Io) !u64 {
    const url = "https://api.github.com/repos/" ++ REPO;
    const body = try httpGet(a, io, url, null);
    return findIntField(body, "\"stargazers_count\":") orelse 0;
}

fn getStarTimeline(a: std.mem.Allocator, io: std.Io) ![]const StarEntry {
    var dates = std.array_list.Managed([]const u8).init(a);
    var page: usize = 1;
    while (page <= 20) : (page += 1) {
        const url = try a.print("https://api.github.com/repos/{s}/stargazers?per_page=100&page={d}", .{ REPO, page });
        const body = httpGet(a, io, url, "application/vnd.github.star+json") catch break;
        var got: usize = 0;
        var it = std.mem.splitSequence(u8, body, "\"starred_at\":");
        _ = it.next(); // before first match
        while (it.next()) |chunk| {
            // chunk starts with ` "YYYY-MM-...`
            const q1 = std.mem.indexOfScalar(u8, chunk, '"') orelse continue;
            if (chunk.len < q1 + 8) continue;
            const ym = chunk[q1 + 1 .. q1 + 8]; // YYYY-MM
            try dates.append(try a.dupe(u8, ym));
            got += 1;
        }
        if (got < 100) break;
    }
    if (dates.items.len == 0) return &.{};

    std.mem.sort([]const u8, dates.items, {}, lessStr);
    var list = std.ArrayList(StarEntry).empty;
    var total: u64 = 0;
    var i: usize = 0;
    while (i < dates.items.len) {
        var j = i;
        while (j < dates.items.len and std.mem.eql(u8, dates.items[j], dates.items[i])) j += 1;
        total += j - i;
        try list.append(a, .{ .month = dates.items[i], .stars = total });
        i = j;
    }
    return list.items;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn gitOut(a: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    return gitOutAt(a, io, ".", args);
}

fn gitOutAt(a: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv = std.array_list.Managed([]const u8).init(a);
    try argv.append("git");
    try argv.appendSlice(args);
    return run(a, io, argv.items, cwd);
}

// GET a URL with the std HTTP client (same approach as src/cli/update.zig).
// `accept` overrides the default GitHub JSON accept header when provided.
fn httpGet(a: std.mem.Allocator, io: std.Io, url: []const u8, accept: ?[]const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.appendSlice(a, &.{
        .{ .name = "user-agent", .value = "ziex-stats" },
        .{ .name = "accept", .value = accept orelse "application/vnd.github+json" },
    });
    // Optional auth - lifts the unauthenticated rate limit.
    if (std.c.getenv("GITHUB_TOKEN")) |tok_z| {
        const tok = std.mem.span(tok_z);
        if (tok.len > 0) {
            try headers.append(a, .{
                .name = "authorization",
                .value = try a.print("Bearer {s}", .{tok}),
            });
        }
    }

    var aw = std.Io.Writer.Allocating.init(a);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = @fromBackingInt(@intCast(5)),
        .response_writer = &aw.writer,
        .extra_headers = headers.items,
    }) catch return error.NetworkError;
    if (result.status != .ok) return error.HttpError;
    return aw.written();
}

fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return result.stdout;
}

const FileStat = struct { size: u64, lines: u64 };

fn statFile(io: std.Io, path: []const u8) ?FileStat {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(64 * 1024 * 1024)) catch return null;
    defer std.heap.page_allocator.free(data);
    var lines: u64 = 0;
    for (data) |c| {
        if (c == '\n') lines += 1;
    }
    return .{ .size = data.len, .lines = lines };
}

fn extIndex(ext: []const u8) ?usize {
    for (CODE_EXTS, 0..) |e, i| {
        if (std.mem.eql(u8, e, ext)) return i;
    }
    return null;
}

fn lsFiles(a: std.mem.Allocator, io: std.Io, repo_root: []const u8) ![][]const u8 {
    const s = try gitOutAt(a, io, repo_root, &.{"ls-files"});
    var list = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try list.append(line);
    }
    return list.items;
}

fn countLines(a: std.mem.Allocator, io: std.Io, repo_root: []const u8, args: []const []const u8) !u64 {
    const s = try gitOutAt(a, io, repo_root, args);
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " \n\r"), 10) catch 0;
}

fn countNonEmptyLines(s: []const u8) u64 {
    var n: u64 = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len > 0) n += 1;
    }
    return n;
}

fn countMatches(a: std.mem.Allocator, io: std.Io, repo_root: []const u8) !u64 {
    var args = std.array_list.Managed([]const u8).init(a);
    try args.appendSlice(&.{ "grep", "-I", "-E", "TODO|FIXME", "--" });
    for (CODE_EXTS) |ext| try args.append(try a.print("*{s}", .{ext}));
    const s = gitOutAt(a, io, repo_root, args.items) catch return 0;
    return countNonEmptyLines(s);
}

fn firstLine(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    _ = a;
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

fn tallyMonths(a: std.mem.Allocator, log: []const u8, out: *std.array_list.Managed(MonthCount)) !void {
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        const m = std.mem.trim(u8, line, " \r");
        if (m.len == 0) continue;
        var found = false;
        for (out.items) |*mc| {
            if (std.mem.eql(u8, mc.month, m)) {
                mc.count += 1;
                found = true;
                break;
            }
        }
        if (!found) try out.append(.{ .month = try a.dupe(u8, m), .count = 1 });
    }
    std.mem.sort(MonthCount, out.items, {}, struct {
        fn lt(_: void, x: MonthCount, y: MonthCount) bool {
            return std.mem.lessThan(u8, x.month, y.month);
        }
    }.lt);
}

fn findIntField(body: []const u8, key: []const u8) ?u64 {
    const i = std.mem.indexOf(u8, body, key) orelse return null;
    var j = i + key.len;
    while (j < body.len and (body[j] == ' ' or body[j] == '"')) j += 1;
    var k = j;
    while (k < body.len and std.ascii.isDigit(body[k])) k += 1;
    if (k == j) return null;
    return std.fmt.parseInt(u64, body[j..k], 10) catch null;
}

fn ageYears(first_iso: []const u8, last_iso: []const u8) f64 {
    const fy = parseYearFrac(first_iso) orelse return 0;
    const ly = parseYearFrac(last_iso) orelse return 0;
    return ly - fy;
}

fn parseYearFrac(iso: []const u8) ?f64 {
    if (iso.len < 10) return null;
    const y = std.fmt.parseInt(u32, iso[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, iso[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, iso[8..10], 10) catch return null;
    return @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(m - 1)) + @as(f64, @floatFromInt(d)) / 30.0) / 12.0;
}
