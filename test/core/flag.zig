const std = @import("std");
const zx = @import("zx");

const Flag = zx.Flag;
const Harness = zx.testing.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;

fn withServer(comptime case: fn (arena: std.mem.Allocator, base: []const u8) anyerror!void) !void {
    var harness = try Harness.start(.std, io, gpa, .{});
    defer harness.stop();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const base = try arena.allocator().print("http://127.0.0.1:{d}/flag", .{harness.tcp.?.port});
    try case(arena.allocator(), base);
}

const pro: Flag.Context = .{
    .targeting_key = "user-1",
    .attributes = &.{.{ .name = "plan", .value = .{ .string = "pro" } }},
};

// --- Interface --- //

test "failing > returns the default with ProviderNotReady" {
    const d = Flag.failing.details(bool, gpa, "any", true, .{});
    try std.testing.expectEqual(true, d.value);
    try std.testing.expectEqual(Flag.Reason.@"error", d.reason);
    try std.testing.expectEqual(error.ProviderNotReady, d.err.?);
}

test "zx.flag > defaults to failing" {
    try std.testing.expectEqualStrings("fallback", zx.flag.value([]const u8, gpa, "title", "fallback", .{}));
}

test "provider > type by tag" {
    try std.testing.expect(Flag.Provider.ofrep.Type() == Flag.Ofrep);
    try std.testing.expect(Flag.Provider.flagship.Type() == Flag.Flagship);
    try std.testing.expect(Flag.Provider.kv.Type() == Flag.Kv);
}

test "context > serializes targetingKey and attributes" {
    const json = try std.json.Stringify.valueAlloc(gpa, pro, .{});
    defer gpa.free(json);
    try std.testing.expectEqualStrings("{\"targetingKey\":\"user-1\",\"plan\":\"pro\"}", json);
    try std.testing.expectEqualStrings("pro", pro.get("plan").?.string);
    try std.testing.expect(pro.get("region") == null);
}

// --- Memory --- //

fn proPlan(context: Flag.Context) ?[]const u8 {
    const plan = context.get("plan") orelse return null;
    return if (std.mem.eql(u8, plan.string, "pro")) "on" else null;
}

var memory: Flag.Memory = .{ .flags = &.{
    .{
        .key = "new-ui",
        .variants = &.{ .{ .name = "on", .value = .{ .boolean = true } }, .{ .name = "off", .value = .{ .boolean = false } } },
        .default_variant = "off",
        .evaluator = &proPlan,
    },
    .{ .key = "limit", .variants = &.{.{ .name = "base", .value = .{ .int = 300 } }}, .default_variant = "base" },
    .{ .key = "title", .variants = &.{.{ .name = "a", .value = .{ .string = "Hello" } }}, .default_variant = "a" },
    .{ .key = "off", .variants = &.{.{ .name = "on", .value = .{ .boolean = true } }}, .default_variant = "on", .disabled = true },
    .{ .key = "broken", .variants = &.{}, .default_variant = "nope" },
} };

test "memory > static default variant" {
    const d = memory.flag().details(bool, gpa, "new-ui", true, .{});
    try std.testing.expectEqual(false, d.value);
    try std.testing.expectEqualStrings("off", d.variant.?);
    try std.testing.expectEqual(Flag.Reason.static, d.reason);
    try std.testing.expect(d.err == null);
}

test "memory > targeting match" {
    const d = memory.flag().details(bool, gpa, "new-ui", false, pro);
    try std.testing.expectEqual(true, d.value);
    try std.testing.expectEqualStrings("on", d.variant.?);
    try std.testing.expectEqual(Flag.Reason.targeting_match, d.reason);
}

test "memory > disabled returns the default" {
    const d = memory.flag().details(bool, gpa, "off", false, .{});
    try std.testing.expectEqual(false, d.value);
    try std.testing.expectEqual(Flag.Reason.disabled, d.reason);
    try std.testing.expect(d.err == null);
}

test "memory > flag not found" {
    const d = memory.flag().details(bool, gpa, "nope", true, .{});
    try std.testing.expectEqual(true, d.value);
    try std.testing.expectEqual(error.FlagNotFound, d.err.?);
}

