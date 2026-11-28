// Compares our MySQL client with libmysqlclient on the same workloads.
// Usage: zig build run -Dmysql=$(brew --prefix mysql-client) -- 'mysql://root:pw@127.0.0.1:3306/test?sslmode=disable'
const std = @import("std");
const Io = std.Io;
const config = @import("config");
const ours = @import("ours");
const Db = @import("zx_db").Db;
const c = if (config.mysql) @import("libmysql") else struct {};

const select_sql = "SELECT ? + 1";
const insert_sql = "INSERT INTO bench_insert (a, b) VALUES (?, ?)";
const fetch_sql = "SELECT g, t FROM bench_rows";
const fetch_rows = 100_000;
const fetch_checksum: u64 = blk: {
    // sum(g) + sum(len("row-" ++ g))
    var sum: u64 = fetch_rows * (fetch_rows + 1) / 2;
    var g: u64 = 1;
    @setEvalBranchQuota(10_000_000);
    while (g <= fetch_rows) : (g += 1) sum += 4 + std.math.log10_int(g) + 1;
    break :blk sum;
};

const setup_sql =
    \\DROP TABLE IF EXISTS bench_insert;
    \\CREATE TABLE bench_insert (a INT, b TEXT);
    \\DROP TABLE IF EXISTS bench_digits;
    \\CREATE TABLE bench_digits (n INT);
    \\INSERT INTO bench_digits VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);
    \\DROP TABLE IF EXISTS bench_rows;
    \\CREATE TABLE bench_rows (g INT PRIMARY KEY, t VARCHAR(16));
    \\INSERT INTO bench_rows
    \\SELECT g, CONCAT('row-', g) FROM (
    \\  SELECT 1 + a.n + 10 * b.n + 100 * c.n + 1000 * d.n + 10000 * e.n AS g
    \\  FROM bench_digits a, bench_digits b, bench_digits c, bench_digits d, bench_digits e
    \\) AS s
;

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
};

const reps = 7;

/// zx.Db (pool, row cloning, placeholder handling) on our client.
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
                .db = try Db.Mysql.open(gpa, io, full, .{ .max_pool_size = 1 }),
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

