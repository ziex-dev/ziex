const OpenAi = @This();

const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");
const api = @import("api.zig");

io: std.Io,
api_key: ?[]const u8 = null,
base_url: []const u8 = default_base_url,
model: ?[]const u8 = null,
image_model: ?[]const u8 = null,

pub const default_base_url = "https://api.openai.com/v1";

pub const Env = enum {
    OPENAI_API_KEY,
    OPENAI_BASE_URL,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const api_key = Env.OPENAI_API_KEY;
    pub const base_url = Env.OPENAI_BASE_URL;
};

pub fn ai(p: *OpenAi) Ai {
    return .{ .gen = .{ .userdata = p, .vtable = &.{ .text = &text, .stream = &stream, .image = &image } } };
}

const Chat = struct {
    model: []const u8,
    messages: []const Ai.Message,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    stream: ?bool = null,
    stream_options: ?struct { include_usage: bool = true } = null,
};

const TokenUsage = struct { prompt_tokens: u32 = 0, completion_tokens: u32 = 0 };

fn chat(p: *const OpenAi, arena: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!Chat {
    var messages: std.ArrayList(Ai.Message) = .empty;
    if (options.system) |s| try messages.append(arena, .{ .role = .system, .content = s });
    try messages.appendSlice(arena, options.messages);
    if (options.prompt) |s| try messages.append(arena, .{ .role = .user, .content = s });

    return .{
        .model = try api.model(options.model, p.model),
        .messages = messages.items,
        .max_tokens = options.max_tokens,
        .temperature = options.temperature,
    };
}

fn text(userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!Ai.Text {
    const p: *OpenAi = @ptrCast(@alignCast(userdata));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try api.endpoint(arena, p.base_url, "/chat/completions");
    const body = try api.post(p.io, gpa, url, try p.headers(arena), try p.chat(arena, options));
    defer gpa.free(body);

    const Completion = struct {
        choices: []const struct {
            message: struct { content: ?[]const u8 = null },
            finish_reason: ?[]const u8 = null,
        },
        usage: ?TokenUsage = null,
    };
    const res = try api.parse(Completion, arena, body);
    if (res.choices.len == 0) return error.InvalidResponse;
    const choice = res.choices[0];

    return .{
        .text = try gpa.dupe(u8, choice.message.content orelse ""),
        .finish = finish(choice.finish_reason),
        .usage = usage(res.usage),
    };
}

fn stream(userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!*Ai.Stream {
    const p: *OpenAi = @ptrCast(@alignCast(userdata));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request = try p.chat(arena, options);
    request.stream = true;
    request.stream_options = .{};

    const url = try api.endpoint(arena, p.base_url, "/chat/completions");
    return Ai.Stream.open(p.io, gpa, url, try p.headers(arena), request, &parseChunk);
}

fn parseChunk(s: *Ai.Stream, arena: std.mem.Allocator, data: []const u8) Ai.Error!?[]const u8 {
    const Chunk = struct {
        choices: []const struct {
            delta: struct { content: ?[]const u8 = null } = .{},
            finish_reason: ?[]const u8 = null,
        } = &.{},
        usage: ?TokenUsage = null,
    };
    const chunk = try api.parse(Chunk, arena, data);
    if (chunk.usage != null) s.usage = usage(chunk.usage);
    if (chunk.choices.len == 0) return null;

    const choice = chunk.choices[0];
    if (choice.finish_reason != null) s.finish = finish(choice.finish_reason);
    return choice.delta.content;
}

fn finish(reason: ?[]const u8) Ai.Finish {
    return std.meta.stringToEnum(Ai.Finish, reason orelse "") orelse .other;
}

fn usage(u: ?TokenUsage) Ai.Usage {
    const t = u orelse return .{};
    return .{ .input_tokens = t.prompt_tokens, .output_tokens = t.completion_tokens };
}

fn image(userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Ai.Image.Options) Ai.Error!Ai.Image {
    const p: *OpenAi = @ptrCast(@alignCast(userdata));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try api.endpoint(arena, p.base_url, "/images/generations");
    const body = try api.post(p.io, gpa, url, try p.headers(arena), .{
        .model = try api.model(options.model, p.image_model),
        .prompt = options.prompt,
        .size = options.size,
        .n = 1,
    });
    defer gpa.free(body);

    // Newer models return base64; older ones a URL by default.
    const Generation = struct {
        data: []const struct { b64_json: ?[]const u8 = null, url: ?[]const u8 = null },
        output_format: ?[]const u8 = null,
    };
    const res = try api.parse(Generation, arena, body);
    if (res.data.len == 0) return error.InvalidResponse;
    const item = res.data[0];

    const bytes = if (item.b64_json) |encoded|
        try decode(gpa, encoded)
    else if (item.url) |link|
        try api.get(p.io, gpa, link)
    else
        return error.InvalidResponse;

    return .{ .bytes = bytes, .media_type = media_types.get(res.output_format orelse "png") orelse "image/png" };
}

const media_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "png", "image/png" },
    .{ "jpeg", "image/jpeg" },
    .{ "webp", "image/webp" },
});

fn decode(gpa: std.mem.Allocator, encoded: []const u8) Ai.Error![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try gpa.alloc(u8, decoder.calcSizeForSlice(encoded) catch return error.InvalidResponse);
    errdefer gpa.free(bytes);
    decoder.decode(bytes, encoded) catch return error.InvalidResponse;
    return bytes;
}

fn headers(p: *const OpenAi, arena: std.mem.Allocator) Ai.Error![]const http.Header {
    const json: http.Header = .{ .name = "content-type", .value = "application/json" };
    const key = p.api_key orelse return arena.dupe(http.Header, &.{json});
    return arena.dupe(http.Header, &.{ json, .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}) } });
}
