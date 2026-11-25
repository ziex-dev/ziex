//! Home page mascots, ported from the branding repo's runner.js and
//! ziggy-crawler.js: Ziguana runners dash across sections and flee when
//! clicked (with a Web Audio sound); Ziggy patrols the code windows.
const std = @import("std");
const zx = @import("zx");

const web = zx.client.web;
const js = zx.client.js;
const gpa = zx.allocator;

var perf: web.Performance = undefined;
var prng: std.Random.DefaultPrng = .init(0);

fn now() f64 {
    return perf.now();
}

fn random() f64 {
    return prng.random().float(f64);
}

fn randRange(a: f64, b: f64) f64 {
    return a + random() * (b - a);
}

fn style(el: anytype, name: []const u8, value: []const u8) void {
    const s = el.as(web.HTMLElement).style();
    defer s.deinit();
    s.setProperty(name, value, null);
}

fn computed(el: anytype, prop: []const u8, buf: []u8) []const u8 {
    const cs = web.window().getComputedStyle(el, null);
    defer cs.deinit();
    const v = cs.getPropertyValue(gpa, prop) catch return "";
    defer gpa.free(v);
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    return buf[0..n];
}

fn classes(el: anytype) web.DOMTokenList {
    return el.as(web.Element).classList();
}

pub fn setup() void {
    perf = web.window().performance();
    prng = .init(@bitCast(now() * 1000));
    setupRunners();
    setupZiggy();
}

// --- Runners ---

const mascot_src = "/assets/mascot.svg";
const slow_px_per_sec = 55.0;
const flee_px_per_sec = 420.0;
const runner_width = 72.0;

const Sound = enum { aa, boing, honk, laser, bubble, bonk, squeak, slide };
const Persona = struct { idle: []const u8, clicked: []const u8, sound: Sound, fx: []const u8 };

const personas = [_]Persona{
    .{ .idle = "catch me!", .clicked = "oops!", .sound = .aa, .fx = "fx-shake" },
    .{ .idle = "too slow!", .clicked = "ouch!", .sound = .boing, .fx = "fx-squish" },
    .{ .idle = "betcha can't", .clicked = "rude!", .sound = .honk, .fx = "fx-spin" },
    .{ .idle = "zoom zoom", .clicked = "yikes!", .sound = .laser, .fx = "fx-flash" },
    .{ .idle = "hi there 👋", .clicked = "byeee", .sound = .bubble, .fx = "fx-squish" },
    .{ .idle = "not it!", .clicked = "tagged!", .sound = .bonk, .fx = "fx-shake" },
    .{ .idle = "I'm fast", .clicked = "hey!", .sound = .squeak, .fx = "fx-spin" },
    .{ .idle = "skrrt", .clicked = "wahhh", .sound = .slide, .fx = "fx-flash" },
};
var persona_idx: usize = 0;

fn nextPersona() Persona {
    defer persona_idx += 1;
    return personas[persona_idx % personas.len];
}

const Runner = struct {
    wrap: web.Element,
    mascot: web.Element,
    bubble: ?web.Element,
    persona: Persona,
    x: f64 = -runner_width,
    dir: f64 = 1,
    paused: bool = false,
    flee_until: f64 = 0,
    next_pause_at: f64,
    resume_at: f64 = 0,
    last: f64,
    bubble_reset_at: f64 = 0,
    fast: ?bool = null,
};

var runners: [8]Runner = undefined;
var n_runners: usize = 0;

fn setupRunners() void {
    const doc = web.document();
    defer doc.deinit();

    const wraps = doc.querySelectorAll(".footer-runner .footer-runner-wrap");
    defer wraps.deinit();
    for (0..wraps.length()) |i| {
        const w = wraps.item(@intCast(i)) orelse continue;
        attachRunner(w.as(web.Element), nextPersona());
    }

    const sections = doc.querySelectorAll(".performance, .deployment, .feature-examples, .benchmarks");
    defer sections.deinit();
    for (0..sections.length()) |i| {
        const n = sections.item(@intCast(i)) orelse continue;
        defer n.deinit();
        const section = n.as(web.Element);
        if (section.querySelector(":scope > .section-runner")) |existing| {
            existing.deinit();
            continue;
        }
        var buf: [32]u8 = undefined;
        if (std.mem.eql(u8, computed(section, "position", &buf), "static")) style(section, "position", "relative");
        const persona = nextPersona();
        const host = doc.createElement("div", null);
        defer host.deinit();
        host.setClassName("footer-runner section-runner");
        host.setInnerHTML(
            \\<div class="footer-runner-wrap"><div class="footer-runner-bubble"></div><img class="footer-runner-mascot" alt="Running Ziguana" /></div>
        );
        if (host.querySelector(".footer-runner-bubble")) |b| {
            b.setTextContent(persona.idle);
            b.deinit();
        }
        if (host.querySelector(".footer-runner-mascot")) |m| {
            m.setAttribute("src", mascot_src);
            m.deinit();
        }
        section.prepend(.{host});
        const wrap = host.querySelector(".footer-runner-wrap") orelse continue;
        attachRunner(wrap, persona);
    }
}

