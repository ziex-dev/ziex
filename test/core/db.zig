const std = @import("std");
const zx = @import("zx");

const Db = zx.Db;
const Sqlite = Db.Sqlite;
var next_db_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

test "api > module surface compiles" {
    const options = Db.OpenOptions{
        .readonly = true,
        .create = false,
        .max_pool_size = 1,
    };

    const sqlite_options = Db.Sqlite.OpenOptions{
        .readonly = true,
        .safe_integers = true,
        .strict = true,
    };
    _ = sqlite_options;

    const value = Db.Value{ .integer = 42 };
    const bindings = Db.Bindings.fromPositional(&.{value});
    const named = Db.Bindings.fromNamed(&.{.{ .name = "$id", .value = value }});

    _ = options;
    _ = bindings;
    _ = named;
    _ = Db.Value.of;
    _ = Db.prepare;
    _ = Db.run;
    _ = Db.get;
    _ = Db.all;
    _ = Db.row;
    _ = Db.rows;
    _ = Db.transaction;
    _ = Db.transactionWith;
    _ = Db.close;

    _ = Db.Sqlite.open;
    _ = Db.Sqlite.deserialize;
    _ = Db.Sqlite.from;
    _ = Db.Sqlite.serialize;
    _ = Db.Sqlite.loadExtension;
    _ = Db.Sqlite.fileControl;
    _ = Db.Sqlite.nativeHandle;
    _ = Db.Sqlite.declaredTypes;
    _ = Db.Sqlite.nativeStatement;
    _ = Db.Statement.all;
    _ = Db.Statement.get;
    _ = Db.Statement.run;
    _ = Db.Statement.values;
    _ = Db.Statement.iterate;
    _ = Db.Statement.deinit;
    _ = Db.Statement.toString;
    _ = Db.Statement.columnNames;
    _ = Db.Statement.columnTypes;
    _ = Db.Statement.paramCount;
    _ = Db.Row.int;
    _ = Db.Row.float;
    _ = Db.Row.text;
    _ = Db.Row.boolean;
    _ = Db.Row.isNull;
}

test "api > database open and run" {
    var database = try openTestDatabase();
    defer database.deinit();

    const create_result = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);
    try std.testing.expectEqual(@as(usize, 0), create_result.changes);

    const insert_result = try database.run(
        "INSERT INTO users (name, score) VALUES (?1, ?2)",
        .{ "Ada", 9.5 },
    );
    try std.testing.expectEqual(@as(usize, 1), insert_result.changes);
    try std.testing.expect(insert_result.last_insert_id > 0);
}

test "api > statement get/all/values and metadata" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var statement = try database.prepare(
        \\SELECT id, name, score
        \\FROM users
        \\WHERE name = $name
        \\ORDER BY id
    );
    defer statement.deinit();

    try std.testing.expectEqual(@as(usize, 1), try statement.paramCount());

    const column_names = try statement.columnNames();
    try std.testing.expectEqual(@as(usize, 3), column_names.len);
    try std.testing.expectEqualStrings("id", column_names[0]);
    try std.testing.expectEqualStrings("name", column_names[1]);
    try std.testing.expectEqualStrings("score", column_names[2]);

    const declared_types = try Db.Sqlite.declaredTypes(statement);
    try std.testing.expectEqual(@as(usize, 3), declared_types.len);
    try std.testing.expectEqualStrings("INTEGER", declared_types[0].?);
    try std.testing.expectEqualStrings("TEXT", declared_types[1].?);
    try std.testing.expectEqualStrings("REAL", declared_types[2].?);

    const column_types = try statement.columnTypes();
    try std.testing.expectEqual(@as(usize, 3), column_types.len);
    try std.testing.expectEqual(.integer, column_types[0]);
    try std.testing.expectEqual(.text, column_types[1]);
    try std.testing.expectEqual(.float, column_types[2]);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const row = (try statement.get(alloc, .{ .name = "Ada" })).?;
    try expectIntField(row, "id", 1);
    try expectTextField(row, "name", "Ada");
    try expectFloatField(row, "score", 9.5);

    const all_rows = try statement.all(alloc, .{ .name = "Ada" });
    try std.testing.expectEqual(@as(usize, 1), all_rows.len);
    try expectTextField(all_rows[0], "name", "Ada");

    const values_rows = try statement.values(alloc, .{ .name = "Ada" });
    try std.testing.expectEqual(@as(usize, 1), values_rows.len);
    try std.testing.expectEqual(@as(usize, 3), values_rows[0].len);
    try std.testing.expectEqual(@as(i64, 1), expectInteger(values_rows[0][0]));
    try std.testing.expectEqualStrings("Ada", expectText(values_rows[0][1]));
}