test "memory > type mismatch returns the default" {
    const f = memory.flag();
    try std.testing.expectEqual(error.TypeMismatch, f.details(bool, gpa, "limit", true, .{}).err.?);
    try std.testing.expectEqual(error.TypeMismatch, f.details([]const u8, gpa, "limit", "x", .{}).err.?);
    // Out of range for the requested integer.
    try std.testing.expectEqual(error.TypeMismatch, f.details(u8, gpa, "limit", 7, .{}).err.?);
    try std.testing.expectEqual(@as(u8, 7), f.value(u8, gpa, "limit", 7, .{}));
}

test "memory > numbers and strings" {
    const f = memory.flag();
    try std.testing.expectEqual(@as(u32, 300), f.value(u32, gpa, "limit", 0, .{}));
    try std.testing.expectEqual(@as(f64, 300), f.value(f64, gpa, "limit", 0, .{}));
    try std.testing.expectEqualStrings("Hello", f.value([]const u8, gpa, "title", "", .{}));
}

test "memory > missing variant is a general error" {
    try std.testing.expectEqual(error.General, memory.flag().details(bool, gpa, "broken", false, .{}).err.?);
}

// --- Kv --- //

var kv_fs = zx.Kv.Fs{
    .io = io,
    .subdir = "zig-out" ++ std.Io.Dir.path.sep_str ++ "test-data" ++ std.Io.Dir.path.sep_str ++ "flag",
};

test "kv > definition roundtrip" {
    var kv: Flag.Kv = .{ .store = kv_fs.kv() };
    try kv.put(gpa, .{
        .key = "kv-banner",
        .variants = &.{ .{ .name = "a", .value = .{ .string = "Sale" } }, .{ .name = "b", .value = .{ .string = "New" } } },
        .default_variant = "b",
    });
    defer kv.delete(gpa, "kv-banner") catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = kv.flag().details([]const u8, arena.allocator(), "kv-banner", "", .{});
    try std.testing.expectEqualStrings("New", d.value);
    try std.testing.expectEqualStrings("b", d.variant.?);
    try std.testing.expectEqual(Flag.Reason.static, d.reason);
}

test "kv > disabled and missing" {
    var kv: Flag.Kv = .{ .store = kv_fs.kv() };
    try kv.put(gpa, .{ .key = "kv-off", .variants = &.{.{ .name = "on", .value = .{ .boolean = true } }}, .default_variant = "on", .disabled = true });
    defer kv.delete(gpa, "kv-off") catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = kv.flag();
    try std.testing.expectEqual(Flag.Reason.disabled, f.details(bool, arena.allocator(), "kv-off", false, .{}).reason);
    try std.testing.expectEqual(error.FlagNotFound, f.details(bool, arena.allocator(), "kv-none", false, .{}).err.?);
}

test "kv > malformed definition is a parse error" {
    var kv: Flag.Kv = .{ .store = kv_fs.kv() };
    try kv.store.put("flag:kv-bad", "{not json", .{});
    defer kv.delete(gpa, "kv-bad") catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqual(error.ParseError, kv.flag().details(bool, arena.allocator(), "kv-bad", false, .{}).err.?);
}

// --- OFREP --- //

fn ofrep(base: []const u8, arena: std.mem.Allocator) !*Flag.Ofrep {
    const o = try arena.create(Flag.Ofrep);
    o.* = .{ .io = io, .base_url = try arena.print("{s}/ofrep/", .{base}), .api_key = "test-key" };
    return o;
}

