const std = @import("std");
const zx = @import("zx");

const Ai = zx.Ai;
const Harness = zx.testing.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;

fn withServer(comptime case: fn (base: []const u8) anyerror!void) !void {
    var harness = try Harness.start(.std, io, gpa, .{});
    defer harness.stop();

    var buf: [64]u8 = undefined;
    try case(try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/ai", .{harness.tcp.?.port}));
}

fn join(buf: []u8, base: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, path }) catch unreachable;
}

// --- Interface --- //

test "failing > every call is unavailable" {
    try std.testing.expectError(error.Unavailable, Ai.failing.gen.text(gpa, .{ .prompt = "hi" }));
    try std.testing.expectError(error.Unavailable, Ai.failing.gen.stream(gpa, .{ .prompt = "hi" }));
    try std.testing.expectError(error.Unavailable, Ai.failing.gen.image(gpa, .{ .prompt = "hi" }));
    try std.testing.expectError(error.Unavailable, Ai.failing.gen.streamImage(gpa, .{ .prompt = "hi" }));
}

test "zx.ai > defaults to failing" {
    try std.testing.expectError(error.Unavailable, zx.ai.gen.text(gpa, .{ .prompt = "hi" }));
}

test "provider > type by tag" {
    try std.testing.expect(Ai.Provider.openai.Type() == Ai.OpenAi);
    try std.testing.expect(Ai.Provider.anthropic.Type() == Ai.Anthropic);
}

// --- OpenAI --- //

test "openai > text with system and prompt" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };
            const ai = openai.ai();

            const res = try ai.gen.text(gpa, .{ .system = "be brief", .prompt = "hello" });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("gpt-test|su|hello", res.text);
            try std.testing.expectEqual(Ai.Finish.stop, res.finish);
            try std.testing.expectEqual(Ai.Usage{ .input_tokens = 2, .output_tokens = 2 }, res.usage);
        }
    }.run);
}

test "openai > text with messages, model override and max tokens" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai/"), .model = "gpt-test" };
            const ai = openai.ai();

            const res = try ai.gen.text(gpa, .{
                .model = "gpt-other",
                .messages = &.{
                    .{ .role = .user, .content = "hi" },
                    .{ .role = .assistant, .content = "hey" },
                    .{ .role = .user, .content = "bye" },
                },
                .max_tokens = 8,
            });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("gpt-other|uau|bye", res.text);
            try std.testing.expectEqual(Ai.Finish.length, res.finish);
        }
    }.run);
}

test "openai > missing model fails before any request" {
    var openai: Ai.OpenAi = .{ .io = io, .base_url = "http://127.0.0.1:1" };
    try std.testing.expectError(error.MissingModel, openai.ai().gen.text(gpa, .{ .prompt = "hi" }));
    try std.testing.expectError(error.MissingModel, openai.ai().gen.image(gpa, .{ .prompt = "hi" }));
}

test "openai > bad key is unauthorized" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "nope", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };
            try std.testing.expectError(error.Unauthorized, openai.ai().gen.text(gpa, .{ .prompt = "hi" }));
        }
    }.run);
}

test "openai > 429 is rate limited" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/limited"), .model = "gpt-test" };
            try std.testing.expectError(error.RateLimited, openai.ai().gen.text(gpa, .{ .prompt = "hi" }));
        }
    }.run);
}

test "openai > image decodes base64" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .image_model = "gpt-image-1" };

            const img = try openai.ai().gen.image(gpa, .{ .prompt = "a red fox", .size = "1024x1024" });
            defer img.deinit(gpa);
            try std.testing.expectEqualStrings("a red fox", img.bytes);
            try std.testing.expectEqualStrings("image/webp", img.media_type);
        }
    }.run);
}

test "openai > image downloads url" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai") };

            const img = try openai.ai().gen.image(gpa, .{ .model = "dall-e-3", .prompt = "blue-fox" });
            defer img.deinit(gpa);
            try std.testing.expectEqualStrings("blue-fox", img.bytes);
            try std.testing.expectEqualStrings("image/png", img.media_type);
        }
    }.run);
}

test "openai > stream reads deltas" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };

            const stream = try openai.ai().gen.stream(gpa, .{ .system = "be brief", .prompt = "hello" });
            defer stream.deinit();

            const text = try stream.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(text);
            try std.testing.expectEqualStrings("gpt-test|su|hello", text);
            try std.testing.expectEqual(Ai.Finish.stop, stream.finish);
            try std.testing.expectEqual(Ai.Usage{ .input_tokens = 2, .output_tokens = 2 }, stream.usage);
        }
    }.run);
}

