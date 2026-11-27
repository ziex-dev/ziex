const Memory = @This();

const std = @import("std");
const Email = @import("../Email.zig");

// Keeps sent messages instead of delivering them, for tests and local dev.
io: std.Io,
arena: std.heap.ArenaAllocator,
messages: std.ArrayList(Email.Message) = .empty,
mutex: std.Io.Mutex = .init,
// Logs each message as it is sent.
log: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io) Memory {
    return .{ .io = io, .arena = .init(gpa) };
}

pub fn deinit(m: *Memory) void {
    m.arena.deinit();
    m.* = undefined;
}

pub fn email(m: *Memory) Email {
    return .{ .userdata = m, .vtable = &.{ .send = &send } };
}

// Not locked; read after sending has finished.
pub fn sent(m: *const Memory) []const Email.Message {
    return m.messages.items;
}

pub fn last(m: *const Memory) ?Email.Message {
    return m.messages.getLastOrNull();
}

pub fn clear(m: *Memory) void {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    m.messages = .empty;
    _ = m.arena.reset(.retain_capacity);
}

fn send(userdata: ?*anyopaque, gpa: std.mem.Allocator, message: Email.Message) Email.Error!Email.Sent {
    const m: *Memory = @ptrCast(@alignCast(userdata));
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);

    const arena = m.arena.allocator();
    try m.messages.append(arena, try message.clone(arena));
    const n = m.messages.items.len;

    if (m.log) std.log.scoped(.zx_email).info("#{d} {f} -> {d} recipient(s): {s}", .{
        n, message.from, message.to.len + message.cc.len + message.bcc.len, message.subject,
    });
    return .{ .id = try std.fmt.allocPrint(gpa, "memory-{d}", .{n}) };
}
