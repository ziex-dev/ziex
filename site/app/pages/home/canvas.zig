//! Animated feature canvases on the home page (`canvas.feature-canvas`).
//! Each scene draws in a fixed design size, scaled to fit, and animates
//! only while at least 20% visible.
const std = @import("std");
const zx = @import("zx");
const data = @import("data.zig");

const web = zx.client.web;
const js = zx.client.js;
const C = web.CanvasRenderingContext2D;
const pi = std.math.pi;

const GREEN = "#4ade80";
const GREEN_LIGHT = "#86efac";
const CYAN = "#7dd3fc";
const AMBER = "#fbbf24";
const ROSE = "#fb7185";
const VIOLET = "#c4b5fd";
const WHITE = "#ffffff";
const TEXT = "rgba(255, 255, 255, 0.86)";
const MUTED = "rgba(255, 255, 255, 0.55)";
const FAINT = "rgba(255, 255, 255, 0.32)";
const LINE = "rgba(255, 255, 255, 0.1)";
const LINE_STRONG = "rgba(255, 255, 255, 0.18)";
const SURFACE_RAISED = "#121212";

const MONO = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace";
const SANS = "system-ui, -apple-system, sans-serif";

// --- Scratch strings ---
// Bindings copy strings synchronously, so a small ring of buffers is enough.

var ring: [32][128]u8 = undefined;
var ring_i: usize = 0;

fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    const b = &ring[ring_i % ring.len];
    ring_i +%= 1;
    return std.fmt.bufPrint(b, f, args) catch b[0..0];
}

/// `#rrggbb` → `rgba(r, g, b, a)`; like the original, non-hex input yields black.
fn withAlpha(hex: []const u8, a: f64) []const u8 {
    const n: u32 = if (hex.len == 7 and hex[0] == '#') std.fmt.parseInt(u32, hex[1..], 16) catch 0 else 0;
    return fmt("rgba({d}, {d}, {d}, {d})", .{ (n >> 16) & 255, (n >> 8) & 255, n & 255, a });
}

// --- Math ---

fn clamp(v: f64) f64 {
    return @min(1, @max(0, v));
}
fn easeOut(p: f64) f64 {
    return 1 - std.math.pow(f64, 1 - clamp(p), 3);
}
fn easeInOut(p: f64) f64 {
    const x = clamp(p);
    return if (x < 0.5) 4 * x * x * x else 1 - std.math.pow(f64, -2 * x + 2, 3) / 2;
}
fn progress(t: f64, start: f64, dur: f64) f64 {
    return clamp((t - start) / dur);
}
/// Fade in at the start of a beat and out before it ends.
fn beatAlpha(local: f64, len: f64, edge: f64) f64 {
    return @min(clamp(local / edge), clamp((len - local) / edge));
}
fn beatIndex(t: f64, beat: f64, n: usize) usize {
    return @as(usize, @intFromFloat(@floor(t / beat))) % n;
}
fn floorUsize(v: f64) usize {
    return @intFromFloat(@max(0, @floor(v)));
}

// --- Primitives ---

fn measure(c: C, s: []const u8) f64 {
    const m = c.measureText(s);
    defer m.deinit();
    return m.width();
}

fn rr(c: C, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const rad = @min(r, w / 2, h / 2);
    c.beginPath();
    c.moveTo(x + rad, y);
    c.arcTo(x + w, y, x + w, y + h, rad);
    c.arcTo(x + w, y + h, x, y + h, rad);
    c.arcTo(x, y + h, x, y, rad);
    c.arcTo(x, y, x + w, y, rad);
    c.closePath();
}

const PanelOpts = struct { r: f64 = 10, fill: []const u8 = SURFACE_RAISED, stroke: []const u8 = LINE, glow: ?[]const u8 = null, glow_blur: f64 = 24 };

fn panel(c: C, x: f64, y: f64, w: f64, h: f64, o: PanelOpts) void {
    c.save();
    if (o.glow) |g| {
        c.setShadowColor(g);
        c.setShadowBlur(o.glow_blur);
    }
    rr(c, x, y, w, h, o.r);
    c.setFillStyle(o.fill);
    c.fill(null);
    c.restore();
    rr(c, x + 0.5, y + 0.5, w - 1, h - 1, o.r);
    c.setStrokeStyle(o.stroke);
    c.setLineWidth(1);
    c.stroke();
}

fn windowChrome(c: C, x: f64, y: f64, w: f64, h: f64, title: []const u8, o: struct { glow: ?[]const u8 = null, stroke: []const u8 = LINE }) void {
    panel(c, x, y, w, h, .{ .r = 10, .glow = o.glow, .stroke = o.stroke });
    c.setStrokeStyle(LINE);
    c.beginPath();
    c.moveTo(x, y + 26.5);
    c.lineTo(x + w, y + 26.5);
    c.stroke();
    for ([_][]const u8{ "#ff5f57", "#febc2e", "#28c840" }, 0..) |col, i| {
        c.setFillStyle(withAlpha(col, 0.75));
        c.beginPath();
        c.arc(x + 14 + @as(f64, @floatFromInt(i)) * 12, y + 13.5, 3.5, 0, pi * 2, null);
        c.fill(null);
    }
    if (title.len > 0) text(c, title, x + w / 2, y + 17, .{ .font = "11px " ++ MONO, .color = FAINT, .alignment = .center });
}

const TextOpts = struct { font: []const u8 = "12px " ++ MONO, color: []const u8 = TEXT, alignment: web.CanvasTextAlign = .left };

fn text(c: C, s: []const u8, x: f64, y: f64, o: TextOpts) void {
    c.setFont(o.font);
    c.setFillStyle(o.color);
    c.setTextAlign(o.alignment);
    c.fillText(s, x, y, null);
    c.setTextAlign(.left);
}

const PillOpts = struct { font: []const u8 = "600 10px " ++ MONO, filled: bool = false, pad_x: f64 = 7, h: f64 = 18, center: bool = false };

fn pill(c: C, s: []const u8, x: f64, y: f64, color: []const u8, o: PillOpts) f64 {
    c.setFont(o.font);
    const w = measure(c, s) + o.pad_x * 2;
    const px = if (o.center) x - w / 2 else x;
    rr(c, px, y, w, o.h, o.h / 2);
    c.setFillStyle(if (o.filled) color else withAlpha(color, 0.12));
    c.fill(null);
    if (!o.filled) {
        c.setStrokeStyle(withAlpha(color, 0.35));
        c.setLineWidth(1);
        c.stroke();
    }
    c.setFillStyle(if (o.filled) "#04140a" else color);
    c.setTextAlign(.center);
    c.fillText(s, px + w / 2, y + o.h / 2 + 3.5, null);
    c.setTextAlign(.left);
    return w;
}

fn glowDot(c: C, x: f64, y: f64, color: []const u8, r: f64) void {
    c.save();
    const g = c.createRadialGradient(x, y, 0, x, y, r * 5);
    defer g.deinit();
    g.addColorStop(0, withAlpha(color, 0.45));
    g.addColorStop(1, withAlpha(color, 0));
    c.setFillStyle(g);
    c.beginPath();
    c.arc(x, y, r * 5, 0, pi * 2, null);
    c.fill(null);
    c.setFillStyle(color);
    c.beginPath();
    c.arc(x, y, r, 0, pi * 2, null);
    c.fill(null);
    c.restore();
}

const Pt = struct { x: f64, y: f64 };

fn bezierPoint(a: Pt, b: Pt, p: f64) Pt {
    const mx = (a.x + b.x) / 2;
    const u = 1 - p;
    return .{
        .x = u * u * u * a.x + 3 * u * u * p * mx + 3 * u * p * p * mx + p * p * p * b.x,
        .y = u * u * u * a.y + 3 * u * u * p * a.y + 3 * u * p * p * b.y + p * p * p * b.y,
    };
}

const StrokeOpts = struct { width: f64 = 1, dash: ?[]const f64 = null, offset: f64 = 0 };

fn dashed(c: C, color: []const u8, o: StrokeOpts) void {
    c.setStrokeStyle(color);
    c.setLineWidth(o.width);
    if (o.dash) |d| {
        c.setLineDash(d);
        c.setLineDashOffset(o.offset);
    }
}

fn curve(c: C, a: Pt, b: Pt, color: []const u8, o: StrokeOpts) void {
    const mx = (a.x + b.x) / 2;
    c.save();
    dashed(c, color, o);
    c.beginPath();
    c.moveTo(a.x, a.y);
    c.bezierCurveTo(mx, a.y, mx, b.y, b.x, b.y);
    c.stroke();
    c.restore();
}

fn line(c: C, a: Pt, b: Pt, color: []const u8, o: StrokeOpts) void {
    c.save();
    dashed(c, color, o);
    c.beginPath();
    c.moveTo(a.x, a.y);
    c.lineTo(b.x, b.y);
    c.stroke();
    c.restore();
}