fn attachRunner(wrap: web.Element, persona: Persona) void {
    if (n_runners == runners.len) return;
    const mascot = wrap.querySelector(".footer-runner-mascot") orelse return;
    const r = &runners[n_runners];
    n_runners += 1;
    const t = now();
    r.* = .{
        .wrap = wrap,
        .mascot = mascot,
        .bubble = wrap.querySelector(".footer-runner-bubble"),
        .persona = persona,
        .next_pause_at = t + randRange(1800, 3200),
        .last = t,
    };
    if (r.bubble) |b| b.setTextContent(persona.idle);
    setBob(r, false);
    mascot.addEventListener("click", .bind(r, onRunnerClick, .{}), null);
    _ = web.window().requestAnimationFrame(.bind(r, runnerFrame, .{ .once = true }));
}

fn setBob(r: *Runner, fast: bool) void {
    if (r.fast == fast) return;
    r.fast = fast;
    style(r.mascot, "--runner-bob", if (fast) "0.14s" else "0.42s");
}

fn runnerFrame(r: *Runner, args: []const js.Value) void {
    const t = if (args.len > 0) args[0].float() catch now() else now();
    const dt = @min(50, t - r.last) / 1000;
    r.last = t;

    if (r.paused) {
        if (t >= r.resume_at) {
            r.paused = false;
            removeClass(r.wrap, "is-paused");
            r.next_pause_at = t + randRange(2000, 3500);
        }
    } else {
        const fleeing = t < r.flee_until;
        setBob(r, fleeing);
        r.x += r.dir * @as(f64, if (fleeing) flee_px_per_sec else slow_px_per_sec) * dt;
        const parent_w: f64 = if (r.wrap.parentElement()) |p| blk: {
            defer p.deinit();
            break :blk @floatFromInt(p.clientWidth());
        } else 0;
        const max_x = @max(0, parent_w - runner_width);
        if (r.dir == 1 and r.x > max_x) {
            r.x = max_x;
            r.dir = -1;
            addClass(r.wrap, "is-flipped");
        } else if (r.dir == -1 and r.x < -runner_width) {
            r.x = -runner_width;
            r.dir = 1;
            removeClass(r.wrap, "is-flipped");
        }
        var buf: [48]u8 = undefined;
        style(r.wrap, "transform", std.fmt.bufPrint(&buf, "translateX({d:.1}px)", .{r.x}) catch "");

        if (!fleeing and t >= r.next_pause_at) {
            r.paused = true;
            addClass(r.wrap, "is-paused");
            r.resume_at = t + randRange(900, 1500);
        }
    }

    if (r.bubble) |b| if (r.bubble_reset_at != 0 and t >= r.bubble_reset_at) {
        b.setTextContent(r.persona.idle);
        r.bubble_reset_at = 0;
    };

    _ = web.window().requestAnimationFrame(.bind(r, runnerFrame, .{ .once = true }));
}

fn addClass(el: web.Element, name: []const u8) void {
    const c = classes(el);
    defer c.deinit();
    c.add(.{name});
}

fn removeClass(el: web.Element, name: []const u8) void {
    const c = classes(el);
    defer c.deinit();
    c.remove(.{name});
}

fn onRunnerClick(r: *Runner, _: []const js.Value) void {
    const t = now();
    if (r.bubble) |b| {
        b.setTextContent(r.persona.clicked);
        r.bubble_reset_at = t + 1400;
    }
    r.paused = true;
    addClass(r.wrap, "is-paused");
    r.resume_at = t + 350;
    r.flee_until = t + 350 + 2200;
    const c = classes(r.mascot);
    defer c.deinit();
    c.remove(.{ "fx-spin", "fx-shake", "fx-squish", "fx-flash" });
    // Force a reflow so the effect animation restarts.
    _ = r.mascot.as(web.HTMLElement).offsetWidth();
    c.add(.{r.persona.fx});
    playSound(r.persona.sound);
}

