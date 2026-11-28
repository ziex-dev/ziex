// MySQL backend integration tests; skipped unless ZX_TEST_MYSQL_URL is set, e.g.
// docker run -d -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=test -p 3306:3306 mysql:8.4
// ZX_TEST_MYSQL_URL=mysql://root:pw@127.0.0.1/test zig build test
// MariaDB works too (mariadb:11).
const std = @import("std");
const zx = @import("zx");

const Db = zx.Db;
const Mysql = Db.Mysql;
const t = std.testing;

fn testUrl() ![]u8 {
    return t.environ.getAlloc(t.allocator, "ZX_TEST_MYSQL_URL") catch error.SkipZigTest;
}

/// Single connection, so TEMPORARY tables stay visible across calls.
fn openTestDatabase() !Db {
    const url = try testUrl();
    defer t.allocator.free(url);
    return Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
}

fn openSeeded() !Db {
    var database = try openTestDatabase();
    errdefer database.deinit();
    _ = try database.run(
        \\DROP TEMPORARY TABLE IF EXISTS users;
        \\CREATE TEMPORARY TABLE users (
        \\  id INT AUTO_INCREMENT PRIMARY KEY,
        \\  name VARCHAR(100) NOT NULL UNIQUE,
        \\  score DOUBLE NOT NULL
        \\);
        \\INSERT INTO users (name, score) VALUES ('Ada', 9.5), ('Linus', 7.25);
    , .empty);
    return database;
}

test "api > open and run" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run("CREATE TEMPORARY TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, n INT)", .empty);
    const result = try database.run("INSERT INTO t (n) VALUES (?), (?)", .{ 10, 20 });
    try t.expectEqual(@as(usize, 2), result.changes);
    try t.expectEqual(@as(i64, 1), result.last_insert_id);

    const text = try database.run("INSERT INTO t (n) VALUES (30)", .empty);
    try t.expectEqual(@as(usize, 1), text.changes);
    try t.expectEqual(@as(i64, 3), text.last_insert_id);

    // matched rows count even when nothing changes
    const same = try database.run("UPDATE t SET n = n", .empty);
    try t.expectEqual(@as(usize, 3), same.changes);
}

test "api > statement get/all/values and metadata" {
    var database = try openSeeded();
    defer database.deinit();

    var stmt = try database.prepare("SELECT id, name, score FROM users WHERE score > ? ORDER BY id", .{});
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

    // no bindings runs over the text protocol
    var plain = try database.prepare("SELECT id, name FROM users ORDER BY id", .{});
    defer plain.deinit();
    const text_rows = try plain.all(a, .{});
    try t.expectEqual(@as(usize, 2), text_rows.len);
    try t.expectEqual(@as(i64, 2), text_rows[1].int("id"));
    try t.expectEqualStrings("Linus", text_rows[1].text("name"));
}

test "api > named bindings across sigils" {
    var database = try openSeeded();
    defer database.deinit();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    // a repeated name fills every `?`
    const row = (try database.get(
        arena.allocator(),
        "SELECT name FROM users WHERE name = :name AND score >= @min AND id = $id AND name = :name",
        .{ .name = "Linus", .min = 7.0, .id = 2 },
    )).?;
    try t.expectEqualStrings("Linus", row.text("name"));

    _ = try database.run("UPDATE users SET score = :s WHERE name = :n", .{ .s = 1.5, .n = "Ada" });
    const updated = (try database.get(arena.allocator(), "SELECT score FROM users WHERE name = 'Ada'", .{})).?;
    try t.expectEqual(@as(f64, 1.5), updated.float("score"));

    try t.expectError(error.InvalidBindings, database.run("UPDATE users SET score = :s", .{ .nope = 1 }));
    try t.expectError(error.InvalidBindings, database.run("UPDATE users SET score = ?", .{ 1, 2 }));
}

test "api > user variables work with positional bindings" {
    var database = try openTestDatabase();
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    _ = try database.run("SET @x = ?", .{41});
    const row = (try database.get(arena.allocator(), "SELECT @x + ? AS v", .{1})).?;
    try t.expectEqual(@as(i64, 42), row.int("v"));
}

