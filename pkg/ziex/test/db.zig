// Fixture for db.test.ts: `zx.Db.Sqlite` on `Io.Web` files, as the client uses it.
// Built from a temp copy of src/runtime (see the test), so it imports by that layout.
const std = @import("std");
const Db = @import("core/Db.zig");
const Web = @import("core/Io/Web.zig");

pub const std_options_cwd = Web.cwd;
// Std's default log handler needs threads; apps get zx's.
pub const std_options: std.Options = .{ .logFn = struct {
    fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
}.log };

const gpa = std.heap.wasm_allocator;
const path = "db/default.db";

var err_name: []const u8 = "";
export fn errPtr() [*]const u8 {
    return err_name.ptr;
}
export fn errLen() usize {
    return err_name.len;
}

fn run(comptime f: fn () anyerror!void) i32 {
    f() catch |err| {
        err_name = @errorName(err);
        return 1;
    };
    return 0;
}

const Rollback = error{Rollback};

export fn write() i32 {
    return run(struct {
        fn f() !void {
            var db = try Db.Sqlite.open(gpa, Web.io(), path, .{});
            defer db.deinit();
            _ = try db.run("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, score REAL, data BLOB)", .empty);
            _ = try db.run("INSERT INTO notes (body, score, data) VALUES (?1, ?2, ?3)", .{ "héllo ✓", 1.5, Db.Value{ .blob = &.{ 0, 0xff, 0x80 } } });
            try db.transaction(.{}, {}, struct {
                fn cb(_: void, tx: Db) !void {
                    var i: i64 = 0;
                    while (i < 500) : (i += 1) _ = try tx.run("INSERT INTO notes (body, score) VALUES (?1, ?2)", .{ "bulk", i });
                }
            }.cb);
            db.transaction(.{}, {}, struct {
                fn cb(_: void, tx: Db) !void {
                    _ = try tx.run("DELETE FROM notes", .empty);
                    return error.Rollback;
                }
            }.cb) catch |err| if (err != error.Rollback) return err;
        }
    }.f);
}

export fn read() i32 {
    return run(struct {
        fn f() !void {
            var db = try Db.Sqlite.open(gpa, Web.io(), path, .{});
            defer db.deinit();
            const count = (try db.get(gpa, "SELECT count(*) AS n, sum(score) AS s FROM notes", .empty)).?;
            if (count.int("n") != 501) return error.WrongCount;
            if (count.float("s") != 1.5 + 499.0 * 500.0 / 2.0) return error.WrongSum;
            const first = (try db.get(gpa, "SELECT body, data FROM notes WHERE id = 1", .empty)).?;
            if (!std.mem.eql(u8, first.text("body"), "héllo ✓")) return error.WrongText;
            const blob = switch (first.get("data").?) {
                .blob => |b| b,
                else => return error.NotBlob,
            };
            if (!std.mem.eql(u8, blob, &.{ 0, 0xff, 0x80 })) return error.WrongBlob;
        }
    }.f);
}