test "api > statement typed row and rows" {
    const UserRow = struct {
        id: i64,
        name: []const u8,
        score: f64,
    };

    const UserName = struct {
        id: i64,
        name: []const u8,
    };

    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var one_stmt = try database.prepare(
        \\SELECT id, name, score
        \\FROM users
        \\WHERE name = $name
    );
    defer one_stmt.deinit();

    const typed_row = (try one_stmt.row(alloc, UserRow, .{ .name = "Ada" })).?;
    try std.testing.expectEqual(@as(i64, 1), typed_row.id);
    try std.testing.expectEqualStrings("Ada", typed_row.name);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), typed_row.score, 0.0001);

    var many_stmt = try database.prepare(
        \\SELECT id, name
        \\FROM users
        \\ORDER BY id
    );
    defer many_stmt.deinit();

    const typed_rows = try many_stmt.rows(alloc, UserName, .{});
    try std.testing.expectEqual(@as(usize, 2), typed_rows.len);
    try std.testing.expectEqual(@as(i64, 1), typed_rows[0].id);
    try std.testing.expectEqualStrings("Ada", typed_rows[0].name);
    try std.testing.expectEqual(@as(i64, 2), typed_rows[1].id);
    try std.testing.expectEqualStrings("Grace", typed_rows[1].name);

    const raw_row = (try one_stmt.get(alloc, .{ .name = "Ada" })).?;
    try std.testing.expectEqual(@as(i64, 1), try raw_row.as("id", i64));
    try std.testing.expectEqualStrings("Ada", try raw_row.as("name", []const u8));
    try std.testing.expectError(Db.Error.InvalidQuery, raw_row.as("missing_column", i64));
}

test "api > statement run with named bindings" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);

    var statement = try database.prepare("INSERT INTO users (name, score) VALUES ($name, $score)");
    defer statement.deinit();

    const result = try statement.run(.{ .name = "Grace", .score = 8.25 });
    try std.testing.expectEqual(@as(usize, 1), result.changes);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS total FROM users WHERE name = 'Grace'", .{})).?;
    try expectIntField(row, "total", 1);
}

test "api > transaction commit and rollback" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);

    try database.transactionWith(.immediate, {}, insertCommittedUser);
    try std.testing.expectEqual(@as(i64, 1), try countUsers(&database));

    const rollback_result = database.transactionWith(.exclusive, {}, insertThenFail);
    try std.testing.expectError(error.ExpectedRollback, rollback_result);
    try std.testing.expectEqual(@as(i64, 1), try countUsers(&database));
}

test "api > file url persists across reopen" {
    const url = try makeTestDatabaseUrl(std.testing.allocator);
    defer freeTestDatabaseUrl(std.testing.allocator, url);

    {
        var database = try Sqlite.open(
            std.testing.allocator,
            std.testing.io,
            url,
            .{},
        );
        defer database.deinit();

        _ = try database.run(
            \\CREATE TABLE visits (
            \\  id INTEGER PRIMARY KEY,
            \\  note TEXT NOT NULL
            \\)
        , .empty);

        _ = try database.run(
            "INSERT INTO visits (note) VALUES (?1)",
            .{"first"},
        );
    }

    {
        var database = try Sqlite.open(
            std.testing.allocator,
            std.testing.io,
            url,
            .{},
        );
        defer database.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS total FROM visits", .{})).?;
        try expectIntField(row, "total", 1);
    }
}