// --- Code colouring ---

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

const keywords = [_][]const u8{ "pub", "fn", "const", "var", "return", "try", "defer", "if", "else", "for", "while", "switch" };

/// Length and colour of a token at `i`, mirroring the original regex:
/// comment, string, @builtin, tag, keyword, .field, number, Type.
fn token(src: []const u8, i: usize) ?struct { len: usize, color: []const u8 } {
    const rest = src[i..];
    const word_before = i > 0 and isWord(src[i - 1]);
    if (std.mem.startsWith(u8, rest, "//")) return .{ .len = rest.len, .color = FAINT };
    if (rest[0] == '"') {
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (rest[j] == '\\') {
                j += 1;
            } else if (rest[j] == '"') return .{ .len = j + 1, .color = GREEN_LIGHT };
        }
    }
    if (rest[0] == '@' and rest.len > 1 and (std.ascii.isAlphabetic(rest[1]) or rest[1] == '_')) {
        var j: usize = 1;
        while (j < rest.len and (std.ascii.isAlphabetic(rest[j]) or rest[j] == '_')) j += 1;
        return .{ .len = j, .color = AMBER };
    }
    if (rest[0] == '<') {
        var j: usize = 1;
        if (j < rest.len and rest[j] == '/') j += 1;
        if (j < rest.len and std.ascii.isAlphabetic(rest[j])) {
            j += 1;
            while (j < rest.len and (isWord(rest[j]) or rest[j] == '.')) j += 1;
            return .{ .len = j, .color = CYAN };
        }
    }
    if (std.mem.startsWith(u8, rest, "/>")) return .{ .len = 2, .color = CYAN };
    if (rest[0] == '>') return .{ .len = 1, .color = CYAN };
    if (!word_before) for (keywords) |kw| {
        if (std.mem.startsWith(u8, rest, kw) and (rest.len == kw.len or !isWord(rest[kw.len]))) return .{ .len = kw.len, .color = ROSE };
    };
    if (rest[0] == '.') {
        var j: usize = 1;
        while (j < rest.len and (std.ascii.isLower(rest[j]) or rest[j] == '_')) j += 1;
        if (j > 1 and (j == rest.len or !isWord(rest[j]))) return .{ .len = j, .color = VIOLET };
    }
    if (!word_before and std.ascii.isDigit(rest[0])) {
        var j: usize = 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j == rest.len or !isWord(rest[j])) return .{ .len = j, .color = AMBER };
    }
    if (std.ascii.isUpper(rest[0])) {
        var j: usize = 1;
        while (j < rest.len and isWord(rest[j])) j += 1;
        return .{ .len = j, .color = GREEN };
    }
    return null;
}

/// Lightweight Zig/ZX token colouring for single code lines. Returns the end x.
fn codeLine(c: C, src: []const u8, x: f64, y: f64, o: struct { size: f64 = 11.5, dim: bool = false }) f64 {
    c.setFont(fmt("{d}px " ++ MONO, .{o.size}));
    c.setTextAlign(.left);
    var cx = x;
    const put = struct {
        fn f(ctx: C, s: []const u8, color: []const u8, dim: bool, px: *f64, py: f64) void {
            if (s.len == 0) return;
            ctx.setFillStyle(if (dim) withAlpha(if (std.mem.eql(u8, color, TEXT)) "#ffffff" else color, 0.35) else color);
            ctx.fillText(s, px.*, py, null);
            px.* += measure(ctx, s);
        }
    }.f;
    var plain: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (token(src, i)) |tok| {
            put(c, src[plain..i], TEXT, o.dim, &cx, y);
            put(c, src[i..][0..tok.len], tok.color, o.dim, &cx, y);
            i += tok.len;
            plain = i;
        } else i += 1;
    }
    put(c, src[plain..], TEXT, o.dim, &cx, y);
    return cx;
}

fn backdrop(c: C, w: f64, h: f64, accent: []const u8) void {
    c.clearRect(0, 0, w, h);
    const gap: f64 = 22.0;
    c.setFillStyle("rgba(255, 255, 255, 0.055)");
    var y = @rem(h, gap) / 2;
    while (y < h) : (y += gap) {
        var x = @rem(w, gap) / 2;
        while (x < w) : (x += gap) c.fillRect(x, y, 1, 1);
    }
    const g = c.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, @max(w, h) * 0.6);
    defer g.deinit();
    g.addColorStop(0, withAlpha(accent, 0.07));
    g.addColorStop(1, withAlpha(accent, 0));
    c.setFillStyle(g);
    c.fillRect(0, 0, w, h);
    const v = c.createRadialGradient(w / 2, h / 2, @min(w, h) * 0.35, w / 2, h / 2, @max(w, h) * 0.75);
    defer v.deinit();
    v.addColorStop(0, "rgba(10, 10, 10, 0)");
    v.addColorStop(1, "rgba(10, 10, 10, 0.85)");
    c.setFillStyle(v);
    c.fillRect(0, 0, w, h);
}

fn formatCount(v: f64) []const u8 {
    if (v >= 1000) return if (v >= 10000) fmt("{d:.0}k", .{v / 1000}) else fmt("{d:.1}k", .{v / 1000});
    return fmt("{d}", .{@round(v)});
}

// --- Scenes ---

fn drawPerformance(c: C, t: f64) void {
    const bars = data.performance;
    if (bars.len == 0) return;
    const W: f64 = 440.0;
    var max: f64 = 1;
    for (bars) |b| max = @max(max, b.value);
    const label_w: f64 = 78.0;
    const value_w: f64 = 50.0;
    const track_x = label_w;
    const track_w = W - label_w - value_w;
    const row_h: f64 = 44.0;
    const top: f64 = 64.0;

    text(c, "SSR THROUGHPUT", 0, 14, .{ .font = "600 10px " ++ MONO, .color = FAINT });
    text(c, "requests / second", 0, 34, .{ .font = "500 15px " ++ SANS, .color = TEXT });

    const chart_h = @as(f64, @floatFromInt(bars.len)) * row_h;
    for (1..4) |i| {
        const gx = track_x + (track_w * @as(f64, @floatFromInt(i))) / 4 + 0.5;
        line(c, .{ .x = gx, .y = top - 6 }, .{ .x = gx, .y = top + chart_h - 10 }, "rgba(255,255,255,0.05)", .{ .dash = &.{ 2, 4 } });
    }

    for (bars, 0..) |bar, i| {
        const fi: f64 = @floatFromInt(i);
        const y = top + fi * row_h;
        const p = easeOut(progress(t, 0.15 + fi * 0.12, 0.9));
        const bw = @max(6, (bar.value / max) * track_w * p);

        text(c, bar.label, track_x - 14, y + 15, .{
            .font = if (bar.self) "600 13px " ++ SANS else "500 13px " ++ SANS,
            .color = if (bar.self) WHITE else MUTED,
            .alignment = .right,
        });

        rr(c, track_x, y + 4, track_w, 14, 7);
        c.setFillStyle("rgba(255,255,255,0.04)");
        c.fill(null);

        c.save();
        const g = c.createLinearGradient(track_x, 0, track_x + bw, 0);
        defer g.deinit();
        if (bar.self) {
            g.addColorStop(0, "#16a34a");
            g.addColorStop(1, GREEN_LIGHT);
            c.setFillStyle(g);
            c.setShadowColor(withAlpha(GREEN, 0.5));
            c.setShadowBlur(18);
        } else {
            g.addColorStop(0, "rgba(255,255,255,0.12)");
            g.addColorStop(1, "rgba(255,255,255,0.3)");
            c.setFillStyle(g);
        }
        rr(c, track_x, y + 4, bw, 14, 7);
        c.fill(null);
        c.restore();

        if (bar.self and p >= 1) {
            // Periodic shimmer across the leading bar.
            const sp = @rem(t - 1.2, 2.6) / 1.1;
            if (sp > 0 and sp < 1) {
                c.save();
                rr(c, track_x, y + 4, bw, 14, 7);
                c.clip(null);
                const sx = track_x + sp * (bw + 80) - 40;
                const sg = c.createLinearGradient(sx - 40, 0, sx + 40, 0);
                defer sg.deinit();
                sg.addColorStop(0, "rgba(255,255,255,0)");
                sg.addColorStop(0.5, "rgba(255,255,255,0.45)");
                sg.addColorStop(1, "rgba(255,255,255,0)");
                c.setFillStyle(sg);
                c.fillRect(sx - 40, y + 4, 80, 14);
                c.restore();
            }
        }

        const shown = if (p >= 1) bar.display else formatCount(bar.value * p);
        text(c, shown, W, y + 15, .{
            .font = if (bar.self) "600 12px " ++ MONO else "400 12px " ++ MONO,
            .color = if (bar.self) GREEN else MUTED,
            .alignment = .right,
        });
    }

    text(c, "2 CPU · 2 GB RAM · Docker", 0, top + chart_h + 14, .{ .font = "11px " ++ MONO, .color = FAINT });
}