// --- Sounds (Web Audio) ---

var audio: ?web.AudioContext = null;

fn audioCtx() web.AudioContext {
    if (audio == null) audio = web.AudioContext.new(null);
    return audio.?;
}

fn at(p: web.AudioParam, v: f32, t: f64) void {
    p.setValueAtTime(v, t).deinit();
}
fn linTo(p: web.AudioParam, v: f32, t: f64) void {
    p.linearRampToValueAtTime(v, t).deinit();
}
fn expTo(p: web.AudioParam, v: f32, t: f64) void {
    p.exponentialRampToValueAtTime(v, t).deinit();
}

/// Connects `nodes` in order, ending at the context's destination.
fn chain(ctx: web.AudioContext, nodes: anytype) void {
    inline for (nodes, 0..) |n, i| {
        if (i + 1 < nodes.len) n.connect(nodes[i + 1], null, null).deinit();
    }
    const dest = ctx.destination();
    defer dest.deinit();
    nodes[nodes.len - 1].connect(dest, null, null).deinit();
}

fn osc(ctx: web.AudioContext, kind: web.OscillatorType) web.OscillatorNode {
    const o = ctx.createOscillator();
    o.setType(kind);
    return o;
}

fn noise(ctx: web.AudioContext, dur: f64, fade: bool) web.AudioBufferSourceNode {
    const rate = ctx.sampleRate();
    const len: u32 = @intFromFloat(@floor(rate * dur));
    const samples = gpa.alloc(f32, len) catch return ctx.createBufferSource();
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const v: f32 = @floatCast(random() * 2 - 1);
        s.* = if (fade) v * (1 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(len))) else v;
    }
    const buf = ctx.createBuffer(1, len, rate);
    defer buf.deinit();
    buf.copyToChannel(samples, 0, null);
    const src = ctx.createBufferSource();
    src.setBuffer(buf);
    return src;
}

