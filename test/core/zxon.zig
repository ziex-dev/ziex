const std = @import("std");
const zx = @import("zx");

const zxon = zx.util.zxon;
const testing = std.testing;

// Test Fixtures
const Status = enum { pending, active, completed };
const SearchContent = struct { title: []const u8, url: []const u8, content: []const u8 };
const SearchProps = struct { search: []const u8, contents: []const SearchContent };
const SimpleProps = struct { count: i32, enabled: bool };
const NumberProps = struct { int_val: i32, negative: i32, zero: i32, float_val: f32, negative_float: f32 };
const NestedInner = struct { value: i32, flag: bool };
const NestedProps = struct { outer_val: i32, inner: NestedInner, outer_flag: bool };
const OptionalProps = struct { required: i32, optional_int: ?i32, optional_str: ?[]const u8 };
const ArrayProps = struct { scores: [3]i32, flags: [2]bool };
const EnumProps = struct { status: Status, value: i32 };
const ComplexProps = struct {
    initial: i32,
    negative: i32,
    zero_val: i32,
    float_val: f32,
    negative_float: f32,
    shared: bool,
    disabled: bool,
    label: []const u8,
    escaped_str: []const u8,
    optional_int: ?i32,
    optional_str: ?[]const u8,
    nested: NestedInner,
    scores: [3]i32,
    status: Status,
};

/// Serialize a value to an owned ZXON string (test helper).
fn encode(comptime T: type, value: T) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try zxon.serialize(value, &aw.writer, .{});
    return testing.allocator.dupe(u8, aw.written());
}

// ----- Parse – Integers ----
test "int positive" {
    const P = struct { value: i32 };
    try testing.expectEqual(@as(i32, 42), (try zxon.parse(P, testing.allocator, "[42]", .{})).value);
}

test "int negative" {
    const P = struct { value: i32 };
    try testing.expectEqual(@as(i32, -100), (try zxon.parse(P, testing.allocator, "[-100]", .{})).value);
}

test "int zero" {
    const P = struct { value: i32 };
    try testing.expectEqual(@as(i32, 0), (try zxon.parse(P, testing.allocator, "[0]", .{})).value);
}

test "int max" {
    const P = struct { value: i32 };
    try testing.expectEqual(@as(i32, 2147483647), (try zxon.parse(P, testing.allocator, "[2147483647]", .{})).value);
}

test "int min" {
    const P = struct { value: i32 };
    try testing.expectEqual(@as(i32, -2147483648), (try zxon.parse(P, testing.allocator, "[-2147483648]", .{})).value);
}

test "int multiple" {
    const r = try zxon.parse(NumberProps, testing.allocator, "[42,-100,0,0,0]", .{});
    try testing.expectEqual(@as(i32, 42), r.int_val);
    try testing.expectEqual(@as(i32, -100), r.negative);
    try testing.expectEqual(@as(i32, 0), r.zero);
}

// ----- Parse – Floats ----
test "float positive" {
    const P = struct { value: f32 };
    try testing.expectApproxEqAbs(@as(f32, 3.14), (try zxon.parse(P, testing.allocator, "[3.14]", .{})).value, 0.001);
}

test "float negative" {
    const P = struct { value: f32 };
    try testing.expectApproxEqAbs(@as(f32, -2.5), (try zxon.parse(P, testing.allocator, "[-2.5]", .{})).value, 0.001);
}

test "float zero" {
    const P = struct { value: f32 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), (try zxon.parse(P, testing.allocator, "[0.0]", .{})).value, 0.001);
}

test "float small" {
    const P = struct { value: f32 };
    try testing.expectApproxEqAbs(@as(f32, 0.000001), (try zxon.parse(P, testing.allocator, "[0.000001]", .{})).value, 0.0000001);
}

test "float scientific" {
    const P = struct { value: f32 };
    try testing.expectApproxEqAbs(@as(f32, 1500.0), (try zxon.parse(P, testing.allocator, "[1.5e3]", .{})).value, 0.1);
}

// ----- Parse – Booleans ----
test "bool true" {
    const P = struct { value: bool };
    try testing.expect((try zxon.parse(P, testing.allocator, "[true]", .{})).value);
}

test "bool false" {
    const P = struct { value: bool };
    try testing.expect(!(try zxon.parse(P, testing.allocator, "[false]", .{})).value);
}

test "bool multiple" {
    const P = struct { a: bool, b: bool, c: bool };
    const r = try zxon.parse(P, testing.allocator, "[true,false,true]", .{});
    try testing.expect(r.a and !r.b and r.c);
}

// ----- Parse – Strings -----
test "string simple" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"hello\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("hello", r.value);
}

test "string empty" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("", r.value);
}

