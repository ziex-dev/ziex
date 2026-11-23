const std = @import("std");
const zx = @import("zx");

const Email = zx.Email;
const Harness = zx.testing.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;

fn withServer(comptime case: fn (base: []const u8) anyerror!void) !void {
    var harness = try Harness.start(.std, io, gpa, .{});
    defer harness.stop();

    var buf: [64]u8 = undefined;
    try case(try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/email/resend", .{harness.tcp.?.port}));
}

const hello: Email.Message = .{
    .from = .{ .email = "hi@acme.dev", .name = "Acme" },
    .to = &.{.{ .email = "a@b.dev" }},
    .subject = "Hello",
    .text = "hi",
};

// --- Interface --- //

test "failing > send is unavailable" {
    try std.testing.expectError(error.Unavailable, Email.failing.send(gpa, hello));
}

test "zx.email > defaults to failing" {
    try std.testing.expectError(error.Unavailable, zx.email.send(gpa, hello));
}

test "provider > type by tag" {
    try std.testing.expect(Email.Provider.resend.Type() == Email.Resend);
    try std.testing.expect(Email.Provider.wasm.Type() == Email.Wasm);
    try std.testing.expect(Email.Provider.memory.Type() == Email.Memory);
}

// --- Address --- //

test "address > parse forms" {
    const bare = try Email.Address.parse(" a@b.dev ");
    try std.testing.expectEqualStrings("a@b.dev", bare.email);
    try std.testing.expect(bare.name == null);

    const named = try Email.Address.parse("Acme Team <hi@acme.dev>");
    try std.testing.expectEqualStrings("hi@acme.dev", named.email);
    try std.testing.expectEqualStrings("Acme Team", named.name.?);

    const quoted = try Email.Address.parse("\"Doe, Jane\" <jane@doe.dev>");
    try std.testing.expectEqualStrings("Doe, Jane", quoted.name.?);

    const no_name = try Email.Address.parse("<a@b.dev>");
    try std.testing.expect(no_name.name == null);
}

test "address > rejects invalid" {
    for ([_][]const u8{ "", "nope", "@b.dev", "a@", "a b@c.dev", "a@b.dev>", "Name <a@b.dev", "a@b.dev\r\nBcc: x@y.dev" }) |s| {
        try std.testing.expectError(error.InvalidAddress, Email.Address.parse(s));
    }
    try std.testing.expectError(error.InvalidAddress, (Email.Address{ .email = "a@b.dev", .name = "x\r\nBcc: y@z.dev" }).validate());
}

test "address > format quotes the name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a@b.dev", try std.fmt.bufPrint(&buf, "{f}", .{Email.Address{ .email = "a@b.dev" }}));
    try std.testing.expectEqualStrings(
        "\"Doe, \\\"J\\\"\" <j@d.dev>",
        try std.fmt.bufPrint(&buf, "{f}", .{Email.Address{ .email = "j@d.dev", .name = "Doe, \"J\"" }}),
    );
}

// --- Validation --- //

test "message > invalid messages fail before sending" {
    var memory: Email.Memory = .init(gpa, io);
    defer memory.deinit();
    const email = memory.email();

    var m = hello;
    m.from = null;
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.to = &.{};
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.subject = "hi\r\nBcc: x@y.dev";
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.text = null;
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.headers = &.{.{ .name = "X-Tag", .value = "a\nb" }};
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.headers = &.{.{ .name = "Bad Name", .value = "v" }};
    try std.testing.expectError(error.InvalidMessage, email.send(gpa, m));

    m = hello;
    m.cc = &.{.{ .email = "nope" }};
    try std.testing.expectError(error.InvalidAddress, email.send(gpa, m));

    try std.testing.expectEqual(0, memory.sent().len);
}

test "message > bcc alone is a recipient" {
    var memory: Email.Memory = .init(gpa, io);
    defer memory.deinit();

    var m = hello;
    m.to = &.{};
    m.bcc = &.{.{ .email = "hidden@b.dev" }};
    const sent = try memory.email().send(gpa, m);
    defer sent.deinit(gpa);
}

// --- Memory --- //

