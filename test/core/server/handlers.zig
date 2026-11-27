const std = @import("std");
const zx = @import("zx");
const app = @import("app");

const io = std.testing.io;
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
const Backend = zx.testing.Backend;
const Harness = zx.testing.Harness;
const Header = zx.testing.Header;
const FetchResult = zx.testing.FetchResult;
const zxon = zx.util.zxon;

const events = app.pages.events;
const actions = app.pages.actions;

const backends = [_]Backend{ .httpz, .std, .wasm };

// ----- Events ----- //

test "event > stateless handler" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", idStr(arena, events.onPing), try eventBody(arena, "hello", &.{}));
            try expectEqual(@as(u16, 200), res.status);
            try expectEqualStrings("{}", res.body);
            try expectContentType(res, "application/json");
            try expectEqual(@as(u32, 1), events.calls.ping);
            try expectEqualStrings("hello", events.calls.lastValue().?);
        }
    }.run);
}

test "event > null value" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", idStr(arena, events.onPing), try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 200), res.status);
            try expectEqual(@as(u32, 1), events.calls.ping);
            try expectEqual(@as(?[]const u8, null), events.calls.lastValue());
        }
    }.run);
}

test "event > stateful round-trip" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", idStr(arena, events.onInc), try eventBody(arena, null, &.{ "41", "\"initial\"" }));
            try expectEqual(@as(u16, 200), res.status);
            try expectContentType(res, "application/json");
            try expectStates(arena, res.body, &.{ "42", "\"initial\"" });
            try expectEqual(@as(u32, 1), events.calls.inc);
        }
    }.run);
}

test "event > header id selects sibling" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const states = &.{ "41", "\"initial\"" };

            const dec = try postEvent(h, arena, "/events", idStr(arena, events.onDec), try eventBody(arena, null, states));
            try expectEqual(@as(u16, 200), dec.status);
            try expectStates(arena, dec.body, &.{ "40", "\"initial\"" });
            try expectEqual(@as(u32, 0), events.calls.inc);
            try expectEqual(@as(u32, 1), events.calls.dec);

            const inc = try postEvent(h, arena, "/events", idStr(arena, events.onInc), try eventBody(arena, null, states));
            try expectEqual(@as(u16, 200), inc.status);
            try expectStates(arena, inc.body, &.{ "42", "\"initial\"" });
            try expectEqual(@as(u32, 1), events.calls.inc);
            try expectEqual(@as(u32, 1), events.calls.dec);
        }
    }.run);
}

test "event > untouched states echoed" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", idStr(arena, events.onLabel), try eventBody(arena, "typed", &.{ "7", "\"initial\"" }));
            try expectEqual(@as(u16, 200), res.status);
            try expectStates(arena, res.body, &.{ "7", "\"typed\"" });
            try expectEqual(@as(u32, 1), events.calls.label);
            try expectEqualStrings("typed", events.calls.lastValue().?);
        }
    }.run);
}

test "event > repeated dispatch" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            var states: []const []const u8 = &.{ "0", "\"initial\"" };
            for (1..4) |expected| {
                const res = try postEvent(h, arena, "/events", idStr(arena, events.onInc), try eventBody(arena, null, states));
                try expectEqual(@as(u16, 200), res.status);
                states = try zxon.parse([]const []const u8, arena, res.body, .{});
                try expectEqual(@as(i32, @intCast(expected)), try zxon.parse(i32, arena, states[0], .{}));
            }
            try expectEqual(@as(u32, 3), events.calls.inc);
        }
    }.run);
}

test "event > unknown id 404" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", "123", try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 404), res.status);
            try expectEqualStrings("No server event handler registered for this route", res.body);
            try expectNoEventCalls();
        }
    }.run);
}

test "event > non-numeric id 404" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", "not-a-number", try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 404), res.status);
            try expectNoEventCalls();
        }
    }.run);
}