test "string spaces" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"hello world\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("hello world", r.value);
}

test "string escape newline" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"line1\\nline2\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("line1\nline2", r.value);
}

test "string escape tab" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"col1\\tcol2\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("col1\tcol2", r.value);
}

test "string escape quote" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"say \\\"hello\\\"\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("say \"hello\"", r.value);
}

test "string escape backslash" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"path\\\\to\\\\file\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("path\\to\\file", r.value);
}

test "string unicode" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"Hello 世界\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("Hello 世界", r.value);
}

test "string emoji" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"Hello 👋\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("Hello 👋", r.value);
}

// ----- Parse – Optionals -----
test "optional null" {
    const r = try zxon.parse(OptionalProps, testing.allocator, "[42,null,null]", .{});
    try testing.expectEqual(@as(i32, 42), r.required);
    try testing.expect(r.optional_int == null);
    try testing.expect(r.optional_str == null);
}

test "optional int present" {
    const r = try zxon.parse(OptionalProps, testing.allocator, "[42,100,null]", .{});
    try testing.expectEqual(@as(i32, 100), r.optional_int.?);
}

test "optional string present" {
    const r = try zxon.parse(OptionalProps, testing.allocator, "[42,null,\"hello\"]", .{});
    defer if (r.optional_str) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("hello", r.optional_str.?);
}

test "optional all present" {
    const r = try zxon.parse(OptionalProps, testing.allocator, "[42,100,\"hello\"]", .{});
    defer if (r.optional_str) |s| testing.allocator.free(s);
    try testing.expectEqual(@as(i32, 100), r.optional_int.?);
    try testing.expectEqualStrings("hello", r.optional_str.?);
}

// ----- Parse – Nested Structs -----
test "nested struct" {
    const r = try zxon.parse(NestedProps, testing.allocator, "[10,[42,true],false]", .{});
    try testing.expectEqual(@as(i32, 10), r.outer_val);
    try testing.expectEqual(@as(i32, 42), r.inner.value);
    try testing.expect(r.inner.flag and !r.outer_flag);
}

test "nested negative" {
    const r = try zxon.parse(NestedProps, testing.allocator, "[0,[-99,false],true]", .{});
    try testing.expectEqual(@as(i32, -99), r.inner.value);
    try testing.expect(!r.inner.flag and r.outer_flag);
}

test "deeply nested" {
    const Inner = struct { value: i32 };
    const Middle = struct { inner: Inner };
    const Outer = struct { middle: Middle };
    const r = try zxon.parse(Outer, testing.allocator, "[[[42]]]", .{});
    try testing.expectEqual(@as(i32, 42), r.middle.inner.value);
}

// ----- Parse – Arrays -----
test "array int" {
    const r = try zxon.parse(ArrayProps, testing.allocator, "[[1,2,3],[true,false]]", .{});
    try testing.expectEqual(@as(i32, 1), r.scores[0]);
    try testing.expectEqual(@as(i32, 2), r.scores[1]);
    try testing.expectEqual(@as(i32, 3), r.scores[2]);
}

test "array negative" {
    const r = try zxon.parse(ArrayProps, testing.allocator, "[[-1,-2,-3],[false,true]]", .{});
    try testing.expectEqual(@as(i32, -1), r.scores[0]);
    try testing.expectEqual(@as(i32, -2), r.scores[1]);
}

// ----- Parse – Enums -----
test "enum first" {
    const r = try zxon.parse(EnumProps, testing.allocator, "[0,42]", .{});
    try testing.expectEqual(Status.pending, r.status);
}

test "enum middle" {
    const r = try zxon.parse(EnumProps, testing.allocator, "[1,42]", .{});
    try testing.expectEqual(Status.active, r.status);
}

test "enum last" {
    const r = try zxon.parse(EnumProps, testing.allocator, "[2,42]", .{});
    try testing.expectEqual(Status.completed, r.status);
}

// ----- Parse – Complex -----
test "complex all types" {
    const r = try zxon.parse(ComplexProps, testing.allocator, "[42,-100,0,3.14,-2.5,true,false,\"Hello\",\"World\",null,null,[10,true],[1,2,3],1]", .{});
    defer testing.allocator.free(r.label);
    defer testing.allocator.free(r.escaped_str);

    try testing.expectEqual(@as(i32, 42), r.initial);
    try testing.expectEqual(@as(i32, -100), r.negative);
    try testing.expectApproxEqAbs(@as(f32, 3.14), r.float_val, 0.01);
    try testing.expect(r.shared and !r.disabled);
    try testing.expectEqualStrings("Hello", r.label);
    try testing.expect(r.optional_int == null);
    try testing.expectEqual(@as(i32, 10), r.nested.value);
    try testing.expectEqual(Status.active, r.status);
}

