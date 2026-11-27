const std = @import("std");
const zx = @import("zx");

const PubSub = zx.App.Server.PubSub;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Hub = PubSub.Hub;
const Subscriber = PubSub.Subscriber;

const MockConn = struct {
    inbox: std.ArrayList([]u8) = .empty,
    allocator: Allocator,
    fail: bool = false,

    fn write(ctx: *anyopaque, message: []const u8) anyerror!void {
        const self: *MockConn = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.WouldBlock;
        const owned = try self.allocator.dupe(u8, message);
        try self.inbox.append(self.allocator, owned);
    }

    fn deinit(self: *MockConn) void {
        for (self.inbox.items) |msg| self.allocator.free(msg);
        self.inbox.deinit(self.allocator);
    }
};

fn testSubscriber(allocator: Allocator, topic_hub: *Hub, conn: *MockConn) Subscriber {
    return Subscriber.initWithHub(allocator, testing.io, conn, MockConn.write, null, topic_hub);
}

test "subscribe publish excludes sender by default" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var b_conn: MockConn = .{ .allocator = allocator };
    defer b_conn.deinit();

    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    defer a.unsubscribeAll();
    var b = testSubscriber(allocator, &topic_hub, &b_conn);
    defer b.unsubscribeAll();

    a.subscribe("chat");
    b.subscribe("chat");
    try testing.expect(a.isSubscribed("chat"));
    try testing.expectEqual(@as(usize, 2), topic_hub.subscriberCount("chat", testing.io));

    const sent = PubSub.publish(&a, "chat", "hello");
    try testing.expectEqual(@as(usize, 1), sent);
    try testing.expectEqual(@as(usize, 0), a_conn.inbox.items.len);
    try testing.expectEqual(@as(usize, 1), b_conn.inbox.items.len);
    try testing.expectEqualStrings("hello", b_conn.inbox.items[0]);
}

test "publish_to_self includes sender" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    defer a.unsubscribeAll();

    a.publish_to_self = true;
    a.subscribe("room");
    try testing.expectEqual(@as(usize, 1), PubSub.publish(&a, "room", "ping"));
    try testing.expectEqualStrings("ping", a_conn.inbox.items[0]);
}

test "unsubscribe cleans empty topics" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    defer a.unsubscribeAll();

    a.subscribe("t");
    a.unsubscribe("t");
    try testing.expect(!a.isSubscribed("t"));
    try testing.expectEqual(@as(usize, 0), topic_hub.subscriberCount("t", testing.io));
    try testing.expectEqual(@as(usize, 0), topic_hub.topics.count());
}

test "detach skips closed subscriber" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var b_conn: MockConn = .{ .allocator = allocator };
    defer b_conn.deinit();

    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    var b = testSubscriber(allocator, &topic_hub, &b_conn);
    defer b.unsubscribeAll();

    a.subscribe("x");
    b.subscribe("x");
    a.unsubscribeAll();

    try testing.expectEqual(@as(usize, 1), topic_hub.publish(testing.io, null, "x", "still"));
    try testing.expectEqual(@as(usize, 0), a_conn.inbox.items.len);
    try testing.expectEqualStrings("still", b_conn.inbox.items[0]);
}

test "rejects empty and oversized topics" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    defer a.unsubscribeAll();

    a.subscribe("");
    try testing.expect(!a.isSubscribed(""));

    var big: [PubSub.max_topic_len + 1]u8 = undefined;
    @memset(&big, 'a');
    a.subscribe(&big);
    try testing.expect(!a.isSubscribed(&big));
}

test "failed deliver does not abort fan-out" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var bad_conn: MockConn = .{ .allocator = allocator, .fail = true };
    defer bad_conn.deinit();
    var good_conn: MockConn = .{ .allocator = allocator };
    defer good_conn.deinit();
    var sender_conn: MockConn = .{ .allocator = allocator };
    defer sender_conn.deinit();

    var bad = testSubscriber(allocator, &topic_hub, &bad_conn);
    defer bad.unsubscribeAll();
    var good = testSubscriber(allocator, &topic_hub, &good_conn);
    defer good.unsubscribeAll();
    var sender = testSubscriber(allocator, &topic_hub, &sender_conn);
    defer sender.unsubscribeAll();

    bad.subscribe("fan");
    good.subscribe("fan");
    sender.subscribe("fan");

    try testing.expectEqual(@as(usize, 1), PubSub.publish(&sender, "fan", "ok"));
    try testing.expectEqualStrings("ok", good_conn.inbox.items[0]);
}

test "publishAll reaches every subscriber" {
    const allocator = testing.allocator;
    var topic_hub = Hub.init(allocator);
    defer topic_hub.deinit();

    var a_conn: MockConn = .{ .allocator = allocator };
    defer a_conn.deinit();
    var b_conn: MockConn = .{ .allocator = allocator };
    defer b_conn.deinit();

    var a = testSubscriber(allocator, &topic_hub, &a_conn);
    defer a.unsubscribeAll();
    var b = testSubscriber(allocator, &topic_hub, &b_conn);
    defer b.unsubscribeAll();

    a.subscribe("all");
    b.subscribe("all");

    const sent = topic_hub.publish(testing.io, null, "all", "broadcast");
    try testing.expectEqual(@as(usize, 2), sent);
    try testing.expectEqual(@as(usize, 1), a_conn.inbox.items.len);
    try testing.expectEqual(@as(usize, 1), b_conn.inbox.items.len);
}