test "event > bad body 404" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const id = idStr(arena, events.onPing);

            const empty = try postEvent(h, arena, "/events", id, "");
            try expectEqual(@as(u16, 404), empty.status);

            const garbage = try postEvent(h, arena, "/events", id, "{not zxon");
            try expectEqual(@as(u16, 404), garbage.status);

            try expectNoEventCalls();
        }
    }.run);
}

test "event > ids dispatch from any page route" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const id = idStr(arena, events.onPing);

            const other_page = try postEvent(h, arena, "/actions", id, try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 200), other_page.status);
            try expectEqual(@as(u32, 1), events.calls.ping);

            const other_route = try postEvent(h, arena, "/events/other", id, try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 200), other_route.status);
            try expectEqual(@as(u32, 2), events.calls.ping);
        }
    }.run);
}

test "event > handler re-exported from a .zig file" {
    // Bound through its original module, it resolves to the re-export's id.
    comptime std.debug.assert(zx.server.handlers.id(events.shared.onShared) == zx.server.handlers.id(events.onShared));

    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postEvent(h, arena, "/events", idStr(arena, events.shared.onShared), try eventBody(arena, null, &.{}));
            try expectEqual(@as(u16, 200), res.status);
            try expectEqual(@as(u32, 1), events.shared.calls);
        }
    }.run);
}

test "registry > kind by signature" {
    const handlers = zx.server.handlers;
    const Upload = struct { name: []const u8, subscribe: bool, age: ?i32 };
    const Ctx = struct { io: std.Io, allocator: Allocator };

    try expectEqual(handlers.Kind.event, handlers.kind(fn (*zx.server.Event) void).?);
    try expectEqual(handlers.Kind.event, handlers.kind(fn (*zx.server.Event.Stateful) void).?);
    try expectEqual(handlers.Kind.action, handlers.kind(fn (*zx.server.Action) void).?);
    try expectEqual(handlers.Kind.action, handlers.kind(fn (Upload) void).?);
    try expectEqual(handlers.Kind.action, handlers.kind(fn (Upload, *zx.StateContext) void).?);

    // Client handlers, components and non-form structs are not endpoints.
    try expectEqual(@as(?handlers.Kind, null), handlers.kind(fn (*zx.client.Event) void));
    try expectEqual(@as(?handlers.Kind, null), handlers.kind(fn (*zx.server.Action) zx.Component));
    try expectEqual(@as(?handlers.Kind, null), handlers.kind(fn (zx.PageContext) void));
    try expectEqual(@as(?handlers.Kind, null), handlers.kind(fn (Ctx) void));
    try expectEqual(@as(?handlers.Kind, null), handlers.kind(fn (struct {}) void));
}

test "registry > lookup by kind and id" {
    const handlers = zx.server.handlers;
    try expect(handlers.action(handlers.id(actions.onProfile)) != null);
    try expect(handlers.event(handlers.id(actions.onProfile)) == null);
    try expect(handlers.event(handlers.id(events.onInc)) != null);
    try expect(handlers.action(0) == null and handlers.event(0) == null);
}

test "event > no header renders page" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const get = try h.fetch(arena, .{ .path = "/events" });
            try expectEqual(@as(u16, 200), get.status);
            try expect(std.mem.find(u8, get.body, "<button") != null);

            const post = try h.fetch(arena, .{
                .method = .POST,
                .path = "/events",
                .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                .body = try eventBody(arena, "ignored", &.{}),
            });
            try expectEqual(@as(u16, 200), post.status);
            try expect(std.mem.find(u8, post.body, "<button") != null);

            try expectNoEventCalls();
        }
    }.run);
}

// ----- Actions ----- //

test "action > forms carry id" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try h.fetch(arena, .{ .path = "/actions" });
            try expectEqual(@as(u16, 200), res.status);
            try expect(std.mem.find(u8, res.body, "method=\"post\" enctype=\"multipart/form-data\"") != null);
            inline for (.{ actions.onProfile, actions.onGreet, actions.onAdd, actions.onDirect }) |s| {
                const needle = try arena.print("name=\"__$action\" value=\"{s}\"", .{idStr(arena, s)});
                if (std.mem.find(u8, res.body, needle) == null) {
                    std.debug.print("missing `{s}` in:\n{s}\n", .{ needle, res.body });
                    return error.MissingActionId;
                }
            }
            try expectNoActionCalls();
        }
    }.run);
}