const TreeRow = struct { name: []const u8, depth: usize, dir: bool, scene: ?usize = null };

/// Explorer rows for the routing scenes, directories first as they appear.
const tree_rows = blk: {
    var rows: []const TreeRow = &.{.{ .name = "pages", .depth = 0, .dir = true }};
    var seen: []const []const u8 = &.{};
    for (data.routing, 0..) |s, i| {
        var parts: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, s.file, '/');
        while (it.next()) |p| parts = parts ++ .{p};
        var end: usize = 0;
        for (0..parts.len - 1) |d| {
            end += parts[d].len + @intFromBool(d > 0);
            const key = s.file[0..end];
            const known = for (seen) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (!known) {
                seen = seen ++ .{key};
                rows = rows ++ .{TreeRow{ .name = parts[d], .depth = d + 1, .dir = true }};
            }
        }
        rows = rows ++ .{TreeRow{ .name = parts[parts.len - 1], .depth = parts.len, .dir = false, .scene = i }};
    }
    break :blk rows;
};

fn fileIcon(c: C, x: f64, y: f64, dir: bool, color: []const u8) void {
    c.save();
    c.setStrokeStyle(color);
    c.setLineWidth(1.2);
    c.beginPath();
    if (dir) {
        c.moveTo(x, y + 9);
        c.lineTo(x, y + 1);
        c.lineTo(x + 4, y + 1);
        c.lineTo(x + 5.5, y + 2.5);
        c.lineTo(x + 11, y + 2.5);
        c.lineTo(x + 11, y + 9);
    } else {
        c.moveTo(x + 1, y);
        c.lineTo(x + 7, y);
        c.lineTo(x + 10, y + 3);
        c.lineTo(x + 10, y + 10);
        c.lineTo(x + 1, y + 10);
    }
    c.closePath();
    c.stroke();
    c.restore();
}

fn drawRouting(c: C, t: f64) void {
    const routes = data.routing;
    const BEAT: f64 = 2.6;
    const idx = beatIndex(t, BEAT, routes.len);
    const local = @rem(t, BEAT);
    const scene = routes[idx];

    const tree_x: f64 = 0.0;
    const tree_w: f64 = 176.0;
    const row_h: f64 = 26.0;
    const tree_h = 40 + @as(f64, @floatFromInt(tree_rows.len)) * row_h;
    const tree_y = (340 - tree_h) / 2;
    panel(c, tree_x, tree_y, tree_w, tree_h, .{});
    text(c, "EXPLORER", tree_x + 14, tree_y + 22, .{ .font = "600 9.5px " ++ MONO, .color = FAINT });

    var active_y: f64 = 0;
    for (tree_rows, 0..) |row, i| {
        const y = tree_y + 34 + @as(f64, @floatFromInt(i)) * row_h;
        const on = row.scene != null and row.scene.? == idx;
        const x = tree_x + 14 + (if (row.depth > 0) @as(f64, @floatFromInt(row.depth - 1)) * 14 + 12 else 0);
        if (on) {
            active_y = y + row_h / 2;
            const a = easeOut(progress(local, 0, 0.3));
            rr(c, tree_x + 6, y + 2, tree_w - 12, row_h - 4, 6);
            c.setFillStyle(withAlpha(GREEN, 0.12 * a));
            c.fill(null);
            c.setFillStyle(withAlpha(GREEN, a));
            c.fillRect(tree_x + 6, y + 6, 2, row_h - 12);
        }
        const color = if (on) GREEN else if (row.dir) MUTED else FAINT;
        fileIcon(c, x, y + 8, row.dir, color);
        text(c, if (row.dir) fmt("{s}/", .{row.name}) else row.name, x + 18, y + 17, .{
            .font = if (on) "600 12px " ++ MONO else "400 12px " ++ MONO,
            .color = if (on) WHITE else if (row.dir) MUTED else "rgba(255,255,255,0.45)",
        });
    }

    // Browser preview.
    const bx: f64 = 226.0;
    const bw: f64 = 214.0;
    const bh: f64 = 200.0;
    const by = (340 - bh) / 2;
    windowChrome(c, bx, by, bw, bh, "", .{ .stroke = LINE_STRONG });
    rr(c, bx + 52, by + 6, bw - 62, 15, 7.5);
    c.setFillStyle("rgba(255,255,255,0.05)");
    c.fill(null);
    const typed = scene.url;
    const n_shown: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(typed.len)) * easeOut(progress(local, 0.15, 0.4))));
    const shown = typed[0..@min(typed.len, n_shown)];
    c.setFont("10px " ++ MONO);
    const host = "localhost:3000";
    text(c, host, bx + 60, by + 17, .{ .font = "10px " ++ MONO, .color = FAINT });
    const host_w = measure(c, host);
    const url_path = if (std.mem.startsWith(u8, scene.url, "/")) shown else "";
    text(c, url_path, bx + 60 + host_w, by + 17, .{ .font = "10px " ++ MONO, .color = TEXT });

    c.setGlobalAlpha(beatAlpha(local, BEAT, 0.3));
    const cx = bx + 14;
    const cy = by + 40;
    const cw = bw - 28;
    const kind = scene.kind;
    if (std.mem.eql(u8, kind, "layout")) {
        rr(c, cx, cy, cw, bh - 54, 6);
        c.setLineDash(&[_]f64{ 4, 3 });
        c.setStrokeStyle(withAlpha(GREEN, 0.7));
        c.stroke();
        c.setLineDash(&[_]f64{});
        c.setFillStyle(withAlpha(GREEN, 0.15));
        c.fillRect(cx + 8, cy + 8, cw - 16, 14);
        c.fillRect(cx + 8, cy + bh - 54 - 22, cw - 16, 14);
        rr(c, cx + 8, cy + 30, cw - 16, bh - 54 - 60, 4);
        c.setFillStyle("rgba(255,255,255,0.03)");
        c.fill(null);
        text(c, "{children}", cx + cw / 2, cy + (bh - 54) / 2 + 4, .{ .font = "11px " ++ MONO, .color = FAINT, .alignment = .center });
    } else if (std.mem.eql(u8, kind, "route")) {
        text(c, "{", cx, cy + 16, .{ .font = "12px " ++ MONO, .color = MUTED });
        text(c, "\"status\": \"ok\"", cx + 14, cy + 36, .{ .font = "12px " ++ MONO, .color = GREEN_LIGHT });
        text(c, "}", cx, cy + 56, .{ .font = "12px " ++ MONO, .color = MUTED });
        _ = pill(c, "application/json", cx, cy + 84, CYAN, .{});
    } else if (std.mem.eql(u8, kind, "error")) {
        rr(c, cx, cy, cw, 54, 6);
        c.setFillStyle(withAlpha(ROSE, 0.08));
        c.fill(null);
        c.setStrokeStyle(withAlpha(ROSE, 0.35));
        c.stroke();
        text(c, "Something went wrong", cx + 12, cy + 22, .{ .font = "600 12px " ++ SANS, .color = ROSE });
        text(c, "error.OutOfMemory", cx + 12, cy + 40, .{ .font = "11px " ++ MONO, .color = MUTED });
        c.setFillStyle("rgba(255,255,255,0.06)");
        c.fillRect(cx, cy + 70, cw * 0.7, 8);
        c.fillRect(cx, cy + 86, cw * 0.5, 8);
    } else if (std.mem.eql(u8, kind, "notfound")) {
        text(c, "404", cx + cw / 2, cy + 70, .{ .font = "700 44px " ++ SANS, .color = "rgba(255,255,255,0.9)", .alignment = .center });
        text(c, "Page not found", cx + cw / 2, cy + 96, .{ .font = "12px " ++ SANS, .color = MUTED, .alignment = .center });
    } else {
        c.setFillStyle(withAlpha(GREEN, 0.75));
        c.fillRect(cx, cy + 4, 40, 6);
        const title = if (std.mem.eql(u8, scene.url, "/"))
            "Home"
        else
            fmt("{c}{s}", .{ std.ascii.toUpper(scene.url[1]), scene.url[2..] });
        text(c, title, cx, cy + 36, .{ .font = "700 18px " ++ SANS, .color = WHITE });
        c.setFillStyle("rgba(255,255,255,0.08)");
        for ([_]f64{ 0.95, 0.8, 0.88, 0.6 }, 0..) |f, i| c.fillRect(cx, cy + 52 + @as(f64, @floatFromInt(i)) * 14, cw * f, 6);
    }
    c.setGlobalAlpha(1);

    text(c, scene.note, bx + bw / 2, by + bh + 26, .{ .font = "12px " ++ SANS, .color = MUTED, .alignment = .center });

    const from: Pt = .{ .x = tree_x + tree_w, .y = active_y };
    const to: Pt = .{ .x = bx, .y = by + bh / 2 };
    curve(c, from, to, withAlpha(GREEN, 0.35), .{ .dash = &.{ 3, 4 }, .offset = -t * 20 });
    const pp = easeInOut(progress(local, 0.1, 0.8));
    if (pp > 0 and pp < 1) {
        const pt = bezierPoint(from, to, pp);
        glowDot(c, pt.x, pt.y, GREEN, 2.5);
    }
}