test "api > value types: null, blob, boolean round-trip" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE items (
        \\  id INTEGER PRIMARY KEY,
        \\  payload BLOB,
        \\  flag INTEGER,
        \\  note TEXT
        \\)
    , .empty);

    const blob_bytes = [_]u8{ 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00 };

    // Bind a blob, a boolean, and an explicit NULL (via optional).
    const maybe_note: ?[]const u8 = null;
    _ = try database.run(
        "INSERT INTO items (payload, flag, note) VALUES (?1, ?2, ?3)",
        .{ Db.Value{ .blob = &blob_bytes }, true, maybe_note },
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const row = (try database.get(alloc, "SELECT payload, flag, note FROM items", .{})).?;

    // Blob comes back as a blob value.
    switch (row.get("payload").?) {
        .blob => |bytes| try std.testing.expectEqualSlices(u8, &blob_bytes, bytes),
        else => return error.UnexpectedValueType,
    }

    // Row accessors: boolean coercion from integer, null detection.
    try std.testing.expectEqual(true, row.boolean("flag"));
    try std.testing.expectEqual(@as(i64, 1), row.int("flag"));
    try std.testing.expect(row.isNull("note"));
    try std.testing.expect(!row.isNull("flag"));
}

test "api > row accessors coerce and default" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const row = (try database.get(arena.allocator(), "SELECT id, name, score FROM users WHERE name = 'Ada'", .{})).?;

    // int() coerces float, float() coerces int, text() returns the string.
    try std.testing.expectEqual(@as(i64, 1), row.int("id"));
    try std.testing.expectEqual(@as(i64, 9), row.int("score")); // 9.5 -> 9
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), row.float("id"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), row.float("score"), 0.0001);
    try std.testing.expectEqualStrings("Ada", row.text("name"));

    // Missing columns return zero values, not errors, from the accessors.
    try std.testing.expectEqual(@as(i64, 0), row.int("missing"));
    try std.testing.expectApproxEqAbs(@as(f64, 0), row.float("missing"), 0.0001);
    try std.testing.expectEqualStrings("", row.text("missing"));
    try std.testing.expectEqual(false, row.boolean("missing"));
    try std.testing.expect(row.isNull("missing"));
    try std.testing.expectEqual(@as(?Db.Value, null), row.get("missing"));
}

test "api > typed row with optional and bool fields" {
    const Item = struct {
        id: i64,
        note: ?[]const u8,
        flag: bool,
    };

    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE items (
        \\  id INTEGER PRIMARY KEY,
        \\  note TEXT,
        \\  flag INTEGER NOT NULL
        \\)
    , .empty);

    const present: ?[]const u8 = "hi";
    const absent: ?[]const u8 = null;
    _ = try database.run("INSERT INTO items (note, flag) VALUES (?1, ?2)", .{ present, true });
    _ = try database.run("INSERT INTO items (note, flag) VALUES (?1, ?2)", .{ absent, false });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rows = try database.rows(alloc, Item, "SELECT id, note, flag FROM items ORDER BY id", .{});
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    try std.testing.expectEqualStrings("hi", rows[0].note.?);
    try std.testing.expectEqual(true, rows[0].flag);

    try std.testing.expectEqual(@as(?[]const u8, null), rows[1].note);
    try std.testing.expectEqual(false, rows[1].flag);
}