fn playSound(kind: Sound) void {
    const ctx = audioCtx();
    const t = ctx.currentTime();
    switch (kind) {
        .aa => {
            const dur = 0.5;
            const o = osc(ctx, .sawtooth);
            defer o.deinit();
            const f = o.frequency();
            defer f.deinit();
            at(f, 420, t);
            linTo(f, 360, t + dur);
            const vib = osc(ctx, .sine);
            defer vib.deinit();
            const vf = vib.frequency();
            defer vf.deinit();
            vf.setValue(5.5);
            const vib_gain = ctx.createGain();
            defer vib_gain.deinit();
            const vg = vib_gain.gain();
            defer vg.deinit();
            vg.setValue(12);
            vib.connect(vib_gain, null, null).deinit();
            vib_gain.connect2(f, null);
            const formant = ctx.createBiquadFilter();
            defer formant.deinit();
            formant.setType(.bandpass);
            const ff = formant.frequency();
            defer ff.deinit();
            ff.setValue(900);
            const q = formant.Q();
            defer q.deinit();
            q.setValue(4);
            const g = ctx.createGain();
            defer g.deinit();
            const gg = g.gain();
            defer gg.deinit();
            at(gg, 0, t);
            linTo(gg, 0.35, t + 0.04);
            at(gg, 0.35, t + dur - 0.08);
            expTo(gg, 0.0001, t + dur);
            chain(ctx, .{ o, formant, g });
            o.start(t);
            vib.start(t);
            o.stop(t + dur);
            vib.stop(t + dur);
        },
        .boing, .laser, .bubble, .squeak => {
            const spec: struct { kind: web.OscillatorType, dur: f64, f0: f32, f1: f32, g0: f32, peak: ?f32 } = switch (kind) {
                .boing => .{ .kind = .sine, .dur = 0.45, .f0 = 180, .f1 = 200, .g0 = 0.0001, .peak = 0.4 },
                .laser => .{ .kind = .sawtooth, .dur = 0.35, .f0 = 1800, .f1 = 120, .g0 = 0.3, .peak = null },
                .bubble => .{ .kind = .sine, .dur = 0.25, .f0 = 400, .f1 = 1600, .g0 = 0.0001, .peak = 0.3 },
                else => .{ .kind = .triangle, .dur = 0.18, .f0 = 1200, .f1 = 2400, .g0 = 0.0001, .peak = 0.25 },
            };
            const o = osc(ctx, spec.kind);
            defer o.deinit();
            const f = o.frequency();
            defer f.deinit();
            at(f, spec.f0, t);
            if (kind == .boing) expTo(f, 720, t + 0.08);
            expTo(f, spec.f1, t + spec.dur);
            const g = ctx.createGain();
            defer g.deinit();
            const gg = g.gain();
            defer gg.deinit();
            at(gg, spec.g0, t);
            if (spec.peak) |peak| expTo(gg, peak, t + (if (kind == .bubble) @as(f64, 0.05) else 0.02));
            expTo(gg, 0.0001, t + spec.dur);
            chain(ctx, .{ o, g });
            o.start(t);
            o.stop(t + spec.dur);
        },
        .honk => {
            const dur = 0.3;
            const o = osc(ctx, .square);
            defer o.deinit();
            const f = o.frequency();
            defer f.deinit();
            f.setValue(220);
            const lp = ctx.createBiquadFilter();
            defer lp.deinit();
            lp.setType(.lowpass);
            const lf = lp.frequency();
            defer lf.deinit();
            lf.setValue(1200);
            const g = ctx.createGain();
            defer g.deinit();
            const gg = g.gain();
            defer gg.deinit();
            at(gg, 0, t);
            linTo(gg, 0.3, t + 0.02);
            at(gg, 0.3, t + dur - 0.05);
            expTo(gg, 0.0001, t + dur);
            chain(ctx, .{ o, lp, g });
            o.start(t);
            o.stop(t + dur);
        },
        .bonk, .slide => {
            const dur: f64 = if (kind == .bonk) 0.2 else 0.5;
            const src = noise(ctx, dur, kind == .bonk);
            defer src.deinit();
            const bp = ctx.createBiquadFilter();
            defer bp.deinit();
            bp.setType(.bandpass);
            const bf = bp.frequency();
            defer bf.deinit();
            const q = bp.Q();
            defer q.deinit();
            if (kind == .bonk) {
                bf.setValue(220);
                q.setValue(5);
            } else {
                q.setValue(8);
                at(bf, 500, t);
                expTo(bf, 2500, t + dur);
            }
            const g = ctx.createGain();
            defer g.deinit();
            const gg = g.gain();
            defer gg.deinit();
            at(gg, if (kind == .bonk) 0.6 else 0.3, t);
            expTo(gg, 0.0001, t + dur);
            chain(ctx, .{ src, bp, g });
            src.start(t, null, null);
            src.stop(t + dur);
        },
    }
}

// --- Ziggy ---

const ziggy_src = "/assets/branding/mascots/ziggy/ziggy-animated.svg";
const ziggy_targets = "#control-flow-tabs, .code-preview-example";
const style_id = "ziggy-crawler-style";

// Ziggy's artboard is 379 × 316; the feet touch the ground around (171, 294).
const aspect = 316.0 / 379.0;
const foot_x = 0.45;
const foot_y = 0.93;
const size = 72.0;
const speed = 60.0;
const hug = 0.09;
const side_reach = 0.25;
const stop_chance = 0.7;
const wave_chance = 0.75;

const Layer = struct { el: web.Element, svg: web.Element };

const Pose = enum {
    none,
    crawling,
    looking,
    waving,

    fn class(p: Pose) []const u8 {
        return switch (p) {
            .none => "ziggy",
            .crawling => "ziggy is-crawling",
            .looking => "ziggy is-looking",
            .waving => "ziggy is-looking is-waving",
        };
    }
};

