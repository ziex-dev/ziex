// Postgres backend integration tests; skipped unless ZX_TEST_POSTGRES_URL is set, e.g.
// docker run -d -e POSTGRES_PASSWORD=pw -p 5432:5432 postgres:17
// ZX_TEST_POSTGRES_URL=postgres://postgres:pw@localhost/postgres zig build test
const std = @import("std");
const zx = @import("zx");

const Db = zx.Db;
const Postgres = Db.Postgres;
const t = std.testing;

fn testUrl() ![]u8 {
    return t.environ.getAlloc(t.allocator, "ZX_TEST_POSTGRES_URL") catch error.SkipZigTest;
}

/// Single connection, so TEMP tables stay visible across calls.
fn openTestDatabase() !Db {
    const url = try testUrl();
    defer t.allocator.free(url);
    return Postgres.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
}

fn openSeeded() !Db {
    var database = try openTestDatabase();
    errdefer database.deinit();
    _ = try database.run(
        \\CREATE TEMP TABLE users (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL UNIQUE,
        \\  score DOUBLE PRECISION NOT NULL
        \\);
        \\INSERT INTO users (name, score) VALUES ('Ada', 9.5), ('Linus', 7.25);
    , .empty);
    return database;
}

test "api > open and run" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run("CREATE TEMP TABLE t (id INT)", .empty);
    const result = try database.run("INSERT INTO t (id) VALUES ($1), ($2)", .{ 1, 2 });
    try t.expectEqual(@as(usize, 2), result.changes);
    try t.expectEqual(@as(i64, 0), result.last_insert_id);
}

test "api > statement get/all/values and metadata" {
    var database = try openSeeded();
    defer database.deinit();

    var stmt = try database.prepare("SELECT id, name, score FROM users WHERE score > $1 ORDER BY id");
    defer stmt.deinit();
    try t.expectEqual(@as(usize, 1), try stmt.paramCount());
    try t.expectEqualStrings("name", (try stmt.columnNames())[1]);
    try t.expectEqual(Db.ColumnType.integer, (try stmt.columnTypes())[0]);
    try t.expectEqual(Db.ColumnType.text, (try stmt.columnTypes())[1]);
    try t.expectEqual(Db.ColumnType.float, (try stmt.columnTypes())[2]);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = try stmt.all(a, .{1.0});
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("Ada", rows[0].text("name"));
    try t.expectEqual(@as(f64, 7.25), rows[1].float("score"));

    const row = (try stmt.get(a, .{8.0})).?;
    try t.expectEqualStrings("Ada", row.text("name"));
    try t.expectEqual(@as(?Db.Row, null), try stmt.get(a, .{100.0}));

    const values = try stmt.values(a, .{1.0});
    try t.expectEqual(@as(usize, 2), values.len);
    try t.expectEqual(@as(i64, 1), values[0][0].integer);
}

test "api > named bindings across sigils" {
    var database = try openSeeded();
    defer database.deinit();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    const row = (try database.get(
        arena.allocator(),
        "SELECT name FROM users WHERE name = :name AND score >= @min AND id = $id",
        .{ .name = "Linus", .min = 7.0, .id = 2 },
    )).?;
    try t.expectEqualStrings("Linus", row.text("name"));

    _ = try database.run("UPDATE users SET score = :s WHERE name = :n", .{ .s = 1.5, .n = "Ada" });
    const updated = (try database.get(arena.allocator(), "SELECT score FROM users WHERE name = 'Ada'", .{})).?;
    try t.expectEqual(@as(f64, 1.5), updated.float("score"));
}

test "api > value types round-trip" {
    var database = try openTestDatabase();
    defer database.deinit();
    _ = try database.run("CREATE TEMP TABLE v (n TEXT, b BYTEA, f BOOLEAN, i BIGINT, d DOUBLE PRECISION, num NUMERIC)", .empty);

    const blob = [_]u8{ 0, 1, 2, 0xff };
    const values = [_]Db.Value{ .null, .{ .blob = &blob }, .{ .boolean = true }, .{ .integer = std.math.maxInt(i64) }, .{ .float = -0.125 }, .{ .text = "12345678901234567890.5" } };
    _ = try database.run("INSERT INTO v VALUES ($1, $2, $3, $4, $5, $6)", Db.Bindings.fromPositional(&values));

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT * FROM v", .{})).?;
    try t.expect(row.isNull("n"));
    try t.expectEqualSlices(u8, &blob, row.get("b").?.blob);
    try t.expect(row.boolean("f"));
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), row.int("i"));
    try t.expectEqual(@as(f64, -0.125), row.float("d"));
    try t.expectEqualStrings("12345678901234567890.5", row.text("num"));
}

