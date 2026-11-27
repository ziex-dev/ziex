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
    try std.testing.expect(Email.Provider.smtp.Type() == Email.Smtp);
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

    m = hello;
    m.from = .{ .email = "nope" };
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

test "memory > keeps copies" {
    var memory: Email.Memory = .init(gpa, io);
    defer memory.deinit();
    const email = memory.email();

    {
        var subject = "Welcome".*;
        var m = hello;
        m.from = .{ .email = "noreply@acme.dev" };
        m.subject = &subject;
        m.attachments = &.{.{ .filename = "a.txt", .content = "abc" }};
        const sent = try email.send(gpa, m);
        defer sent.deinit(gpa);
        try std.testing.expectEqualStrings("memory-1", sent.id.?);
        subject[0] = 'X';
    }

    const last = memory.last().?;
    try std.testing.expectEqualStrings("Welcome", last.subject);
    try std.testing.expectEqualStrings("noreply@acme.dev", last.from.email);
    try std.testing.expectEqualStrings("a@b.dev", last.to[0].email);
    try std.testing.expectEqualStrings("abc", last.attachments[0].content);

    const second = try email.send(gpa, hello);
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("hi@acme.dev", memory.last().?.from.email);
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

// --- SMTP --- //

test "smtp > parse tls tags" {
    try std.testing.expect(Email.Smtp.parseTls("starttls") == .starttls);
    try std.testing.expect(Email.Smtp.parseTls("tls") == .tls);
    try std.testing.expect(Email.Smtp.parseTls("none") == .none);
    try std.testing.expect(Email.Smtp.parseTls("nope") == null);
}

test "smtp > send through plaintext mock" {
    const captured = try withSmtp(struct {
        fn handle(stream: std.Io.net.Stream) ![]u8 {
            var rbuf: [4096]u8 = undefined;
            var wbuf: [512]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var w = stream.writer(io, &wbuf);
            const ri = &r.interface;
            const wi = &w.interface;

            try reply(wi, "220 localhost ESMTP mock");
            _ = try readLine(ri); // EHLO
            try reply(wi, "250-localhost");
            try reply(wi, "250-AUTH PLAIN");
            try reply(wi, "250 OK");
            _ = try readLine(ri); // AUTH PLAIN …
            try reply(wi, "235 2.7.0 OK");
            _ = try readLine(ri); // MAIL FROM
            try reply(wi, "250 2.1.0 OK");
            _ = try readLine(ri); // RCPT TO
            try reply(wi, "250 2.1.5 OK");
            _ = try readLine(ri); // DATA
            try reply(wi, "354 End data with <CR><LF>.<CR><LF>");
            const body = try readData(ri);
            try reply(wi, "250 2.0.0 OK");
            _ = try readLine(ri); // QUIT
            try reply(wi, "221 2.0.0 Bye");
            return body;
        }
    }.handle);

    defer gpa.free(captured);
    try std.testing.expect(std.mem.indexOf(u8, captured, "Subject: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "From:") != null);
}

test "smtp > empty host is unavailable" {
    var smtp: Email.Smtp = .{ .io = io, .host = "", .tls_mode = .none };
    try std.testing.expectError(error.Unavailable, smtp.email().send(gpa, hello));
}

const SmtpHandler = *const fn (stream: std.Io.net.Stream) anyerror![]u8;

fn withSmtp(comptime handle: SmtpHandler) ![]u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var result: ?anyerror![]u8 = null;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.Io.net.Server, out: *?anyerror![]u8) void {
            const stream = s.accept(io) catch |err| {
                out.* = err;
                return;
            };
            defer stream.close(io);
            out.* = handle(stream);
        }
    }.run, .{ &server, &result });

    var smtp: Email.Smtp = .{
        .io = io,
        .host = "127.0.0.1",
        .port = port,
        .username = "user",
        .password = "pass",
        .tls_mode = .none,
    };
    const sent = smtp.email().send(gpa, hello);
    thread.join();
    const body = try result.?;
    errdefer gpa.free(body);
    _ = try sent;
    return body;
}

fn reply(w: *std.Io.Writer, line: []const u8) !void {
    try w.print("{s}\r\n", .{line});
    try w.flush();
}

fn readLine(r: *std.Io.Reader) ![]const u8 {
    const line = try r.takeDelimiterInclusive('\n');
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn readData(r: *std.Io.Reader) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    while (true) {
        const line = try readLine(r);
        if (std.mem.eql(u8, line, ".")) break;
        const content = if (line.len > 0 and line[0] == '.') line[1..] else line;
        if (body.items.len > 0) try body.appendSlice(gpa, "\r\n");
        try body.appendSlice(gpa, content);
    }
    return try body.toOwnedSlice(gpa);
}
