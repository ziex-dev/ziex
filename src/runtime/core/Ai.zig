const Ai = @This();

const std = @import("std");
const http = @import("http.zig");

gen: Gen,

pub const OpenAi = @import("Ai/OpenAi.zig");
pub const Anthropic = @import("Ai/Anthropic.zig");
pub const Stream = @import("Ai/Stream.zig");
pub const ui = @import("Ai/ui.zig");

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
    streamImage: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, options: Image.Options) Error!*Stream,
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

    // Yields `.image` events from `Stream.next`: partial previews, then the final image.
    pub fn streamImage(g: Gen, gpa: std.mem.Allocator, options: Image.Options) Error!*Stream {
        return g.vtable.streamImage(g.userdata, gpa, options);
    }

    pub const failing: Gen = .{ .vtable = &.{
        .text = &failingText,
        .stream = &failingStream,
        .image = &failingImage,
        .streamImage = &failingStreamImage,
    } };
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
        // Overrides the provider's configured key for this request.
        api_key: ?[]const u8 = null,
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
        // `low`, `medium`, `high` or `auto` (GPT image models).
        quality: ?[]const u8 = null,
        // Previews sent before the final image by `streamImage`, 0-3. Default 2.
        partial_images: ?u8 = null,
        // Overrides the provider's configured key for this request.
        api_key: ?[]const u8 = null,
    };

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }

    // One image from `streamImage`, still base64 encoded.
    pub const Chunk = struct {
        base64: []const u8,
        media_type: []const u8 = "image/png",
        // A lower quality preview; the final image follows.
        partial: bool = false,

        pub fn decode(c: Chunk, gpa: std.mem.Allocator) Error![]u8 {
            const decoder = std.base64.standard.Decoder;
            const bytes = try gpa.alloc(u8, decoder.calcSizeForSlice(c.base64) catch return error.InvalidResponse);
            errdefer gpa.free(bytes);
            decoder.decode(bytes, c.base64) catch return error.InvalidResponse;
            return bytes;
        }
    };
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

fn failingStreamImage(_: ?*anyopaque, _: std.mem.Allocator, _: Image.Options) Error!*Stream {
    return error.Unavailable;
}
