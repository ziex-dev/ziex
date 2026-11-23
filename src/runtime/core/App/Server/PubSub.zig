/// App.Server.PubSub - experimental message broadcasting system.
const PubSub = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Subscriber = struct {
    topics: std.StringHashMapUnmanaged(void) = .empty,
    publish_to_self: bool = false,
    allocator: Allocator,
    io: std.Io,
    /// Backend connection pointer passed to `writeFn`.
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, message: []const u8) anyerror!void,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        ctx: *anyopaque,
        writeFn: *const fn (ctx: *anyopaque, message: []const u8) anyerror!void,
    ) Subscriber {
        return .{
            .allocator = allocator,
            .io = io,
            .ctx = ctx,
            .writeFn = writeFn,
        };
    }

    pub fn deinit(self: *Subscriber) void {
        var iter = self.topics.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.topics.deinit(self.allocator);
        self.topics = .empty;
    }

    pub fn deliver(self: *Subscriber, message: []const u8) anyerror!void {
        try self.writeFn(self.ctx, message);
    }

    pub fn subscribe(self: *Subscriber, topic: []const u8) void {
        if (self.topics.contains(topic)) return;

        const owned = self.allocator.dupe(u8, topic) catch return;
        self.topics.put(self.allocator, owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        hub().addSubscriber(topic, self);
    }

    pub fn unsubscribe(self: *Subscriber, topic: []const u8) void {
        hub().removeSubscriber(topic, self);
        if (self.topics.fetchRemove(topic)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    pub fn unsubscribeAll(self: *Subscriber) void {
        var iter = self.topics.keyIterator();
        while (iter.next()) |key| {
            hub().removeSubscriber(key.*, self);
        }
        self.deinit();
    }

    pub fn isSubscribed(self: *const Subscriber, topic: []const u8) bool {
        return self.topics.contains(topic);
    }
};

const SubscriberSet = std.AutoHashMapUnmanaged(*Subscriber, void);

pub const Hub = struct {
    topics: std.StringHashMapUnmanaged(SubscriberSet) = .empty,
    lock: std.Io.RwLock = .init,
    allocator: Allocator,

    var instance: ?*Hub = null;

    pub fn getInstance(allocator: Allocator) *Hub {
        if (@atomicLoad(?*Hub, &instance, .acquire)) |ps| return ps;

        const ps = allocator.create(Hub) catch @panic("Failed to create PubSub hub");
        ps.* = .{ .allocator = allocator };
        @atomicStore(?*Hub, &instance, ps, .release);
        return ps;
    }

    pub fn addSubscriber(self: *Hub, topic: []const u8, subscriber: *Subscriber) void {
        self.lock.lockUncancelable(subscriber.io);
        defer self.lock.unlock(subscriber.io);

        const result = self.topics.getOrPut(self.allocator, topic) catch return;
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, topic) catch return;
            result.value_ptr.* = .empty;
        }
        result.value_ptr.put(self.allocator, subscriber, {}) catch return;
    }

    pub fn removeSubscriber(self: *Hub, topic: []const u8, subscriber: *Subscriber) void {
        self.lock.lockUncancelable(subscriber.io);
        defer self.lock.unlock(subscriber.io);

        if (self.topics.getPtr(topic)) |subscriber_set| {
            _ = subscriber_set.remove(subscriber);
            if (subscriber_set.count() == 0) {
                subscriber_set.deinit(self.allocator);
                if (self.topics.fetchRemove(topic)) |entry| {
                    self.allocator.free(entry.key);
                }
            }
        }
    }

    /// Fan-out `message` to topic subscribers. Returns how many writes succeeded.
    pub fn publish(self: *Hub, io: std.Io, sender: ?*Subscriber, topic: []const u8, message: []const u8) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var sent: usize = 0;
        if (self.topics.get(topic)) |subscriber_set| {
            var iter = subscriber_set.keyIterator();
            while (iter.next()) |sub_ptr| {
                const subscriber = sub_ptr.*;
                if (sender) |s| {
                    if (subscriber == s and !s.publish_to_self) continue;
                }
                subscriber.deliver(message) catch continue;
                sent += 1;
            }
        }
        return sent;
    }

    pub fn subscriberCount(self: *Hub, topic: []const u8, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        if (self.topics.get(topic)) |subscriber_set| return subscriber_set.count();
        return 0;
    }
};

pub fn hub() *Hub {
    return Hub.getInstance(std.heap.page_allocator);
}

pub fn publish(sender: *Subscriber, topic: []const u8, message: []const u8) usize {
    return hub().publish(sender.io, sender, topic, message);
}