fn methodColor(m: []const u8) []const u8 {
    if (std.mem.eql(u8, m, "POST")) return CYAN;
    if (std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "PATCH")) return AMBER;
    if (std.mem.eql(u8, m, "DELETE")) return ROSE;
    return GREEN;
}

fn drawApiRoutes(c: C, t: f64) void {
    const methods = data.api.methods;
    const BEAT: f64 = 3.2;
    const idx = beatIndex(t, BEAT, methods.len);
    const local = @rem(t, BEAT);
    const req = methods[idx];
    const color = methodColor(req.method);
    const W: f64 = 420.0;
    const fade = beatAlpha(local, BEAT, 0.25);

    // Request bar.
    panel(c, 0, 0, W, 44, .{ .stroke = withAlpha(color, 0.35) });
    c.setGlobalAlpha(fade);
    const mw = pill(c, req.method, 12, 13, color, .{ .h = 18 });
    text(c, req.path, 12 + mw + 10, 26, .{ .font = "13px " ++ MONO, .color = WHITE });
    c.setGlobalAlpha(1);
    text(c, "fetch", W - 14, 26, .{ .font = "11px " ++ MONO, .color = FAINT, .alignment = .right });

    // Route handler file.
    const fy: f64 = 78.0;
    const fh = 30 + @as(f64, @floatFromInt(methods.len)) * 28 + 10;
    windowChrome(c, 0, fy, W, fh, data.api.file, .{});
    for (methods, 0..) |m, i| {
        const y = fy + 36 + @as(f64, @floatFromInt(i)) * 28;
        const on = i == idx;
        const mc = methodColor(m.method);
        if (on) {
            const a = easeOut(progress(local, 0.35, 0.3)) * fade;
            rr(c, 8, y, W - 16, 24, 5);
            c.setFillStyle(withAlpha(mc, 0.1 * a));
            c.fill(null);
            c.setFillStyle(withAlpha(mc, a));
            c.fillRect(8, y + 5, 2, 14);
        }
        c.setFont("12px " ++ MONO);
        var x: f64 = 22;
        const parts = [_]struct { []const u8, []const u8 }{
            .{ "pub fn ", if (on) ROSE else withAlpha(ROSE, 0.4) },
            .{ m.method, if (on) mc else withAlpha(mc, 0.45) },
            .{ data.api.signature, if (on) TEXT else FAINT },
        };
        for (parts) |part| {
            c.setFillStyle(part[1]);
            c.fillText(part[0], x, y + 16, null);
            x += measure(c, part[0]);
        }
    }

    // Connectors with travelling packets.
    const mid_x = W / 2;
    line(c, .{ .x = mid_x, .y = 44 }, .{ .x = mid_x, .y = fy }, LINE_STRONG, .{});
    const req_p = progress(local, 0.05, 0.35);
    if (req_p > 0 and req_p < 1) glowDot(c, mid_x, 44 + req_p * (fy - 44), color, 2.5);

    const ry = fy + fh + 34;
    line(c, .{ .x = mid_x, .y = fy + fh }, .{ .x = mid_x, .y = ry }, LINE_STRONG, .{});
    const res_p = progress(local, 0.8, 0.35);
    if (res_p > 0 and res_p < 1) glowDot(c, mid_x, fy + fh + res_p * 34, GREEN, 2.5);

    // Response.
    panel(c, 0, ry, W, 50, .{});
    c.setGlobalAlpha(easeOut(progress(local, 1.1, 0.3)) * fade);
    const status_color = if (std.mem.startsWith(u8, req.status, "2")) GREEN else ROSE;
    const sw = pill(c, req.status, 12, ry + 16, status_color, .{ .h = 18 });
    if (req.body.len > 0) {
        const chars: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(req.body.len)) * progress(local, 1.25, 0.6)));
        _ = codeLine(c, req.body[0..@min(chars, req.body.len)], 12 + sw + 12, ry + 29, .{ .size = 12 });
    } else {
        text(c, "(empty body)", 12 + sw + 12, ry + 29, .{ .font = "12px " ++ MONO, .color = FAINT });
    }
    c.setGlobalAlpha(1);
    text(c, "response", W - 14, ry + 29, .{ .font = "11px " ++ MONO, .color = FAINT, .alignment = .right });
}

fn node(c: C, label: []const u8, cx: f64, cy: f64, on: bool, color: []const u8, min_w: f64) f64 {
    const font = if (on) "600 12px " ++ MONO else "500 12px " ++ MONO;
    c.setFont(font);
    const w = @max(min_w, measure(c, label) + 26);
    const h: f64 = 30.0;
    panel(c, cx - w / 2, cy - h / 2, w, h, .{
        .r = 8,
        .fill = if (on) withAlpha(color, 0.12) else SURFACE_RAISED,
        .stroke = if (on) withAlpha(color, 0.75) else LINE,
        .glow = if (on) withAlpha(color, 0.45) else null,
        .glow_blur = 20,
    });
    text(c, label, cx, cy + 4, .{ .font = font, .color = if (on) color else MUTED, .alignment = .center });
    return w;
}

fn branchStroke(c: C, on: bool, flow: f64) void {
    c.setStrokeStyle(if (on) withAlpha(GREEN, 0.7) else LINE_STRONG);
    c.setLineWidth(if (on) 1.5 else 1);
    if (on) {
        c.setLineDash(&[_]f64{ 4, 4 });
        c.setLineDashOffset(flow);
    }
}