test "api > value types round-trip" {
    var database = try openTestDatabase();
    defer database.deinit();
    _ = try database.run(
        \\CREATE TEMPORARY TABLE v (
        \\  n TEXT, b BLOB, f TINYINT(1), i BIGINT, d DOUBLE, num DECIMAL(30,5),
        \\  u BIGINT UNSIGNED, j JSON, ts DATETIME(6), dt DATE, tm TIME, bits BIT(8), flag BIT(1), s VARCHAR(20), vb VARBINARY(8)
        \\)
    , .empty);

    const blob = [_]u8{ 0, 1, 2, 0xff };
    const values = [_]Db.Value{
        .null,
        .{ .blob = &blob },
        .{ .boolean = true },
        .{ .integer = std.math.maxInt(i64) },
        .{ .float = -0.125 },
        .{ .text = "12345678901234567890.12345" },
        .{ .text = "18446744073709551615" },
        .{ .text = "{\"a\": [1, 2]}" },
        .{ .text = "2024-02-29 13:14:15.123456" },
        .{ .text = "2024-02-29" },
        .{ .text = "-100:02:03" },
        .{ .integer = 0xA5 },
        .{ .integer = 1 },
        .{ .text = "héllo ✓" },
        .{ .blob = &blob },
    };
    _ = try database.run("INSERT INTO v VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", Db.Bindings.fromPositional(&values));

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // binary protocol (a parameter forces a prepared statement) and text protocol must agree
    const binary = (try database.get(a, "SELECT *, ? AS p FROM v", .{1})).?;
    const text = (try database.get(a, "SELECT * FROM v", .{})).?;
    for (text.fields, binary.fields[0..text.fields.len]) |x, y| {
        try t.expectEqualStrings(x.name, y.name);
        try t.expectEqualDeep(x.value, y.value);
    }

    for ([_]Db.Row{ binary, text }) |row| {
        try t.expect(row.isNull("n"));
        try t.expectEqualSlices(u8, &blob, row.get("b").?.blob);
        try t.expectEqual(@as(i64, 1), row.int("f"));
        try t.expect(row.boolean("f"));
        try t.expectEqual(@as(i64, std.math.maxInt(i64)), row.int("i"));
        try t.expectEqual(@as(f64, -0.125), row.float("d"));
        try t.expectEqualStrings("12345678901234567890.12345", row.text("num"));
        try t.expectEqualStrings("18446744073709551615", row.text("u"));
        try t.expectEqualStrings("2024-02-29 13:14:15.123456", row.text("ts"));
        try t.expectEqualStrings("2024-02-29", row.text("dt"));
        try t.expectEqualStrings("-100:02:03", row.text("tm"));
        try t.expectEqual(@as(i64, 0xA5), row.int("bits"));
        try t.expect(row.boolean("flag"));
        try t.expectEqualStrings("héllo ✓", row.text("s"));
        try t.expectEqualSlices(u8, &blob, row.get("vb").?.blob);
        try t.expect(std.mem.find(u8, row.text("j"), "[1, 2]") != null);
    }
}

test "api > iterate drained and abandoned" {
    var database = try openTestDatabase();
    defer database.deinit();

    var stmt = try database.prepare("SELECT n FROM (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) x WHERE n > ?", .{});
    defer stmt.deinit();

    var it = try stmt.iterate(.{0});
    var sum: i64 = 0;
    while (try it.next()) |row| sum += row.int("n");
    it.deinit();
    try t.expectEqual(@as(i64, 15), sum);

    var early = try stmt.iterate(.{0});
    _ = try early.next();
    early.deinit();

    // connection is back in sync after the abandoned iterator
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT 42 AS x", .{})).?;
    try t.expectEqual(@as(i64, 42), row.int("x"));
}

test "api > iterate formats dates per row" {
    var database = try openTestDatabase();
    defer database.deinit();
    var stmt = try database.prepare("SELECT CAST('2024-01-05' AS DATE) AS d, CAST(18446744073709551615 AS UNSIGNED) - n AS big FROM (SELECT 1 AS n UNION ALL SELECT 2) x WHERE n > ?", .{});
    defer stmt.deinit();
    var it = try stmt.iterate(.{0});
    defer it.deinit();
    var seen: usize = 0;
    while (try it.next()) |row| {
        seen += 1;
        try t.expectEqualStrings("2024-01-05", row.text("d"));
        try t.expectEqual(@as(usize, 20), row.text("big").len);
    }
    try t.expectEqual(@as(usize, 2), seen);
}

fn insertThenFail(_: void, database: Db) anyerror!void {
    _ = try database.run("INSERT INTO users (name, score) VALUES (?, ?)", .{ "Rolled", 1.0 });
    return error.Boom;
}

