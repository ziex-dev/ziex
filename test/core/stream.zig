const std = @import("std");
const zx = @import("zx");

const render = zx.server.render;
const gpa = std.testing.allocator;
const io = std.testing.io;

const Sink = struct {
    out: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    fail: bool = false,

    fn write(s: *Sink, bytes: []const u8) anyerror!void {
        s.writes += 1;
        if (s.fail) return error.BrokenPipe;
        try s.out.appendSlice(gpa, bytes);
    }

    fn deinit(s: *Sink) void {
        s.out.deinit(gpa);
    }
};

fn wait(ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

const TickerProps = struct { steps: u32, pause: i64 };

// Flushes "0".."steps-1", pausing `pause` ms between each, then renders "done".
fn Ticker(ctx: *zx.ComponentCtx(TickerProps)) zx.Component {
    var x = zx.x.allocInit(ctx.allocator, .{});
    const digits = "0123456789";
    for (0..ctx.props.steps) |i| {
        ctx.flush(x.txt(digits[i .. i + 1]));
        wait(ctx.props.pause);
    }
    return x.txt("done");
}

fn section(arena: std.mem.Allocator, id: u32, steps: u32, pause: i64) render.AsyncComponent {
    var x = zx.x.allocInit(arena, .{});
    return .{ .id = id, .component = x.cmp(Ticker, .{}, .{}, .{ .steps = steps, .pause = pause }) };
}

test "partial flushes precede the final script" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sink: Sink = .{};
    defer sink.deinit();

    render.streamAsync(io, &.{section(arena.allocator(), 7, 2, 60)}, &sink, Sink.write);

    try std.testing.expectEqualStrings(
        "<script>$ZX(7,`0`,1)</script><script>$ZX(7,`1`,1)</script><script>$ZX(7,`done`)</script>",
        sink.out.items,
    );
}

test "rapid flushes are throttled" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sink: Sink = .{};
    defer sink.deinit();

    render.streamAsync(io, &.{section(arena.allocator(), 1, 5, 0)}, &sink, Sink.write);

    try std.testing.expectEqualStrings("<script>$ZX(1,`0`,1)</script><script>$ZX(1,`done`)</script>", sink.out.items);
}

test "sections render in parallel" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sink: Sink = .{};
    defer sink.deinit();

    const a = arena.allocator();
    const start = std.Io.Timestamp.now(io, .awake);
    render.streamAsync(io, &.{ section(a, 0, 1, 150), section(a, 1, 1, 150), section(a, 2, 1, 150) }, &sink, Sink.write);
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    for ([_][]const u8{ "$ZX(0,`done`)", "$ZX(1,`done`)", "$ZX(2,`done`)" }) |final| {
        try std.testing.expect(std.mem.find(u8, sink.out.items, final) != null);
    }
    try std.testing.expect(elapsed < 400);
}

test "a failed write stops further output" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sink: Sink = .{ .fail = true };
    defer sink.deinit();

    render.streamAsync(io, &.{section(arena.allocator(), 3, 3, 60)}, &sink, Sink.write);

    try std.testing.expectEqual(@as(usize, 1), sink.writes);
}

test "flush outside a section is a no-op" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x = zx.x.allocInit(arena.allocator(), .{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try x.cmp(Ticker, .{}, .{}, TickerProps{ .steps = 2, .pause = 0 }).render(&out.writer, .{});
    try std.testing.expectEqualStrings("done", out.written());
}

var seen_io: ?std.Io = null;

fn IoProbe(ctx: *zx.ComponentCtx(struct {})) zx.Component {
    seen_io = ctx.io;
    return .none;
}

test "render hands its io to component contexts" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x = zx.x.allocInit(arena.allocator(), .{});
    seen_io = null;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try x.cmp(IoProbe, .{}, .{}, .{}).render(&out.writer, .{ .io = io });
    try std.testing.expectEqual(io.userdata, seen_io.?.userdata);
}

test "async sections hand the stream io to component contexts" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x = zx.x.allocInit(arena.allocator(), .{});
    var sink: Sink = .{};
    defer sink.deinit();
    seen_io = null;

    render.streamAsync(io, &.{.{ .id = 0, .component = x.cmp(IoProbe, .{}, .{}, .{}) }}, &sink, Sink.write);
    try std.testing.expectEqual(io.userdata, seen_io.?.userdata);
}

test "islands render with the render io" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x = zx.x.allocInit(arena.allocator(), .{});
    seen_io = null;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const island = x.cmp(IoProbe, .{}, .{ .name = "IoProbe", .client = .{ .name = "IoProbe", .id = "p" } }, .{});
    try island.render(&out.writer, .{ .io = io });
    try std.testing.expectEqual(io.userdata, seen_io.?.userdata);
}

test "without a render io, component contexts get std.Io.failing" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x = zx.x.allocInit(arena.allocator(), .{});
    seen_io = null;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try x.cmp(IoProbe, .{}, .{}, .{}).render(&out.writer, .{});
    try std.testing.expectEqual(std.Io.failing.vtable, seen_io.?.vtable);
}
