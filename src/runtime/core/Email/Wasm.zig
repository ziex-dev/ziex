const Wasm = @This();

const std = @import("std");
const builtin = @import("builtin");
const Email = @import("../Email.zig");
const wire = @import("wire.zig");
const host = @import("../../wasm/imports.zig");

// Sends through a host email binding, e.g. `new Ziex({ email: "EMAIL" })`. The
// message is Cloudflare Email Service's `send()` shape, so its binding works as is
// and any other runtime can provide an object with the same `send`.
binding: []const u8 = "default",

pub const Env = enum {
    EMAIL_BINDING,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const env = struct {
    pub const binding = Env.EMAIL_BINDING;
};

pub fn email(w: *Wasm) Email {
    return .{ .userdata = w, .vtable = &.{ .send = &send } };
}

const Address = struct {
    a: Email.Address,

    pub fn jsonStringify(self: Address, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        const name = self.a.name orelse return jw.write(self.a.email);
        try jw.write(.{ .email = self.a.email, .name = name });
    }
};

pub const Message = struct {
    from: Address,
    to: ?[]const Address,
    cc: ?[]const Address,
    bcc: ?[]const Address,
    replyTo: ?Address,
    subject: []const u8,
    text: ?[]const u8,
    html: ?[]const u8,
    headers: ?wire.Headers,
    attachments: ?[]const Attachment,

    const Attachment = struct {
        // Base64 only to cross the host boundary as JSON: the host decodes it
        // (`decodeMessage` in runtime/email.ts) and bindings get the bytes.
        content: wire.Base64,
        filename: []const u8,
        type: []const u8,
        disposition: []const u8,
        contentId: ?[]const u8,
    };

    pub fn encode(arena: std.mem.Allocator, m: Email.Message) std.mem.Allocator.Error![]const u8 {
        const attachments = try arena.alloc(Attachment, m.attachments.len);
        for (attachments, m.attachments) |*d, a| d.* = .{
            .content = .{ .bytes = a.content },
            .filename = a.filename,
            .type = a.content_type orelse "application/octet-stream",
            .disposition = if (a.content_id != null) "inline" else "attachment",
            .contentId = a.content_id,
        };
        return std.json.Stringify.valueAlloc(arena, Message{
            .from = .{ .a = m.from },
            .to = try list(arena, m.to),
            .cc = try list(arena, m.cc),
            .bcc = try list(arena, m.bcc),
            .replyTo = if (m.reply_to) |a| .{ .a = a } else null,
            .subject = m.subject,
            .text = m.text,
            .html = m.html,
            .headers = if (m.headers.len > 0) .{ .list = m.headers } else null,
            .attachments = if (attachments.len > 0) attachments else null,
        }, .{ .emit_null_optional_fields = false });
    }

    fn list(arena: std.mem.Allocator, addrs: []const Email.Address) std.mem.Allocator.Error!?[]const Address {
        if (addrs.len == 0) return null;
        const out = try arena.alloc(Address, addrs.len);
        for (out, addrs) |*d, a| d.* = .{ .a = a };
        return out;
    }
};

const Reply = struct {
    messageId: ?[]const u8 = null,
    @"error": ?struct { code: ?[]const u8 = null, message: ?[]const u8 = null } = null,
};

fn send(userdata: ?*anyopaque, gpa: std.mem.Allocator, m: Email.Message) Email.Error!Email.Sent {
    if (comptime builtin.os.tag != .wasi) return error.Unavailable;
    const w: *Wasm = @ptrCast(@alignCast(userdata));

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload = try Message.encode(arena, m);
    var out: [*]u8 = undefined;
    const n = host.wait(.email_send, .{ w.binding, payload, &out });
    if (n == host.missing or n == host.unsupported) return error.Unavailable;
    if (n <= 0) return error.ApiError;

    const owned = host.owned(out, n);
    defer host.free(owned);
    const reply = std.json.parseFromSliceLeaky(Reply, arena, owned, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return error.InvalidResponse;

    if (reply.@"error") |e| {
        const code = e.code orelse "";
        std.log.scoped(.zx_email).warn("{s}: {s}", .{ code, e.message orelse "" });
        return errorFromCode(code);
    }
    return .{ .id = if (reply.messageId) |id| try gpa.dupe(u8, id) else null };
}

// Cloudflare Email Service error codes; other bindings may throw the same.
pub fn errorFromCode(code: []const u8) Email.Error {
    const map = std.StaticStringMap(Email.Error).initComptime(.{
        .{ "E_RATE_LIMIT_EXCEEDED", error.RateLimited },
        .{ "E_DAILY_LIMIT_EXCEEDED", error.RateLimited },
        .{ "E_SENDER_NOT_VERIFIED", error.Unauthorized },
        .{ "E_SENDER_DOMAIN_NOT_AVAILABLE", error.Unauthorized },
        .{ "E_SENDER_DOMAIN_NOT_CONFIGURED", error.Unauthorized },
        .{ "E_RECIPIENT_NOT_ALLOWED", error.Unauthorized },
        .{ "E_RECIPIENT_PLAN_RESTRICTED", error.Unauthorized },
        .{ "E_ACCOUNT_SUSPENDED", error.Unauthorized },
        .{ "E_EMAIL_SENDING_NOT_READY", error.Unavailable },
        .{ "E_INTERNAL_SERVER_ERROR", error.ApiError },
        .{ "E_DELIVERY_FAILED", error.ApiError },
    });
    if (map.get(code)) |err| return err;
    return if (std.mem.startsWith(u8, code, "E_")) error.Rejected else error.ApiError;
}