/// libmysqlclient; `prepared` keeps MYSQL_STMT handles open instead of prepare+close per call.
fn Libmysql(comptime prepared: bool) type {
    return struct {
        const Self = @This();
        const name = if (prepared) "libmysql (prepared)" else "libmysql";
        const skip_connect = prepared;

        gpa: std.mem.Allocator,
        conn: *c.MYSQL,
        select_stmt: ?*c.MYSQL_STMT = null,
        insert_stmt: ?*c.MYSQL_STMT = null,
        fetch_stmt: ?*c.MYSQL_STMT = null,

        fn init(gpa: std.mem.Allocator, _: Io, url: []const u8) !*Self {
            var parsed = try ours.uri.parse(gpa, url);
            defer parsed.deinit();

            const conn = c.mysql_init(null) orelse return error.OutOfMemory;
            errdefer c.mysql_close(conn);

            // match the URL's sslmode; stock MySQL often requests a client cert over TLS
            const ssl_mode: c.enum_mysql_ssl_mode = switch (parsed.sslmode) {
                .disable => c.SSL_MODE_DISABLED,
                .prefer => c.SSL_MODE_PREFERRED,
                .require => c.SSL_MODE_REQUIRED,
                .verify_ca => c.SSL_MODE_VERIFY_CA,
                .verify_full => c.SSL_MODE_VERIFY_IDENTITY,
            };
            _ = c.mysql_options(conn, c.MYSQL_OPT_SSL_MODE, &ssl_mode);

            const host = try gpa.dupeSentinel(u8, parsed.host, 0);
            defer gpa.free(host);
            const user = try gpa.dupeSentinel(u8, parsed.user, 0);
            defer gpa.free(user);
            const password = try gpa.dupeSentinel(u8, parsed.password orelse "", 0);
            defer gpa.free(password);
            const database = try gpa.dupeSentinel(u8, parsed.database orelse "", 0);
            defer gpa.free(database);

            if (c.mysql_real_connect(
                conn,
                host.ptr,
                user.ptr,
                password.ptr,
                if (parsed.database != null) database.ptr else null,
                parsed.port,
                null,
                0,
            ) == null) {
                std.log.err("libmysql: {s}", .{c.mysql_error(conn)});
                return error.ConnectFailed;
            }

            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .gpa = gpa, .conn = conn };
            if (prepared) {
                self.select_stmt = try self.prepare(select_sql);
                self.insert_stmt = try self.prepare(insert_sql);
                self.fetch_stmt = try self.prepare(fetch_sql);
            }
            return self;
        }

        fn prepare(self: *Self, sql: []const u8) !*c.MYSQL_STMT {
            const stmt = c.mysql_stmt_init(self.conn) orelse return error.OutOfMemory;
            errdefer _ = c.mysql_stmt_close(stmt);
            if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
                std.log.err("libmysql prepare: {s}", .{c.mysql_stmt_error(stmt)});
                return error.PrepareFailed;
            }
            return stmt;
        }

        fn deinit(self: *Self) void {
            if (self.select_stmt) |s| _ = c.mysql_stmt_close(s);
            if (self.insert_stmt) |s| _ = c.mysql_stmt_close(s);
            if (self.fetch_stmt) |s| _ = c.mysql_stmt_close(s);
            c.mysql_close(self.conn);
            self.gpa.destroy(self);
        }

        fn exec(self: *Self, sql: []const u8) !void {
            if (c.mysql_real_query(self.conn, sql.ptr, sql.len) != 0) {
                std.log.err("libmysql: {s}", .{c.mysql_error(self.conn)});
                return error.QueryFailed;
            }
            // drain any result sets from multi-statement setup SQL
            while (c.mysql_next_result(self.conn) == 0) {
                if (c.mysql_store_result(self.conn)) |res| c.mysql_free_result(res);
            }
        }

        fn selectOne(self: *Self, v: i32) !i32 {
            const stmt = if (prepared) self.select_stmt.? else try self.prepare(select_sql);
            defer if (!prepared) {
                _ = c.mysql_stmt_close(stmt);
            };

            var in_v = v;
            var is_null: bool = false;
            var bind_in: c.MYSQL_BIND = std.mem.zeroes(c.MYSQL_BIND);
            bind_in.buffer_type = c.MYSQL_TYPE_LONG;
            bind_in.buffer = @ptrCast(&in_v);
            bind_in.is_null = @ptrCast(&is_null);
            // bool APIs: true means failure
            if (c.mysql_stmt_bind_param(stmt, &bind_in)) return error.QueryFailed;
            if (c.mysql_stmt_execute(stmt) != 0) return error.QueryFailed;

            var result: i32 = 0;
            var res_null: bool = false;
            var bind_out: c.MYSQL_BIND = std.mem.zeroes(c.MYSQL_BIND);
            bind_out.buffer_type = c.MYSQL_TYPE_LONG;
            bind_out.buffer = @ptrCast(&result);
            bind_out.is_null = @ptrCast(&res_null);
            if (c.mysql_stmt_bind_result(stmt, &bind_out)) return error.QueryFailed;
            if (c.mysql_stmt_store_result(stmt) != 0) return error.QueryFailed;
            if (c.mysql_stmt_fetch(stmt) != 0) return error.QueryFailed;
            _ = c.mysql_stmt_free_result(stmt);
            return result;
        }

        fn insert(self: *Self, v: i32, text: []const u8) !void {
            const stmt = if (prepared) self.insert_stmt.? else try self.prepare(insert_sql);
            defer if (!prepared) {
                _ = c.mysql_stmt_close(stmt);
            };

            var in_v = v;
            var is_null_a: bool = false;
            var is_null_b: bool = false;
            var length_b: c_ulong = @intCast(text.len);
            var binds: [2]c.MYSQL_BIND = .{ std.mem.zeroes(c.MYSQL_BIND), std.mem.zeroes(c.MYSQL_BIND) };
            binds[0].buffer_type = c.MYSQL_TYPE_LONG;
            binds[0].buffer = @ptrCast(&in_v);
            binds[0].is_null = @ptrCast(&is_null_a);
            binds[1].buffer_type = c.MYSQL_TYPE_STRING;
            binds[1].buffer = @ptrCast(@constCast(text.ptr));
            binds[1].buffer_length = @intCast(text.len);
            binds[1].length = &length_b;
            binds[1].is_null = @ptrCast(&is_null_b);
            if (c.mysql_stmt_bind_param(stmt, &binds)) return error.QueryFailed;
            if (c.mysql_stmt_execute(stmt) != 0) return error.QueryFailed;
        }

        fn fetch(self: *Self) !u64 {
            const stmt = if (prepared) self.fetch_stmt.? else try self.prepare(fetch_sql);
            defer if (!prepared) {
                _ = c.mysql_stmt_close(stmt);
            };

            if (c.mysql_stmt_execute(stmt) != 0) return error.QueryFailed;

            var g: i32 = 0;
            var t_buf: [32]u8 = undefined;
            var t_len: c_ulong = 0;
            var null_g: bool = false;
            var null_t: bool = false;
            var binds: [2]c.MYSQL_BIND = .{ std.mem.zeroes(c.MYSQL_BIND), std.mem.zeroes(c.MYSQL_BIND) };
            binds[0].buffer_type = c.MYSQL_TYPE_LONG;
            binds[0].buffer = @ptrCast(&g);
            binds[0].is_null = @ptrCast(&null_g);
            binds[1].buffer_type = c.MYSQL_TYPE_STRING;
            binds[1].buffer = &t_buf;
            binds[1].buffer_length = t_buf.len;
            binds[1].length = &t_len;
            binds[1].is_null = @ptrCast(&null_t);
            if (c.mysql_stmt_bind_result(stmt, &binds)) return error.QueryFailed;
            if (c.mysql_stmt_store_result(stmt) != 0) return error.QueryFailed;

            var sum: u64 = 0;
            while (true) {
                const rc = c.mysql_stmt_fetch(stmt);
                if (rc == c.MYSQL_NO_DATA) break;
                if (rc != 0 and rc != c.MYSQL_DATA_TRUNCATED) return error.QueryFailed;
                sum += @intCast(g);
                sum += t_len;
            }
            _ = c.mysql_stmt_free_result(stmt);
            return sum;
        }
    };
}