fn drawControlFlow(c: C, t: f64) void {
    const cf = data.control_flow;
    const tabs = cf.scenes;
    const BEAT: f64 = 3.6;
    const idx = beatIndex(t, BEAT, tabs.len);
    const local = @rem(t, BEAT);
    const kind = tabs[idx].id;
    const W: f64 = 440.0;
    const cx = W / 2;
    const fade = beatAlpha(local, BEAT, 0.3);

    // Tabs.
    c.setFont("600 11px " ++ MONO);
    var tab_w: [tabs.len]f64 = undefined;
    var total_tabs: f64 = 6 * @as(f64, @floatFromInt(tabs.len - 1)) + 8;
    for (tabs, 0..) |s, i| {
        tab_w[i] = measure(c, s.id) + 28;
        total_tabs += tab_w[i];
    }
    var tx = cx - total_tabs / 2;
    rr(c, tx, 0, total_tabs, 30, 15);
    c.setFillStyle("rgba(255,255,255,0.03)");
    c.fill(null);
    c.setStrokeStyle(LINE);
    c.stroke();
    tx += 4;
    for (tabs, 0..) |s, i| {
        const on = i == idx;
        if (on) {
            rr(c, tx, 4, tab_w[i], 22, 11);
            c.setFillStyle(withAlpha(GREEN, 0.15));
            c.fill(null);
        }
        text(c, s.id, tx + tab_w[i] / 2, 19, .{ .font = "600 11px " ++ MONO, .color = if (on) GREEN else FAINT, .alignment = .center });
        tx += tab_w[i] + 6;
    }

    c.setGlobalAlpha(fade);
    const top: f64 = 90.0;
    const flow = -t * 24;

    if (std.mem.eql(u8, kind, "if")) {
        const branch = floorUsize(local / 1.4) % 2 == 0;
        const dy = top + 20;
        c.save();
        c.translate(cx, dy);
        c.rotate(pi / 4.0);
        panel(c, -22, -22, 44, 44, .{ .r = 6, .fill = withAlpha(GREEN, 0.1), .stroke = withAlpha(GREEN, 0.7), .glow = withAlpha(GREEN, 0.35) });
        c.restore();
        text(c, "if", cx, dy + 4, .{ .font = "600 12px " ++ MONO, .color = GREEN, .alignment = .center });

        const arm_y = top + 120;
        for (cf.if_arms, 0..) |label, i| {
            const ax = cx + @as(f64, if (i == 0) -110.0 else 110.0);
            const on = if (i == 0) branch else !branch;
            const from: Pt = .{ .x = cx + @as(f64, if (i == 0) -31.0 else 31.0), .y = dy };
            c.save();
            branchStroke(c, on, flow);
            c.beginPath();
            c.moveTo(from.x, from.y);
            c.lineTo(ax, from.y);
            c.lineTo(ax, arm_y - 15);
            c.stroke();
            c.restore();
            text(c, if (i == 0) "true" else "false", (from.x + ax) / 2, dy - 8, .{ .font = "10px " ++ MONO, .color = if (on) GREEN else FAINT, .alignment = .center });
            _ = node(c, label, ax, arm_y, on, GREEN, 84);
        }
    } else if (std.mem.eql(u8, kind, "for")) {
        const ly = top + 20;
        const r: f64 = 22.0;
        c.save();
        c.setStrokeStyle(withAlpha(GREEN, 0.75));
        c.setLineWidth(1.5);
        c.setShadowColor(withAlpha(GREEN, 0.4));
        c.setShadowBlur(14);
        const spin = t * 2.4;
        c.beginPath();
        c.arc(cx, ly, r, spin, spin + pi * 1.6, null);
        c.stroke();
        c.setFillStyle(GREEN);
        c.beginPath();
        c.arc(cx + @cos(spin + pi * 1.6) * r, ly + @sin(spin + pi * 1.6) * r, 2.5, 0, pi * 2, null);
        c.fill(null);
        c.restore();
        text(c, "for", cx, ly + 4, .{ .font = "600 12px " ++ MONO, .color = GREEN, .alignment = .center });

        const n_rows: usize = @max(1, cf.for_count);
        const row_w: f64 = 220.0;
        const row_h: f64 = 30.0;
        const rows_top = top + 62;
        const active = floorUsize(local * 1.4) % n_rows;
        const built = @min(n_rows, floorUsize(local * 2.2) + 1);
        line(c, .{ .x = cx, .y = ly + r + 2 }, .{ .x = cx, .y = rows_top }, LINE_STRONG, .{ .dash = &.{ 3, 3 }, .offset = flow });
        for (0..n_rows) |i| {
            const fi: f64 = @floatFromInt(i);
            const y = rows_top + fi * (row_h + 8);
            const appear = easeOut(progress(local, fi * 0.45, 0.35));
            if (i >= built and appear <= 0) continue;
            c.setGlobalAlpha(fade * appear);
            const on = i == active;
            const yy = y + (1 - appear) * 8;
            panel(c, cx - row_w / 2, yy, row_w, row_h, .{
                .r = 7,
                .fill = if (on) withAlpha(GREEN, 0.1) else SURFACE_RAISED,
                .stroke = if (on) withAlpha(GREEN, 0.6) else LINE,
            });
            text(c, cf.for_item, cx - row_w / 2 + 14, yy + 19, .{ .font = "12px " ++ MONO, .color = if (on) GREEN else MUTED });
            text(c, fmt("item[{d}]", .{i}), cx + row_w / 2 - 14, yy + 19, .{ .font = "11px " ++ MONO, .color = FAINT, .alignment = .right });
        }
        c.setGlobalAlpha(fade);
    } else {
        const sy = top + 20;
        _ = node(c, cf.switch_title, cx, sy, true, GREEN, 0);
        const arms = cf.switch_arms;
        const active = floorUsize(local / 1.1) % @max(arms.len, 1);
        const arm_y = top + 120;
        const spread: f64 = 130.0;
        for (arms, 0..) |label, i| {
            const ax = cx + (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(arms.len - 1)) / 2) * spread;
            const on = i == active;
            c.save();
            branchStroke(c, on, flow);
            c.beginPath();
            c.moveTo(cx, sy + 15);
            c.bezierCurveTo(cx, sy + 60, ax, arm_y - 60, ax, arm_y - 15);
            c.stroke();
            c.restore();
            _ = node(c, label, ax, arm_y, on, GREEN, 84);
        }
    }

    // Snippet card.
    const snippet = tabs[idx].snippet;
    c.setFont("12px " ++ MONO);
    const sw = @min(W, measure(c, snippet) + 32);
    panel(c, cx - sw / 2, 300, sw, 38, .{ .r = 8 });
    _ = codeLine(c, snippet, cx - sw / 2 + 16, 323, .{ .size = 12 });
    c.setGlobalAlpha(1);
}

fn drawHybrid(c: C, t: f64) void {
    const hy = data.hybrid;
    const BEAT: f64 = 3.0;
    const beat = beatIndex(t, BEAT, 3);
    const local = @rem(t, BEAT);
    const W: f64 = 460.0;

    // Server.
    const sx: f64 = 0.0;
    const sy: f64 = 70.0;
    const sw: f64 = 136.0;
    const sh: f64 = 150.0;
    const server_on = beat == 0;
    panel(c, sx, sy, sw, sh, .{
        .stroke = if (server_on) withAlpha(GREEN, 0.6) else LINE,
        .glow = if (server_on) withAlpha(GREEN, 0.25) else null,
    });
    text(c, "SERVER", sx + 14, sy + 22, .{ .font = "600 9.5px " ++ MONO, .color = if (server_on) GREEN else FAINT });
    for (0..3) |i| {
        const ry = sy + 36 + @as(f64, @floatFromInt(i)) * 18;
        rr(c, sx + 14, ry, sw - 28, 12, 3);
        c.setFillStyle("rgba(255,255,255,0.04)");
        c.fill(null);
        c.setStrokeStyle(LINE);
        c.stroke();
        const blink = server_on and (floorUsize(t * 4) + i) % 3 == 0;
        c.setFillStyle(if (blink) GREEN else withAlpha(GREEN, 0.35));
        c.beginPath();
        c.arc(sx + sw - 22, ry + 6, 2, 0, pi * 2, null);
        c.fill(null);
    }
    for (hy.server_steps, 0..) |s, i| {
        const fi: f64 = @floatFromInt(i);
        const done = if (server_on) local > 0.3 + fi * 0.5 else true;
        text(c, fmt("{s} {s}", .{ if (done) "✓" else "·", s }), sx + 14, sy + 108 + fi * 18, .{
            .font = "11px " ++ MONO,
            .color = if (done) (if (server_on) TEXT else MUTED) else FAINT,
        });
    }

    // Browser.
    const bx: f64 = 196.0;
    const by: f64 = 30.0;
    const bw = W - bx;
    const bh: f64 = 230.0;
    windowChrome(c, bx, by, bw, bh, "localhost:3000", .{ .stroke = if (beat >= 1) withAlpha(CYAN, 0.45) else LINE_STRONG });

    // Wire between server and browser.
    const wy = sy + sh / 2;
    line(c, .{ .x = sx + sw, .y = wy }, .{ .x = bx, .y = wy }, LINE_STRONG, .{});
    if (beat == 0) {
        const p = easeInOut(progress(local, 0.9, 0.9));
        if (p > 0 and p < 1) {
            c.save();
            c.setShadowColor(withAlpha(GREEN, 0.6));
            c.setShadowBlur(14);
            _ = pill(c, "HTML", sx + sw + p * (bx - sx - sw), wy - 9, GREEN, .{ .filled = true, .center = true });
            c.restore();
        }
    } else if (beat == 1) {
        const p = easeInOut(progress(local, 0.1, 0.7));
        if (p > 0 and p < 1) _ = pill(c, "wasm", sx + sw + p * (bx - sx - sw), wy - 9, CYAN, .{ .center = true });
    }

    // Page content.
    const cx = bx + 18;
    const cy = by + 44;
    const cw = bw - 36;
    c.setGlobalAlpha(if (beat == 0) easeOut(progress(local, 1.7, 0.5)) else 1);
    c.setFillStyle("rgba(255,255,255,0.75)");
    c.fillRect(cx, cy, 90, 9);
    c.setFillStyle("rgba(255,255,255,0.09)");
    for ([_]f64{ 0.92, 0.78, 0.85 }, 0..) |f, i| c.fillRect(cx, cy + 22 + @as(f64, @floatFromInt(i)) * 13, cw * f, 6);

    // Island.
    const ix = cx;
    const iy = cy + 72;
    const iw = cw;
    const ih: f64 = 88.0;
    const island_on = beat >= 1;
    const hydrate_p: f64 = if (beat == 1) easeOut(progress(local, 0.8, 0.6)) else if (beat == 2) 1 else 0;
    rr(c, ix, iy, iw, ih, 8);
    c.save();
    c.setLineDash(if (island_on) &[_]f64{} else &[_]f64{ 4, 4 });
    c.setStrokeStyle(if (island_on) withAlpha(CYAN, 0.35 + 0.4 * hydrate_p) else LINE_STRONG);
    c.setLineWidth(if (island_on) 1.25 else 1);
    if (island_on) {
        c.setShadowColor(withAlpha(CYAN, 0.4 * hydrate_p));
        c.setShadowBlur(18);
    }
    c.stroke();
    c.restore();
    c.setFillStyle(withAlpha(CYAN, 0.05 * hydrate_p));
    c.fill(null);
    if (beat == 1) {
        const rp = progress(local, 0.8, 1.2);
        if (rp > 0 and rp < 1) {
            c.save();
            rr(c, ix, iy, iw, ih, 8);
            c.clip(null);
            c.setStrokeStyle(withAlpha(CYAN, 0.5 * (1 - rp)));
            c.setLineWidth(2);
            c.beginPath();
            c.arc(ix + iw / 2, iy + ih / 2, rp * iw * 0.6, 0, pi * 2, null);
            c.stroke();
            c.restore();
        }
    }
    text(c, if (island_on) "client" else "static", ix + iw - 10, iy + 16, .{
        .font = "10px " ++ MONO,
        .color = if (island_on) CYAN else FAINT,
        .alignment = .right,
    });

    // Counter button.
    const clicks: usize = if (beat == 2) @min(3, floorUsize(@max(0, local - 0.6) / 0.6)) else 0;
    const btn_label = fmt("{s}: {d}", .{ hy.button, clicks });
    c.setFont("600 12px " ++ SANS);
    const btn_w = measure(c, btn_label) + 28;
    const btn_x = ix + 14;
    const btn_y = iy + 36;
    const pressed = beat == 2 and local > 0.6 and @rem(local - 0.6, 0.6) < 0.12;
    const press: f64 = if (pressed) 1 else 0;
    rr(c, btn_x, btn_y + press, btn_w, 30, 7);
    c.setFillStyle(if (island_on) withAlpha(CYAN, if (pressed) 0.3 else 0.18) else "rgba(255,255,255,0.06)");
    c.fill(null);
    c.setStrokeStyle(if (island_on) withAlpha(CYAN, 0.6) else LINE);
    c.stroke();
    text(c, btn_label, btn_x + btn_w / 2, btn_y + 20 + press, .{
        .font = "600 12px " ++ SANS,
        .color = if (island_on) CYAN else MUTED,
        .alignment = .center,
    });
    c.setGlobalAlpha(1);

    if (beat == 2) {
        // Cursor glides onto the button, then clicks.
        const mp = easeInOut(progress(local, 0, 0.6));
        const tx = btn_x + btn_w * 0.7;
        const ty = btn_y + 20;
        c.save();
        c.translate(tx + (1 - mp) * 70, ty + (1 - mp) * 40);
        c.setFillStyle(WHITE);
        c.setStrokeStyle("#000");
        c.setLineWidth(1);
        c.beginPath();
        c.moveTo(0, 0);
        c.lineTo(0, 14);
        c.lineTo(3.5, 10.5);
        c.lineTo(6.5, 16);
        c.lineTo(8.5, 15);
        c.lineTo(5.5, 9.5);
        c.lineTo(10, 9.5);
        c.closePath();
        c.fill(null);
        c.stroke();
        c.restore();
    }

    // Footer: hint + caption.
    c.setFont("11.5px " ++ MONO);
    const hw = measure(c, hy.hint) + 28;
    const hint_on = beat >= 1;
    panel(c, (W - hw) / 2, 282, hw, 30, .{ .r = 7, .stroke = if (hint_on) withAlpha(CYAN, 0.4) else LINE });
    c.setGlobalAlpha(if (hint_on) 1 else 0.5);
    _ = codeLine(c, hy.hint, (W - hw) / 2 + 14, 301, .{ .size = 11.5 });
    c.setGlobalAlpha(beatAlpha(local, BEAT, 0.3));
    text(c, hy.captions[beat], W / 2, 338, .{ .font = "12.5px " ++ SANS, .color = MUTED, .alignment = .center });
    c.setGlobalAlpha(1);
}

