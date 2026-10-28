// Benchmark WebSocket route - mirrors the Bun benchmark server
// See benches/realtime.mjs for the benchmark client
const CLIENTS_TO_WAIT_FOR: u32 = 32;

var remaining_clients = std.atomic.Value(u32).init(CLIENTS_TO_WAIT_FOR);

pub fn GET(ctx: zx.RouteContext) !void {
    const current = remaining_clients.load(.monotonic);
    const name = ctx.request.query.get("name") orelse
        ctx.arena.print("Client #{d}", .{CLIENTS_TO_WAIT_FOR - current}) catch "Client";

    try ctx.socket.upgrade(SocketData{
        .name = name,
    });
}

pub fn SocketOpen(ctx: zx.SocketOpenCtx(SocketData)) !void {
    ctx.socket.configure(.{ .publish_to_self = true });
    ctx.socket.subscribe(ROOM_TOPIC);

    const prev = remaining_clients.fetchSub(1, .monotonic);
    const current = prev -| 1;
    std.debug.print("{s} connected ({d} remain)\n", .{ ctx.data.name, current });
    ctx.socket.send(.{ .text = "connected" }) catch {};

    if (current == 0) {
        std.debug.print("All clients connected\n", .{});
        remaining_clients.store(CLIENTS_TO_WAIT_FOR, .monotonic);
        _ = ctx.socket.publish(ROOM_TOPIC, "ready");
    }
}

pub fn Socket(ctx: zx.SocketCtx(SocketData)) !void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{s}: {s}", .{ ctx.data.name, ctx.message.bytes() }) catch {
        const allocated = try ctx.fmt("{s}: {s}", .{ ctx.data.name, ctx.message.bytes() });
        _ = ctx.socket.publish(ROOM_TOPIC, allocated);
        return;
    };
    _ = ctx.socket.publish(ROOM_TOPIC, out);
}

pub fn SocketClose(ctx: zx.SocketCloseCtx(SocketData)) void {
    _ = ctx;
    _ = remaining_clients.fetchAdd(1, .monotonic);
}

const ROOM_TOPIC = "room";
const SocketData = struct { name: []const u8 };

const std = @import("std");
const zx = @import("zx");