test "api > value.of comptime conversions" {
    try std.testing.expectEqual(Db.Value.null, Db.Value.of(null));
    try std.testing.expectEqual(Db.Value{ .boolean = true }, Db.Value.of(true));
    try std.testing.expectEqual(Db.Value{ .integer = 7 }, Db.Value.of(@as(u8, 7)));
    try std.testing.expectEqual(Db.Value{ .integer = 42 }, Db.Value.of(42));

    switch (Db.Value.of(3.5)) {
        .float => |v| try std.testing.expectApproxEqAbs(@as(f64, 3.5), v, 0.0001),
        else => return error.UnexpectedValueType,
    }
    switch (Db.Value.of("hi")) {
        .text => |v| try std.testing.expectEqualStrings("hi", v),
        else => return error.UnexpectedValueType,
    }

    // Optional with a value unwraps; identity passthrough for an existing Value.
    const some: ?i64 = 9;
    try std.testing.expectEqual(Db.Value{ .integer = 9 }, Db.Value.of(some));
    const none: ?i64 = null;
    try std.testing.expectEqual(Db.Value.null, Db.Value.of(none));
    const existing = Db.Value{ .integer = 5 };
    try std.testing.expectEqual(existing, Db.Value.of(existing));
}

test "api > explicit bindings positional and named slices" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var positional_stmt = try database.prepare("SELECT name FROM users WHERE score > ?1 ORDER BY id");
    defer positional_stmt.deinit();

    const positional = Db.Bindings.fromPositional(&.{.{ .float = 9.0 }});
    const positional_rows = try positional_stmt.all(alloc, positional);
    try std.testing.expectEqual(@as(usize, 1), positional_rows.len);
    try expectTextField(positional_rows[0], "name", "Ada");

    var named_stmt = try database.prepare("SELECT name FROM users WHERE name = $who");
    defer named_stmt.deinit();

    const named = Db.Bindings.fromNamed(&.{.{ .name = "$who", .value = .{ .text = "Grace" } }});
    const named_row = (try named_stmt.get(alloc, named)).?;
    try expectTextField(named_row, "name", "Grace");
}

test "api > prepared statement reused with different bindings" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var statement = try database.prepare("SELECT id FROM users WHERE name = $name");
    defer statement.deinit();

    const ada = (try statement.get(alloc, .{ .name = "Ada" })).?;
    try expectIntField(ada, "id", 1);

    // Re-run the same prepared statement with a different binding.
    const grace = (try statement.get(alloc, .{ .name = "Grace" })).?;
    try expectIntField(grace, "id", 2);

    // And once more, back to the first.
    const ada_again = (try statement.get(alloc, .{ .name = "Ada" })).?;
    try expectIntField(ada_again, "id", 1);
}

test "api > statement iterate yields rows then null" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var statement = try database.prepare("SELECT name FROM users ORDER BY id");
    defer statement.deinit();

    var it = try statement.iterate(.{});
    defer it.deinit();

    // Each row is valid only until the next advance, so read it before stepping.
    const first = (try it.next()).?;
    try expectTextField(first, "name", "Ada");

    const second = (try it.next()).?;
    try expectTextField(second, "name", "Grace");

    try std.testing.expectEqual(@as(?Db.Row, null), try it.next());
    // Idempotent after exhaustion.
    try std.testing.expectEqual(@as(?Db.Row, null), try it.next());
}

test "api > iterate fully drained via loop frees every row" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var statement = try database.prepare("SELECT id FROM users ORDER BY id");
    defer statement.deinit();

    var it = try statement.iterate(.{});
    defer it.deinit();

    var count: usize = 0;
    var sum: i64 = 0;
    while (try it.next()) |row| {
        count += 1;
        sum += row.int("id");
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(i64, 3), sum); // ids 1 + 2
}

test "api > iterate abandoned early frees the in-flight row" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var statement = try database.prepare("SELECT id FROM users ORDER BY id");
    defer statement.deinit();

    var it = try statement.iterate(.{});
    // Pull one row, then bail without draining - deinit must free the held row.
    const row = (try it.next()).?;
    try std.testing.expectEqual(@as(i64, 1), row.int("id"));
    it.deinit();
}