/// A timed routine replacing the original async greet/turn sequences.
const Routine = struct {
    kind: enum { greet, turn },
    wave: bool = false,
    step: usize = 0,
    step_start: f64,
    from: f64 = 1,
    to: f64 = 1,

    const Step = struct { pose: Pose, ms: f64 };

    fn steps(r: Routine, buf: *[4]Step) []const Step {
        return switch (r.kind) {
            .greet => if (r.wave) blk: {
                buf.* = .{ .{ .pose = .looking, .ms = 650 }, .{ .pose = .waving, .ms = 1650 }, .{ .pose = .looking, .ms = 500 }, .{ .pose = .none, .ms = 250 } };
                break :blk buf[0..4];
            } else blk: {
                buf[0..3].* = .{ .{ .pose = .looking, .ms = 650 }, .{ .pose = .looking, .ms = 1100 }, .{ .pose = .none, .ms = 250 } };
                break :blk buf[0..3];
            },
            // Pause, then ease `facing` round over 320ms while crawling.
            .turn => blk: {
                buf[0..2].* = .{ .{ .pose = .none, .ms = 300 }, .{ .pose = .crawling, .ms = 320 } };
                break :blk buf[0..2];
            },
        };
    }
};

const Seg = struct { len: f64, kind: enum { left, tl, top, tr, right } };
const Point = struct { x: f64, y: f64, a: f64, top: bool = false };

const Path = struct {
    x: f64,
    y: f64,
    w: f64,
    r: f64,
    side: f64,
    arc: f64,
    segs: [5]Seg,
    total: f64,
    top_start: f64,
    top_len: f64,

    fn at(p: Path, sg: Seg, d: f64) Point {
        return switch (sg.kind) {
            .left => .{ .x = p.x, .y = p.y + p.r + p.side - d, .a = 270 },
            .tl => p.corner(p.x + p.r, p.y + p.r, 180 + (d / p.arc) * 90),
            .top => .{ .x = p.x + p.r + d, .y = p.y, .a = 360, .top = true },
            .tr => p.corner(p.x + p.w - p.r, p.y + p.r, -90 + (d / p.arc) * 90),
            .right => .{ .x = p.x + p.w, .y = p.y + p.r + d, .a = 90 },
        };
    }

    // Facing along the tangent: 90° ahead of the radius.
    fn corner(p: Path, cx: f64, cy: f64, deg: f64) Point {
        const rad = deg * std.math.pi / 180;
        return .{ .x = cx + p.r * @cos(rad), .y = cy + p.r * @sin(rad), .a = deg + 90 };
    }

    fn pointAt(p: Path, s: f64) Point {
        var d = @min(@max(s, 0), p.total);
        for (p.segs) |sg| {
            if (d <= sg.len) return p.at(sg, d);
            d -= sg.len;
        }
        var last = p.at(p.segs[4], p.segs[4].len);
        last.top = false;
        return last;
    }
};