test "action > native multipart" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", null, &.{
                .{ "__$action", idStr(arena, actions.onProfile) },
                .{ "name", "Ada Lovelace" },
                .{ "age", "36" },
                .{ "subscribe", "on" },
                .{ "nickname", "ada" },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expect(std.mem.find(u8, res.body, "<form") != null);
            try expectEqual(@as(u32, 1), actions.calls.profile);
            try expectEqualStrings("Ada Lovelace", actions.calls.name());
            try expectEqual(@as(i32, 36), actions.calls.age);
            try expect(actions.calls.subscribe);
            try expectEqualStrings("ada", actions.calls.nickname().?);
        }
    }.run);
}

test "action > native urlencoded" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const body = try arena.print("__%24action={s}&name=Grace+Hopper&age=85", .{idStr(arena, actions.onProfile)});
            const res = try h.fetch(arena, .{
                .method = .POST,
                .path = "/actions",
                .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
                .body = body,
            });
            try expectEqual(@as(u16, 200), res.status);
            try expect(std.mem.find(u8, res.body, "<form") != null);
            try expectEqual(@as(u32, 1), actions.calls.profile);
            try expectEqualStrings("Grace Hopper", actions.calls.name());
            try expectEqual(@as(i32, 85), actions.calls.age);
            try expect(!actions.calls.subscribe);
            try expectEqual(@as(?[]const u8, null), actions.calls.nickname());
        }
    }.run);
}

test "action > direct typed attribute" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", null, &.{
                .{ "__$action", idStr(arena, actions.onDirect) },
                .{ "name", "Linus" },
                .{ "age", "21" },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expectEqual(@as(u32, 1), actions.calls.direct);
            try expectEqual(@as(u32, 0), actions.calls.profile);
            try expectEqualStrings("Linus", actions.calls.name());
            try expectEqual(@as(i32, 21), actions.calls.age);
        }
    }.run);
}

test "action > progressive StateContext" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", idStr(arena, actions.onGreet), &.{
                .{ "name", "Ada" },
                .{ "__$states", try statesJson(arena, &.{"\"Please log in\""}) },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expectContentType(res, "application/json");
            try expectStates(arena, res.body, &.{"\"Hello, Ada!\""});
            try expectEqual(@as(u32, 1), actions.calls.greet);
        }
    }.run);
}

test "action > progressive Action.Stateful" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", idStr(arena, actions.onAdd), &.{
                .{ "amount", "5" },
                .{ "__$states", try statesJson(arena, &.{"10"}) },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expectStates(arena, res.body, &.{"15"});
            try expectEqual(@as(u32, 1), actions.calls.add);
        }
    }.run);
}

test "action > progressive stateless" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", idStr(arena, actions.onProfile), &.{
                .{ "name", "Ada" },
                .{ "age", "36" },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expectEqualStrings("", res.body);
            try expectEqual(@as(u32, 1), actions.calls.profile);
            try expectEqualStrings("Ada", actions.calls.name());
        }
    }.run);
}

test "action > form field beats header" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", idStr(arena, actions.onGreet), &.{
                .{ "__$action", idStr(arena, actions.onProfile) },
                .{ "name", "Ada" },
            });
            try expectEqual(@as(u16, 200), res.status);
            try expectEqual(@as(u32, 1), actions.calls.profile);
            try expectEqual(@as(u32, 0), actions.calls.greet);
        }
    }.run);
}

test "action > unknown id 400" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const native = try postMultipart(h, arena, "/actions", null, &.{.{ "__$action", "123" }});
            try expectEqual(@as(u16, 400), native.status);
            try expectEqualStrings("No action handler registered for this route", native.body);

            const progressive = try postMultipart(h, arena, "/actions", "123", &.{.{ "name", "x" }});
            try expectEqual(@as(u16, 400), progressive.status);

            try expectNoActionCalls();
        }
    }.run);
}

