const Ai = @This();

const std = @import("std");
const http = @import("http.zig");

gen: Gen,

pub const OpenAi = @import("Ai/OpenAi.zig");
pub const Anthropic = @import("Ai/Anthropic.zig");
pub const Stream = @import("Ai/Stream.zig");

pub const Provider = enum {
    openai,
    anthropic,

    pub fn Type(comptime provider: Provider) type {
        return switch (provider) {
            .openai => OpenAi,
            .anthropic => Anthropic,
        };
    }
};

pub const Error = error{
    Unavailable,
    Unsupported,
    MissingModel,
    Unauthorized,
    RateLimited,
    ApiError,
} || http.Client.Error;

pub const VTable = struct {
    text: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Text.Options) Error!Text,
    stream: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Text.Options) Error!*Stream,
    image: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Image.Options) Error!Image,
};

pub const Gen = struct {
    userdata: ?*anyopaque = null,
    vtable: *const VTable,

    pub fn text(g: Gen, gpa: std.mem.Allocator, options: Text.Options) Error!Text {
        return g.vtable.text(g.userdata, gpa, options);
    }

    pub fn stream(g: Gen, gpa: std.mem.Allocator, options: Text.Options) Error!*Stream {
        return g.vtable.stream(g.userdata, gpa, options);
    }

    pub fn image(g: Gen, gpa: std.mem.Allocator, options: Image.Options) Error!Image {
        return g.vtable.image(g.userdata, gpa, options);
    }

    pub const failing: Gen = .{ .vtable = &.{ .text = &failingText, .stream = &failingStream, .image = &failingImage } };
};

pub const failing: Ai = .{ .gen = .failing };

pub const Message = struct {
    role: Role,
    content: []const u8,

    pub const Role = enum { system, user, assistant };
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
};

pub const Finish = enum { stop, length, content_filter, tool_calls, other };

pub const Text = struct {
    text: []const u8,
    finish: Finish = .other,
    usage: Usage = .{},

    pub const Options = struct {
        model: ?[]const u8 = null,
        system: ?[]const u8 = null,
        prompt: ?[]const u8 = null,
        messages: []const Message = &.{},
        max_tokens: ?u32 = null,
        temperature: ?f32 = null,
    };

    pub fn deinit(self: Text, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }
};

pub const Image = struct {
    bytes: []const u8,
    media_type: []const u8 = "image/png",

    pub const Options = struct {
        model: ?[]const u8 = null,
        prompt: []const u8,
        size: ?[]const u8 = null,
    };

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

fn failingText(_: ?*anyopaque, _: std.mem.Allocator, _: Text.Options) Error!Text {
    return error.Unavailable;
}

fn failingStream(_: ?*anyopaque, _: std.mem.Allocator, _: Text.Options) Error!*Stream {
    return error.Unavailable;
}

fn failingImage(_: ?*anyopaque, _: std.mem.Allocator, _: Image.Options) Error!Image {
    return error.Unavailable;
}
