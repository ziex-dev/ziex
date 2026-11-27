const PubSub = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_topic_len: usize = 256;
pub const max_topics_per_subscriber: usize = 128;
const stack_frame_max: usize = 4096;

pub const WriteFn = *const fn (ctx: *anyopaque, message: []const u8) anyerror!void;
pub const WriteFramedFn = *const fn (ctx: *anyopaque, framed: []const u8) anyerror!void;

pub const Subscriber = struct {
    topics: std.StringHashMapUnmanaged(void) = .empty,
    publish_to_self: bool = false,
    alive: bool = true,
    allocator: Allocator,
    io: Io,
    hub: *Hub,
    ctx: *anyopaque,
    writeFn: WriteFn,
    writeFramedFn: ?WriteFramedFn = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        ctx: *anyopaque,
        writeFn: WriteFn,
    ) Subscriber {
        return initWithHub(allocator, io, ctx, writeFn, null, hub());
    }

    pub fn initFramed(
        allocator: Allocator,
        io: Io,
        ctx: *anyopaque,
        write_framed: WriteFramedFn,
        write_fallback: WriteFn,
    ) Subscriber {
        return initWithHub(allocator, io, ctx, write_fallback, write_framed, hub());
    }

    pub fn initWithHub(
        allocator: Allocator,
        io: Io,
        ctx: *anyopaque,
        writeFn: WriteFn,
        writeFramedFn: ?WriteFramedFn,
        topic_hub: *Hub,
    ) Subscriber {
        return .{
            .allocator = allocator,
            .io = io,
            .hub = topic_hub,
            .ctx = ctx,
            .writeFn = writeFn,
            .writeFramedFn = writeFramedFn,
        };
    }

    pub fn deinit(self: *Subscriber) void {
        var iter = self.topics.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.topics.deinit(self.allocator);
        self.topics = .empty;
    }

    pub fn deliver(self: *Subscriber, message: []const u8) anyerror!void {
        if (!self.alive) return error.Closed;
        try self.writeFn(self.ctx, message);
    }

    pub fn subscribe(self: *Subscriber, topic: []const u8) void {
        if (!validTopic(topic)) return;
        if (!self.alive) return;
        if (self.topics.contains(topic)) return;
        if (self.topics.count() >= max_topics_per_subscriber) return;

        const owned = self.allocator.dupe(u8, topic) catch return;
        self.topics.put(self.allocator, owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        if (!self.hub.addSubscriber(owned, self)) {
            if (self.topics.fetchRemove(owned)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    pub fn unsubscribe(self: *Subscriber, topic: []const u8) void {
        self.hub.removeSubscriber(topic, self);
        if (self.topics.fetchRemove(topic)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    pub fn unsubscribeAll(self: *Subscriber) void {
        self.hub.detachSubscriber(self);
        self.deinit();
    }

    pub fn isSubscribed(self: *const Subscriber, topic: []const u8) bool {
        return self.topics.contains(topic);
    }
};

const SubscriberSet = std.AutoHashMapUnmanaged(*Subscriber, void);

pub const Hub = struct {
    topics: std.StringHashMapUnmanaged(SubscriberSet) = .empty,
    /// Serializes fan-out so concurrent publishers cannot stampede per-conn write locks.
    lock: Io.Mutex = .init,
    allocator: Allocator,

    var instance: ?*Hub = null;

    pub fn init(allocator: Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub) void {
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.topics.deinit(self.allocator);
        self.topics = .empty;
    }

    pub fn getInstance(allocator: Allocator) *Hub {
        if (@atomicLoad(?*Hub, &instance, .acquire)) |existing| return existing;

        const created = allocator.create(Hub) catch @panic("PubSub hub alloc failed");
        created.* = .init(allocator);

        if (@cmpxchgStrong(?*Hub, &instance, null, created, .acq_rel, .acquire)) |existing| {
            allocator.destroy(created);
            return existing.?;
        }
        return created;
    }

    pub fn addSubscriber(self: *Hub, topic: []const u8, subscriber: *Subscriber) bool {
        self.lock.lockUncancelable(subscriber.io);
        defer self.lock.unlock(subscriber.io);

        if (!subscriber.alive) return false;

        const gop = self.topics.getOrPut(self.allocator, topic) catch return false;
        if (!gop.found_existing) {
            const owned = self.allocator.dupe(u8, topic) catch {
                _ = self.topics.remove(topic);
                return false;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.put(self.allocator, subscriber, {}) catch return false;
        return true;
    }

    pub fn removeSubscriber(self: *Hub, topic: []const u8, subscriber: *Subscriber) void {
        self.lock.lockUncancelable(subscriber.io);
        defer self.lock.unlock(subscriber.io);
        self.removeSubscriberLocked(topic, subscriber);
    }

    pub fn detachSubscriber(self: *Hub, subscriber: *Subscriber) void {
        self.lock.lockUncancelable(subscriber.io);
        defer self.lock.unlock(subscriber.io);

        subscriber.alive = false;

        var stack_keys: [max_topics_per_subscriber][]const u8 = undefined;
        var n: usize = 0;
        var iter = subscriber.topics.keyIterator();
        while (iter.next()) |key| {
            if (n == stack_keys.len) break;
            stack_keys[n] = key.*;
            n += 1;
        }
        for (stack_keys[0..n]) |topic| {
            self.removeSubscriberLocked(topic, subscriber);
        }
    }

    fn removeSubscriberLocked(self: *Hub, topic: []const u8, subscriber: *Subscriber) void {
        const set = self.topics.getPtr(topic) orelse return;
        _ = set.remove(subscriber);
        if (set.count() == 0) {
            set.deinit(self.allocator);
            if (self.topics.fetchRemove(topic)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    /// Frame once, fan-out under the hub mutex (Bun-like single-threaded publish).
    pub fn publish(self: *Hub, io: Io, sender: ?*Subscriber, topic: []const u8, message: []const u8) usize {
        if (!validTopic(topic)) return 0;

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const set = self.topics.getPtr(topic) orelse return 0;

        var frame_buf: [stack_frame_max]u8 = undefined;
        const framed = frameText(&frame_buf, message);

        var sent: usize = 0;
        var iter = set.keyIterator();
        while (iter.next()) |sub_ptr| {
            const subscriber = sub_ptr.*;
            if (!subscriber.alive) continue;
            if (sender) |s| {
                if (subscriber == s and !s.publish_to_self) continue;
            }

            if (framed) |frame| {
                if (subscriber.writeFramedFn) |wf| {
                    wf(subscriber.ctx, frame) catch continue;
                } else {
                    subscriber.deliver(message) catch continue;
                }
            } else {
                subscriber.deliver(message) catch continue;
            }
            sent += 1;
        }
        return sent;
    }

    pub fn subscriberCount(self: *Hub, topic: []const u8, io: Io) usize {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.topics.get(topic)) |set| return set.count();
        return 0;
    }
};

pub fn hub() *Hub {
    return Hub.getInstance(std.heap.page_allocator);
}

pub fn publish(sender: *Subscriber, topic: []const u8, message: []const u8) usize {
    return sender.hub.publish(sender.io, sender, topic, message);
}

pub fn publishAll(io: Io, topic: []const u8, message: []const u8) usize {
    return hub().publish(io, null, topic, message);
}

fn validTopic(topic: []const u8) bool {
    return topic.len > 0 and topic.len <= max_topic_len;
}

fn frameText(buf: []u8, payload: []const u8) ?[]u8 {
    const header_len: usize = if (payload.len <= 125)
        2
    else if (payload.len <= 65535)
        4
    else
        10;
    if (buf.len < header_len + payload.len) return null;

    buf[0] = 0x81;
    if (payload.len <= 125) {
        buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload.len), .big);
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], payload.len, .big);
    }
    @memcpy(buf[header_len..][0..payload.len], payload);
    return buf[0 .. header_len + payload.len];
}