const Crawler = struct {
    target: web.HTMLElement,
    stage: web.HTMLElement,
    layers: [2]Layer,
    dir: f64 = 1,
    facing: f64 = 1,
    busy: ?Routine = null,
    paused: bool = false,
    visible: bool = true,
    was_on_top: bool = true,
    stop_at: ?f64 = null,
    reduced: bool,
    s: f64 = 0,
    last: f64,

    fn path(c: *Crawler) Path {
        const t = c.target;
        const x: f64 = @floatFromInt(t.offsetLeft());
        const y: f64 = @floatFromInt(t.offsetTop());
        const w: f64 = @floatFromInt(t.offsetWidth());
        const h: f64 = @floatFromInt(t.offsetHeight());
        var buf: [32]u8 = undefined;
        const radius = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, computed(t, "border-top-left-radius", &buf), "px")) catch 0;
        const r = @min(radius, w / 2, h / 2);
        const side = @max(0, h * side_reach - r);
        const arc = std.math.pi / 2.0 * r;
        const top = w - 2 * r;
        const segs = [5]Seg{ .{ .len = side, .kind = .left }, .{ .len = arc, .kind = .tl }, .{ .len = top, .kind = .top }, .{ .len = arc, .kind = .tr }, .{ .len = side, .kind = .right } };
        return .{ .x = x, .y = y, .w = w, .r = r, .side = side, .arc = arc, .segs = segs, .total = 2 * side + 2 * arc + top, .top_start = side + arc, .top_len = top };
    }

    fn setPose(c: *Crawler, pose: Pose) void {
        for (c.layers) |l| l.svg.setAttribute("class", pose.class());
    }

    fn crawlPose(c: *Crawler) Pose {
        return if (c.reduced or c.paused) .none else .crawling;
    }

    fn place(c: *Crawler) void {
        const p = c.path().pointAt(c.s);
        // Sink into the edge along Ziggy's own "down", so the feet tuck behind the window.
        const sink = size * hug;
        const rad = p.a * std.math.pi / 180;
        const x = p.x - @sin(rad) * sink;
        const y = p.y + @cos(rad) * sink;
        var buf: [160]u8 = undefined;
        const transform = std.fmt.bufPrint(&buf, "translate({d}px, {d}px) rotate({d}deg) scaleX({d})", .{ x - size * foot_x, y - size * aspect * foot_y, p.a, c.facing }) catch return;
        for (c.layers) |l| style(l.el, "transform", transform);
    }

    fn run(c: *Crawler, r: Routine) void {
        c.busy = r;
        var buf: [4]Routine.Step = undefined;
        c.setPose(r.steps(&buf)[0].pose);
    }

    fn greet(c: *Crawler, wave: bool) void {
        c.run(.{ .kind = .greet, .wave = wave, .step_start = now() });
    }

    fn turnAround(c: *Crawler) void {
        c.run(.{ .kind = .turn, .step_start = now(), .from = c.facing, .to = -c.dir });
    }

    /// Advances the running routine; clears it when done.
    fn advance(c: *Crawler, t: f64) void {
        const r = if (c.busy) |*b| b else return;
        var buf: [4]Routine.Step = undefined;
        const steps = r.steps(&buf);
        if (r.kind == .turn and r.step == 1) {
            const k = @min(1, (t - r.step_start) / 320);
            c.facing = r.from + (r.to - r.from) * (0.5 - @cos(std.math.pi * k) / 2);
        }
        if (t - r.step_start < steps[r.step].ms) return;
        r.step += 1;
        r.step_start = t;
        if (r.step < steps.len) {
            c.setPose(steps[r.step].pose);
            return;
        }
        if (r.kind == .turn) {
            c.facing = r.to;
            c.dir = r.to;
            c.was_on_top = false;
        }
        c.busy = null;
        c.setPose(c.crawlPose());
    }

    fn tick(c: *Crawler, t: f64) void {
        const dt = @min(0.05, (t - c.last) / 1000);
        c.last = t;
        c.advance(t);
        if (!c.reduced and !c.paused and c.busy == null and c.visible) {
            c.s += speed * dt * c.dir;
            const p = c.path();
            const on_top = p.pointAt(c.s).top;
            // Crossing onto the top edge: maybe plan a stop somewhere along it.
            if (on_top and !c.was_on_top and random() < stop_chance) {
                const f = 0.25 + random() * 0.5;
                c.stop_at = p.top_start + p.top_len * (if (c.dir > 0) f else 1 - f);
            }
            c.was_on_top = on_top;
            if (c.stop_at) |stop| if (if (c.dir > 0) c.s >= stop else c.s <= stop) {
                c.s = stop;
                c.stop_at = null;
                c.greet(random() < wave_chance);
                c.place();
                return;
            };
            if (c.s >= p.total or c.s <= 0) {
                c.s = @min(@max(c.s, 0), p.total);
                c.turnAround();
            }
        }
        c.place();
    }
};

var crawlers: [4]Crawler = undefined;
var n_crawlers: usize = 0;

fn setupZiggy() void {
    const p = web.window().fetch(ziggy_src, null);
    defer p.deinit();
    p.then(.fromFn(onZiggyResponse, .{ .once = true }), null);
}

fn onZiggyResponse(args: []const js.Value) void {
    if (args.len == 0) return;
    const res: web.Response = .{ .h = args[0] };
    if (!res.ok()) return;
    const p = res.text();
    defer p.deinit();
    p.then(.fromFn(onZiggyText, .{ .once = true }), null);
}

fn onZiggyText(args: []const js.Value) void {
    if (args.len == 0) return;
    const svg = args[0].string(gpa) catch return;
    defer gpa.free(svg);
    injectStyle();
    const doc = web.document();
    defer doc.deinit();
    const targets = doc.querySelectorAll(ziggy_targets);
    defer targets.deinit();
    for (0..targets.length()) |i| {
        const n = targets.item(@intCast(i)) orelse continue;
        attachZiggy(n.as(web.HTMLElement), svg);
    }
}

// Only the near-side legs are drawn above the window; the rest of Ziggy stays behind it.
fn injectStyle() void {
    const doc = web.document();
    defer doc.deinit();
    if (doc.getElementById(style_id)) |existing| {
        existing.deinit();
        return;
    }
    const el = doc.createElement("style", null);
    defer el.deinit();
    el.setId(style_id);
    el.setTextContent(".ziggy-crawler--front .ziggy-rig > :not(.ziggy-leg-near):not(.ziggy-leg-rear) { visibility: hidden; }");
    const head = doc.head() orelse return;
    defer head.deinit();
    head.append(.{el});
}