test "ofrep > typed values" {
    try withServer(struct {
        fn run(arena: std.mem.Allocator, base: []const u8) !void {
            const f = (try ofrep(base, arena)).flag();

            const ui = f.details(bool, arena, "new-ui", false, pro);
            try std.testing.expectEqual(true, ui.value);
            try std.testing.expectEqualStrings("on", ui.variant.?);
            try std.testing.expectEqual(Flag.Reason.targeting_match, ui.reason);
            try std.testing.expectEqualStrings("web", ui.metadata.?.object.get("team").?.string);

            try std.testing.expectEqual(false, f.value(bool, arena, "new-ui", true, .{}));
            try std.testing.expectEqualStrings("Hello", f.value([]const u8, arena, "title", "", .{}));
            try std.testing.expectEqual(@as(i32, 42), f.value(i32, arena, "limit", 0, .{}));
            try std.testing.expectEqual(@as(f32, 0.5), f.value(f32, arena, "ratio", 0, .{}));
            try std.testing.expectEqual(Flag.Reason.split, f.details(f32, arena, "ratio", 0, .{}).reason);
        }
    }.run);
}

test "ofrep > object into a struct" {
    try withServer(struct {
        fn run(arena: std.mem.Allocator, base: []const u8) !void {
            const f = (try ofrep(base, arena)).flag();
            const Echo = struct { targetingKey: []const u8 = "", plan: []const u8 = "" };
            const echo = f.value(Echo, arena, "echo", .{}, pro);
            try std.testing.expectEqualStrings("user-1", echo.targetingKey);
            try std.testing.expectEqualStrings("pro", echo.plan);
        }
    }.run);
}

test "ofrep > errors return the default" {
    try withServer(struct {
        fn run(arena: std.mem.Allocator, base: []const u8) !void {
            const f = (try ofrep(base, arena)).flag();

            const off = f.details(bool, arena, "off", true, .{});
            try std.testing.expectEqual(true, off.value);
            try std.testing.expectEqual(Flag.Reason.disabled, off.reason);

            try std.testing.expectEqual(error.FlagNotFound, f.details(bool, arena, "missing", false, .{}).err.?);
            try std.testing.expectEqual(error.TargetingKeyMissing, f.details(bool, arena, "needs-key", false, .{}).err.?);
            try std.testing.expectEqual(error.TypeMismatch, f.details(bool, arena, "title", false, .{}).err.?);

            const o = try ofrep(base, arena);
            o.api_key = "wrong";
            const d = o.flag().details(bool, arena, "new-ui", true, .{});
            try std.testing.expectEqual(true, d.value);
            try std.testing.expectEqual(error.General, d.err.?);
        }
    }.run);
}

// --- Flagship --- //

fn flagship(base: []const u8, arena: std.mem.Allocator) !*Flag.Flagship {
    const f = try arena.create(Flag.Flagship);
    f.* = .{
        .io = io,
        .base_url = try arena.print("{s}/flagship", .{base}),
        .account_id = "acc",
        .app_id = "app",
        .api_token = "cf-token",
    };
    return f;
}

test "flagship > evaluates over rest" {
    try withServer(struct {
        fn run(arena: std.mem.Allocator, base: []const u8) !void {
            const f = (try flagship(base, arena)).flag();

            const d = f.details(bool, arena, "checkout", false, pro);
            try std.testing.expectEqual(true, d.value);
            try std.testing.expectEqualStrings("new", d.variant.?);
            try std.testing.expectEqual(Flag.Reason.targeting_match, d.reason);

            const wrapped = f.details([]const u8, arena, "wrapped", "v1", .{});
            try std.testing.expectEqualStrings("v2", wrapped.value);
            try std.testing.expectEqual(Flag.Reason.default, wrapped.reason);
        }
    }.run);
}

test "flagship > errors return the default" {
    try withServer(struct {
        fn run(arena: std.mem.Allocator, base: []const u8) !void {
            const p = try flagship(base, arena);
            const f = p.flag();
            try std.testing.expectEqual(error.TypeMismatch, f.details(bool, arena, "mismatch", true, .{}).err.?);
            try std.testing.expectEqual(error.FlagNotFound, f.details(bool, arena, "missing", true, .{}).err.?);
            try std.testing.expectEqual(error.InvalidContext, f.details(bool, arena, "bad", true, .{}).err.?);

            p.api_token = "wrong";
            try std.testing.expectEqual(error.General, f.details(bool, arena, "checkout", true, .{}).err.?);

            p.api_token = null;
            try std.testing.expectEqual(error.ProviderNotReady, f.details(bool, arena, "checkout", true, .{}).err.?);
        }
    }.run);
}
