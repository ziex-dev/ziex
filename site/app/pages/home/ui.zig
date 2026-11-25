//! Home page controls: open-in-playground buttons and the feature nav.
//! One delegated click listener handles both; copy buttons live in copy.zig.
const std = @import("std");
const zx = @import("zx");

const web = zx.client.web;
const js = zx.client.js;
const gpa = zx.allocator;
const copy = @import("../components/copy.zig");

pub fn setup() void {
    copy.setup();
    setupFeatureNav();
    const doc = web.document();
    defer doc.deinit();
    doc.addEventListener("click", .fromFn(onClick, .{}), null);
}

fn onClick(args: []const js.Value) void {
    if (args.len == 0) return;
    const ev: web.Event = .{ .h = args[0] };
    const target = ev.target() orelse return;
    defer target.deinit();
    const el = target.as(web.Element);

    if (el.closest(".code-example-open-playground")) |button| {
        defer button.deinit();
        ev.preventDefault();
        openPlayground(button);
    } else if (el.closest(".features-nav-btn")) |button| {
        defer button.deinit();
        scrollToFeature(button);
    }
}

fn attr(el: web.Element, name: []const u8) ?[]u8 {
    const v = (el.getAttribute(gpa, name) catch return null) orelse return null;
    if (v.len == 0) {
        gpa.free(v);
        return null;
    }
    return v;
}

// --- Open in playground ---

/// The link is rendered server-side: on the button, or per tab panel.
fn openPlayground(button: web.Element) void {
    const url = attr(button, "data-playground-url") orelse blk: {
        const container = button.closest(".code-example, .code-preview-example") orelse return;
        defer container.deinit();
        const panel = visiblePanel(container) orelse return;
        defer panel.deinit();
        break :blk attr(panel, "data-playground-url") orelse return;
    };
    defer gpa.free(url);
    web.window().open(url, "_blank", "noopener,noreferrer").deinit();
}

/// The panel for the checked tab radio, else the first.
fn visiblePanel(container: web.Element) ?web.Element {
    const tab_panels = container.querySelectorAll(".code-example-panel");
    defer tab_panels.deinit();
    const radios = container.querySelectorAll(".code-example-tab-radio");
    defer radios.deinit();
    var index: u32 = 0;
    for (0..radios.length()) |i| {
        const r = radios.item(@intCast(i)) orelse continue;
        defer r.deinit();
        if (r.as(web.HTMLInputElement).checked()) index = @intCast(i);
    }
    const n = tab_panels.item(if (index < tab_panels.length()) index else 0) orelse return null;
    return n.as(web.Element);
}

// --- Feature nav ---

var panels: [16]web.Element = undefined;
var items: [16]web.Element = undefined;
var ratios: [16]f64 = @splat(0);
var n_panels: usize = 0;
var n_items: usize = 0;
var active: ?usize = null;

fn setupFeatureNav() void {
    const doc = web.document();
    defer doc.deinit();
    const stack = doc.querySelector(".features-stack") orelse return;
    defer stack.deinit();
    collect(stack, ".feature-panel", &panels, &n_panels);
    collect(stack, ".features-nav-item", &items, &n_items);
    if (n_panels == 0) return;
    setActive(0);

    const thresholds = comptime blk: {
        var t: [21]f64 = undefined;
        for (&t, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i)) / 20;
        break :blk t;
    };
    const io = web.IntersectionObserver.new(.fromFn(onIntersect, .{}), .{
        .threshold = &thresholds,
        .rootMargin = "-30% 0px -40% 0px",
    });
    for (panels[0..n_panels]) |p| io.observe(p);
}

fn collect(root: web.Element, selector: []const u8, out: []web.Element, n: *usize) void {
    const list = root.querySelectorAll(selector);
    defer list.deinit();
    for (0..@min(list.length(), out.len)) |i| {
        const node = list.item(@intCast(i)) orelse continue;
        out[n.*] = node.as(web.Element);
        n.* += 1;
    }
}

fn setActive(index: usize) void {
    if (active == index) return;
    active = index;
    for (items[0..n_items], 0..) |item, i| {
        const on = i == index;
        const classes = item.classList();
        defer classes.deinit();
        _ = classes.toggle("is-active", on);
        const btn = item.querySelector(".features-nav-btn") orelse continue;
        defer btn.deinit();
        if (on) btn.setAttribute("aria-current", "true") else btn.removeAttribute("aria-current");
    }
}

fn onIntersect(args: []const js.Value) void {
    if (args.len == 0) return;
    const entries = args[0];
    for (0..entries.len()) |i| {
        const entry: web.IntersectionObserverEntry = .{ .h = entries.at(i) };
        defer entry.deinit();
        const target = entry.target();
        defer target.deinit();
        for (panels[0..n_panels], 0..) |p, j| {
            if (p.isSameNode(target)) ratios[j] = if (entry.isIntersecting()) entry.intersectionRatio() else 0;
        }
    }
    var best: usize = 0;
    var best_ratio: f64 = -1;
    for (ratios[0..n_panels], 0..) |r, j| {
        if (r > best_ratio) {
            best_ratio = r;
            best = j;
        }
    }
    if (best_ratio > 0) setActive(best);
}

fn scrollToFeature(button: web.Element) void {
    const id = attr(button, "data-feature-target") orelse return;
    defer gpa.free(id);
    const doc = web.document();
    defer doc.deinit();
    const el = doc.getElementById(id) orelse return;
    defer el.deinit();
    el.scrollIntoView(.{ .behavior = "smooth", .block = "center" }).deinit();
}
