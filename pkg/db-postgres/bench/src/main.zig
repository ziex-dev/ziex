// Compares our Postgres client with pg.zig and libpq on the same workloads.
// Usage: zig build run -Dlibpq=$(brew --prefix libpq) -- 'postgres://postgres:pw@127.0.0.1:5432/postgres?sslmode=disable'
const std = @import("std");
const Io = std.Io;
const config = @import("config");
const ours = @import("ours");
const pgz = @import("pg");
const Db = @import("zx_db").Db;
const c = @import("libpq");

const select_sql = "SELECT $1::int4 + 1";
const insert_sql = "INSERT INTO bench_insert (a, b) VALUES ($1, $2)";
const fetch_sql = "SELECT g, 'row-' || g FROM generate_series(1, 100000) AS g";
const fetch_rows = 100_000;
const fetch_checksum: u64 = blk: {
    // sum(g) + sum(len("row-" ++ g))
    var sum: u64 = fetch_rows * (fetch_rows + 1) / 2;
    var g: u64 = 1;
    @setEvalBranchQuota(10_000_000);
    while (g <= fetch_rows) : (g += 1) sum += 4 + std.math.log10_int(g) + 1;
    break :blk sum;
};

const Workload = enum {
    connect,
    select_one,
    insert,
    fetch_100k,

    fn ops(self: Workload) usize {
        return switch (self) {
            .connect => 50,
            .select_one => 5000,
            .insert => 5000,
            .fetch_100k => 1,
        };
    }

    fn unit(self: Workload) []const u8 {
        return switch (self) {
            .fetch_100k => "rows",
            else => "ops",
        };
    }
};

const reps = 7;

// --- Drivers --- //
// Each driver: init(gpa, io, url) !*Self, deinit, selectOne, insert, fetch, exec.

/// zx.Db (pool, row cloning, placeholder rewrite, stale-statement retry) on our client.
/// `cached` keeps the per-connection prepared statement cache on (the default).
fn ZxDb(comptime cached: bool) type {
    return struct {
        const Self = @This();
        const name = if (cached) "zx.Db (cached)" else "zx.Db";
        const skip_connect = cached;

        gpa: std.mem.Allocator,
        db: Db,
        arena: std.heap.ArenaAllocator,

        fn init(gpa: std.mem.Allocator, io: Io, url: []const u8) !*Self {
            const full = if (cached) url else try withParam(gpa, url, "statement_cache_size=0");
            defer if (!cached) gpa.free(full);
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .db = try Db.Postgres.open(gpa, io, full, .{ .max_pool_size = 1 }),
                .arena = .init(gpa),
            };
            return self;
        }

        fn deinit(self: *Self) void {
            self.db.deinit();
            self.arena.deinit();
            self.gpa.destroy(self);
        }

        fn exec(self: *Self, sql: []const u8) !void {
            _ = try self.db.run(sql, .empty);
        }

        fn selectOne(self: *Self, v: i32) !i32 {
            defer _ = self.arena.reset(.retain_capacity);
            const row = (try self.db.get(self.arena.allocator(), select_sql, .{v})).?;
            return @intCast(row.fields[0].value.integer);
        }

        fn insert(self: *Self, v: i32, text: []const u8) !void {
            _ = try self.db.run(insert_sql, .{ v, text });
        }

        fn fetch(self: *Self) !u64 {
            var stmt = try self.db.prepare(fetch_sql, .{});
            defer stmt.deinit();
            var it = try stmt.iterate(.{});
            defer it.deinit();
            var sum: u64 = 0;
            while (try it.next()) |row| {
                sum += @intCast(row.fields[0].value.integer);
                sum += row.fields[1].value.text.len;
            }
            return sum;
        }
    };
}

fn withParam(gpa: std.mem.Allocator, url: []const u8, param: []const u8) ![]u8 {
    const sep: u8 = if (std.mem.findScalar(u8, url, '?') == null) '?' else '&';
    return gpa.print("{s}{c}{s}", .{ url, sep, param });
}