test "api > statement to string returns the prepared sql" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run("CREATE TABLE t (id INTEGER PRIMARY KEY)", .empty);

    const sql = "SELECT id FROM t WHERE id = $id";
    var statement = try database.prepare(sql);
    defer statement.deinit();

    const rendered = try statement.toString(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(sql, rendered);
}

test "api > get and row return null on no match" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Row = struct { id: i64 };

    try std.testing.expectEqual(
        @as(?Db.Row, null),
        try database.get(alloc, "SELECT id FROM users WHERE name = $name", .{ .name = "Nobody" }),
    );
    try std.testing.expectEqual(
        @as(?@TypeOf(@as(Row, undefined)), null),
        try database.row(alloc, Row, "SELECT id FROM users WHERE name = $name", .{ .name = "Nobody" }),
    );

    const empty = try database.all(alloc, "SELECT id FROM users WHERE 1 = 0", .{});
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "api > plain and deferred transactions commit" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);

    try database.transaction({}, insertCommittedUser);
    try std.testing.expectEqual(@as(i64, 1), try countUsers(&database));

    try database.transactionWith(.deferred, {}, insertCommittedUser);
    try std.testing.expectEqual(@as(i64, 2), try countUsers(&database));
}

test "api > transaction passes typed context" {
    var database = try openTestDatabase();
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);

    const Ctx = struct { name: []const u8, score: f64 };
    const insert = struct {
        fn call(ctx: Ctx, db: Db) !void {
            _ = try db.run("INSERT INTO users (name, score) VALUES (?1, ?2)", .{ ctx.name, ctx.score });
        }
    }.call;

    try database.transaction(Ctx{ .name = "Linus", .score = 7.0 }, insert);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT score FROM users WHERE name = 'Linus'", .{})).?;
    try expectFloatField(row, "score", 7.0);
}

test "api > invalid sql surfaces an error" {
    var database = try openTestDatabase();
    defer database.deinit();

    try std.testing.expectError(error.Error, database.prepare("SELECT this is not valid sql"));
    try std.testing.expectError(error.Error, database.run("NOT A STATEMENT", .empty));
}

test "api > operations on a closed database fail" {
    var database = try openTestDatabase();
    _ = try database.run("CREATE TABLE t (id INTEGER PRIMARY KEY)", .empty);
    database.deinit();

    // The backend is freed; the vtable userdata is gone. Statement handles that
    // outlive the connection report Closed.
    try std.testing.expectError(Db.Error.Closed, requireClosedStatement());
}

fn requireClosedStatement() !void {
    var statement = Db.Statement{ .db = Db.failing };
    _ = try statement.all(std.testing.allocator, .{});
}

test "api > failing connection returns closed" {
    const database = Db.failing;

    try std.testing.expectError(Db.Error.Closed, database.prepare("SELECT 1"));
    try std.testing.expectError(Db.Error.Closed, database.run("SELECT 1", .empty));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Db.Error.Closed, database.get(arena.allocator(), "SELECT 1", .{}));
    try std.testing.expectError(Db.Error.Closed, database.all(arena.allocator(), "SELECT 1", .{}));
}

test "api > sqlite.from recovers the backend" {
    var database = try openTestDatabase();
    defer database.deinit();

    const backend = try Db.Sqlite.from(database);
    // The in-memory connection exposes a native handle.
    try std.testing.expect(backend.nativeHandle() != null);
}

test "api > serialize and deserialize round-trip" {
    var source = try openSeededDatabase();
    defer source.deinit();

    const backend = try Db.Sqlite.from(source);
    const image = try backend.serialize(std.testing.allocator);
    defer std.testing.allocator.free(image);
    try std.testing.expect(image.len > 0);

    var restored = try Sqlite.deserialize(std.testing.allocator, std.testing.io, image, .{});
    defer restored.deinit();

    try std.testing.expectEqual(@as(i64, 2), try countUsers(&restored));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = (try restored.get(arena.allocator(), "SELECT name FROM users WHERE id = 1", .{})).?;
    try expectTextField(row, "name", "Ada");
}

