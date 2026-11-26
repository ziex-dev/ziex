// Sends email through a provider: Resend over HTTP, SMTP, a host binding on edge
// runtimes (Cloudflare Email Service or your own), or in memory for tests and dev.
const Email = @This();

const std = @import("std");
const http = @import("http.zig");

userdata: ?*anyopaque = null,
vtable: *const VTable,
// Used when a message has no `from`.
from: ?Address = null,

pub const Resend = @import("Email/Resend.zig");
pub const Smtp = @import("Email/Smtp.zig");
pub const Wasm = @import("Email/Wasm.zig");
pub const Memory = @import("Email/Memory.zig");

pub const Env = enum {
    EMAIL_FROM,

    pub fn key(self: Env) []const u8 {
        return @tagName(self);
    }
};

pub const Provider = enum {
    resend,
    smtp,
    wasm,
    memory,

    pub fn Type(comptime provider: Provider) type {
        return switch (provider) {
            .resend => Resend,
            .smtp => Smtp,
            .wasm => Wasm,
            .memory => Memory,
        };
    }
};

pub const Error = error{
    Unavailable,
    InvalidAddress,
    InvalidMessage,
    Unauthorized,
    RateLimited,
    Rejected,
    ApiError,
} || http.Client.Error;

pub const VTable = struct {
    send: *const fn (userdata: ?*anyopaque, gpa: std.mem.Allocator, message: Message) Error!Sent,
};

pub const failing: Email = .{ .vtable = &.{ .send = &failingSend } };

pub const Address = struct {
    email: []const u8,
    name: ?[]const u8 = null,

    // Accepts `a@b.com`, `Name <a@b.com>` and `"Name" <a@b.com>`.
    pub fn parse(text: []const u8) Error!Address {
        const s = std.mem.trim(u8, text, " \t");
        const addr: Address = if (std.mem.endsWith(u8, s, ">")) blk: {
            const lt = std.mem.lastIndexOfScalar(u8, s, '<') orelse return error.InvalidAddress;
            var name = std.mem.trim(u8, s[0..lt], " \t");
            if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
            break :blk .{ .email = s[lt + 1 .. s.len - 1], .name = if (name.len > 0) name else null };
        } else .{ .email = s };
        try addr.validate();
        return addr;
    }

    pub fn validate(a: Address) Error!void {
        const at = std.mem.lastIndexOfScalar(u8, a.email, '@') orelse return error.InvalidAddress;
        if (at == 0 or at == a.email.len - 1) return error.InvalidAddress;
        for (a.email) |c| switch (c) {
            0...' ', 0x7f, '<', '>', '(', ')', ',', ';', ':', '"', '\\', '[', ']' => return error.InvalidAddress,
            else => {},
        };
        if (a.name) |n| if (hasLineBreak(n)) return error.InvalidAddress;
    }

    // `"Name" <a@b.com>`, or the bare address without a name.
    pub fn format(a: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const name = a.name orelse return w.writeAll(a.email);
        try w.writeByte('"');
        for (name) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.print("\" <{s}>", .{a.email});
    }
};

pub const Attachment = struct {
    filename: []const u8,
    // Raw bytes; providers encode as needed.
    content: []const u8,
    content_type: ?[]const u8 = null,
    // Set to embed inline, referenced from html as `cid:<content_id>`.
    content_id: ?[]const u8 = null,
};

pub const Message = struct {
    from: ?Address = null,
    to: []const Address = &.{},
    cc: []const Address = &.{},
    bcc: []const Address = &.{},
    reply_to: ?Address = null,
    subject: []const u8,
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    attachments: []const Attachment = &.{},
    // Dedupes retries where the provider supports it.
    idempotency_key: ?[]const u8 = null,

    pub fn validate(m: Message) Error!void {
        const from = m.from orelse return error.InvalidMessage;
        try from.validate();
        if (m.to.len + m.cc.len + m.bcc.len == 0) return error.InvalidMessage;
        for ([_][]const Address{ m.to, m.cc, m.bcc }) |list| for (list) |a| try a.validate();
        if (m.reply_to) |a| try a.validate();
        if (hasLineBreak(m.subject)) return error.InvalidMessage;
        if (m.text == null and m.html == null) return error.InvalidMessage;
        for (m.headers) |h| {
            if (h.name.len == 0 or hasLineBreak(h.value)) return error.InvalidMessage;
            for (h.name) |c| if (c <= ' ' or c >= 0x7f or c == ':') return error.InvalidMessage;
        }
    }

    // Deep copy into `arena`.
    pub fn clone(m: Message, arena: std.mem.Allocator) std.mem.Allocator.Error!Message {
        var out = m;
        if (m.from) |a| out.from = try cloneAddress(arena, a);
        out.to = try cloneAddresses(arena, m.to);
        out.cc = try cloneAddresses(arena, m.cc);
        out.bcc = try cloneAddresses(arena, m.bcc);
        if (m.reply_to) |a| out.reply_to = try cloneAddress(arena, a);
        out.subject = try arena.dupe(u8, m.subject);
        out.text = try dupeOpt(arena, m.text);
        out.html = try dupeOpt(arena, m.html);
        out.idempotency_key = try dupeOpt(arena, m.idempotency_key);

        const headers = try arena.alloc(http.Header, m.headers.len);
        for (headers, m.headers) |*d, h| d.* = .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) };
        out.headers = headers;

        const attachments = try arena.alloc(Attachment, m.attachments.len);
        for (attachments, m.attachments) |*d, a| d.* = .{
            .filename = try arena.dupe(u8, a.filename),
            .content = try arena.dupe(u8, a.content),
            .content_type = try dupeOpt(arena, a.content_type),
            .content_id = try dupeOpt(arena, a.content_id),
        };
        out.attachments = attachments;
        return out;
    }
};

pub const Sent = struct {
    // The provider's message id, when it returns one.
    id: ?[]const u8 = null,

    pub fn deinit(self: Sent, gpa: std.mem.Allocator) void {
        if (self.id) |id| gpa.free(id);
    }
};

pub fn send(e: Email, gpa: std.mem.Allocator, message: Message) Error!Sent {
    var m = message;
    if (m.from == null) m.from = e.from;
    try m.validate();
    return e.vtable.send(e.userdata, gpa, m);
}

fn hasLineBreak(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") != null;
}

fn dupeOpt(arena: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (s) |v| try arena.dupe(u8, v) else null;
}

fn cloneAddress(arena: std.mem.Allocator, a: Address) std.mem.Allocator.Error!Address {
    return .{ .email = try arena.dupe(u8, a.email), .name = try dupeOpt(arena, a.name) };
}

fn cloneAddresses(arena: std.mem.Allocator, list: []const Address) std.mem.Allocator.Error![]const Address {
    const out = try arena.alloc(Address, list.len);
    for (out, list) |*d, a| d.* = try cloneAddress(arena, a);
    return out;
}

fn failingSend(_: ?*anyopaque, _: std.mem.Allocator, _: Message) Error!Sent {
    return error.Unavailable;
}