test "memory > keeps copies and applies the default sender" {
    var memory: Email.Memory = .init(gpa, io);
    defer memory.deinit();
    var email = memory.email();
    email.from = .{ .email = "noreply@acme.dev" };

    {
        var subject = "Welcome".*;
        var m = hello;
        m.from = null;
        m.subject = &subject;
        m.attachments = &.{.{ .filename = "a.txt", .content = "abc" }};
        const sent = try email.send(gpa, m);
        defer sent.deinit(gpa);
        try std.testing.expectEqualStrings("memory-1", sent.id.?);
        subject[0] = 'X';
    }

    const last = memory.last().?;
    try std.testing.expectEqualStrings("Welcome", last.subject);
    try std.testing.expectEqualStrings("noreply@acme.dev", last.from.?.email);
    try std.testing.expectEqualStrings("a@b.dev", last.to[0].email);
    try std.testing.expectEqualStrings("abc", last.attachments[0].content);

    const second = try email.send(gpa, hello);
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("hi@acme.dev", memory.last().?.from.?.email);
    try std.testing.expectEqual(2, memory.sent().len);

    memory.clear();
    try std.testing.expectEqual(0, memory.sent().len);
}

// --- Wasm --- //

test "wasm > encodes the Cloudflare send() shape" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const json = try Email.Wasm.Message.encode(arena_state.allocator(), .{
        .from = .{ .email = "hi@acme.dev", .name = "Acme" },
        .to = &.{ .{ .email = "a@b.dev" }, .{ .email = "c@d.dev", .name = "C" } },
        .reply_to = .{ .email = "support@acme.dev" },
        .subject = "Hello",
        .html = "<p>hi</p>",
        .headers = &.{.{ .name = "X-Tag", .value = "welcome" }},
        .attachments = &.{
            .{ .filename = "a.txt", .content = "hello", .content_type = "text/plain" },
            .{ .filename = "logo.png", .content = "png", .content_id = "logo" },
        },
    });
    try std.testing.expectEqualStrings(
        \\{"from":{"email":"hi@acme.dev","name":"Acme"},"to":["a@b.dev",{"email":"c@d.dev","name":"C"}],"replyTo":"support@acme.dev","subject":"Hello","html":"<p>hi</p>","headers":{"X-Tag":"welcome"},"attachments":[{"content":"aGVsbG8=","filename":"a.txt","type":"text/plain","disposition":"attachment"},{"content":"cG5n","filename":"logo.png","type":"application/octet-stream","disposition":"inline","contentId":"logo"}]}
    , json);
}

test "wasm > maps binding error codes" {
    try std.testing.expectEqual(error.RateLimited, Email.Wasm.errorFromCode("E_RATE_LIMIT_EXCEEDED"));
    try std.testing.expectEqual(error.Unauthorized, Email.Wasm.errorFromCode("E_SENDER_NOT_VERIFIED"));
    try std.testing.expectEqual(error.Rejected, Email.Wasm.errorFromCode("E_VALIDATION_ERROR"));
    try std.testing.expectEqual(error.ApiError, Email.Wasm.errorFromCode(""));
}

test "wasm > unavailable natively" {
    var wasm: Email.Wasm = .{};
    try std.testing.expectError(error.Unavailable, wasm.email().send(gpa, hello));
}

// --- Resend --- //

test "resend > sends and returns the id" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var resend: Email.Resend = .{ .io = io, .api_key = "test-key", .base_url = base };
            const sent = try resend.email().send(gpa, .{
                .from = .{ .email = "hi@acme.dev", .name = "Acme" },
                .to = &.{ .{ .email = "a@b.dev" }, .{ .email = "c@d.dev" } },
                .cc = &.{.{ .email = "e@f.dev", .name = "E" }},
                .reply_to = .{ .email = "support@acme.dev" },
                .subject = "Hello",
                .html = "<p>hi</p>",
                .headers = &.{.{ .name = "X-Tag", .value = "welcome" }},
                .attachments = &.{.{ .filename = "a.txt", .content = "hello" }},
                .idempotency_key = "welcome/42",
            });
            defer sent.deinit(gpa);
            try std.testing.expectEqualStrings(
                "\"Acme\" <hi@acme.dev>|a@b.dev,c@d.dev|\"E\" <e@f.dev>|support@acme.dev|Hello|welcome|welcome/42|a.txt=hello",
                sent.id.?,
            );
        }
    }.run);
}

test "resend > missing key fails before any request" {
    var resend: Email.Resend = .{ .io = io, .base_url = "http://127.0.0.1:1" };
    try std.testing.expectError(error.Unauthorized, resend.email().send(gpa, hello));
}

test "resend > status codes map to errors" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var bad: Email.Resend = .{ .io = io, .api_key = "nope", .base_url = base };
            try std.testing.expectError(error.Unauthorized, bad.email().send(gpa, hello));

            var resend: Email.Resend = .{ .io = io, .api_key = "test-key", .base_url = base };
            var m = hello;
            m.subject = "limit";
            try std.testing.expectError(error.RateLimited, resend.email().send(gpa, m));
            m.subject = "reject";
            try std.testing.expectError(error.Rejected, resend.email().send(gpa, m));
        }
    }.run);
}
