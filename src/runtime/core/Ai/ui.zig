//! The AI SDK UI message stream protocol, as spoken by `useChat`.
//!
//! ```zig
//! pub fn POST(ctx: zx.RouteContext) !void {
//!     const body = try ctx.request.json(struct { messages: []const zx.Ai.ui.Message }, .{ .ignore_unknown_fields = true }) orelse
//!         return zx.Ai.ui.respond(ctx.response, error.InvalidRequest);
//!     const messages = try zx.Ai.ui.messages(ctx.arena, body.messages);
//!     try zx.Ai.ui.respond(ctx.response, zx.ai.gen.stream(ctx.allocator, .{ .messages = messages }));
//! }
//! ```
//!
//! Text becomes `text-*` parts and the final image a `file` part with a data
//! URL. Partial images are transient `data-image` parts, seen only by `onData`.

const std = @import("std");
const Ai = @import("../Ai.zig");
const http = @import("../http.zig");

pub const headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "x-vercel-ai-ui-message-stream", .value = "v1" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

// Streams `opened` to `res`, sending a failure to open as an `error` part.
// Takes ownership of the stream.
pub fn respond(res: http.Response, opened: anyerror!*Ai.Stream) !void {
    for (headers) |h| res.headers.set(h.name, h.value);
    var buffer: [4096]u8 = undefined;
    var out: ResponseWriter = .{ .res = res, .interface = .{ .vtable = &.{ .drain = ResponseWriter.drain }, .buffer = &buffer } };
    const s = opened catch |err| {
        try writeError(&out.interface, err);
        return out.interface.flush();
    };
    defer s.deinit();
    try write(&out.interface, s);
}

// Writes the whole stream as SSE to `w`, flushing after each part.
// A failing stream ends with an `error` part rather than an error.
pub fn write(w: *std.Io.Writer, s: *Ai.Stream) std.Io.Writer.Error!void {
    try part(w, .{ .type = "start" });
    var text_open = false;
    while (true) {
        const event = s.next() catch |err| {
            try writeError(w, err);
            return;
        } orelse break;
        switch (event) {
            .text => |delta| {
                if (!text_open) try part(w, .{ .type = "text-start", .id = text_id });
                text_open = true;
                try part(w, .{ .type = "text-delta", .id = text_id, .delta = delta });
            },
            .image => |img| try image(w, img),
        }
    }
    if (text_open) try part(w, .{ .type = "text-end", .id = text_id });
    try part(w, .{ .type = "finish", .finishReason = finishReason(s.finish) });
    try done(w);
}

pub const Message = struct {
    role: []const u8,
    parts: []const struct { type: []const u8, text: ?[]const u8 = null } = &.{},
    // Plain `content`, as AI SDK 4 sent it.
    content: ?[]const u8 = null,
};

// Joins each message's text parts, dropping messages without text.
pub fn messages(arena: std.mem.Allocator, ui: []const Message) ![]const Ai.Message {
    var out: std.ArrayList(Ai.Message) = .empty;
    for (ui) |m| {
        const role = std.meta.stringToEnum(Ai.Message.Role, m.role) orelse continue;
        var text: std.ArrayList(u8) = .empty;
        if (m.content) |c| try text.appendSlice(arena, c);
        for (m.parts) |p| if (std.mem.eql(u8, p.type, "text")) {
            try text.appendSlice(arena, p.text orelse "");
        };
        if (text.items.len == 0) continue;
        try out.append(arena, .{ .role = role, .content = text.items });
    }
    return out.items;
}

const text_id = "text-0";

fn part(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    try w.print("data: {f}\n\n", .{std.json.fmt(value, .{})});
    try w.flush();
}

// Written by hand so megabytes of base64 aren't copied into a data URL first.
fn image(w: *std.Io.Writer, img: Ai.Image.Chunk) std.Io.Writer.Error!void {
    if (img.partial) {
        try w.writeAll("data: {\"type\":\"data-image\",\"id\":\"image-0\",\"transient\":true,\"data\":{\"partial\":true,\"mediaType\":");
    } else {
        try w.writeAll("data: {\"type\":\"file\",\"mediaType\":");
    }
    try w.print("{f}", .{std.json.fmt(img.media_type, .{})});
    try w.print(",\"url\":\"data:{s};base64,", .{img.media_type});
    try w.writeAll(img.base64);
    try w.writeAll(if (img.partial) "\"}}\n\n" else "\"}\n\n");
    try w.flush();
}

fn writeError(w: *std.Io.Writer, err: anyerror) std.Io.Writer.Error!void {
    try part(w, .{ .type = "error", .errorText = @errorName(err) });
    try done(w);
}

fn done(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("data: [DONE]\n\n");
    try w.flush();
}

fn finishReason(f: Ai.Finish) []const u8 {
    return switch (f) {
        .stop => "stop",
        .length => "length",
        .content_filter => "content-filter",
        .tool_calls => "tool-calls",
        .other => "other",
    };
}

// Sends each flush as one chunk of the response body.
const ResponseWriter = struct {
    res: http.Response,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ResponseWriter = @alignCast(@fieldParentPtr("interface", w));
        if (w.end > 0) {
            self.res.write(w.buffered()) catch return error.WriteFailed;
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            if (d.len > 0) self.res.write(d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        if (last.len > 0) for (0..splat) |_| {
            self.res.write(last) catch return error.WriteFailed;
            n += last.len;
        };
        return n;
    }
};