const Seg = struct { s: []const u8, color: []const u8, weight: []const u8 = "400" };

fn segs(c: C, x0: f64, y: f64, parts: []const Seg) void {
    var x = x0;
    for (parts) |p| {
        c.setFont(fmt("{s} 12px " ++ MONO, .{p.weight}));
        c.setFillStyle(p.color);
        c.fillText(p.s, x, y, null);
        x += measure(c, p.s);
    }
}

fn drawTooling(c: C, t: f64) void {
    const tl = data.tooling;
    const W: f64 = 460.0;
    const CYCLE: f64 = 7.0;
    const local = @rem(t, CYCLE);

    // Editor.
    const eh: f64 = 222.0;
    windowChrome(c, 0, 0, W, eh, "", .{});
    rr(c, 54, 4, 120, 22, 5);
    c.setFillStyle("rgba(255,255,255,0.05)");
    c.fill(null);
    const base = if (std.mem.lastIndexOfScalar(u8, tl.file, '/')) |i| tl.file[i + 1 ..] else tl.file;
    text(c, base, 66, 19, .{ .font = "11px " ++ MONO, .color = TEXT });
    c.setFillStyle(GREEN);
    c.fillRect(54, 24, 120, 1.5);
    text(c, "zx lsp ●", W - 12, 18, .{ .font = "10px " ++ MONO, .color = withAlpha(GREEN, 0.8), .alignment = .right });

    const lh: f64 = 20.0;
    const code_top: f64 = 48.0;
    const type_line: ?usize = for (tl.code, 0..) |l, i| {
        if (std.mem.indexOf(u8, l, "@client") != null) break i;
    } else null;
    const type_at: usize = if (type_line) |i| std.mem.indexOf(u8, tl.code[i], "@client").? else 0;
    const typed: usize = if (type_line != null) floorUsize(clamp((local - 0.4) / 1.0) * 4) else 0;
    const accepted = local > 2.6;

    for (tl.code, 0..) |src, i| {
        const y = code_top + @as(f64, @floatFromInt(i)) * lh;
        const is_type = type_line != null and type_line.? == i;
        text(c, fmt("{d: >2}", .{i + 1}), 12, y, .{ .font = "11px " ++ MONO, .color = if (is_type) MUTED else "rgba(255,255,255,0.2)" });
        if (is_type) {
            rr(c, 34, y - 14, W - 42, 19, 3);
            c.setFillStyle("rgba(255,255,255,0.035)");
            c.fill(null);
        }
        const shown = if (is_type and !accepted) src[0..@min(src.len, type_at + 1 + typed)] else src;
        const end = codeLine(c, shown, 40, y, .{ .size = 11.5 });
        if (is_type and !accepted and floorUsize(t * 2.2) % 2 == 0) {
            c.setFillStyle(WHITE);
            c.fillRect(end + 1, y - 11, 1.5, 14);
        }
        if (is_type and !accepted and local > 1.0) {
            // Completion popup.
            c.setGlobalAlpha(easeOut(progress(local, 1.0, 0.2)));
            const px = @min(end - 20, W - 190);
            const py = y + 8;
            const items = tl.completions;
            panel(c, px, py, 180, @as(f64, @floatFromInt(items.len)) * 22 + 8, .{ .r = 7, .fill = "#181818", .stroke = LINE_STRONG, .glow = "rgba(0,0,0,0.6)", .glow_blur = 20 });
            const sel: usize = if (local > 2.0) 0 else floorUsize((local - 1.0) * 3) % items.len;
            for (items, 0..) |it, j| {
                const iy = py + 4 + @as(f64, @floatFromInt(j)) * 22;
                if (j == sel) {
                    rr(c, px + 4, iy, 172, 22, 4);
                    c.setFillStyle(withAlpha(GREEN, 0.14));
                    c.fill(null);
                }
                rr(c, px + 10, iy + 6, 10, 10, 2);
                c.setFillStyle(withAlpha(if (std.mem.startsWith(u8, it, "@")) AMBER else CYAN, 0.25));
                c.fill(null);
                text(c, it, px + 28, iy + 15, .{ .font = "11.5px " ++ MONO, .color = if (j == sel) WHITE else MUTED });
                if (j == sel) text(c, "attr", px + 168, iy + 15, .{ .font = "10px " ++ MONO, .color = FAINT, .alignment = .right });
            }
            c.setGlobalAlpha(1);
        }
    }

    // Terminal, mirroring `zx dev` output.
    const ty = eh + 14;
    panel(c, 0, ty, W, 112, .{ .fill = "#0d0d0d" });
    text(c, "TERMINAL", 14, ty + 20, .{ .font = "600 9.5px " ++ MONO, .color = FAINT });
    const row = struct {
        fn y(top: f64, i: f64) f64 {
            return top + 44 + i * 18;
        }
    }.y;
    const banner = [_]Seg{ .{ .s = "Ziex", .color = WHITE, .weight = "700" }, .{ .s = " - v" ++ tl.version, .color = FAINT }, .{ .s = " | " ++ tl.url, .color = TEXT } };
    segs(c, 14, row(ty, 0), &.{ .{ .s = "$ ", .color = GREEN }, .{ .s = tl.command, .color = TEXT } });
    segs(c, 14, row(ty, 1), &banner);
    const rebuild_at: f64 = 2.7;
    const restart_at: f64 = 3.3;
    if (local > rebuild_at and local <= restart_at) {
        const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        const f = frames[floorUsize(t * 12) % frames.len];
        segs(c, 14, row(ty, 2), &.{ .{ .s = fmt("{s} ", .{f}), .color = CYAN }, .{ .s = "Rebuilding...", .color = CYAN, .weight = "700" } });
    } else if (local > restart_at) {
        c.setGlobalAlpha(easeOut(progress(local, restart_at, 0.2)));
        segs(c, 14, row(ty, 2), &.{ .{ .s = "╭─", .color = FAINT }, .{ .s = "[", .color = FAINT }, .{ .s = "App Logs", .color = VIOLET }, .{ .s = "]", .color = FAINT }, .{ .s = " ↻ " ++ tl.restart_time, .color = FAINT } });
        segs(c, 14, row(ty, 3), &banner);
        c.setGlobalAlpha(1);
    }
}

