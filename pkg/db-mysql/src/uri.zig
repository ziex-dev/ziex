// mysql:// and mysql2:// connection URL parsing.
const std = @import("std");

pub const SslMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,

    /// Accepts the Postgres spellings and MySQL's `ssl-mode` values.
    pub fn parse(value: []const u8) ?SslMode {
        const map = std.StaticStringMap(SslMode).initComptime(.{
            .{ "disable", .disable },
            .{ "disabled", .disable },
            .{ "allow", .prefer },
            .{ "prefer", .prefer },
            .{ "preferred", .prefer },
            .{ "require", .require },
            .{ "required", .require },
            .{ "verify-ca", .verify_ca },
            .{ "verify_ca", .verify_ca },
            .{ "verify-full", .verify_full },
            .{ "verify_full", .verify_full },
            .{ "verify_identity", .verify_full },
            .{ "verify-identity", .verify_full },
        });
        var buf: [16]u8 = undefined;
        if (value.len > buf.len) return null;
        return map.get(std.ascii.lowerString(&buf, value));
    }

    pub fn requiresTls(self: SslMode) bool {
        return self != .disable and self != .prefer;
    }
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16 = 3306,
    user: []const u8,
    password: ?[]const u8 = null,
    database: ?[]const u8 = null,
    sslmode: SslMode = .prefer,
    /// Prepared statements kept per connection; 0 prepares and closes around every execution.
    statement_cache_size: u16 = 128,
    /// caching_sha2_password/sha256_password over plaintext fetch the server's RSA key.
    allow_public_key_retrieval: bool = true,
    /// Not part of the URL; set from open options.
    readonly: bool = false,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub const Error = error{InvalidUrl};

pub fn parse(gpa: std.mem.Allocator, url: []const u8) !Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const uri = std.Uri.parse(url) catch return Error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "mysql") and !std.mem.eql(u8, uri.scheme, "mysql2") and !std.mem.eql(u8, uri.scheme, "mariadb"))
        return Error.InvalidUrl;

    var host: []const u8 = if (uri.host) |h| try h.toRawMaybeAlloc(a) else "localhost";
    if (host.len == 0) host = "localhost";
    // strip IPv6 brackets
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];

    const user: []const u8 = if (uri.user) |u| try u.toRawMaybeAlloc(a) else "root";
    const password: ?[]const u8 = if (uri.password) |p| try p.toRawMaybeAlloc(a) else null;

    const path = try uri.path.toRawMaybeAlloc(a);
    const db_name = std.mem.trimStart(u8, path, "/");

    var config: Config = .{
        .arena = undefined,
        .host = host,
        .port = uri.port orelse 3306,
        .user = if (user.len == 0) "root" else user,
        .password = password,
        .database = if (db_name.len == 0) null else db_name,
    };

    if (uri.query) |q| {
        const query = try q.toRawMaybeAlloc(a);
        var it = std.mem.tokenizeScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (eqlAny(key, &.{ "sslmode", "ssl-mode", "ssl_mode" })) {
                config.sslmode = SslMode.parse(value) orelse return Error.InvalidUrl;
            } else if (std.mem.eql(u8, key, "statement_cache_size")) {
                config.statement_cache_size = std.fmt.parseInt(u16, value, 10) catch return Error.InvalidUrl;
            } else if (eqlAny(key, &.{ "allow_public_key_retrieval", "allowPublicKeyRetrieval" })) {
                config.allow_public_key_retrieval = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
            }
        }
    }

    config.arena = arena;
    return config;
}

fn eqlAny(key: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, key, n)) return true;
    return false;
}

// --- Tests --- //

const t = std.testing;

test "full url" {
    var c = try parse(t.allocator, "mysql://ada:p%40ss%2Fw@db.example.com:3307/app?sslmode=verify-full&statement_cache_size=16");
    defer c.deinit();
    try t.expectEqualStrings("db.example.com", c.host);
    try t.expectEqual(@as(u16, 3307), c.port);
    try t.expectEqualStrings("ada", c.user);
    try t.expectEqualStrings("p@ss/w", c.password.?);
    try t.expectEqualStrings("app", c.database.?);
    try t.expectEqual(SslMode.verify_full, c.sslmode);
    try t.expectEqual(@as(u16, 16), c.statement_cache_size);
}

test "mysql2 and mariadb schemes" {
    var a = try parse(t.allocator, "mysql2://u@h/db");
    defer a.deinit();
    try t.expectEqualStrings("db", a.database.?);
    var b = try parse(t.allocator, "mariadb://u@h/db");
    defer b.deinit();
    try t.expectEqualStrings("u", b.user);
}

test "defaults" {
    var c = try parse(t.allocator, "mysql://bob@localhost");
    defer c.deinit();
    try t.expectEqual(@as(u16, 3306), c.port);
    try t.expectEqual(@as(?[]const u8, null), c.database);
    try t.expectEqual(@as(?[]const u8, null), c.password);
    try t.expectEqual(SslMode.prefer, c.sslmode);
    try t.expectEqual(@as(u16, 128), c.statement_cache_size);
    try t.expect(c.allow_public_key_retrieval);

    var d = try parse(t.allocator, "mysql://localhost/");
    defer d.deinit();
    try t.expectEqualStrings("root", d.user);
    try t.expectEqual(@as(?[]const u8, null), d.database);
}

test "ssl mode spellings" {
    try t.expectEqual(@as(?SslMode, .require), SslMode.parse("REQUIRED"));
    try t.expectEqual(@as(?SslMode, .disable), SslMode.parse("DISABLED"));
    try t.expectEqual(@as(?SslMode, .verify_full), SslMode.parse("VERIFY_IDENTITY"));
    try t.expectEqual(@as(?SslMode, null), SslMode.parse("bogus"));
    try t.expect(SslMode.require.requiresTls());
    try t.expect(!SslMode.prefer.requiresTls());

    var c = try parse(t.allocator, "mysql://u@h/db?ssl-mode=DISABLED");
    defer c.deinit();
    try t.expectEqual(SslMode.disable, c.sslmode);
}

test "options" {
    var c = try parse(t.allocator, "mysql://u@h/db?statement_cache_size=0&allow_public_key_retrieval=false");
    defer c.deinit();
    try t.expectEqual(@as(u16, 0), c.statement_cache_size);
    try t.expect(!c.allow_public_key_retrieval);
    try t.expectError(Error.InvalidUrl, parse(t.allocator, "mysql://u@h/db?statement_cache_size=-1"));
}

test "ipv6 host and bad input" {
    var c = try parse(t.allocator, "mysql://u:p@[::1]:3307/db");
    defer c.deinit();
    try t.expectEqualStrings("::1", c.host);
    try t.expectEqual(@as(u16, 3307), c.port);

    try t.expectError(Error.InvalidUrl, parse(t.allocator, "postgres://u@h/db"));
    try t.expectError(Error.InvalidUrl, parse(t.allocator, "mysql://u@h/db?sslmode=bogus"));
}