/// pg.zig; `cached` reuses a named prepared statement (one round trip instead of two).
fn PgZig(comptime cached: bool) type {
    return struct {
        const Self = @This();
        const name = if (cached) "pg.zig (cached stmt)" else "pg.zig";
        // connect cost is the same as the uncached variant
        const skip_connect = cached;

        gpa: std.mem.Allocator,
        conn: pgz.Conn,

        fn opts(key: []const u8) pgz.Conn.QueryOpts {
            return if (cached) .{ .cache_name = key } else .{};
        }

        fn init(gpa: std.mem.Allocator, io: Io, url: []const u8) !*Self {
            var parsed = try ours.uri.parse(gpa, url);
            defer parsed.deinit();
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .conn = try pgz.Conn.openAndAuth(io, gpa, .{
                    .host = parsed.host,
                    .port = parsed.port,
                    .tls = try pgTls(parsed.sslmode),
                }, .{
                    .username = parsed.user,
                    .password = parsed.password,
                    .database = parsed.database,
                }),
            };
            return self;
        }

        fn deinit(self: *Self) void {
            self.conn.deinit();
            self.gpa.destroy(self);
        }

        fn exec(self: *Self, sql: []const u8) !void {
            _ = try self.conn.exec(sql, .{});
        }

        fn selectOne(self: *Self, v: i32) !i32 {
            var res = try self.conn.queryOpts(select_sql, .{v}, opts("select_one"));
            defer res.deinit();
            const out = try (try res.next()).?.get(i32, 0);
            try res.drain();
            return out;
        }

        fn insert(self: *Self, v: i32, text: []const u8) !void {
            _ = try self.conn.execOpts(insert_sql, .{ v, text }, opts("insert"));
        }

        fn fetch(self: *Self) !u64 {
            var res = try self.conn.queryOpts(fetch_sql, .{}, opts("fetch"));
            defer res.deinit();
            var sum: u64 = 0;
            while (try res.next()) |row| {
                sum += @intCast(try row.get(i32, 0));
                sum += (try row.get([]const u8, 1)).len;
            }
            return sum;
        }
    };
}

fn pgTls(mode: ours.uri.SslMode) !pgz.Conn.Opts.TLS {
    return switch (mode) {
        // pg.zig has no "prefer"; plain unless the URL insists on TLS
        .disable, .prefer => .off,
        .require, .verify_ca => if (config.pg_tls) .require else error.PgZigBuiltWithoutOpenSsl,
        .verify_full => if (config.pg_tls) .{ .verify_full = null } else error.PgZigBuiltWithoutOpenSsl,
    };
}