test "action > non-numeric id ignored" {
    try forEachBackend(struct {
        fn run(h: *Harness, arena: Allocator) !void {
            const res = try postMultipart(h, arena, "/actions", null, &.{.{ "__$action", "abc" }});
            try expectEqual(@as(u16, 200), res.status);
            try expect(std.mem.find(u8, res.body, "<form") != null);
            try expectNoActionCalls();
        }
    }.run);
}

// ----- Helpers ----- //

fn forEachBackend(comptime body: *const fn (*Harness, Allocator) anyerror!void) !void {
    inline for (backends) |backend| {
        runOn(backend, body) catch |err| {
            std.debug.print("backend={s} failed: {s}\n", .{ backend.name(), @errorName(err) });
            return err;
        };
    }
}

fn runOn(backend: Backend, comptime body: *const fn (*Harness, Allocator) anyerror!void) !void {
    var harness = try Harness.start(backend, io, allocator, .{
        .workers = .{ .count = 1, .min_conn = 1, .max_conn = 2 },
        .thread_pool = .{ .count = 1 },
    });
    defer harness.stop();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    events.calls.reset();
    actions.calls.reset();
    events.shared.calls = 0;
    try body(&harness, arena_state.allocator());
}

/// Handler/action id the runtime derives from an attribute's `@src()`.
fn idStr(arena: Allocator, comptime handler: anytype) []const u8 {
    const id = comptime zx.server.handlers.id(handler);
    return arena.print("{d}", .{id}) catch @panic("OOM");
}

fn eventBody(arena: Allocator, value: ?[]const u8, states: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try zxon.serialize(zx.EventHandler.Payload{ .value = value, .states = states }, &aw.writer, .{});
    return aw.written();
}

fn statesJson(arena: Allocator, states: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try zxon.serialize(states, &aw.writer, .{});
    return aw.written();
}

fn postEvent(h: *Harness, arena: Allocator, path: []const u8, handler_id: []const u8, body: []const u8) !FetchResult {
    return h.fetch(arena, .{
        .method = .POST,
        .path = path,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-event", .value = handler_id },
        },
        .body = body,
    });
}

const boundary = "----ziex-test-boundary";

/// POSTs a multipart form; `action_header` mirrors the browser's progressive `x-action` submit.
fn postMultipart(h: *Harness, arena: Allocator, path: []const u8, action_header: ?[]const u8, fields: []const [2][]const u8) !FetchResult {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (fields) |f| {
        try aw.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, f[0], f[1] });
    }
    try aw.writer.print("--{s}--\r\n", .{boundary});

    var headers: std.ArrayList(Header) = .empty;
    try headers.append(arena, .{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ boundary });
    if (action_header) |id| try headers.append(arena, .{ .name = "x-action", .value = id });

    return h.fetch(arena, .{
        .method = .POST,
        .path = path,
        .headers = headers.items,
        .body = aw.written(),
    });
}

fn expectStates(arena: Allocator, body: []const u8, expected: []const []const u8) !void {
    const actual = zxon.parse([]const []const u8, arena, body, .{}) catch |err| {
        std.debug.print("unparsable states body: `{s}`\n", .{body});
        return err;
    };
    try expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try expectEqualStrings(e, a);
}

fn expectContentType(res: FetchResult, expected: []const u8) !void {
    const ct = res.header("content-type") orelse return error.MissingContentType;
    try expect(std.mem.find(u8, ct, expected) != null);
}

fn expectNoEventCalls() !void {
    try expectEqual(@as(u32, 0), events.calls.ping);
    try expectEqual(@as(u32, 0), events.calls.inc);
    try expectEqual(@as(u32, 0), events.calls.dec);
    try expectEqual(@as(u32, 0), events.calls.label);
}

fn expectNoActionCalls() !void {
    try expectEqual(@as(u32, 0), actions.calls.profile);
    try expectEqual(@as(u32, 0), actions.calls.greet);
    try expectEqual(@as(u32, 0), actions.calls.add);
    try expectEqual(@as(u32, 0), actions.calls.direct);
}
