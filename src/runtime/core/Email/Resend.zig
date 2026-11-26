const Resend = @This();

const std = @import("std");
const Email = @import("../Email.zig");
const http = @import("../http.zig");
const wire = @import("wire.zig");

io: std.Io,
api_key: ?[]const u8 = null,
base_url: []const u8 = default_base_url,

pub const default_base_url = "https://api.resend.com";

pub const Env = enum {
    RESEND_API_KEY,
    RESEND_BASE_URL,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const api_key = Env.RESEND_API_KEY;
    pub const base_url = Env.RESEND_BASE_URL;
};

pub fn email(r: *Resend) Email {
    return .{ .userdata = r, .vtable = &.{ .send = &send } };
}

const Body = struct {
    from: []const u8,
    to: ?[]const []const u8,
    cc: ?[]const []const u8,
    bcc: ?[]const []const u8,
    reply_to: ?[]const u8,
    subject: []const u8,
    text: ?[]const u8,
    html: ?[]const u8,
    headers: ?wire.Headers,
    attachments: ?[]const Attachment,

    const Attachment = struct {
        filename: []const u8,
        content: wire.Base64,
        content_type: ?[]const u8,
        content_id: ?[]const u8,
    };
};

fn send(userdata: ?*anyopaque, gpa: std.mem.Allocator, m: Email.Message) Email.Error!Email.Sent {
    const r: *Resend = @ptrCast(@alignCast(userdata));
    const key = r.api_key orelse return error.Unauthorized;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const attachments = try arena.alloc(Body.Attachment, m.attachments.len);
    for (attachments, m.attachments) |*d, a| d.* = .{
        .filename = a.filename,
        .content = .{ .bytes = a.content },
        .content_type = a.content_type,
        .content_id = a.content_id,
    };

    const payload = try std.json.Stringify.valueAlloc(arena, Body{
        .from = try formatAddress(arena, m.from.?),
        .to = try formatList(arena, m.to),
        .cc = try formatList(arena, m.cc),
        .bcc = try formatList(arena, m.bcc),
        .reply_to = if (m.reply_to) |a| try formatAddress(arena, a) else null,
        .subject = m.subject,
        .text = m.text,
        .html = m.html,
        .headers = if (m.headers.len > 0) .{ .list = m.headers } else null,
        .attachments = if (attachments.len > 0) attachments else null,
    }, .{ .emit_null_optional_fields = false });

    var headers: std.ArrayList(http.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    try headers.append(arena, .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}) });
    if (m.idempotency_key) |k| try headers.append(arena, .{ .name = "idempotency-key", .value = k });

    const url = try std.fmt.allocPrint(arena, "{s}/emails", .{std.mem.trimEnd(u8, r.base_url, "/")});
    var client: http.Client = .{ .io = r.io, .allocator = gpa };
    defer client.deinit();
    const res = try client.fetch(.{ .url = url, .method = .POST, .headers = headers.items, .payload = payload });
    defer res.deinit(gpa);

    if (res.status.class() != .success) {
        std.log.scoped(.zx_email).warn("{d} {s}: {s}", .{ @backingInt(res.status), url, res.body });
        return switch (res.status) {
            .unauthorized, .forbidden => error.Unauthorized,
            .too_many_requests => error.RateLimited,
            .bad_request, .unprocessable_entity => error.Rejected,
            else => error.ApiError,
        };
    }

    const reply = std.json.parseFromSliceLeaky(struct { id: ?[]const u8 = null }, arena, res.body, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidResponse;
    return .{ .id = if (reply.id) |id| try gpa.dupe(u8, id) else null };
}

fn formatAddress(arena: std.mem.Allocator, a: Email.Address) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{a});
}

fn formatList(arena: std.mem.Allocator, list: []const Email.Address) std.mem.Allocator.Error!?[]const []const u8 {
    if (list.len == 0) return null;
    const out = try arena.alloc([]const u8, list.len);
    for (out, list) |*d, a| d.* = try formatAddress(arena, a);
    return out;
}