fn artifactColor(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "wasi")) return CYAN;
    if (std.mem.eql(u8, id, "static")) return AMBER;
    return GREEN;
}

fn drawDeploy(c: C, t: f64) void {
    const targets = data.deploy;
    const artifacts = data.deploy_artifacts;
    const BEAT: f64 = 2.8;
    const ai = beatIndex(t, BEAT, artifacts.len);
    const local = @rem(t, BEAT);
    const active = artifacts[ai];
    const H: f64 = 330.0;

    // Source.
    const src_w: f64 = 160.0;
    const src_h: f64 = 56.0;
    const src_y = H / 2 - src_h / 2 - 14;
    const src_color = artifactColor(active.id);
    panel(c, 0, src_y, src_w, src_h, .{ .stroke = withAlpha(src_color, 0.4), .glow = withAlpha(src_color, 0.15) });
    c.setGlobalAlpha(beatAlpha(local, BEAT, 0.2));
    segs(c, 14, src_y + 24, &.{ .{ .s = "$ ", .color = src_color }, .{ .s = active.command, .color = WHITE, .weight = "600" } });
    text(c, active.flag, 14, src_y + 42, .{ .font = "11px " ++ MONO, .color = MUTED });
    c.setGlobalAlpha(1);

    // Artifacts.
    const art_x: f64 = 194.0;
    const art_w: f64 = 112.0;
    const art_h: f64 = 40.0;
    const art_gap: f64 = 22.0;
    const n_art: f64 = @floatFromInt(artifacts.len);
    const art_top = H / 2 - 14 - (n_art * art_h + (n_art - 1) * art_gap) / 2;
    const artY = struct {
        fn f(top: f64, i: usize) f64 {
            return top + @as(f64, @floatFromInt(i)) * (40.0 + 22.0);
        }
    }.f;

    // Targets.
    const tg_x: f64 = 328.0;
    const tg_w: f64 = 132.0;
    const tg_h: f64 = 28.0;
    const tg_gap: f64 = 8.0;
    const n_tg: f64 = @floatFromInt(targets.len);
    const tg_top = H / 2 - 14 - (n_tg * tg_h + (n_tg - 1) * tg_gap) / 2;

    for (artifacts, 0..) |a, i| {
        const on = std.mem.eql(u8, a.id, active.id);
        const col = artifactColor(a.id);
        const from: Pt = .{ .x = src_w, .y = src_y + src_h / 2 };
        const to: Pt = .{ .x = art_x, .y = artY(art_top, i) + art_h / 2 };
        curve(c, from, to, if (on) withAlpha(col, 0.7) else LINE, .{ .width = if (on) 1.5 else 1, .dash = if (on) &.{ 4, 4 } else null, .offset = -t * 24 });
        if (on) {
            const p = easeInOut(progress(local, 0, 0.6));
            if (p > 0 and p < 1) {
                const pt = bezierPoint(from, to, p);
                glowDot(c, pt.x, pt.y, col, 2.5);
            }
        }
    }

    for (targets, 0..) |tg, i| {
        const fi: f64 = @floatFromInt(i);
        const y = tg_top + fi * (tg_h + tg_gap);
        const on = std.mem.eql(u8, tg.artifact, active.id);
        const col = artifactColor(tg.artifact);
        const ap: ?usize = for (artifacts, 0..) |a, j| {
            if (std.mem.eql(u8, a.id, tg.artifact)) break j;
        } else null;
        if (ap) |j| {
            const from: Pt = .{ .x = art_x + art_w, .y = artY(art_top, j) + art_h / 2 };
            const to: Pt = .{ .x = tg_x, .y = y + tg_h / 2 };
            curve(c, from, to, if (on) withAlpha(col, 0.6) else "rgba(255,255,255,0.06)", .{ .width = if (on) 1.25 else 1 });
            if (on) {
                const p = easeInOut(progress(local, 0.55 + fi * 0.04, 0.7));
                if (p > 0 and p < 1) {
                    const pt = bezierPoint(from, to, p);
                    glowDot(c, pt.x, pt.y, col, 2);
                }
            }
        }
        const lit = if (on) easeOut(progress(local, 1.1, 0.3)) else 0;
        panel(c, tg_x, y, tg_w, tg_h, .{
            .r = 7,
            .fill = if (lit > 0) withAlpha(col, 0.08 * lit) else SURFACE_RAISED,
            .stroke = if (on) withAlpha(col, 0.25 + 0.4 * lit) else LINE,
        });
        c.setFillStyle(if (on) col else "rgba(255,255,255,0.2)");
        c.beginPath();
        c.arc(tg_x + 13, y + tg_h / 2, 3, 0, pi * 2, null);
        c.fill(null);
        text(c, tg.name, tg_x + 24, y + 18, .{ .font = if (on) "600 12px " ++ SANS else "500 12px " ++ SANS, .color = if (on) WHITE else MUTED });
    }

    for (artifacts, 0..) |a, i| {
        const on = std.mem.eql(u8, a.id, active.id);
        const col = artifactColor(a.id);
        const y = artY(art_top, i);
        panel(c, art_x, y, art_w, art_h, .{
            .r = 8,
            .fill = if (on) withAlpha(col, 0.1) else SURFACE_RAISED,
            .stroke = if (on) withAlpha(col, 0.7) else LINE,
            .glow = if (on) withAlpha(col, 0.35) else null,
            .glow_blur = 18,
        });
        text(c, a.label, art_x + art_w / 2, y + 25, .{ .font = "600 12px " ++ MONO, .color = if (on) col else MUTED, .alignment = .center });
    }

    c.setGlobalAlpha(beatAlpha(local, BEAT, 0.3));
    text(c, active.caption, 230, H - 2, .{ .font = "12.5px " ++ SANS, .color = MUTED, .alignment = .center });
    c.setGlobalAlpha(1);
}