test "complex with optionals" {
    const r = try zxon.parse(ComplexProps, testing.allocator, "[42,-100,0,3.14,-2.5,true,false,\"Label\",\"Escaped\\n\",99,\"opt\",[0,false],[0,0,0],0]", .{});
    defer testing.allocator.free(r.label);
    defer testing.allocator.free(r.escaped_str);
    defer if (r.optional_str) |s| testing.allocator.free(s);

    try testing.expectEqualStrings("Escaped\n", r.escaped_str);
    try testing.expectEqual(@as(i32, 99), r.optional_int.?);
    try testing.expectEqualStrings("opt", r.optional_str.?);
}

test "complex large data" {
    const content_parsed: std.json.Parsed([]SearchContent) = std.json.parseFromSlice([]SearchContent, testing.allocator, search_txt, .{}) catch unreachable;
    defer content_parsed.deinit();

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    try zxon.serialize(content_parsed.value, &aw.writer, .{});

    const data = aw.written();
    try testing.expect(data.len > 0);
    try testing.expect(std.mem.startsWith(u8, data, "[[\"std.Io\""));
}

// --- Serialize ---
test "serialize int positive" {
    const P = struct { value: i32 };
    const data = try encode(P, .{ .value = 42 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[42]", data);
}

test "serialize nested pointer struct" {
    const search_p = SearchProps{
        .search = "query",
        .contents = &.{.{ .title = "std.Io", .url = "https://ziglang.org/", .content = "std.Io is a library for Zig." }},
    };
    const data = try encode(SearchProps, search_p);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"query\",[[\"std.Io\",\"https://ziglang.org/\",\"std.Io is a library for Zig.\"]]]", data);
}

test "serialize int negative" {
    const P = struct { value: i32 };
    const data = try encode(P, .{ .value = -100 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[-100]", data);
}

test "serialize int zero" {
    const P = struct { value: i32 };
    const data = try encode(P, .{ .value = 0 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[0]", data);
}

test "serialize multiple ints" {
    const P = struct { a: i32, b: i32, c: i32 };
    const data = try encode(P, .{ .a = 1, .b = -2, .c = 0 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[1,-2,0]", data);
}

test "serialize float positive" {
    const P = struct { value: f32 };
    const data = try encode(P, .{ .value = 3.14 });
    defer testing.allocator.free(data);
    try testing.expect(std.mem.startsWith(u8, data, "[3.14"));
}

test "serialize float negative" {
    const P = struct { value: f32 };
    const data = try encode(P, .{ .value = -2.5 });
    defer testing.allocator.free(data);
    try testing.expect(std.mem.startsWith(u8, data, "[-2.5"));
}

test "serialize bool true" {
    const P = struct { value: bool };
    const data = try encode(P, .{ .value = true });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[true]", data);
}

test "serialize bool false" {
    const P = struct { value: bool };
    const data = try encode(P, .{ .value = false });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[false]", data);
}

test "serialize string simple" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "hello" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"hello\"]", data);
}

test "serialize string empty" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"\"]", data);
}

test "serialize string with spaces" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "hello world" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"hello world\"]", data);
}

test "serialize string escape newline" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "line1\nline2" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"line1\\nline2\"]", data);
}

test "serialize string escape tab" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "col1\tcol2" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"col1\\tcol2\"]", data);
}

test "serialize string escape quote" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "say \"hello\"" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"say \\\"hello\\\"\"]", data);
}

test "serialize string escape backslash" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "path\\to\\file" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"path\\\\to\\\\file\"]", data);
}

test "serialize string escape carriage return" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "line1\rline2" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"line1\\rline2\"]", data);
}

test "serialize string unicode" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "Hello 世界" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"Hello 世界\"]", data);
}

test "serialize string emoji" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "Hello 👋" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"Hello 👋\"]", data);
}

test "serialize optional null" {
    const P = struct { value: ?i32 };
    const data = try encode(P, .{ .value = null });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[null]", data);
}

test "serialize optional present int" {
    const P = struct { value: ?i32 };
    const data = try encode(P, .{ .value = 42 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[42]", data);
}

test "serialize optional present string" {
    const P = struct { value: ?[]const u8 };
    const data = try encode(P, .{ .value = "hello" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"hello\"]", data);
}

test "serialize optional string null" {
    const P = struct { value: ?[]const u8 };
    const data = try encode(P, .{ .value = null });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[null]", data);
}

test "serialize nested struct" {
    const Inner = struct { x: i32 };
    const Outer = struct { inner: Inner };
    const data = try encode(Outer, .{ .inner = .{ .x = 42 } });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[42]]", data);
}

test "serialize deeply nested struct" {
    const A = struct { val: i32 };
    const B = struct { a: A };
    const C = struct { b: B };
    const data = try encode(C, .{ .b = .{ .a = .{ .val = 123 } } });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[[123]]]", data);
}

test "serialize nested with multiple fields" {
    const data = try encode(NestedProps, .{
        .outer_val = 10,
        .inner = .{ .value = 42, .flag = true },
        .outer_flag = false,
    });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[10,[42,true],false]", data);
}

test "serialize array int" {
    const P = struct { values: [3]i32 };
    const data = try encode(P, .{ .values = .{ 1, 2, 3 } });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[1,2,3]]", data);
}