// --- Harness --- //

const drivers = if (config.mysql)
    .{ ZxDb(false), ZxDb(true), Libmysql(false), Libmysql(true) }
else
    .{ ZxDb(false), ZxDb(true) };
const clients = drivers.len / 2;
const client_names = [_][]const u8{ "zx.Db", "libmysql" };

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
    if (w == .insert) try d.exec("TRUNCATE TABLE bench_insert");
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
    const first = args.next();
    // `--profile <zx|libmysql> <workload> <url>` loops one cached-mode workload for ~10s
    if (first != null and std.mem.eql(u8, first.?, "--profile")) {
        const which = args.next() orelse "zx";
        const w = std.meta.stringToEnum(Workload, args.next() orelse "fetch_100k") orelse return error.UnknownWorkload;
        const url = args.next() orelse init.environ_map.get("MYSQL_BENCH_URL") orelse return error.MissingUrl;
        if (std.mem.eql(u8, which, "libmysql")) {
            if (!config.mysql) return error.LibmysqlNotLinked;
            return profile(Libmysql(true), gpa, io, url, w);
        }
        return profile(ZxDb(true), gpa, io, url, w);
    }
    const url = first orelse init.environ_map.get("MYSQL_BENCH_URL") orelse {
        std.log.err("usage: mysql-bench <mysql-url>  (or set MYSQL_BENCH_URL)", .{});
        return error.MissingUrl;
    };

    {
        const setup = try ZxDb(false).init(gpa, io, url);
        defer setup.deinit();
        try setup.exec(setup_sql);
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
            if (cached) "Cached / prepared statements (zx.Db cache on, libmysql MYSQL_STMT reused)" else "Unprepared (prepare + execute + close per call)",
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
