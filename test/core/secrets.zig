const std = @import("std");
const zx = @import("zx");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Map = std.process.Environ.Map;

fn expectEntry(map: *const Map, key: []const u8, expected: []const u8) !void {
    const value = map.get(key) orelse {
        std.debug.print("missing key: {s}\n", .{key});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(expected, value);
}

test "dotenv: keys, separators and comments" {
    var map: Map = .init(gpa);
    defer map.deinit();
    try zx.Secrets.dotenv.parse(&map,
        \\# comment
        \\PLAIN=hello
        \\SPACED  =   padded value
        \\export EXPORTED=yes
        \\COLON: value
        \\EMPTY=
        \\INLINE=value # trailing comment
        \\HASH=http://x/#frag
        \\dotted.key-name=ok
        \\not a line
        \\PLAIN=override
        \\
    , null);

    try expectEntry(&map, "PLAIN", "override");
    try expectEntry(&map, "SPACED", "padded value");
    try expectEntry(&map, "EXPORTED", "yes");
    try expectEntry(&map, "COLON", "value");
    try expectEntry(&map, "EMPTY", "");
    try expectEntry(&map, "INLINE", "value");
    try expectEntry(&map, "HASH", "http://x/#frag");
    try expectEntry(&map, "dotted.key-name", "ok");
    try std.testing.expectEqual(8, map.count());
}

test "dotenv: quoted values" {
    var map: Map = .init(gpa);
    defer map.deinit();
    try zx.Secrets.dotenv.parse(&map,
        \\DOUBLE="a\nb\t\"c\" # not a comment" # comment
        \\SINGLE='raw\n $HOME'
        \\BACKTICK=`it's "fine"`
        \\MULTI="line 1
        \\line 2"
        \\WINDOWS="C:\\path"
        \\UNCLOSED="abc
    , null);

    try expectEntry(&map, "DOUBLE", "a\nb\t\"c\" # not a comment");
    try expectEntry(&map, "SINGLE", "raw\\n $HOME");
    try expectEntry(&map, "BACKTICK", "it's \"fine\"");
    try expectEntry(&map, "MULTI", "line 1\nline 2");
    try expectEntry(&map, "UNCLOSED", "\"abc");
    try expectEntry(&map, "WINDOWS", "C:\\path");
}

test "dotenv: expansion" {
    var base: Map = .init(gpa);
    defer base.deinit();
    try base.put("HOST", "example.com");

    var map: Map = .init(gpa);
    defer map.deinit();
    try zx.Secrets.dotenv.parse(&map,
        \\PORT=8080
        \\URL=https://${HOST}:$PORT/api
        \\FALLBACK=${MISSING:-default}
        \\ESCAPED=\$HOST
        \\LONE=cost $ 5
        \\RAW='${HOST}'
        \\
    , &base);

    try expectEntry(&map, "URL", "https://example.com:8080/api");
    try expectEntry(&map, "FALLBACK", "default");
    try expectEntry(&map, "ESCAPED", "$HOST");
    try expectEntry(&map, "LONE", "cost $ 5");
    try expectEntry(&map, "RAW", "${HOST}");
}

test "env: .env file priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const files = [_][2][]const u8{
        .{ ".env", "A=env\nB=env\nC=env\nD=env\nE=env\nBASE=root" },
        .{ ".env.staging", "B=staging\nC=staging\nD=staging\nREF=${BASE}/x" },
        .{ ".env.local", "C=local\nD=local" },
        .{ ".env.staging.local", "D=staging.local" },
        .{ ".env.production", "A=production" },
    };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });

    var env: zx.Secrets.Env = .init(gpa);
    defer env.deinit();
    try env.map.put("E", "process");
    try env.load(io, .{ .dir = tmp.dir, .mode = "staging" });

    try expectEntry(&env.map, "A", "env");
    try expectEntry(&env.map, "B", "staging");
    try expectEntry(&env.map, "C", "local");
    try expectEntry(&env.map, "D", "staging.local");
    try expectEntry(&env.map, "E", "process");
    try expectEntry(&env.map, "REF", "root/x");
}

test "env: test mode skips .env.local" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env.local", .data = "A=local" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env.test", .data = "A=test" });

    var env: zx.Secrets.Env = .init(gpa);
    defer env.deinit();
    try env.load(io, .{ .dir = tmp.dir, .mode = "test" });
    try expectEntry(&env.map, "A", "test");
}

test "secrets: get, require and chain" {
    var primary: zx.Secrets.Env = .init(gpa);
    defer primary.deinit();
    try primary.map.put("API_KEY", "primary");

    var fallback: zx.Secrets.Env = .init(gpa);
    defer fallback.deinit();
    try fallback.map.put("API_KEY", "fallback");
    try fallback.map.put("DB_URL", "postgres://");

    const stores = [_]zx.Secrets{ primary.secrets(), fallback.secrets() };
    const chain: zx.Secrets.Chain = .{ .stores = &stores };
    const secrets = chain.secrets();

    const key = try secrets.require(gpa, "API_KEY");
    defer gpa.free(key);
    try std.testing.expectEqualStrings("primary", key);

    const db = (try secrets.get(gpa, "DB_URL")).?;
    defer gpa.free(db);
    try std.testing.expectEqualStrings("postgres://", db);

    try std.testing.expectEqual(null, try secrets.get(gpa, "NOPE"));
    try std.testing.expectError(error.SecretNotFound, secrets.require(gpa, "NOPE"));
    try std.testing.expectError(error.Unavailable, zx.Secrets.failing.get(gpa, "X"));
}