test "serialize array bool" {
    const P = struct { flags: [2]bool };
    const data = try encode(P, .{ .flags = .{ true, false } });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[true,false]]", data);
}

test "serialize array negative" {
    const P = struct { values: [3]i32 };
    const data = try encode(P, .{ .values = .{ -1, -2, -3 } });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[-1,-2,-3]]", data);
}

test "serialize enum first" {
    const data = try encode(EnumProps, .{ .status = .pending, .value = 42 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[0,42]", data);
}

test "serialize enum middle" {
    const data = try encode(EnumProps, .{ .status = .active, .value = 42 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[1,42]", data);
}

test "serialize enum last" {
    const data = try encode(EnumProps, .{ .status = .completed, .value = 42 });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[2,42]", data);
}

test "serialize slice of structs" {
    const Item = struct { id: i32, name: []const u8 };
    const items: []const Item = &.{
        .{ .id = 1, .name = "first" },
        .{ .id = 2, .name = "second" },
    };
    const data = try encode([]const Item, items);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[[1,\"first\"],[2,\"second\"]]", data);
}

test "serialize slice of ints" {
    const values: []const i32 = &.{ 10, 20, 30 };
    const data = try encode([]const i32, values);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[10,20,30]", data);
}

test "serialize empty slice" {
    const items: []const i32 = &.{};
    const data = try encode([]const i32, items);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[]", data);
}

test "serialize complex props" {
    const props = ComplexProps{
        .initial = 42,
        .negative = -100,
        .zero_val = 0,
        .float_val = 3.14,
        .negative_float = -2.5,
        .shared = true,
        .disabled = false,
        .label = "Hello",
        .escaped_str = "World\n",
        .optional_int = null,
        .optional_str = null,
        .nested = .{ .value = 10, .flag = true },
        .scores = .{ 1, 2, 3 },
        .status = .active,
    };
    const data = try encode(ComplexProps, props);
    defer testing.allocator.free(data);
    try testing.expect(std.mem.startsWith(u8, data, "[42,-100,0,"));
    try testing.expect(std.mem.indexOf(u8, data, "\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"World\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "[10,true]") != null);
    try testing.expect(std.mem.indexOf(u8, data, "[1,2,3]") != null);
    try testing.expect(std.mem.endsWith(u8, data, ",1]"));
}

// ---- Roundtrip ----
test "roundtrip simple" {
    const original = SimpleProps{ .count = 42, .enabled = true };
    const data = try encode(SimpleProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(SimpleProps, testing.allocator, data, .{});
    try testing.expectEqual(original.count, parsed.count);
    try testing.expectEqual(original.enabled, parsed.enabled);
}

test "roundtrip nested" {
    const original = NestedProps{
        .outer_val = 10,
        .inner = .{ .value = 42, .flag = true },
        .outer_flag = false,
    };
    const data = try encode(NestedProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(NestedProps, testing.allocator, data, .{});
    try testing.expectEqual(original.outer_val, parsed.outer_val);
    try testing.expectEqual(original.inner.value, parsed.inner.value);
    try testing.expectEqual(original.inner.flag, parsed.inner.flag);
    try testing.expectEqual(original.outer_flag, parsed.outer_flag);
}

test "roundtrip array" {
    const original = ArrayProps{
        .scores = .{ 10, 20, 30 },
        .flags = .{ true, false },
    };
    const data = try encode(ArrayProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(ArrayProps, testing.allocator, data, .{});
    try testing.expectEqual(original.scores[0], parsed.scores[0]);
    try testing.expectEqual(original.scores[1], parsed.scores[1]);
    try testing.expectEqual(original.scores[2], parsed.scores[2]);
    try testing.expectEqual(original.flags[0], parsed.flags[0]);
    try testing.expectEqual(original.flags[1], parsed.flags[1]);
}

test "roundtrip enum" {
    const original = EnumProps{ .status = .completed, .value = 99 };
    const data = try encode(EnumProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(EnumProps, testing.allocator, data, .{});
    try testing.expectEqual(original.status, parsed.status);
    try testing.expectEqual(original.value, parsed.value);
}

test "roundtrip optional null" {
    const original = OptionalProps{ .required = 42, .optional_int = null, .optional_str = null };
    const data = try encode(OptionalProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(OptionalProps, testing.allocator, data, .{});
    try testing.expectEqual(original.required, parsed.required);
    try testing.expect(parsed.optional_int == null);
    try testing.expect(parsed.optional_str == null);
}

test "roundtrip optional present" {
    const original = OptionalProps{ .required = 42, .optional_int = 100, .optional_str = "hello" };
    const data = try encode(OptionalProps, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(OptionalProps, testing.allocator, data, .{});
    defer if (parsed.optional_str) |s| testing.allocator.free(s);
    try testing.expectEqual(original.required, parsed.required);
    try testing.expectEqual(original.optional_int, parsed.optional_int);
    try testing.expectEqualStrings("hello", parsed.optional_str.?);
}

// Parse – Whitespace
test "whitespace spaces" {
    const r = try zxon.parse(SimpleProps, testing.allocator, "[ 42 , true ]", .{});
    try testing.expectEqual(@as(i32, 42), r.count);
}

test "whitespace newlines" {
    const r = try zxon.parse(SimpleProps, testing.allocator, "[\n42\n,\ntrue\n]", .{});
    try testing.expectEqual(@as(i32, 42), r.count);
}

test "whitespace mixed" {
    const r = try zxon.parse(SimpleProps, testing.allocator, "[ \n\t42 , \n\ttrue ]", .{});
    try testing.expectEqual(@as(i32, 42), r.count);
}

// Parse – Error Cases
test "parse error: missing bracket" {
    const P = struct { value: i32 };
    try testing.expectError(error.ExpectedArrayStart, zxon.parse(P, testing.allocator, "42", .{}));
}

test "parse direct" {
    const P = struct { x: i32, y: i32 };
    const r = try zxon.parse(P, testing.allocator, "[10,20]", .{});
    try testing.expectEqual(@as(i32, 10), r.x);
    try testing.expectEqual(@as(i32, 20), r.y);
}

// ----- Parse – More Edge Cases -----

test "parse empty string input" {
    const P = struct { value: i32 };
    try testing.expectError(error.ExpectedArrayStart, zxon.parse(P, testing.allocator, "", .{}));
}

test "parse truncated input" {
    const P = struct { a: i32, b: i32 };
    // Missing closing bracket and second field
    try testing.expectError(error.ExpectedComma, zxon.parse(P, testing.allocator, "[42", .{}));
}

test "parse omits trailing default fields" {
    const Link = struct { label: []const u8, href: []const u8 };
    const User = struct {
        username: []const u8,
        places: []const struct { lat: f64, lng: f64 },
        links: []const Link = &.{},
    };
    const r = try zxon.parse(User, testing.allocator, "[\"miktwon\",[[50.4501,30.5234]]]", .{});
    defer {
        testing.allocator.free(r.username);
        testing.allocator.free(r.places);
    }
    try testing.expectEqualStrings("miktwon", r.username);
    try testing.expectEqual(@as(usize, 1), r.places.len);
    try testing.expectEqual(@as(usize, 0), r.links.len);
}

test "parse omits multiple trailing defaults" {
    const P = struct {
        required: i32,
        opt_a: bool = false,
        opt_b: []const u8 = "",
    };
    const r = try zxon.parse(P, testing.allocator, "[7]", .{});
    try testing.expectEqual(@as(i32, 7), r.required);
    try testing.expect(!r.opt_a);
    try testing.expectEqualStrings("", r.opt_b);
}

test "parse missing required field when array ends early" {
    const P = struct { a: i32, b: i32 };
    try testing.expectError(error.MissingRequiredField, zxon.parse(P, testing.allocator, "[42]", .{}));
}

test "parse empty struct" {
    const Empty = struct {};
    const r = try zxon.parse(Empty, testing.allocator, "[]", .{});
    _ = r;
}

test "parse single field struct" {
    const P = struct { x: i32 };
    const r = try zxon.parse(P, testing.allocator, "[99]", .{});
    try testing.expectEqual(@as(i32, 99), r.x);
}

test "parse nested slice of ints" {
    const P = struct { rows: []const []const i32 };
    const r = try zxon.parse(P, testing.allocator, "[[[1,2],[3]]]", .{});
    defer {
        for (r.rows) |row| testing.allocator.free(row);
        testing.allocator.free(r.rows);
    }
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqual(@as(i32, 1), r.rows[0][0]);
    try testing.expectEqual(@as(i32, 3), r.rows[1][0]);
}

test "parse empty slice" {
    const P = struct { items: []const i32 };
    const r = try zxon.parse(P, testing.allocator, "[[]]", .{});
    defer testing.allocator.free(r.items);
    try testing.expectEqual(@as(usize, 0), r.items.len);
}

test "parse string all escapes combined" {
    const P = struct { value: []const u8 };
    const r = try zxon.parse(P, testing.allocator, "[\"a\\nb\\tc\\\\d\\\"e\\rf\"]", .{});
    defer testing.allocator.free(r.value);
    try testing.expectEqualStrings("a\nb\tc\\d\"e\rf", r.value);
}

test "parse nested optional" {
    const P = struct { value: ??i32 };
    const r = try zxon.parse(P, testing.allocator, "[42]", .{});
    try testing.expectEqual(@as(i32, 42), r.value.?.?);
}

test "parse nested optional null outer" {
    const P = struct { value: ??i32 };
    const r = try zxon.parse(P, testing.allocator, "[null]", .{});
    try testing.expect(r.value == null);
}

// ----- Serialize – More Edge Cases -----

test "serialize empty struct" {
    const Empty = struct {};
    const data = try encode(Empty, .{});
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[]", data);
}

test "serialize nested optional present" {
    const P = struct { value: ??i32 };
    const data = try encode(P, .{ .value = @as(?i32, 42) });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[42]", data);
}

test "serialize nested optional null inner" {
    const P = struct { value: ??i32 };
    const data = try encode(P, .{ .value = @as(?i32, null) });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[null]", data);
}

test "serialize nested optional null outer" {
    const P = struct { value: ??i32 };
    const data = try encode(P, .{ .value = null });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[null]", data);
}

test "serialize string all escapes combined" {
    const P = struct { value: []const u8 };
    const data = try encode(P, .{ .value = "a\nb\tc\\d\"e\rf" });
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("[\"a\\nb\\tc\\\\d\\\"e\\rf\"]", data);
}

// ----- Roundtrip – Slices -----

test "roundtrip slice of strings" {
    const P = struct { tags: []const []const u8 };
    const original = P{ .tags = &.{ "hello", "world" } };
    const data = try encode(P, original);
    defer testing.allocator.free(data);

    const parsed = try zxon.parse(P, testing.allocator, data, .{});
    defer {
        for (parsed.tags) |s| testing.allocator.free(s);
        testing.allocator.free(parsed.tags);
    }
    try testing.expectEqual(@as(usize, 2), parsed.tags.len);
    try testing.expectEqualStrings("hello", parsed.tags[0]);
    try testing.expectEqualStrings("world", parsed.tags[1]);
}

// ----- Schema -----

test "schema same type same hash" {
    const a = zxon.schema(SimpleProps);
    const b = zxon.schema(SimpleProps);
    try testing.expectEqual(a.hash, b.hash);
}

test "schema different types different hash" {
    const a = zxon.schema(SimpleProps);
    const b = zxon.schema(NestedProps);
    try testing.expect(a.hash != b.hash);
}

test "schema field order matters" {
    const A = struct { x: i32, y: bool };
    const B = struct { y: bool, x: i32 };
    try testing.expect(zxon.schema(A).hash != zxon.schema(B).hash);
}

test "schema field names matter" {
    const A = struct { count: i32 };
    const B = struct { value: i32 };
    try testing.expect(zxon.schema(A).hash != zxon.schema(B).hash);
}

// ----- Performance -----

const test_util = @import("./../util.zig");

fn expectLessThan(expected: f64, actual: f64) !void {
    if (actual > expected) {
        std.debug.print("\x1b[31m✗\x1b[0m Expected < {d:.2}ms, got {d:.2}ms\n", .{ expected, actual });
        return error.TestExpectedLessThan;
    }
}

test "flaky: performance > serialize" {
    const ITERATIONS = 500;
    const MAX_MS = 100.0 * 10; // ~100ms on M1 Pro

    const content_parsed = std.json.parseFromSlice([]SearchContent, testing.allocator, search_txt, .{}) catch unreachable;
    defer content_parsed.deinit();

    var total_bytes: u64 = 0;
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..ITERATIONS) |_| {
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        zxon.serialize(content_parsed.value, &aw.writer, .{}) catch {};
        total_bytes += aw.written().len;
        aw.deinit();
    }
    const elapsed_ns: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start);
    const total_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    const avg_ms = total_ms / ITERATIONS;
    const rate = test_util.Throughput.init(total_bytes, elapsed_ns);

    test_util.perf(
        "zxon > serialize {d:.2}ms | Avg: {d:.4}ms | {f} ({d} bytes)",
        .{ total_ms, avg_ms, rate, total_bytes },
    );
    try expectLessThan(MAX_MS, total_ms);
}

test "flaky: performance > parse" {
    const ITERATIONS = 500;
    const MAX_MS = 20.0 * 10; // ~20ms on M1 Pro

    const content_parsed = std.json.parseFromSlice([]SearchContent, testing.allocator, search_txt, .{}) catch unreachable;
    defer content_parsed.deinit();

    // Serialize once to get ZXON data
    var aw_init = std.Io.Writer.Allocating.init(testing.allocator);
    try zxon.serialize(content_parsed.value, &aw_init.writer, .{});
    const zxon_data = try testing.allocator.dupe(u8, aw_init.written());
    defer testing.allocator.free(zxon_data);
    aw_init.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..ITERATIONS) |_| {
        _ = arena.reset(.retain_capacity);
        _ = zxon.parse([]SearchContent, arena.allocator(), zxon_data, .{}) catch {};
    }
    const elapsed_ns: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start);
    const total_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    const avg_ms = total_ms / ITERATIONS;
    const total_bytes: u64 = zxon_data.len * ITERATIONS;
    const rate = test_util.Throughput.init(total_bytes, elapsed_ns);

    test_util.perf(
        "zxon > parse {d:.2}ms | Avg: {d:.4}ms | {f} ({d} bytes)",
        .{ total_ms, avg_ms, rate, total_bytes },
    );
    try expectLessThan(MAX_MS, total_ms);
}

test "strings are JSON strings" {
    const allocator = testing.allocator;
    const original: []const u8 = "q\"b\\n\nt\tc\x01\x1f bn: বাংলা";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try zxon.serialize(original, &aw.writer, .{});
    try testing.expectEqualStrings("\"q\\\"b\\\\n\\nt\\tc\\u0001\\u001f bn: বাংলা\"", aw.written());

    const via_json = try std.json.parseFromSlice([]const u8, allocator, aw.written(), .{});
    defer via_json.deinit();
    try testing.expectEqualStrings(original, via_json.value);

    const back = try zxon.parse([]const u8, allocator, aw.written(), .{});
    defer allocator.free(back);
    try testing.expectEqualStrings(original, back);
}

test "parses JSON escapes (JSON.stringify output)" {
    const allocator = testing.allocator;
    const long: [5000]u8 = @splat('x');
    const src = "[\"a\\u0001\\u00e9\\ud83d\\ude00\\b\\f\\/z\",\"" ++ long ++ "\\n\"]";
    const got = try zxon.parse([]const []const u8, allocator, src, .{});
    defer {
        for (got) |g| allocator.free(g);
        allocator.free(got);
    }
    try testing.expectEqualStrings("a\x01é😀\x08\x0c/z", got[0]);
    try testing.expectEqualStrings(long ++ "\n", got[1]);
}

const search_txt =
    \\[{"title":"std.Io","url":"/std/Io","content":"A cross-platform interface that abstracts all I/O operations and concurrency, including file system, networking, processes, time, randomness, async/await, concurrent queues, synchronization primitives, and memory mapped files."},{"title":"AnyFuture","url":"/std/Io/AnyFuture","content":"Type-erased future for async operations"},{"title":"CancelProtection","url":"/std/Io/CancelProtection","content":"Protection state for cancelation"},{"title":"Clock","url":"/std/Io/Clock","content":"Clock source for time operations"},{"title":"Condition","url":"/std/Io/Condition","content":"Condition variable for synchronization"},{"title":"Dir","url":"/std/Io/Dir","content":"Directory handle"},{"title":"Duration","url":"/std/Io/Duration","content":"Time duration representation"},{"title":"Event","url":"/std/Io/Event","content":"Event primitive"},{"title":"File","url":"/std/Io/File","content":"File handle"},{"title":"Future","url":"/std/Io/Future","content":"Typed future for async results"},{"title":"Group","url":"/std/Io/Group","content":"Wait group for concurrent operations"},{"title":"Mutex","url":"/std/Io/Mutex","content":"Mutual exclusion lock"},{"title":"Queue","url":"/std/Io/Queue","content":"Concurrent queue"},{"title":"Reader","url":"/std/Io/Reader","content":"Buffered reader interface"},{"title":"Writer","url":"/std/Io/Writer","content":"Buffered writer interface"},{"title":"net","url":"/std/Io/net","content":"Networking functionality including TCP, UDP, and address resolution"},{"title":"async","url":"/std/Io/async","content":"Calls function with args, return value available after await"},{"title":"checkCancel","url":"/std/Io/checkCancel","content":"Acts as a pure cancelation point"},{"title":"concurrent","url":"/std/Io/concurrent","content":"Calls function allowing caller to progress while waiting"},{"title":"futexWait","url":"/std/Io/futexWait","content":"Atomically checks value and blocks until woken"},{"title":"futexWake","url":"/std/Io/futexWake","content":"Unblocks pending futex waits"},{"title":"lockStderr","url":"/std/Io/lockStderr","content":"Coordinates application-level writes to stderr"},{"title":"poll","url":"/std/Io/poll","content":"Creates a poller for monitoring file descriptors"},{"title":"random","url":"/std/Io/random","content":"Obtains cryptographically secure random bytes"},{"title":"select","url":"/std/Io/select","content":"Waits on multiple futures, returns when any completes"},{"title":"sleep","url":"/std/Io/sleep","content":"Suspends execution for the specified duration"},{"title":"Overview","url":"/std/Io#overview","content":"What it represents A cross-platform interface that abstracts all I/O operations and concurrency. This interface allows programmers to write optimal, reusable code while participating in these operations. Category:std namespace › Io struct Source:lib/std/Io.zig "},{"title":"Capabilities","url":"/std/Io#capabilities","content":"What Io provides The Io struct provides a unified interface for a wide range of system operations: file system - read, write, and manage files and directories networking - TCP, UDP, and other network protocols processes - spawn and manage child processes time and sleeping - timers, delays, and clock access randomness - cryptographic and general-purpose random number generation async, await, concurrent, and cancel - asynchronous programming primitives concurrent queues - thread-safe data structures wait groups and select - synchronization mechanisms mutexes, futexes, events, and conditions - low-level synchronization memory mapped files - efficient file I/O via memory mapping "},{"title":"Fields","url":"/std/Io#fields","content":"Struct fields userdata:?*anyopaque - User-defined data pointer for custom context vtable:*const VTable - Virtual table containing function pointers for I/O operations "},{"title":"Types","url":"/std/Io#types","content":"Associated types The Io struct defines many associated types for different I/O operations: AnyFuture - Type-erased future for async operations CancelProtection - Protection state for cancelation Clock - Clock source for time operations Condition - Condition variable for synchronization Dir - Directory handle Duration - Time duration representation Event - Event primitive Evented - Event-based I/O wrapper File - File handle Future - Typed future for async results Group - Wait group for concurrent operations IoUring - Linux io_uring backend Kqueue - BSD/macOS kqueue backend Limit - Resource limits LockedStderr - Locked stderr for coordinated writes Mutex - Mutual exclusion lock PollFiles - File polling interface Poller - Platform-specific poller Queue - Concurrent queue Reader - Buffered reader interface Select - Select operation for multiple futures SelectUnion - Union type for select results Terminal - Terminal I/O interface Threaded - Threaded I/O backend Timeout - Timeout configuration Timestamp - Point in time representation TypeErasedQueue - Type-erased concurrent queue VTable - Virtual function table Writer - Buffered writer interface "},{"title":"Namespaces","url":"/std/Io#namespaces","content":"Sub-namespaces net:Networking functionality including TCP, UDP, and address resolution "},{"title":"Functions","url":"/std/Io#functions","content":"Public API methods The Io struct provides many functions for asynchronous I/O and concurrency: async:Calls function with args, such that the return value is not guaranteed to be available until await is called. checkCancel:Acts as a pure cancelation point and does nothing else. Returns error.Canceled if there is an outstanding non-blocked cancelation request. concurrent:Calls function with args, allowing the caller to progress while waiting for any Io operations. futexWait:Atomically checks if the value at ptr equals expected, and if so, blocks until woken. futexWaitTimeout:Same as futexWait, except also unblocks if timeout expires. Spurious wakeups are possible. futexWaitUncancelable:Same as futexWait, except does not introduce a cancelation point. futexWake:Unblocks pending futex waits on ptr, up to a limit of max_waiters calls. lockStderr:For application-level writes to stderr. Coordinates with debug-level writes ignorant of Io interface. poll:Creates a poller for monitoring multiple file descriptors. random:Obtains entropy from a cryptographically secure pseudo-random number generator. randomSecure:Obtains cryptographically secure entropy from outside the process. recancel:Re-arms the cancelation request so error.Canceled will be returned from the next cancelation point. select:Waits on multiple futures, returning when any one completes. sleep:Suspends execution for the specified duration. swapCancelProtection:Updates the current task's cancel protection state. tryLockStderr:Same as lockStderr but non-blocking. unlockStderr:Unlocks stderr after a lockStderr call. "},{"title":"Error Sets","url":"/std/Io#error-sets","content":"Possible errors The Io functions may return these error sets: Cancelable:Operation was canceled via cancelation point ConcurrentError:Error during concurrent operation execution QueueClosedError:Attempted operation on a closed queue RandomSecureError:Failed to obtain secure random bytes SleepError:Error during sleep operation UnexpectedError:Unexpected system error occurred "}]
;