fn insertOk(_: void, database: Db) anyerror!void {
    _ = try database.run("INSERT INTO users (name, score) VALUES (?, ?)", .{ "Committed", 1.0 });
}

fn countUsers(database: Db) !i64 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    return (try database.get(arena.allocator(), "SELECT COUNT(*) AS n FROM users", .{})).?.int("n");
}

test "api > transaction commit and rollback" {
    var database = try openSeeded();
    defer database.deinit();
    try t.expectError(error.Boom, database.transaction(.{}, {}, insertThenFail));
    try t.expectEqual(@as(i64, 2), try countUsers(database));

    try database.transaction(.{ .mode = .immediate }, {}, insertOk);
    try t.expectEqual(@as(i64, 3), try countUsers(database));

    // "Committed" exists now; the failed statement rolls the serializable transaction back
    try t.expectError(error.ConstraintUnique, database.transaction(.{ .mode = .exclusive }, {}, insertOk));
    try t.expectEqual(@as(i64, 3), try countUsers(database));
}

test "api > errors map to shared names" {
    var database = try openSeeded();
    defer database.deinit();

    try t.expectError(error.ConstraintUnique, database.run("INSERT INTO users (name, score) VALUES (?, ?)", .{ "Ada", 1.0 }));
    try t.expectError(error.ConstraintNotNull, database.run("INSERT INTO users (name, score) VALUES (?, NULL)", .{"X"}));
    // prepare is lazy; the error surfaces on first execution or metadata access
    var bad = try database.prepare("SELECT FROM nowhere_table", .{});
    defer bad.deinit();
    try t.expectError(error.InvalidQuery, bad.columnNames());
    try t.expectError(error.InvalidQuery, bad.all(t.allocator, .{}));
    try t.expectError(error.InvalidQuery, database.run("SELEC 1", .empty));
    try t.expectError(error.InvalidQuery, database.run("SELECT * FROM nowhere_table WHERE a = ?", .{1}));
    // a failing statement inside a multi-statement script ends the script
    try t.expectError(error.InvalidQuery, database.run("SELECT 1; SELEC 2", .empty));
    // still usable after errors
    try t.expectEqual(@as(i64, 2), try countUsers(database));
}

test "api > multiple result sets" {
    var database = try openTestDatabase();
    defer database.deinit();
    _ = try database.run("DROP PROCEDURE IF EXISTS ziex_multi", .empty);
    _ = try database.run("CREATE PROCEDURE ziex_multi(IN x INT) BEGIN SELECT x AS a; SELECT x + 1 AS b; END", .empty);
    defer _ = database.run("DROP PROCEDURE IF EXISTS ziex_multi", .empty) catch {};

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // text and binary protocols both walk to the end and leave the connection usable
    _ = try database.run("CALL ziex_multi(1)", .empty);
    _ = try database.run("CALL ziex_multi(?)", .{1});
    const rows = try database.all(a, "CALL ziex_multi(?)", .{5});
    // only the first result set is exposed
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqual(@as(i64, 5), rows[0].int("a"));

    _ = try database.run("SELECT 1; SELECT 2; SELECT 3", .empty);
    const row = (try database.get(a, "SELECT 7 AS ok", .{})).?;
    try t.expectEqual(@as(i64, 7), row.int("ok"));
}

test "api > pooled connections serve concurrent queries" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var database = try Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 3 });
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
    const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS c, CAST(SUM(n) AS SIGNED) AS s FROM ziex_pool_test", .{})).?;
    try t.expectEqual(@as(i64, 8), row.int("c"));
    try t.expectEqual(@as(i64, 28), row.int("s"));
}

fn insertN(database: Db, n: i64) void {
    _ = database.run("INSERT INTO ziex_pool_test (n) VALUES (?)", .{n}) catch |err| std.debug.panic("insert failed: {s}", .{@errorName(err)});
}

test "api > bad credentials fail at open" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var parsed = try zx.Db.Mysql.uri.parse(t.allocator, url);
    defer parsed.deinit();

    const bad = try t.allocator.print("mysql://{s}:definitely-wrong@{s}:{d}/{s}?sslmode={s}", .{
        parsed.user, parsed.host, parsed.port, parsed.database orelse "", @tagName(parsed.sslmode),
    });
    defer t.allocator.free(bad);
    try t.expectError(error.OpenFailed, Mysql.open(t.allocator, t.io, bad, .{}));
}

