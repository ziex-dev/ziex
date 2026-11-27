const std = @import("std");
const zx = @import("zx");

const testing = std.testing;
const props = zx.util.props;

const Props = struct {
    title: []const u8 = "default",
    count: i32 = 0,
};

test "coerce > fills defaults for missing fields" {
    const coerced = props.coerce(Props, .{ .title = "hi" });
    try testing.expectEqualStrings("hi", coerced.title);
    try testing.expectEqual(@as(i32, 0), coerced.count);
}

test "coerce > keeps provided fields" {
    const coerced = props.coerce(Props, .{ .title = "x", .count = 7 });
    try testing.expectEqualStrings("x", coerced.title);
    try testing.expectEqual(@as(i32, 7), coerced.count);
}

test "zxon > serializes positional values" {
    const encoded = props.zxon(testing.allocator, props.coerce(Props, .{ .title = "Main", .count = 5 })).?;
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("[\"Main\",5]", encoded);
}

test "zxon > applies defaults before serialize" {
    const encoded = props.zxon(testing.allocator, props.coerce(Props, .{ .count = 3 })).?;
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("[\"default\",3]", encoded);
}

test "zxon > empty struct returns null" {
    const Empty = struct {};
    try testing.expect(props.zxon(testing.allocator, Empty{}) == null);
}

test "json > serializes named fields" {
    const encoded = props.json(testing.allocator, props.coerce(Props, .{ .title = "Main", .count = 5 })).?;
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.find(u8, encoded, "\"title\"") != null);
    try testing.expect(std.mem.find(u8, encoded, "Main") != null);
    try testing.expect(std.mem.find(u8, encoded, "\"count\"") != null);
    try testing.expect(std.mem.find(u8, encoded, "5") != null);
}

test "merged > override wins and adds new fields" {
    const Base = struct { a: i32 = 1, b: []const u8 = "b" };
    const Override = struct { b: []const u8 = "B", c: bool = true };
    const M = props.Merged(Base, Override);

    try testing.expect(@hasField(M, "a"));
    try testing.expect(@hasField(M, "b"));
    try testing.expect(@hasField(M, "c"));
    try testing.expect(@FieldType(M, "b") == []const u8);
    try testing.expect(@FieldType(M, "c") == bool);
}
