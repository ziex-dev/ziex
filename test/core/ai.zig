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