/// libpq; `prepared` uses PQprepare/PQexecPrepared instead of PQexecParams.
fn Libpq(comptime prepared: bool) type {
    return struct {
        const Self = @This();
        const name = if (prepared) "libpq (prepared)" else "libpq";
        const skip_connect = prepared;

        gpa: std.mem.Allocator,
        conn: *c.PGconn,

        fn init(gpa: std.mem.Allocator, _: Io, url: []const u8) !*Self {
            const info = try gpa.dupeSentinel(u8, url, 0);
            defer gpa.free(info);
            const conn = c.PQconnectdb(info) orelse return error.OutOfMemory;
            errdefer c.PQfinish(conn);
            if (c.PQstatus(conn) != c.CONNECTION_OK) {
                std.log.err("libpq: {s}", .{c.PQerrorMessage(conn)});
                return error.ConnectFailed;
            }
            const self = try gpa.create(Self);
            self.* = .{ .gpa = gpa, .conn = conn };
            if (prepared) {
                try self.prepare("select_one", select_sql, 1);
                try self.prepare("insert", insert_sql, 2);
                try self.prepare("fetch", fetch_sql, 0);
            }
            return self;
        }

        fn prepare(self: *Self, stmt: [*:0]const u8, sql: [*:0]const u8, n: c_int) !void {
            try check(c.PQprepare(self.conn, stmt, sql, n, null), c.PGRES_COMMAND_OK, self.conn);
        }

        fn deinit(self: *Self) void {
            c.PQfinish(self.conn);
            self.gpa.destroy(self);
        }

        fn run(self: *Self, stmt: [*:0]const u8, sql: [*:0]const u8, values: []const [*c]const u8) ?*c.PGresult {
            const n: c_int = @intCast(values.len);
            const ptr: [*c]const [*c]const u8 = if (values.len == 0) null else values.ptr;
            return if (prepared)
                c.PQexecPrepared(self.conn, stmt, n, ptr, null, null, 0)
            else
                c.PQexecParams(self.conn, sql, n, null, ptr, null, null, 0);
        }

        fn check(res: ?*c.PGresult, want: c.ExecStatusType, conn: *c.PGconn) !void {
            defer c.PQclear(res);
            if (c.PQresultStatus(res) != want) {
                std.log.err("libpq: {s}", .{c.PQerrorMessage(conn)});
                return error.QueryFailed;
            }
        }

        fn exec(self: *Self, sql: []const u8) !void {
            const z = try self.gpa.dupeSentinel(u8, sql, 0);
            defer self.gpa.free(z);
            try check(c.PQexec(self.conn, z), c.PGRES_COMMAND_OK, self.conn);
        }

        fn selectOne(self: *Self, v: i32) !i32 {
            var buf: [16]u8 = undefined;
            const text = try std.mem.printSentinel(&buf, "{d}", .{v}, 0);
            const res = self.run("select_one", select_sql, &.{text.ptr});
            defer c.PQclear(res);
            if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) return error.QueryFailed;
            return std.fmt.parseInt(i32, std.mem.span(c.PQgetvalue(res, 0, 0)), 10);
        }

        fn insert(self: *Self, v: i32, text: [:0]const u8) !void {
            var buf: [16]u8 = undefined;
            const num = try std.mem.printSentinel(&buf, "{d}", .{v}, 0);
            try check(self.run("insert", insert_sql, &.{ num.ptr, text.ptr }), c.PGRES_COMMAND_OK, self.conn);
        }

        fn fetch(self: *Self) !u64 {
            const res = self.run("fetch", fetch_sql, &.{});
            defer c.PQclear(res);
            if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) return error.QueryFailed;
            var sum: u64 = 0;
            const n = c.PQntuples(res);
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                sum += try std.fmt.parseInt(u64, std.mem.span(c.PQgetvalue(res, i, 0)), 10);
                sum += @intCast(c.PQgetlength(res, i, 1));
            }
            return sum;
        }
    };
}

// --- Harness --- //

// grouped as plain/cached pairs per client: zx.Db, pg.zig, libpq
const drivers = if (config.libpq)
    .{ ZxDb(false), ZxDb(true), PgZig(false), PgZig(true), Libpq(false), Libpq(true) }
else
    .{ ZxDb(false), ZxDb(true), PgZig(false), PgZig(true) };
const clients = drivers.len / 2;
const client_names = [_][]const u8{ "zx.Db", "pg.zig", "libpq" };

const workloads = std.enums.values(Workload);
const skipped = std.math.maxInt(u64);

fn now(io: Io, clock: Io.Clock) i96 {
    return Io.Timestamp.now(io, clock).nanoseconds;
}

const Sample = struct {
    wall: u64,
    /// Client process CPU time; unaffected by network latency.
    cpu: u64,
};

fn runOnce(comptime D: type, d: *D, gpa: std.mem.Allocator, io: Io, url: []const u8, w: Workload, ops: usize) !Sample {
    if (w == .insert) try d.exec("TRUNCATE bench_insert");
    const start = now(io, .awake);
    const cpu_start = now(io, .cpu_process);
    switch (w) {
        .connect => for (0..ops) |_| {
            const fresh = try D.init(gpa, io, url);
            fresh.deinit();
        },
        .select_one => for (0..ops) |i| {
            const v: i32 = @intCast(i);
            if (try d.selectOne(v) != v + 1) return error.WrongResult;
        },
        .insert => for (0..ops) |i| try d.insert(@intCast(i), "benchmark payload text"),
        .fetch_100k => if (try d.fetch() != fetch_checksum) return error.WrongResult,
    }
    return .{ .wall = @intCast(now(io, .awake) - start), .cpu = @intCast(now(io, .cpu_process) - cpu_start) };
}