test "openai > stream works with reader helpers" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };

            const stream = try openai.ai().gen.stream(gpa, .{ .prompt = "a|b", .max_tokens = 4 });
            defer stream.deinit();

            const r = &stream.interface;
            try std.testing.expectEqualStrings("gpt-test", (try r.takeDelimiter('|')).?);
            try std.testing.expectEqualStrings("u", (try r.takeDelimiter('|')).?);
            try std.testing.expectEqualStrings("a", (try r.takeDelimiter('|')).?);
            try std.testing.expectEqualStrings("b", (try r.takeDelimiter('|')).?);
            try std.testing.expect(try r.takeDelimiter('|') == null);
            try std.testing.expectEqual(Ai.Finish.length, stream.finish);
        }
    }.run);
}

test "openai > stream bad key is unauthorized" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "nope", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };
            try std.testing.expectError(error.Unauthorized, openai.ai().gen.stream(gpa, .{ .prompt = "hi" }));
        }
    }.run);
}

test "openai > stream events are text deltas" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };

            const stream = try openai.ai().gen.stream(gpa, .{ .prompt = "hey" });
            defer stream.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            while (try stream.next()) |event| try out.writer.writeAll(event.text);
            try std.testing.expectEqualStrings("gpt-test|u|hey", out.written());
            try std.testing.expect(try stream.next() == null);
        }
    }.run);
}

test "openai > stream image sends partials then the final image" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .image_model = "gpt-image-1" };

            const stream = try openai.ai().gen.streamImage(gpa, .{ .prompt = "abcdef", .partial_images = 2 });
            defer stream.deinit();

            const want = [_]struct { []const u8, bool }{ .{ "ab", true }, .{ "abcd", true }, .{ "abcdef", false } };
            for (want) |w| {
                const img = (try stream.next()).?.image;
                const bytes = try img.decode(gpa);
                defer gpa.free(bytes);
                try std.testing.expectEqualStrings(w[0], bytes);
                try std.testing.expectEqual(w[1], img.partial);
                try std.testing.expectEqualStrings("image/webp", img.media_type);
            }
            try std.testing.expect(try stream.next() == null);
            try std.testing.expectEqual(Ai.Finish.stop, stream.finish);
            try std.testing.expectEqual(Ai.Usage{ .input_tokens = 3, .output_tokens = 7 }, stream.usage);
        }
    }.run);
}

test "openai > stream image reads events larger than the transfer buffer" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .image_model = "gpt-image-1" };

            const prompt = try gpa.alloc(u8, 96 * 1024);
            defer gpa.free(prompt);
            for (prompt, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

            const stream = try openai.ai().gen.streamImage(gpa, .{ .prompt = prompt, .partial_images = 1 });
            defer stream.deinit();

            try std.testing.expect((try stream.next()).?.image.partial);
            const bytes = try (try stream.next()).?.image.decode(gpa);
            defer gpa.free(bytes);
            try std.testing.expectEqualStrings(prompt, bytes);
        }
    }.run);
}

test "openai > reader skips image events" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .image_model = "gpt-image-1" };

            const stream = try openai.ai().gen.streamImage(gpa, .{ .prompt = "fox" });
            defer stream.deinit();
            const text = try stream.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(text);
            try std.testing.expectEqualStrings("", text);
        }
    }.run);
}

// --- AI SDK UI message stream --- //

test "ui > text stream as UI message chunks" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .model = "gpt-test" };

            const stream = try openai.ai().gen.stream(gpa, .{ .prompt = "hey" });
            defer stream.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try Ai.ui.write(&out.writer, stream);

            try std.testing.expectEqualStrings(
                \\data: {"type":"start"}
                \\
                \\data: {"type":"text-start","id":"text-0"}
                \\
                \\data: {"type":"text-delta","id":"text-0","delta":"gpt"}
                \\
                \\data: {"type":"text-delta","id":"text-0","delta":"-te"}
                \\
                \\data: {"type":"text-delta","id":"text-0","delta":"st|"}
                \\
                \\data: {"type":"text-delta","id":"text-0","delta":"u|h"}
                \\
                \\data: {"type":"text-delta","id":"text-0","delta":"ey"}
                \\
                \\data: {"type":"text-end","id":"text-0"}
                \\
                \\data: {"type":"finish","finishReason":"stop"}
                \\
                \\data: [DONE]
                \\
                \\
            , out.written());
        }
    }.run);
}

test "ui > image stream as transient previews and a file part" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var openai: Ai.OpenAi = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/openai"), .image_model = "gpt-image-1" };

            const stream = try openai.ai().gen.streamImage(gpa, .{ .prompt = "fox", .partial_images = 1 });
            defer stream.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try Ai.ui.write(&out.writer, stream);

            // "f" and "fox" in base64.
            try std.testing.expectEqualStrings(
                \\data: {"type":"start"}
                \\
                \\data: {"type":"data-image","id":"image-0","transient":true,"data":{"partial":true,"mediaType":"image/webp","url":"data:image/webp;base64,Zg=="}}
                \\
                \\data: {"type":"file","mediaType":"image/webp","url":"data:image/webp;base64,Zm94"}
                \\
                \\data: {"type":"finish","finishReason":"stop"}
                \\
                \\data: [DONE]
                \\
                \\
            , out.written());
        }
    }.run);
}

