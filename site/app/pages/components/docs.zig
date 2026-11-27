//! Docs page behaviour (replaces scripts/docs.ts): copy buttons, copying a
//! section link when its heading is clicked, and highlighting the current
//! section in the sidebars while scrolling.
const std = @import("std");
const zx = @import("zx");
const copy = @import("copy.zig");
const install_os = @import("install_os.zig");

const web = zx.client.web;
const js = zx.client.js;
const gpa = zx.allocator;

var ready = false;

pub fn setup() void {
    if (ready) return;
    ready = true;
    copy.setup();
    const doc = web.document();
    defer doc.deinit();
    doc.addEventListener("click", .fromFn(onClick, .{}), null);
    setupScrollSpy();
    install_os.setup();
}

/// Heading anchors navigate as usual and also put their URL on the clipboard.
fn onClick(args: []const js.Value) void {
    if (args.len == 0) return;
    const ev: web.Event = .{ .h = args[0] };
    const target = ev.target() orelse return;
    defer target.deinit();
    const anchor = target.as(web.Element).closest(".section-anchor") orelse return;
    defer anchor.deinit();
    const href = anchor.as(web.HTMLAnchorElement).href(gpa) catch return;
    defer gpa.free(href);
    const nav = web.window().navigator();
    defer nav.deinit();
    const clipboard = nav.clipboard();
    defer clipboard.deinit();
    clipboard.writeText(href).deinit();
}

// --- Scroll spy ---

const Target = struct { id: []u8, el: web.Element, links: std.ArrayList(web.Element) = .empty };

var targets: std.ArrayList(Target) = .empty;
var nav_links: std.ArrayList(web.Element) = .empty;
var page_links: std.ArrayList(web.Element) = .empty;
var current: ?usize = null;
var scheduled = false;

fn hashOf(link: web.Element) ?[]u8 {
    const href = (link.getAttribute(gpa, "href") catch return null) orelse return null;
    defer gpa.free(href);
    const at = std.mem.findScalar(u8, href, '#') orelse return null;
    if (at + 1 >= href.len) return null;
    return gpa.dupe(u8, href[at + 1 ..]) catch null;
}

fn setupScrollSpy() void {
    const doc = web.document();
    defer doc.deinit();
    const links = doc.querySelectorAll(".sidebar a[href*='#'], .right-sidebar a[href*='#']");
    defer links.deinit();
    for (0..links.length()) |i| {
        const link = (links.item(@intCast(i)) orelse continue).as(web.Element);
        const id = hashOf(link) orelse {
            link.deinit();
            continue;
        };
        nav_links.append(gpa, link) catch return;
        const t = for (targets.items) |*t| {
            if (std.mem.eql(u8, t.id, id)) break t;
        } else blk: {
            const el = doc.getElementById(id) orelse {
                gpa.free(id);
                continue;
            };
            targets.append(gpa, .{ .id = id, .el = el }) catch return;
            break :blk &targets.items[targets.items.len - 1];
        };
        t.links.append(gpa, link) catch {};
    }
    if (nav_links.items.len == 0) return;

    // Links to this page itself (no hash) are active near the top.
    const loc = web.window().location();
    defer loc.deinit();
    const path = loc.pathname(gpa) catch return;
    defer gpa.free(path);
    const all = doc.querySelectorAll(".sidebar a[href]:not(.sidebar-tab)");
    defer all.deinit();
    for (0..all.length()) |i| {
        const link = (all.item(@intCast(i)) orelse continue).as(web.HTMLAnchorElement);
        const link_path = link.pathname(gpa) catch "";
        defer if (link_path.len > 0) gpa.free(link_path);
        const hash = link.hash(gpa) catch "";
        defer if (hash.len > 0) gpa.free(hash);
        if (hash.len == 0 and samePath(link_path, path)) {
            page_links.append(gpa, link.as(web.Element)) catch {};
        } else link.deinit();
    }

    // Document order, so the last section above the fold wins.
    std.mem.sort(Target, targets.items, {}, struct {
        fn less(_: void, a: Target, b: Target) bool {
            return a.el.compareDocumentPosition(b.el) & web.Node.DOCUMENT_POSITION_FOLLOWING != 0;
        }
    }.less);

    const win = web.window();
    win.addEventListener("scroll", .fromFn(onScroll, .{}), .{ .passive = true });
    win.addEventListener("hashchange", .fromFn(onHashChange, .{}), null);
    onHashChange(&.{});
}

fn samePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn onScroll(_: []const js.Value) void {
    if (scheduled) return;
    scheduled = true;
    _ = web.window().requestAnimationFrame(.fromFn(onFrame, .{ .once = true }));
}

fn onFrame(_: []const js.Value) void {
    scheduled = false;
    updateFromScroll();
}

fn onHashChange(_: []const js.Value) void {
    const loc = web.window().location();
    defer loc.deinit();
    const hash = loc.hash(gpa) catch return updateFromScroll();
    defer gpa.free(hash);
    const id = if (hash.len > 1) hash[1..] else return updateFromScroll();
    for (targets.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.id, id)) return setActive(i);
    }
    updateFromScroll();
}

fn updateFromScroll() void {
    const offset = 120;
    var active: ?usize = null;
    for (targets.items, 0..) |t, i| {
        const rect = t.el.getBoundingClientRect();
        defer rect.deinit();
        if (rect.top() - offset <= 0) active = i else break;
    }
    // Near the top, prefer the page's own link (e.g. Quick Start).
    setActive(if (web.window().scrollY() < 48) null else active);
}

fn setActive(next: ?usize) void {
    if (next == current and current != null) return;
    current = next;
    for (nav_links.items) |l| toggle(l, false);
    for (page_links.items) |l| toggle(l, next == null);
    const i = next orelse return;
    for (targets.items[i].links.items) |link| {
        toggle(link, true);
        if (link.closest("details")) |d| {
            d.as(web.HTMLDetailsElement).setOpen(true);
            d.deinit();
        }
    }
}

fn toggle(el: web.Element, on: bool) void {
    const classes = el.classList();
    defer classes.deinit();
    _ = classes.toggle("active", on);
}