test "api > pooled file database serves concurrent-style queries" {
    const url = try makeTestDatabaseUrl(std.testing.allocator);
    defer freeTestDatabaseUrl(std.testing.allocator, url);

    var database = try Sqlite.open(
        std.testing.allocator,
        std.testing.io,
        url,
        .{ .max_pool_size = 3 },
    );
    defer database.deinit();

    _ = try database.run(
        \\CREATE TABLE nums (n INTEGER NOT NULL)
    , .empty);

    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        _ = try database.run("INSERT INTO nums (n) VALUES (?1)", .{i});
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS total, SUM(n) AS s FROM nums", .{})).?;
    try expectIntField(row, "total", 5);
    try expectIntField(row, "s", 10);
}

test "api > named bindings resolve across all sigils" {
    var database = try openSeededDatabase();
    defer database.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { sql: []const u8, name: []const u8 }{
        .{ .sql = "SELECT id FROM users WHERE name = $who", .name = "$who" },
        .{ .sql = "SELECT id FROM users WHERE name = :who", .name = ":who" },
        .{ .sql = "SELECT id FROM users WHERE name = @who", .name = "@who" },
    };

    for (cases) |case| {
        var statement = try database.prepare(case.sql);
        defer statement.deinit();

        const named = Db.Bindings.fromNamed(&.{.{ .name = case.name, .value = .{ .text = "Ada" } }});
        const row = (try statement.get(alloc, named)).?;
        try expectIntField(row, "id", 1);
    }

    // A bare name (no sigil) resolves against the statement's `$` parameter.
    var bare_stmt = try database.prepare("SELECT id FROM users WHERE name = $who");
    defer bare_stmt.deinit();
    const bare = Db.Bindings.fromNamed(&.{.{ .name = "who", .value = .{ .text = "Grace" } }});
    const bare_row = (try bare_stmt.get(alloc, bare)).?;
    try expectIntField(bare_row, "id", 2);

    // An unknown named parameter is rejected rather than silently ignored.
    var miss_stmt = try database.prepare("SELECT id FROM users WHERE name = $who");
    defer miss_stmt.deinit();
    const missing = Db.Bindings.fromNamed(&.{.{ .name = "$nope", .value = .{ .text = "Ada" } }});
    try std.testing.expectError(Db.Error.InvalidBindings, miss_stmt.get(alloc, missing));
}

test "api > schema option targets an attached database for serialize" {
    var database = try Sqlite.open(
        std.testing.allocator,
        std.testing.io,
        "mem://",
        .{ .schema = "aux" },
    );
    defer database.deinit();

    _ = try database.run("ATTACH DATABASE ':memory:' AS aux", .empty);
    _ = try database.run("CREATE TABLE aux.items (id INTEGER PRIMARY KEY, label TEXT NOT NULL)", .empty);
    _ = try database.run("INSERT INTO aux.items (label) VALUES (?1), (?2)", .{ "x", "y" });

    const backend = try Db.Sqlite.from(database);
    const image = try backend.serialize(std.testing.allocator);
    defer std.testing.allocator.free(image);
    try std.testing.expect(image.len > 0);

    var restored = try Sqlite.deserialize(std.testing.allocator, std.testing.io, image, .{});
    defer restored.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = (try restored.get(arena.allocator(), "SELECT COUNT(*) AS total FROM items", .{})).?;
    try expectIntField(row, "total", 2);
}