test "api > iterate drained and abandoned" {
    var database = try openTestDatabase();
    defer database.deinit();

    var stmt = try database.prepare("SELECT g FROM generate_series(1, 5) AS g");
    defer stmt.deinit();

    var it = try stmt.iterate(.{});
    var sum: i64 = 0;
    while (try it.next()) |row| sum += row.int("g");
    it.deinit();
    try t.expectEqual(@as(i64, 15), sum);

    var early = try stmt.iterate(.{});
    _ = try early.next();
    early.deinit();

    // connection is back in sync after the abandoned iterator
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT 42 AS x", .{})).?;
    try t.expectEqual(@as(i64, 42), row.int("x"));
}

fn insertThenFail(_: void, database: Db) anyerror!void {
    _ = try database.run("INSERT INTO users (name, score) VALUES ($1, $2)", .{ "Rolled", 1.0 });
    return error.Boom;
}

fn insertOk(_: void, database: Db) anyerror!void {
    _ = try database.run("INSERT INTO users (name, score) VALUES ($1, $2)", .{ "Committed", 1.0 });
}

fn countUsers(database: Db) !i64 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    return (try database.get(arena.allocator(), "SELECT COUNT(*) AS n FROM users", .{})).?.int("n");
}

test "api > transaction commit and rollback" {
    var database = try openSeeded();
    defer database.deinit();
    try t.expectError(error.Boom, database.transaction({}, insertThenFail));
    try t.expectEqual(@as(i64, 2), try countUsers(database));

    try database.transactionWith(.immediate, {}, insertOk);
    try t.expectEqual(@as(i64, 3), try countUsers(database));
}

test "api > errors map to shared names" {
    var database = try openSeeded();
    defer database.deinit();

    try t.expectError(error.ConstraintUnique, database.run("INSERT INTO users (name, score) VALUES ($1, $2)", .{ "Ada", 1.0 }));
    try t.expectError(error.ConstraintNotNull, database.run("INSERT INTO users (name, score) VALUES ($1, NULL)", .{"X"}));
    // prepare is lazy on Postgres; the error surfaces on first execution or metadata access
    var bad = try database.prepare("SELECT FROM nowhere_table");
    defer bad.deinit();
    try t.expectError(error.InvalidQuery, bad.columnNames());
    try t.expectError(error.InvalidQuery, bad.all(t.allocator, .{}));
    try t.expectError(error.InvalidQuery, database.run("SELEC 1", .empty));
    // still usable after errors
    try t.expectEqual(@as(i64, 2), try countUsers(database));
}

test "api > pooled connections serve concurrent queries" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var database = try Postgres.open(t.allocator, t.io, url, .{ .max_pool_size = 3 });
    defer database.deinit();

    _ = try database.run(
        \\DROP TABLE IF EXISTS ziex_pool_test;
        \\CREATE TABLE ziex_pool_test (n INT NOT NULL)
    , .empty);
    defer _ = database.run("DROP TABLE IF EXISTS ziex_pool_test", .empty) catch {};

    var group: std.Io.Group = .init;
    for (0..8) |i| group.async(t.io, insertN, .{ database, @as(i64, @intCast(i)) });
    try group.await(t.io);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS c, SUM(n) AS s FROM ziex_pool_test", .{})).?;
    try t.expectEqual(@as(i64, 8), row.int("c"));
    try t.expectEqual(@as(i64, 28), row.int("s"));
}

fn insertN(database: Db, n: i64) void {
    _ = database.run("INSERT INTO ziex_pool_test (n) VALUES ($1)", .{n}) catch |err| std.debug.panic("insert failed: {s}", .{@errorName(err)});
}

test "api > bad credentials fail at open" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var parsed = try zx.Db.Postgres.uri.parse(t.allocator, url);
    defer parsed.deinit();

    const bad = try t.allocator.print("postgres://{s}:definitely-wrong@{s}:{d}/{s}?sslmode={s}", .{
        parsed.user, parsed.host, parsed.port, parsed.database, @tagName(parsed.sslmode),
    });
    defer t.allocator.free(bad);
    try t.expectError(error.OpenFailed, Postgres.open(t.allocator, t.io, bad, .{}));
}

test "api > readonly option rejects writes" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var database = try Postgres.open(t.allocator, t.io, url, .{ .readonly = true, .max_pool_size = 1 });
    defer database.deinit();
    try t.expectError(error.QueryFailed, database.run("CREATE TABLE ziex_ro_test (id INT)", .empty));
}