test "ui > a failing stream ends with an error part" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/anthropic"), .model = "claude-error" };

            const stream = try anthropic.ai().gen.stream(gpa, .{ .prompt = "hi" });
            defer stream.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try Ai.ui.write(&out.writer, stream);

            try std.testing.expect(std.mem.endsWith(u8, out.written(),
                \\data: {"type":"error","errorText":"ApiError"}
                \\
                \\data: [DONE]
                \\
                \\
            ));
        }
    }.run);
}

test "ui > messages joins text parts and skips the rest" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const Body = struct { messages: []const Ai.ui.Message };
    const body = try std.json.parseFromSliceLeaky(Body, arena.allocator(),
        \\{"id":"c1","trigger":"submit-message","messages":[
        \\  {"id":"1","role":"system","parts":[{"type":"text","text":"be brief"}]},
        \\  {"id":"2","role":"user","parts":[{"type":"text","text":"a "},{"type":"step-start"},{"type":"text","text":"b"}]},
        \\  {"id":"3","role":"assistant","parts":[{"type":"file","url":"data:,","mediaType":"image/png"}]},
        \\  {"id":"4","role":"assistant","content":"c"}
        \\]}
    , .{ .ignore_unknown_fields = true });
    const msgs = try Ai.ui.messages(arena.allocator(), body.messages);
    try std.testing.expectEqual(3, msgs.len);
    try std.testing.expectEqual(Ai.Message.Role.system, msgs[0].role);
    try std.testing.expectEqualStrings("a b", msgs[1].content);
    try std.testing.expectEqualStrings("c", msgs[2].content);
}

// --- Anthropic --- //

test "anthropic > text moves system messages out of messages" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/anthropic"), .model = "claude-test" };
            const ai = anthropic.ai();

            const res = try ai.gen.text(gpa, .{
                .system = "be brief",
                .messages = &.{
                    .{ .role = .system, .content = "no emoji" },
                    .{ .role = .user, .content = "a" },
                    .{ .role = .assistant, .content = "b" },
                },
                .prompt = "c",
            });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("claude-test|be brief\n\nno emoji|uau|c", res.text);
            try std.testing.expectEqual(Ai.Finish.stop, res.finish);
            try std.testing.expectEqual(Ai.Usage{ .input_tokens = 3, .output_tokens = 5 }, res.usage);
        }
    }.run);
}

test "anthropic > max tokens maps to length" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/anthropic"), .model = "claude-test" };

            const res = try anthropic.ai().gen.text(gpa, .{ .prompt = "hi", .max_tokens = 1 });
            defer res.deinit(gpa);

            try std.testing.expectEqualStrings("claude-test|-|u|hi", res.text);
            try std.testing.expectEqual(Ai.Finish.length, res.finish);
        }
    }.run);
}

test "anthropic > missing key is unauthorized" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .base_url = join(&buf, base, "/anthropic"), .model = "claude-test" };
            try std.testing.expectError(error.Unauthorized, anthropic.ai().gen.text(gpa, .{ .prompt = "hi" }));
        }
    }.run);
}

test "anthropic > stream reads text deltas" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/anthropic"), .model = "claude-test" };

            const stream = try anthropic.ai().gen.stream(gpa, .{ .system = "be brief", .prompt = "hi" });
            defer stream.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            _ = try stream.interface.streamRemaining(&out.writer);

            try std.testing.expectEqualStrings("claude-test|be brief|u|hi", out.written());
            try std.testing.expectEqual(Ai.Finish.stop, stream.finish);
            try std.testing.expectEqual(Ai.Usage{ .input_tokens = 3, .output_tokens = 5 }, stream.usage);
        }
    }.run);
}

test "anthropic > stream error event fails the read" {
    try withServer(struct {
        fn run(base: []const u8) !void {
            var buf: [96]u8 = undefined;
            var anthropic: Ai.Anthropic = .{ .io = io, .api_key = "test-key", .base_url = join(&buf, base, "/anthropic"), .model = "claude-error" };

            const stream = try anthropic.ai().gen.stream(gpa, .{ .prompt = "hi" });
            defer stream.deinit();

            try std.testing.expectError(error.ReadFailed, stream.interface.allocRemaining(gpa, .unlimited));
            try std.testing.expectEqual(@as(?Ai.Error, error.ApiError), stream.err);
        }
    }.run);
}

test "anthropic > image is unsupported" {
    var anthropic: Ai.Anthropic = .{ .io = io };
    try std.testing.expectError(error.Unsupported, anthropic.ai().gen.image(gpa, .{ .prompt = "hi" }));
}