fn drawMemory(c: C, t: f64) void {
    const mem = data.memory;
    const W: f64 = 440.0;
    const CYCLE: f64 = 6.4;
    const local = @rem(t, CYCLE);
    const allocs = mem.allocs;
    const cap: f64 = mem.capacity;

    // Phase timeline: init, allocations, render, deinit.
    const alloc_start: f64 = 0.6;
    const alloc_step: f64 = 0.7;
    const deinit_at = alloc_start + @as(f64, @floatFromInt(allocs.len)) * alloc_step + 0.9;
    const freed = local > deinit_at;
    var allocated: usize = 0;
    for (0..allocs.len) |i| {
        if (local > alloc_start + @as(f64, @floatFromInt(i)) * alloc_step) allocated += 1;
    }

    var active_line: usize = 0;
    if (freed) {
        active_line = mem.code.len - 1;
    } else if (allocated > 0) active_line = @min(mem.code.len - 2, allocated);

    // Code panel.
    const lh: f64 = 22.0;
    const ch = 40 + @as(f64, @floatFromInt(mem.code.len)) * lh;
    windowChrome(c, 0, 0, W, ch, mem.file, .{});
    for (mem.code, 0..) |src, i| {
        const y = 50 + @as(f64, @floatFromInt(i)) * lh;
        const on = i == active_line;
        if (on) {
            rr(c, 8, y - 15, W - 16, 21, 4);
            c.setFillStyle(withAlpha(if (freed) ROSE else GREEN, 0.1));
            c.fill(null);
            c.setFillStyle(if (freed) ROSE else GREEN);
            c.fillRect(8, y - 11, 2, 13);
        }
        _ = codeLine(c, src, 20, y, .{ .size = 11, .dim = !on });
    }

    // Arena strip.
    const sy = ch + 36;
    const sh: f64 = 40.0;
    text(c, "CTX.ARENA · PER REQUEST", 0, sy - 10, .{ .font = "600 9.5px " ++ MONO, .color = FAINT });
    panel(c, 0, sy, W, sh, .{ .r = 8, .fill = "#0e0e0e" });
    const inner = W - 12;
    var x: f64 = 6;
    var used: f64 = 0;
    const colors = [_][]const u8{ GREEN, CYAN, VIOLET, AMBER };
    for (allocs, 0..) |a, i| {
        const size: f64 = @floatFromInt(a.size);
        const w = (size / cap) * inner;
        const appear = easeOut(progress(local, alloc_start + @as(f64, @floatFromInt(i)) * alloc_step, 0.35));
        const gone = if (freed) 1 - easeOut(progress(local, deinit_at, 0.4)) else 1;
        const vis = appear * gone;
        if (vis > 0) {
            const col = colors[i % colors.len];
            c.setGlobalAlpha(vis);
            rr(c, x, sy + 6, @max(2, (w - 3) * appear), sh - 12, 5);
            c.setFillStyle(withAlpha(col, 0.22));
            c.fill(null);
            c.setStrokeStyle(withAlpha(col, 0.7));
            c.stroke();
            if (appear > 0.6) {
                c.setFont("600 11px " ++ MONO);
                const roomy = w > measure(c, a.label) + 52;
                text(c, a.label, if (roomy) x + 8 else x + w / 2 - 1.5, sy + 24, .{
                    .font = "600 11px " ++ MONO,
                    .color = col,
                    .alignment = if (roomy) .left else .center,
                });
                if (roomy) text(c, fmt("{d}B", .{a.size}), x + w - 9, sy + 24, .{ .font = "10px " ++ MONO, .color = withAlpha(col, 0.7), .alignment = .right });
            }
            c.setGlobalAlpha(1);
            used += size * vis;
        }
        x += w;
    }
    if (freed) {
        const fp = progress(local, deinit_at, 0.6);
        if (fp < 1) {
            c.save();
            c.setGlobalAlpha(1 - fp);
            c.setStrokeStyle(ROSE);
            c.setLineWidth(1.5);
            rr(c, 0.5, sy + 0.5, W - 1, sh - 1, 8);
            c.stroke();
            c.restore();
        }
    }

    // Usage meter.
    const my = sy + sh + 32;
    text(c, fmt("{d} / {d} B", .{ @round(used), mem.capacity }), 0, my, .{ .font = "12px " ++ MONO, .color = TEXT });
    text(c, if (freed) "response sent, arena reset" else if (allocated > 0) "no hidden allocations" else "request started", W, my, .{
        .font = "12px " ++ SANS,
        .color = if (freed) ROSE else MUTED,
        .alignment = .right,
    });
    rr(c, 0, my + 12, W, 4, 2);
    c.setFillStyle("rgba(255,255,255,0.06)");
    c.fill(null);
    rr(c, 0, my + 12, @max(0, (used / cap) * W), 4, 2);
    c.setFillStyle(GREEN);
    c.fill(null);
}

// --- Driver ---

const Scene = struct { id: []const u8, w: f64, h: f64, accent: []const u8 = GREEN, draw: *const fn (C, f64) void };

const scenes = [_]Scene{
    .{ .id = "performance", .w = 440, .h = 330, .draw = drawPerformance },
    .{ .id = "routing", .w = 440, .h = 340, .draw = drawRouting },
    .{ .id = "api-routes", .w = 420, .h = 300, .draw = drawApiRoutes },
    .{ .id = "control-flow", .w = 440, .h = 340, .draw = drawControlFlow },
    .{ .id = "hybrid", .w = 460, .h = 345, .accent = CYAN, .draw = drawHybrid },
    .{ .id = "tooling", .w = 460, .h = 348, .draw = drawTooling },
    .{ .id = "deploy", .w = 460, .h = 335, .accent = CYAN, .draw = drawDeploy },
    .{ .id = "memory", .w = 440, .h = 310, .draw = drawMemory },
};

const Canvas = struct {
    el: web.HTMLCanvasElement,
    c: C,
    scene: *const Scene,
    visible: bool = false,
    running: bool = false,
    raf: u32 = 0,
    start: f64 = 0,
};

var canvases: [scenes.len]Canvas = undefined;
var count: usize = 0;
var perf: web.Performance = undefined;
var reduced = false;
// Reduced motion gets a representative still frame instead of t=0.
var still: f64 = 0;

fn now() f64 {
    return perf.now();
}

fn drawOnce(cv: *Canvas, t: f64) void {
    const c = cv.c;
    const rect = cv.el.getBoundingClientRect();
    defer rect.deinit();
    const w = rect.width();
    const h = rect.height();
    const dpr = @min(web.window().devicePixelRatio(), 2.5);
    const cw: u32 = @intFromFloat(@max(1, @round(w * dpr)));
    const ch: u32 = @intFromFloat(@max(1, @round(h * dpr)));
    if (cv.el.width() != cw or cv.el.height() != ch) {
        cv.el.setWidth(cw);
        cv.el.setHeight(ch);
    }
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    backdrop(c, w, h, cv.scene.accent);
    const pad = @min(36, w * 0.06);
    const s = @min((w - pad * 2) / cv.scene.w, (h - pad * 2) / cv.scene.h, 1.2);
    c.save();
    c.translate((w - cv.scene.w * s) / 2, (h - cv.scene.h * s) / 2);
    c.scale(s, s);
    c.setTextBaseline(.alphabetic);
    // rAF timestamps can precede the recorded start, giving a negative t.
    cv.scene.draw(c, @max(0, t));
    c.restore();
}

fn tick(cv: *Canvas, args: []const js.Value) void {
    if (!cv.running or !cv.visible) {
        cv.running = false;
        return;
    }
    const ts = if (args.len > 0) args[0].float() catch now() else now();
    drawOnce(cv, (ts - cv.start) / 1000);
    cv.raf = web.window().requestAnimationFrame(.bind(cv, tick, .{ .once = true }));
}

fn play(cv: *Canvas) void {
    if (cv.running or reduced) return;
    cv.running = true;
    cv.start = now();
    cv.raf = web.window().requestAnimationFrame(.bind(cv, tick, .{ .once = true }));
}

fn pause(cv: *Canvas) void {
    cv.running = false;
    if (cv.raf != 0) web.window().cancelAnimationFrame(cv.raf);
    cv.raf = 0;
}

fn redrawAll(_: []const js.Value) void {
    for (canvases[0..count]) |*cv| {
        drawOnce(cv, if (reduced) still else if (cv.start != 0) (now() - cv.start) / 1000 else 0);
    }
}

fn find(target: web.Element) ?*Canvas {
    for (canvases[0..count]) |*cv| {
        if (cv.el.isSameNode(target)) return cv;
    }
    return null;
}

fn intersect(args: []const js.Value) void {
    if (args.len == 0) return;
    const entries = args[0];
    for (0..entries.len()) |i| {
        const entry: web.IntersectionObserverEntry = .{ .h = entries.at(i) };
        defer entry.deinit();
        const target = entry.target();
        defer target.deinit();
        const cv = find(target) orelse continue;
        cv.visible = entry.isIntersecting() and entry.intersectionRatio() > 0.2;
        if (cv.visible) play(cv) else pause(cv);
    }
}

pub fn setup() void {
    const doc = web.document();
    defer doc.deinit();
    const list = doc.querySelectorAll(".feature-canvas");
    defer list.deinit();

    perf = web.window().performance();
    const mq = web.window().matchMedia("(prefers-reduced-motion: reduce)");
    defer mq.deinit();
    reduced = mq.matches();
    still = if (reduced) 2.4 else 0;

    for (0..list.length()) |i| {
        const n = list.item(@intCast(i)) orelse continue;
        const el = n.as(web.HTMLCanvasElement);
        const id = el.getAttribute(zx.allocator, "data-feature") catch null orelse {
            n.deinit();
            continue;
        };
        defer zx.allocator.free(id);
        const scene = for (&scenes) |*s| {
            if (std.mem.eql(u8, s.id, id)) break s;
        } else {
            n.deinit();
            continue;
        };
        const c = web.context2d(el) orelse {
            n.deinit();
            continue;
        };
        if (count == canvases.len) break;
        canvases[count] = .{ .el = el, .c = c, .scene = scene };
        drawOnce(&canvases[count], still);
        count += 1;
    }
    if (count == 0) return;

    web.window().addEventListener("resize", .fromFn(redrawAll, .{}), null);
    if (reduced) return;

    const io = web.IntersectionObserver.new(.fromFn(intersect, .{}), .{ .threshold = &[_]f64{ 0, 0.2, 0.5 } });
    for (canvases[0..count]) |cv| io.observe(cv.el);
}
