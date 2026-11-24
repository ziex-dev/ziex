// postgres:// connection URL parsing.
const std = @import("std");

pub const SslMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,

    pub fn parse(value: []const u8) ?SslMode {
        const map = std.StaticStringMap(SslMode).initComptime(.{
            .{ "disable", .disable },
            .{ "allow", .prefer },
            .{ "prefer", .prefer },
            .{ "require", .require },
            .{ "verify-ca", .verify_ca },
            .{ "verify-full", .verify_full },
        });
        return map.get(value);
    }

    pub fn requiresTls(self: SslMode) bool {
        return self != .disable and self != .prefer;
    }
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16 = 5432,
    user: []const u8,
    password: ?[]const u8 = null,
    database: []const u8,
    sslmode: SslMode = .prefer,
    application_name: []const u8 = "ziex",
    /// Named prepared statements kept per connection; 0 disables (e.g. behind PgBouncer transaction pooling).
    statement_cache_size: u16 = 128,
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
    if (!std.mem.eql(u8, uri.scheme, "postgres") and !std.mem.eql(u8, uri.scheme, "postgresql"))
        return Error.InvalidUrl;

    var host: []const u8 = if (uri.host) |h| try h.toRawMaybeAlloc(a) else "localhost";
    if (host.len == 0) host = "localhost";
    // strip IPv6 brackets
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];

    const user: []const u8 = if (uri.user) |u| try u.toRawMaybeAlloc(a) else "postgres";
    const password: ?[]const u8 = if (uri.password) |p| try p.toRawMaybeAlloc(a) else null;

    const path = try uri.path.toRawMaybeAlloc(a);
    const db_name = std.mem.trimStart(u8, path, "/");

    var config: Config = .{
        .arena = undefined,
        .host = host,
        .port = uri.port orelse 5432,
        .user = if (user.len == 0) "postgres" else user,
        .password = password,
        .database = if (db_name.len == 0) (if (user.len == 0) "postgres" else user) else db_name,
    };

    if (uri.query) |q| {
        const query = try q.toRawMaybeAlloc(a);
        var it = std.mem.tokenizeScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "sslmode")) {
                config.sslmode = SslMode.parse(value) orelse return Error.InvalidUrl;
            } else if (std.mem.eql(u8, key, "application_name")) {
                config.application_name = value;
            } else if (std.mem.eql(u8, key, "statement_cache_size")) {
                config.statement_cache_size = std.fmt.parseInt(u16, value, 10) catch return Error.InvalidUrl;
            }
        }
    }

    config.arena = arena;
    return config;
}

// --- Tests --- //

const t = std.testing;

test "full url" {
    var c = try parse(t.allocator, "postgresql://ada:p%40ss%2Fw@db.example.com:6543/app?sslmode=verify-full&application_name=web");
    defer c.deinit();
    try t.expectEqualStrings("db.example.com", c.host);
    try t.expectEqual(@as(u16, 6543), c.port);
    try t.expectEqualStrings("ada", c.user);
    try t.expectEqualStrings("p@ss/w", c.password.?);
    try t.expectEqualStrings("app", c.database);
    try t.expectEqual(SslMode.verify_full, c.sslmode);
    try t.expectEqualStrings("web", c.application_name);
    try t.expectEqual(@as(u16, 128), c.statement_cache_size);
}

test "statement cache size" {
    var c = try parse(t.allocator, "postgres://u@h/db?statement_cache_size=0");
    defer c.deinit();
    try t.expectEqual(@as(u16, 0), c.statement_cache_size);
    try t.expectError(Error.InvalidUrl, parse(t.allocator, "postgres://u@h/db?statement_cache_size=-1"));
}

test "defaults" {
    var c = try parse(t.allocator, "postgres://bob@localhost");
    defer c.deinit();
    try t.expectEqual(@as(u16, 5432), c.port);
    try t.expectEqualStrings("bob", c.database);
    try t.expectEqual(@as(?[]const u8, null), c.password);
    try t.expectEqual(SslMode.prefer, c.sslmode);
}

test "ipv6 host and bad input" {
    var c = try parse(t.allocator, "postgres://u:p@[::1]:5433/db");
    defer c.deinit();
    try t.expectEqualStrings("::1", c.host);

    try t.expectError(Error.InvalidUrl, parse(t.allocator, "mysql://u@h/db"));
    try t.expectError(Error.InvalidUrl, parse(t.allocator, "postgres://u@h/db?sslmode=bogus"));
}