test "api > session is encrypted when sslmode requires it" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var parsed = try zx.Db.Postgres.uri.parse(t.allocator, url);
    defer parsed.deinit();
    if (!parsed.sslmode.requiresTls()) return error.SkipZigTest;

    var database = try Postgres.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", .{})).?;
    try t.expect(row.boolean("ssl"));
}

fn urlWith(param: []const u8) ![]u8 {
    const url = try testUrl();
    defer t.allocator.free(url);
    const sep: u8 = if (std.mem.findScalar(u8, url, '?') == null) '?' else '&';
    return t.allocator.print("{s}{c}{s}", .{ url, sep, param });
}

fn preparedCount(database: Db) !i64 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    // with caching on, this query is itself one of the cached statements
    var stmt = try database.prepare("SELECT count(*) AS n FROM pg_prepared_statements");
    defer stmt.deinit();
    return (try stmt.get(arena.allocator(), .{})).?.int("n");
}

test "api > statement cache survives DDL and DEALLOCATE ALL" {
    var database = try openTestDatabase();
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try database.run("CREATE TEMP TABLE sc (x INT); INSERT INTO sc VALUES (1)", .empty);
    for (0..3) |_| {
        const row = (try database.get(a, "SELECT * FROM sc WHERE x = $1", .{1})).?;
        try t.expectEqual(@as(usize, 1), row.fields.len);
    }

    // cached plan's result type changes; the stale statement is replaced transparently
    _ = try database.run("ALTER TABLE sc ADD COLUMN y INT DEFAULT 7", .empty);
    const widened = (try database.get(a, "SELECT * FROM sc WHERE x = $1", .{1})).?;
    try t.expectEqual(@as(i64, 7), widened.int("y"));

    _ = try database.run("DEALLOCATE ALL", .empty);
    const again = (try database.get(a, "SELECT * FROM sc WHERE x = $1", .{1})).?;
    try t.expectEqual(@as(i64, 7), again.int("y"));
}

test "api > statement cache is bounded and can be disabled" {
    {
        const url = try urlWith("statement_cache_size=2");
        defer t.allocator.free(url);
        var database = try Postgres.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
        defer database.deinit();
        for (1..6) |i| {
            const sql = try t.allocator.print("SELECT {d} + $1 AS v", .{i});
            defer t.allocator.free(sql);
            _ = try database.run(sql, .{1});
        }
        try t.expect(try preparedCount(database) <= 2);
    }
    {
        const url = try urlWith("statement_cache_size=0");
        defer t.allocator.free(url);
        var database = try Postgres.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
        defer database.deinit();
        _ = try database.run("SELECT $1::int", .{1});
        try t.expectEqual(@as(i64, 0), try preparedCount(database));
    }
}

test "api > cached (binary) results match the first (text) result" {
    var database = try openTestDatabase();
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql =
        \\SELECT $1::int2 AS i2, $2::int4 AS i4, $3::int8 AS i8, 4294967295::oid AS o,
        \\  $4::float4 AS f4, $5::float8 AS f8, $6::bool AS b, NULL::int4 AS n, 'x'::text AS s,
        \\  '\x00ff'::bytea AS blob, 1.5::numeric AS num
    ;
    const args = .{ -32768, -2147483648, std.math.minInt(i64), 0.25, -1.0e300, true };
    const first = (try database.get(a, sql, args)).?;
    for (0..3) |_| {
        const again = (try database.get(a, sql, args)).?;
        try t.expectEqual(first.fields.len, again.fields.len);
        for (first.fields, again.fields) |x, y| {
            try t.expectEqualStrings(x.name, y.name);
            try t.expectEqualDeep(x.value, y.value);
        }
    }
    try t.expectEqual(@as(i64, -32768), first.int("i2"));
    try t.expectEqual(@as(i64, std.math.minInt(i64)), first.int("i8"));
    try t.expectEqual(@as(i64, 4294967295), first.int("o"));
    try t.expectEqual(@as(f64, 0.25), first.float("f4"));
    try t.expectEqual(@as(f64, -1.0e300), first.float("f8"));
    try t.expect(first.boolean("b"));
    try t.expect(first.isNull("n"));
    try t.expectEqualStrings("1.5", first.text("num"));

    // iterator rows (borrowed, binary on hits) agree too
    var stmt = try database.prepare(sql);
    defer stmt.deinit();
    for (0..2) |_| {
        var it = try stmt.iterate(args);
        defer it.deinit();
        const row = (try it.next()).?;
        try t.expectEqual(@as(i64, std.math.minInt(i64)), row.int("i8"));
        try t.expectEqualSlices(u8, "\x00\xff", row.get("blob").?.blob);
        try t.expectEqualStrings("x", row.text("s"));
    }
}