fn attachZiggy(target: web.HTMLElement, svg: []const u8) void {
    if (n_crawlers == crawlers.len) return;
    const stage = (target.parentElement() orelse return).as(web.HTMLElement);
    var buf: [32]u8 = undefined;
    if (std.mem.eql(u8, computed(stage, "position", &buf), "static")) style(stage, "position", "relative");
    style(stage, "isolation", "isolate");
    if (std.mem.eql(u8, computed(target, "position", &buf), "static")) style(target, "position", "relative");
    if (std.mem.eql(u8, computed(target, "z-index", &buf), "auto")) style(target, "z-index", "1");

    const mq = web.window().matchMedia("(prefers-reduced-motion: reduce)");
    defer mq.deinit();
    const c = &crawlers[n_crawlers];
    n_crawlers += 1;
    c.* = .{
        .target = target,
        .stage = stage,
        .layers = .{ layer(stage, svg, 0, "back"), layer(stage, svg, 2, "front") },
        .reduced = mq.matches(),
        .last = now(),
    };
    for (c.layers) |l| l.el.addEventListener("click", .bind(c, onZiggyClick, .{}), null);

    const io = web.IntersectionObserver.new(.bind(c, onZiggyVisible, .{}), null);
    defer io.deinit();
    io.observe(stage);

    // Start a little way along the top edge.
    const p = c.path();
    c.s = p.top_start + p.top_len * (if (c.reduced) @as(f64, 0.7) else 0.2);
    c.setPose(if (c.reduced) .none else .crawling);
    c.place();
    _ = web.window().requestAnimationFrame(.bind(c, ziggyFrame, .{ .once = true }));
}

fn layer(stage: web.HTMLElement, svg: []const u8, z: u8, name: []const u8) Layer {
    const doc = web.document();
    defer doc.deinit();
    const el = doc.createElement("div", null);
    var buf: [64]u8 = undefined;
    el.setClassName(std.fmt.bufPrint(&buf, "ziggy-crawler ziggy-crawler--{s}", .{name}) catch "ziggy-crawler");
    if (std.mem.eql(u8, name, "back")) {
        el.setAttribute("role", "img");
        el.setAttribute("aria-label", "Ziggy the Ziguana");
    } else {
        el.setAttribute("aria-hidden", "true");
    }
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [48]u8 = undefined;
    var b4: [4]u8 = undefined;
    const props = [_][2][]const u8{
        .{ "position", "absolute" },
        .{ "left", "0" },
        .{ "top", "0" },
        .{ "width", std.fmt.bufPrint(&b1, "{d}px", .{size}) catch "" },
        .{ "height", std.fmt.bufPrint(&b2, "{d}px", .{size * aspect}) catch "" },
        .{ "transform-origin", std.fmt.bufPrint(&b3, "{d}px {d}px", .{ size * foot_x, size * aspect * foot_y }) catch "" },
        .{ "cursor", "pointer" },
        .{ "z-index", std.fmt.bufPrint(&b4, "{d}", .{z}) catch "" },
        .{ "will-change", "transform" },
    };
    for (props) |kv| style(el, kv[0], kv[1]);
    el.setInnerHTML(svg);
    const svg_el = el.firstElementChild() orelse el;
    svg_el.setAttribute("width", "100%");
    svg_el.setAttribute("height", "100%");
    style(svg_el, "display", "block");
    style(svg_el, "overflow", "visible");
    stage.append(.{el});
    return .{ .el = el, .svg = svg_el };
}

fn onZiggyClick(c: *Crawler, _: []const js.Value) void {
    c.greet(true);
}

fn onZiggyVisible(c: *Crawler, args: []const js.Value) void {
    if (args.len == 0) return;
    const entry: web.IntersectionObserverEntry = .{ .h = args[0].at(0) };
    defer entry.deinit();
    c.visible = entry.isIntersecting();
}

fn ziggyFrame(c: *Crawler, args: []const js.Value) void {
    c.tick(if (args.len > 0) args[0].float() catch now() else now());
    _ = web.window().requestAnimationFrame(.bind(c, ziggyFrame, .{ .once = true }));
}