test "api > readonly option rejects writes" {
    const url = try testUrl();
    defer t.allocator.free(url);
    var database = try Mysql.open(t.allocator, t.io, url, .{ .readonly = true, .max_pool_size = 1 });
    defer database.deinit();
    try t.expectError(error.QueryFailed, database.run("CREATE TABLE ziex_ro_test (id INT)", .empty));
}

fn urlWith(param: []const u8) ![]u8 {
    const url = try testUrl();
    defer t.allocator.free(url);
    const sep: u8 = if (std.mem.findScalar(u8, url, '?') == null) '?' else '&';
    return t.allocator.print("{s}{c}{s}", .{ url, sep, param });
}

fn cipher(database: Db) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SHOW SESSION STATUS LIKE 'Ssl_cipher'", .{})).?;
    return t.allocator.dupe(u8, row.text("Value"));
}

test "api > tls follows sslmode" {
    {
        const url = try urlWith("sslmode=disable");
        defer t.allocator.free(url);
        var database = try Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
        defer database.deinit();
        const name = try cipher(database);
        defer t.allocator.free(name);
        try t.expectEqualStrings("", name);
    }
    {
        const url = try urlWith("sslmode=require");
        defer t.allocator.free(url);
        var database = Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 1 }) catch |err| switch (err) {
            // server without TLS, or std.crypto.tls can't answer MySQL's CertificateRequest
            error.TlsUnavailable, error.TlsUnexpectedMessage => return error.SkipZigTest,
            else => return err,
        };
        defer database.deinit();
        const name = try cipher(database);
        defer t.allocator.free(name);
        try t.expect(name.len > 0);

        // queries keep working over the encrypted channel
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const row = (try database.get(arena.allocator(), "SELECT ? AS x", .{"over tls"})).?;
        try t.expectEqualStrings("over tls", row.text("x"));
    }
}

fn preparedCount(database: Db) !i64 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'", .{})).?;
    return try std.fmt.parseInt(i64, row.text("Value"), 10);
}

test "api > statement cache is bounded and can be disabled" {
    {
        const url = try urlWith("statement_cache_size=2");
        defer t.allocator.free(url);
        var database = try Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
        defer database.deinit();
        for (1..6) |i| {
            const sql = try t.allocator.print("SELECT {d} + ? AS v", .{i});
            defer t.allocator.free(sql);
            _ = try database.run(sql, .{1});
        }
        try t.expectEqual(@as(i64, 2), try preparedCount(database));
    }
    {
        const url = try urlWith("statement_cache_size=0");
        defer t.allocator.free(url);
        var database = try Mysql.open(t.allocator, t.io, url, .{ .max_pool_size = 1 });
        defer database.deinit();
        for (0..3) |_| _ = try database.run("SELECT ? AS v", .{1});
        var stmt = try database.prepare("SELECT ? AS v, 1 AS w", .{});
        defer stmt.deinit();
        try t.expectEqual(@as(usize, 2), (try stmt.columnNames()).len);
        try t.expectEqual(@as(i64, 0), try preparedCount(database));
    }
}

test "api > cached statements are reused across executions" {
    var database = try openTestDatabase();
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try preparedCount(database);
    for (0..5) |i| {
        const row = (try database.get(a, "SELECT ? + 1 AS v /* zx cache reuse */", .{@as(i64, @intCast(i))})).?;
        try t.expectEqual(@as(i64, @intCast(i)) + 1, row.int("v"));
    }
    try t.expectEqual(before + 1, try preparedCount(database));
}

test "api > large payloads cross the 16 MiB packet boundary" {
    var database = try openTestDatabase();
    defer database.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const max_packet = (try database.get(a, "SELECT @@max_allowed_packet AS m", .{})).?.int("m");
    if (max_packet < 40 * 1024 * 1024) return error.SkipZigTest;

    _ = try database.run("CREATE TEMPORARY TABLE big (b LONGBLOB)", .empty);
    const size = 17 * 1024 * 1024;
    const payload = try t.allocator.alloc(u8, size);
    defer t.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 7);
    _ = try database.run("INSERT INTO big VALUES (?)", .{Db.Value{ .blob = payload }});

    const row = (try database.get(a, "SELECT b, LENGTH(b) AS n FROM big WHERE ? = 1", .{1})).?;
    try t.expectEqual(@as(i64, size), row.int("n"));
    try t.expectEqualSlices(u8, payload, row.get("b").?.blob);
    // same over the text protocol
    const text_row = (try database.get(a, "SELECT b FROM big", .{})).?;
    try t.expectEqualSlices(u8, payload, text_row.get("b").?.blob);
}