/// One sample of every workload for driver `D`, after a short warm-up.
fn sampleDriver(comptime D: type, gpa: std.mem.Allocator, io: Io, url: []const u8, out: *[workloads.len][reps]Sample, rep: usize) !void {
    const d = try D.init(gpa, io, url);
    defer d.deinit();
    for (workloads, 0..) |w, wi| {
        if (w == .connect and D.skip_connect) {
            out[wi][rep] = .{ .wall = skipped, .cpu = skipped };
            continue;
        }
        _ = try runOnce(D, d, gpa, io, url, w, @max(w.ops() / 10, 1));
        out[wi][rep] = try runOnce(D, d, gpa, io, url, w, w.ops());
    }
}

fn profile(comptime D: type, gpa: std.mem.Allocator, io: Io, url: []const u8, w: Workload) !void {
    const d = try D.init(gpa, io, url);
    defer d.deinit();
    try d.exec("DROP TABLE IF EXISTS bench_insert; CREATE UNLOGGED TABLE bench_insert (a INT, b TEXT)");
    const deadline = now(io, .awake) + 10 * std.time.ns_per_s;
    var runs: usize = 0;
    while (now(io, .awake) < deadline) : (runs += 1) _ = try runOnce(D, d, gpa, io, url, w, w.ops());
    std.debug.print("{s}: {d} runs of {s}\n", .{ D.name, runs, @tagName(w) });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    var url_arg = args.next();
    // `--profile <zx|pgzig> <workload> <url>` loops one cached-mode workload for ~10s (for samplers / time)
    if (url_arg != null and std.mem.eql(u8, url_arg.?, "--profile")) {
        const which = args.next() orelse "zx";
        const w = std.meta.stringToEnum(Workload, args.next() orelse "fetch_100k") orelse return error.UnknownWorkload;
        const url = args.next() orelse init.environ_map.get("PG_BENCH_URL") orelse return error.MissingUrl;
        if (std.mem.eql(u8, which, "pgzig")) return profile(PgZig(true), gpa, io, url, w);
        return profile(ZxDb(true), gpa, io, url, w);
    }
    const url = url_arg orelse init.environ_map.get("PG_BENCH_URL") orelse {
        std.log.err("usage: pg-bench <postgres-url>  (or set PG_BENCH_URL)", .{});
        return error.MissingUrl;
    };
    url_arg = null;

    // shared fixture; UNLOGGED keeps the insert numbers about the client, not fsync
    {
        const setup = try ZxDb(false).init(gpa, io, url);
        defer setup.deinit();
        try setup.exec("DROP TABLE IF EXISTS bench_insert; CREATE UNLOGGED TABLE bench_insert (a INT, b TEXT)");
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    // interleave drivers within each repetition so server-side drift hits all of them equally
    var samples: [drivers.len][workloads.len][reps]Sample = undefined;
    for (0..reps) |rep| {
        inline for (drivers, 0..) |D, di| try sampleDriver(D, gpa, io, url, &samples[di], rep);
        try out.print("\rrun {d}/{d}", .{ rep + 1, reps });
        try out.flush();
    }

    // per driver/workload medians: ops/s, and client CPU ns per op; 0 = not measured
    var rate: [drivers.len][workloads.len]u64 = undefined;
    var cpu_ns: [drivers.len][workloads.len]u64 = undefined;
    inline for (drivers, 0..) |_, di| {
        for (workloads, 0..) |w, wi| {
            const runs = &samples[di][wi];
            if (runs[0].wall == skipped) {
                rate[di][wi] = 0;
                cpu_ns[di][wi] = 0;
                continue;
            }
            var wall: [reps]u64 = undefined;
            var cpu: [reps]u64 = undefined;
            for (runs, &wall, &cpu) |r, *wl, *cp| {
                wl.* = r.wall;
                cp.* = r.cpu;
            }
            std.mem.sort(u64, &wall, {}, std.sort.asc(u64));
            std.mem.sort(u64, &cpu, {}, std.sort.asc(u64));
            const count: u64 = if (w == .fetch_100k) fetch_rows else w.ops();
            rate[di][wi] = count * std.time.ns_per_s / wall[reps / 2];
            cpu_ns[di][wi] = cpu[reps / 2] / count;
        }
    }

    try out.print("\rmedian of {d} interleaved runs; ops/s (fetch_100k: rows/s); higher is better\n", .{reps});
    for ([_]bool{ false, true }) |cached| {
        try out.print("\n{s}\n\n| {s:<10} |", .{
            if (cached) "Cached / prepared statements (zx.Db cache on, pg.zig cache_name, libpq PQprepare)" else "Unprepared (every query parsed by the server)",
            "workload",
        });
        for (client_names[0..clients]) |n| try out.print(" {s:>10} |", .{n});
        for (client_names[1..clients]) |n| try out.print(" zx.Db vs {s:<7} |", .{n});
        try out.print("\n|{s:-<12}|", .{""});
        for (0..clients) |_| try out.writeAll("-----------:|");
        for (1..clients) |_| try out.writeAll("-----------------:|");
        try out.writeAll("\n");

        for (workloads, 0..) |w, wi| {
            const zx_rate = rate[@intFromBool(cached)][wi];
            if (zx_rate == 0) continue; // connect is only measured unprepared
            try out.print("| {s:<10} |", .{@tagName(w)});
            for (0..clients) |ci| {
                var num: [32]u8 = undefined;
                try out.print(" {s:>10} |", .{thousands(&num, rate[ci * 2 + @intFromBool(cached)][wi])});
            }
            for (1..clients) |ci| {
                const other = rate[ci * 2 + @intFromBool(cached)][wi];
                const zx_f: f64 = @floatFromInt(zx_rate);
                const other_f: f64 = @floatFromInt(other);
                if (zx_f >= other_f)
                    try out.print(" {d:>5.2}x faster    |", .{zx_f / other_f})
                else
                    try out.print(" {d:>5.2}x slower    |", .{other_f / zx_f});
            }
            try out.writeAll("\n");
        }
    }

    try out.writeAll("\nClient CPU per op in ns (fetch_100k: per row); lower is better\n\n| workload   | mode     |");
    for (client_names[0..clients]) |n| try out.print(" {s:>8} |", .{n});
    for (client_names[1..clients]) |n| try out.print(" zx.Db vs {s:<7} |", .{n});
    try out.writeAll("\n|------------|----------|");
    for (0..clients) |_| try out.writeAll("---------:|");
    for (1..clients) |_| try out.writeAll("-----------------:|");
    try out.writeAll("\n");
    for (workloads, 0..) |w, wi| {
        for ([_]bool{ false, true }) |cached| {
            const m = @intFromBool(cached);
            const zx = cpu_ns[m][wi];
            if (zx == 0) continue;
            try out.print("| {s:<10} | {s:<8} |", .{ @tagName(w), if (cached) "cached" else "plain" });
            for (0..clients) |ci| {
                var num: [32]u8 = undefined;
                try out.print(" {s:>8} |", .{thousands(&num, cpu_ns[ci * 2 + m][wi])});
            }
            for (1..clients) |ci| {
                const zx_f: f64 = @floatFromInt(zx);
                const other_f: f64 = @floatFromInt(cpu_ns[ci * 2 + m][wi]);
                if (zx_f <= other_f)
                    try out.print(" {d:>5.2}x faster    |", .{other_f / zx_f})
                else
                    try out.print(" {d:>5.2}x slower    |", .{zx_f / other_f});
            }
            try out.writeAll("\n");
        }
    }
    try out.flush();
}

fn thousands(buf: *[32]u8, value: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const raw = std.mem.print(&digits, "{d}", .{value}) catch unreachable;
    var len: usize = 0;
    for (raw, 0..) |ch, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            buf[len] = ',';
            len += 1;
        }
        buf[len] = ch;
        len += 1;
    }
    return buf[0..len];
}
