const Anthropic = @This();

const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");
const api = @import("api.zig");

io: std.Io,
api_key: ?[]const u8 = null,
base_url: []const u8 = default_base_url,
model: ?[]const u8 = null,

pub const default_base_url = "https://api.anthropic.com/v1";

pub const Env = enum {
    ANTHROPIC_API_KEY,
    ANTHROPIC_BASE_URL,
    ANTHROPIC_MODEL,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const api_key = Env.ANTHROPIC_API_KEY;
    pub const base_url = Env.ANTHROPIC_BASE_URL;
    pub const model = Env.ANTHROPIC_MODEL;
};

const version = "2023-06-01";
const default_max_tokens = 4096;

pub fn ai(p: *Anthropic) Ai {
    return .{ .gen = .{ .userdata = p, .vtable = &.{ .text = &text, .stream = &stream, .image = &image } } };
}

const Turn = struct {
    role: Ai.Message.Role,
    content: []const u8,
};

const Messages = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    messages: []const Turn,
    temperature: ?f32 = null,
    stream: ?bool = null,
};

fn messages(p: *const Anthropic, arena: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!Messages {
    // System prompts go in their own field, not in `messages`.
    var system: std.ArrayList([]const u8) = .empty;
    var turns: std.ArrayList(Turn) = .empty;
    if (options.system) |s| try system.append(arena, s);
    for (options.messages) |m| switch (m.role) {
        .system => try system.append(arena, m.content),
        else => try turns.append(arena, .{ .role = m.role, .content = m.content }),
    };
    if (options.prompt) |s| try turns.append(arena, .{ .role = .user, .content = s });

    return .{
        .model = try api.model(options.model, p.model),
        .max_tokens = options.max_tokens orelse default_max_tokens,
        .system = if (system.items.len > 0) try std.mem.join(arena, "\n\n", system.items) else null,
        .messages = turns.items,
        .temperature = options.temperature,
    };
}

fn text(userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!Ai.Text {
    const p: *Anthropic = @ptrCast(@alignCast(userdata));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try api.endpoint(arena, p.base_url, "/messages");
    const body = try api.post(p.io, gpa, url, try p.headers(arena), try p.messages(arena, options));
    defer gpa.free(body);

    const Reply = struct {
        content: []const struct { type: []const u8, text: ?[]const u8 = null },
        stop_reason: ?[]const u8 = null,
        usage: Ai.Usage = .{},
    };
    const res = try api.parse(Reply, arena, body);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (res.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) try out.appendSlice(gpa, block.text orelse "");
    }

    return .{
        .text = try out.toOwnedSlice(gpa),
        .finish = finish(res.stop_reason orelse ""),
        .usage = res.usage,
    };
}

fn stream(userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Ai.Text.Options) Ai.Error!*Ai.Stream {
    const p: *Anthropic = @ptrCast(@alignCast(userdata));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request = try p.messages(arena, options);
    request.stream = true;

    const url = try api.endpoint(arena, p.base_url, "/messages");
    return Ai.Stream.open(p.io, gpa, url, try p.headers(arena), request, &parseEvent);
}

fn parseEvent(s: *Ai.Stream, arena: std.mem.Allocator, data: []const u8) Ai.Error!?[]const u8 {
    const Event = struct {
        type: []const u8,
        message: ?struct { usage: Ai.Usage = .{} } = null,
        delta: ?struct { text: ?[]const u8 = null, stop_reason: ?[]const u8 = null } = null,
        usage: ?struct { output_tokens: u32 = 0 } = null,
    };
    const event = try api.parse(Event, arena, data);
    const kind = std.meta.stringToEnum(enum { message_start, content_block_delta, message_delta, @"error" }, event.type) orelse return null;

    switch (kind) {
        .message_start => if (event.message) |m| {
            s.usage = m.usage;
        },
        .content_block_delta => return if (event.delta) |d| d.text else null,
        .message_delta => {
            if (event.delta) |d| if (d.stop_reason) |r| {
                s.finish = finish(r);
            };
            if (event.usage) |u| s.usage.output_tokens = u.output_tokens;
        },
        .@"error" => {
            std.log.scoped(.zx_ai).warn("stream error: {s}", .{data});
            return error.ApiError;
        },
    }
    return null;
}

fn image(_: ?*anyopaque, _: std.mem.Allocator, _: Ai.Image.Options) Ai.Error!Ai.Image {
    return error.Unsupported;
}

fn finish(reason: []const u8) Ai.Finish {
    const map = std.StaticStringMap(Ai.Finish).initComptime(.{
        .{ "end_turn", .stop },
        .{ "stop_sequence", .stop },
        .{ "max_tokens", .length },
        .{ "tool_use", .tool_calls },
        .{ "refusal", .content_filter },
    });
    return map.get(reason) orelse .other;
}

fn headers(p: *const Anthropic, arena: std.mem.Allocator) Ai.Error![]const http.Header {
    const base = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "anthropic-version", .value = version },
    };
    const key = p.api_key orelse return arena.dupe(http.Header, &base);
    return arena.dupe(http.Header, &(base ++ [_]http.Header{.{ .name = "x-api-key", .value = key }}));
}
