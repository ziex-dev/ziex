//! Picks the install tabs for the visitor's OS. Pages are prerendered, so this
//! runs in the browser from `navigator.userAgent` rather than the request.
const std = @import("std");
const zx = @import("zx");

const web = zx.client.web;
const gpa = zx.allocator;

pub const Os = enum { mac, windows, linux, other };

pub fn fromUserAgent(ua: []const u8) Os {
    if (std.mem.find(u8, ua, "Windows NT") != null) return .windows;
    if (std.mem.find(u8, ua, "Android") != null) return .other;
    if (std.mem.find(u8, ua, "iPhone") != null or std.mem.find(u8, ua, "iPad") != null) return .other;
    if (std.mem.find(u8, ua, "Macintosh") != null or std.mem.find(u8, ua, "Mac OS X") != null) return .mac;
    if (std.mem.find(u8, ua, "Linux") != null) return .linux;
    return .other;
}

// The static HTML checks the unix / macOS tabs; switch to the detected OS.
pub fn setup() void {
    const win = web.window();
    defer win.deinit();
    const nav = win.navigator();
    defer nav.deinit();
    const ua = nav.userAgent(gpa) catch return;
    defer gpa.free(ua);

    switch (fromUserAgent(ua)) {
        .windows => {
            check("tab-windows");
            check("tab-zig-win");
        },
        .linux => check("tab-zig-other"),
        .mac, .other => {},
    }
}

fn check(id: []const u8) void {
    const doc = web.document();
    defer doc.deinit();
    const el = doc.getElementById(id) orelse return;
    defer el.deinit();
    el.as(web.HTMLInputElement).setChecked(true);
}