test "api > default schema still serializes main" {
    var source = try openSeededDatabase();
    defer source.deinit();

    const backend = try Db.Sqlite.from(source);
    try std.testing.expectEqualStrings("main", backend.schema);

    const image = try backend.serialize(std.testing.allocator);
    defer std.testing.allocator.free(image);

    var restored = try Sqlite.deserialize(std.testing.allocator, std.testing.io, image, .{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(i64, 2), try countUsers(&restored));
}

test "api > memory url variants open an in-memory database" {
    for ([_][]const u8{ "mem://", ":memory:", "memory:" }) |location| {
        var database = try Sqlite.open(std.testing.allocator, std.testing.io, location, .{});
        defer database.deinit();

        _ = try database.run("CREATE TABLE t (id INTEGER PRIMARY KEY)", .empty);
        _ = try database.run("INSERT INTO t (id) VALUES (1)", .empty);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS total FROM t", .{})).?;
        try expectIntField(row, "total", 1);
    }
}

fn openTestDatabase() !Db {
    return Sqlite.open(
        std.testing.allocator,
        std.testing.io,
        "mem://",
        .{},
    );
}

fn openSeededDatabase() !Db {
    var database = try openTestDatabase();
    errdefer database.deinit();

    _ = try database.run(
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score REAL NOT NULL
        \\)
    , .empty);

    _ = try database.run(
        \\INSERT INTO users (name, score) VALUES
        \\  (?1, ?2),
        \\  (?3, ?4)
    , .{ "Ada", 9.5, "Grace", 8.25 });

    return database;
}

fn countUsers(database: *Db) !i64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const row = (try database.get(arena.allocator(), "SELECT COUNT(*) AS total FROM users", .{})).?;
    return expectInteger(row.get("total") orelse .null);
}

fn insertCommittedUser(_: void, database: Db) !void {
    _ = try database.run(
        "INSERT INTO users (name, score) VALUES (?1, ?2)",
        .{ "Committed", 10.0 },
    );
}

fn insertThenFail(_: void, database: Db) !void {
    _ = try database.run(
        "INSERT INTO users (name, score) VALUES (?1, ?2)",
        .{ "Rolled Back", 1.0 },
    );
    return error.ExpectedRollback;
}

fn expectIntField(row: Db.Row, name: []const u8, expected: i64) !void {
    try std.testing.expectEqual(expected, expectInteger(row.get(name) orelse .null));
}

fn expectFloatField(row: Db.Row, name: []const u8, expected: f64) !void {
    switch (row.get(name) orelse .null) {
        .float => |value| try std.testing.expectApproxEqAbs(expected, value, 0.0001),
        .integer => |value| try std.testing.expectApproxEqAbs(expected, @as(f64, @floatFromInt(value)), 0.0001),
        else => return error.UnexpectedValueType,
    }
}

fn expectTextField(row: Db.Row, name: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, expectText(row.get(name) orelse .null));
}

fn expectInteger(value: Db.Value) i64 {
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => unreachable,
    };
}

fn expectText(value: Db.Value) []const u8 {
    return switch (value) {
        .text => |v| v,
        else => unreachable,
    };
}

fn makeTestDatabaseUrl(allocator: std.mem.Allocator) ![]const u8 {
    const id = next_db_id.fetchAdd(1, .monotonic);
    const url = try allocator.print("file:/tmp/ziex-db-test-{d}.sqlite", .{id});
    errdefer allocator.free(url);

    try cleanupDatabaseFiles(filePathFromUrl(url));

    return url;
}

fn freeTestDatabaseUrl(allocator: std.mem.Allocator, url: []const u8) void {
    cleanupDatabaseFiles(filePathFromUrl(url)) catch {};
    allocator.free(url);
}

fn filePathFromUrl(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "file:")) return url["file:".len..];
    return url;
}

fn cleanupDatabaseFiles(path: []const u8) !void {
    try deleteIfExists(path);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try deleteIfExists(try std.fmt.bufPrint(&buf, "{s}-wal", .{path}));
    try deleteIfExists(try std.fmt.bufPrint(&buf, "{s}-shm", .{path}));
    try deleteIfExists(try std.fmt.bufPrint(&buf, "{s}-journal", .{path}));
}

fn deleteIfExists(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
