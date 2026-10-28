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
const SURFACE = "rgba(255, 255, 255, 0.025)";
const SURFACE_RAISED = "#121212";

const MONO = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace";
const SANS = "system-ui, -apple-system, sans-serif";

type PerfBar = { label: string; value: number; display: string; self?: boolean };
type RoutingScene = { file: string; kind: string; url: string; note: string };
type DeployTarget = { name: string; artifact: string };
type DeployArtifact = { id: string; label: string; command: string; flag: string; caption: string };
type ApiMethod = { method: string; path: string; status: string; body: string };
type ControlScene = { id: string; snippet: string };
type Allocation = { label: string; size: number };

export type FeatureCanvasData = {
  performance: PerfBar[];
  routing: RoutingScene[];
  api: { file: string; signature: string; methods: ApiMethod[] };
  control_flow: {
    eyebrow: string;
    scenes: ControlScene[];
    if_arms: string[];
    for_item: string;
    for_count: number;
    switch_title: string;
    switch_arms: string[];
  };
  hybrid: { server_steps: string[]; hint: string; button: string; captions: string[] };
  tooling: {
    file: string;
    code: string[];
    completions: string[];
    command: string;
    version: string;
    url: string;
    restart_time: string;
  };
  deploy: DeployTarget[];
  deploy_artifacts: DeployArtifact[];
  memory: { file: string; code: string[]; allocs: Allocation[]; capacity: number };
};

type Ctx = CanvasRenderingContext2D;
type DrawFn = (ctx: Ctx, t: number, data: FeatureCanvasData) => void;
type Scene = { w: number; h: number; draw: DrawFn };

function emptyCanvasData(): FeatureCanvasData {
  return {
    performance: [],
    routing: [],
    api: { file: "", signature: "", methods: [] },
    control_flow: {
      eyebrow: "",
      scenes: [],
      if_arms: [],
      for_item: "",
      for_count: 0,
      switch_title: "",
      switch_arms: [],
    },
    hybrid: { server_steps: [], hint: "", button: "", captions: [] },
    tooling: { file: "", code: [], completions: [], command: "", version: "", url: "", restart_time: "" },
    deploy: [],
    deploy_artifacts: [],
    memory: { file: "", code: [], allocs: [], capacity: 0 },
  };
}

function loadCanvasData(): FeatureCanvasData {
  const empty = emptyCanvasData();
  const el = document.getElementById("feature-canvas-data");
  if (!el?.textContent) return empty;
  try {
    return { ...empty, ...JSON.parse(el.textContent) } as FeatureCanvasData;
  } catch {
    return empty;
  }
}

// --- Math ---

const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
const easeOut = (p: number) => 1 - Math.pow(1 - clamp(p), 3);
const easeInOut = (p: number) => {
  const x = clamp(p);
  return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
};
const progress = (t: number, start: number, dur: number) => clamp((t - start) / dur);
/** Fade in at the start of a beat and out before it ends. */
const beatAlpha = (local: number, len: number, edge = 0.25) =>
  Math.min(clamp(local / edge), clamp((len - local) / edge));

function withAlpha(hex: string, a: number) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

// --- Primitives ---

function rr(ctx: Ctx, x: number, y: number, w: number, h: number, r: number) {
  const rad = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + rad, y);
  ctx.arcTo(x + w, y, x + w, y + h, rad);
  ctx.arcTo(x + w, y + h, x, y + h, rad);
  ctx.arcTo(x, y + h, x, y, rad);
  ctx.arcTo(x, y, x + w, y, rad);
  ctx.closePath();
}

function panel(
  ctx: Ctx,
  x: number,
  y: number,
  w: number,
  h: number,
  opts: { r?: number; fill?: string; stroke?: string; glow?: string; glowBlur?: number } = {},
) {
  const { r = 10, fill = SURFACE_RAISED, stroke = LINE, glow, glowBlur = 24 } = opts;
  ctx.save();
  if (glow) {
    ctx.shadowColor = glow;
    ctx.shadowBlur = glowBlur;
  }
  rr(ctx, x, y, w, h, r);
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.restore();
  rr(ctx, x + 0.5, y + 0.5, w - 1, h - 1, r);
  ctx.strokeStyle = stroke;
  ctx.lineWidth = 1;
  ctx.stroke();
}

function windowChrome(ctx: Ctx, x: number, y: number, w: number, h: number, title: string, opts: { glow?: string; stroke?: string } = {}) {
  panel(ctx, x, y, w, h, { r: 10, glow: opts.glow, stroke: opts.stroke });
  ctx.strokeStyle = LINE;
  ctx.beginPath();
  ctx.moveTo(x, y + 26.5);
  ctx.lineTo(x + w, y + 26.5);
  ctx.stroke();
  ["#ff5f57", "#febc2e", "#28c840"].forEach((c, i) => {
    ctx.fillStyle = withAlpha(c, 0.75);
    ctx.beginPath();
    ctx.arc(x + 14 + i * 12, y + 13.5, 3.5, 0, Math.PI * 2);
    ctx.fill();
  });
  if (title) {
    text(ctx, title, x + w / 2, y + 17, { font: `11px ${MONO}`, color: FAINT, align: "center" });
  }
}

function text(
  ctx: Ctx,
  s: string,
  x: number,
  y: number,
  opts: { font?: string; color?: string; align?: CanvasTextAlign } = {},
) {
  ctx.font = opts.font ?? `12px ${MONO}`;
  ctx.fillStyle = opts.color ?? TEXT;
  ctx.textAlign = opts.align ?? "left";
  ctx.fillText(s, x, y);
  ctx.textAlign = "left";
}

function pill(
  ctx: Ctx,
  s: string,
  x: number,
  y: number,
  color: string,
  opts: { font?: string; filled?: boolean; padX?: number; h?: number; align?: "left" | "center" } = {},
) {
  const { font = `600 10px ${MONO}`, filled = false, padX = 7, h = 18, align = "left" } = opts;
  ctx.font = font;
  const w = ctx.measureText(s).width + padX * 2;
  const px = align === "center" ? x - w / 2 : x;
  rr(ctx, px, y, w, h, h / 2);
  ctx.fillStyle = filled ? color : withAlpha(color, 0.12);
  ctx.fill();
  if (!filled) {
    ctx.strokeStyle = withAlpha(color, 0.35);
    ctx.lineWidth = 1;
    ctx.stroke();
  }
  ctx.fillStyle = filled ? "#04140a" : color;
  ctx.textAlign = "center";
  ctx.fillText(s, px + w / 2, y + h / 2 + 3.5);
  ctx.textAlign = "left";
  return w;
}

function glowDot(ctx: Ctx, x: number, y: number, color: string, r = 3) {
  ctx.save();
  const g = ctx.createRadialGradient(x, y, 0, x, y, r * 5);
  g.addColorStop(0, withAlpha(color, 0.45));
  g.addColorStop(1, withAlpha(color, 0));
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(x, y, r * 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

type Pt = { x: number; y: number };

function bezierPoint(a: Pt, b: Pt, p: number): Pt {
  const mx = (a.x + b.x) / 2;
  const c1 = { x: mx, y: a.y };
  const c2 = { x: mx, y: b.y };
  const u = 1 - p;
  return {
    x: u * u * u * a.x + 3 * u * u * p * c1.x + 3 * u * p * p * c2.x + p * p * p * b.x,
    y: u * u * u * a.y + 3 * u * u * p * c1.y + 3 * u * p * p * c2.y + p * p * p * b.y,
  };
}

function curve(ctx: Ctx, a: Pt, b: Pt, color: string, opts: { width?: number; dash?: number[]; offset?: number } = {}) {
  const mx = (a.x + b.x) / 2;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = opts.width ?? 1;
  if (opts.dash) {
    ctx.setLineDash(opts.dash);
    ctx.lineDashOffset = opts.offset ?? 0;
  }
  ctx.beginPath();
  ctx.moveTo(a.x, a.y);
  ctx.bezierCurveTo(mx, a.y, mx, b.y, b.x, b.y);
  ctx.stroke();
  ctx.restore();
}

function line(ctx: Ctx, a: Pt, b: Pt, color: string, opts: { width?: number; dash?: number[]; offset?: number } = {}) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = opts.width ?? 1;
  if (opts.dash) {
    ctx.setLineDash(opts.dash);
    ctx.lineDashOffset = opts.offset ?? 0;
  }
  ctx.beginPath();
  ctx.moveTo(a.x, a.y);
  ctx.lineTo(b.x, b.y);
  ctx.stroke();
  ctx.restore();
}

/** Lightweight Zig/ZX token colouring for single code lines. */
function codeLine(ctx: Ctx, src: string, x: number, y: number, opts: { size?: number; dim?: boolean } = {}) {
  const size = opts.size ?? 11.5;
  ctx.font = `${size}px ${MONO}`;
  ctx.textAlign = "left";
  const re =
    /(\/\/.*$)|("(?:[^"\\]|\\.)*")|(@[A-Za-z_]+)|(<\/?[A-Za-z][\w.]*|\/?>)|\b(pub|fn|const|var|return|try|defer|if|else|for|while|switch)\b|(\.[a-z_]+\b)|(\b\d+\b)|([A-Z][A-Za-z0-9_]*)/g;
  let last = 0;
  let cx = x;
  const put = (s: string, color: string) => {
    if (!s) return;
    ctx.fillStyle = opts.dim ? withAlpha(color === TEXT ? "#ffffff" : color, 0.35) : color;
    ctx.fillText(s, cx, y);
    cx += ctx.measureText(s).width;
  };
  for (const m of src.matchAll(re)) {
    put(src.slice(last, m.index), TEXT);
    const tok = m[0];
    const color = m[1]
      ? FAINT
      : m[2]
        ? GREEN_LIGHT
        : m[3]
          ? AMBER
          : m[4]
            ? CYAN
            : m[5]
              ? ROSE
              : m[6]
                ? VIOLET
                : m[7]
                  ? AMBER
                  : GREEN;
    put(tok, color);
    last = (m.index ?? 0) + tok.length;
  }
  put(src.slice(last), TEXT);
  return cx;
}

function backdrop(ctx: Ctx, w: number, h: number, accent: string) {
  ctx.clearRect(0, 0, w, h);
  const gap = 22;
  ctx.fillStyle = "rgba(255, 255, 255, 0.055)";
  for (let y = (h % gap) / 2; y < h; y += gap) {
    for (let x = (w % gap) / 2; x < w; x += gap) {
      ctx.fillRect(x, y, 1, 1);
    }
  }
  const g = ctx.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, Math.max(w, h) * 0.6);
  g.addColorStop(0, withAlpha(accent, 0.07));
  g.addColorStop(1, withAlpha(accent, 0));
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, w, h);
  const v = ctx.createRadialGradient(w / 2, h / 2, Math.min(w, h) * 0.35, w / 2, h / 2, Math.max(w, h) * 0.75);
  v.addColorStop(0, "rgba(10, 10, 10, 0)");
  v.addColorStop(1, "rgba(10, 10, 10, 0.85)");
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, w, h);
}

function formatCount(v: number) {
  if (v >= 1000) return `${(v / 1000).toFixed(v >= 10000 ? 0 : 1)}k`;
  return `${Math.round(v)}`;
}

// --- Scenes ---

function drawPerformance(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const bars = data.performance;
  if (bars.length === 0) return;
  const W = 440;
  const max = Math.max(...bars.map((b) => b.value), 1);
  const labelW = 78;
  const valueW = 50;
  const trackX = labelW;
  const trackW = W - labelW - valueW;
  const rowH = 44;
  const top = 64;

  text(ctx, "SSR THROUGHPUT", 0, 14, { font: `600 10px ${MONO}`, color: FAINT });
  text(ctx, "requests / second", 0, 34, { font: `500 15px ${SANS}`, color: TEXT });

  const chartH = bars.length * rowH;
  for (let i = 1; i < 4; i++) {
    const gx = trackX + (trackW * i) / 4 + 0.5;
    line(ctx, { x: gx, y: top - 6 }, { x: gx, y: top + chartH - 10 }, "rgba(255,255,255,0.05)", { dash: [2, 4] });
  }

  bars.forEach((bar, i) => {
    const y = top + i * rowH;
    const p = easeOut(progress(t, 0.15 + i * 0.12, 0.9));
    const bw = Math.max(6, (bar.value / max) * trackW * p);

    text(ctx, bar.label, trackX - 14, y + 15, {
      font: `${bar.self ? 600 : 500} 13px ${SANS}`,
      color: bar.self ? WHITE : MUTED,
      align: "right",
    });

    rr(ctx, trackX, y + 4, trackW, 14, 7);
    ctx.fillStyle = "rgba(255,255,255,0.04)";
    ctx.fill();

    ctx.save();
    if (bar.self) {
      const g = ctx.createLinearGradient(trackX, 0, trackX + bw, 0);
      g.addColorStop(0, "#16a34a");
      g.addColorStop(1, GREEN_LIGHT);
      ctx.fillStyle = g;
      ctx.shadowColor = withAlpha(GREEN, 0.5);
      ctx.shadowBlur = 18;
    } else {
      const g = ctx.createLinearGradient(trackX, 0, trackX + bw, 0);
      g.addColorStop(0, "rgba(255,255,255,0.12)");
      g.addColorStop(1, "rgba(255,255,255,0.3)");
      ctx.fillStyle = g;
    }
    rr(ctx, trackX, y + 4, bw, 14, 7);
    ctx.fill();
    ctx.restore();

    if (bar.self && p >= 1) {
      // Periodic shimmer across the leading bar.
      const sp = ((t - 1.2) % 2.6) / 1.1;
      if (sp > 0 && sp < 1) {
        ctx.save();
        rr(ctx, trackX, y + 4, bw, 14, 7);
        ctx.clip();
        const sx = trackX + sp * (bw + 80) - 40;
        const sg = ctx.createLinearGradient(sx - 40, 0, sx + 40, 0);
        sg.addColorStop(0, "rgba(255,255,255,0)");
        sg.addColorStop(0.5, "rgba(255,255,255,0.45)");
        sg.addColorStop(1, "rgba(255,255,255,0)");
        ctx.fillStyle = sg;
        ctx.fillRect(sx - 40, y + 4, 80, 14);
        ctx.restore();
      }
    }

    const shown = p >= 1 ? bar.display : formatCount(bar.value * p);
    text(ctx, shown, W, y + 15, {
      font: `${bar.self ? 600 : 400} 12px ${MONO}`,
      color: bar.self ? GREEN : MUTED,
      align: "right",
    });
  });

  text(ctx, "2 CPU · 2 GB RAM · Docker", 0, top + chartH + 14, { font: `11px ${MONO}`, color: FAINT });
}

type TreeRow = { name: string; depth: number; dir: boolean; scene?: number };

function buildTree(scenes: RoutingScene[]): TreeRow[] {
  const rows: TreeRow[] = [{ name: "pages", depth: 0, dir: true }];
  const seen = new Set<string>();
  scenes.forEach((s, i) => {
    const parts = s.file.split("/");
    for (let d = 0; d < parts.length - 1; d++) {
      const key = parts.slice(0, d + 1).join("/");
      if (!seen.has(key)) {
        seen.add(key);
        rows.push({ name: parts[d], depth: d + 1, dir: true });
      }
    }
    rows.push({ name: parts[parts.length - 1], depth: parts.length, dir: false, scene: i });
  });
  return rows;
}

function fileIcon(ctx: Ctx, x: number, y: number, dir: boolean, color: string) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.2;
  if (dir) {
    ctx.beginPath();
    ctx.moveTo(x, y + 9);
    ctx.lineTo(x, y + 1);
    ctx.lineTo(x + 4, y + 1);
    ctx.lineTo(x + 5.5, y + 2.5);
    ctx.lineTo(x + 11, y + 2.5);
    ctx.lineTo(x + 11, y + 9);
    ctx.closePath();
    ctx.stroke();
  } else {
    ctx.beginPath();
    ctx.moveTo(x + 1, y);
    ctx.lineTo(x + 7, y);
    ctx.lineTo(x + 10, y + 3);
    ctx.lineTo(x + 10, y + 10);
    ctx.lineTo(x + 1, y + 10);
    ctx.closePath();
    ctx.stroke();
  }
  ctx.restore();
}

function drawRouting(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const scenes = data.routing;
  if (scenes.length === 0) return;
  const BEAT = 2.6;
  const idx = Math.floor(t / BEAT) % scenes.length;
  const local = t % BEAT;
  const scene = scenes[idx];
  const rows = buildTree(scenes);

  const treeX = 0;
  const treeW = 176;
  const rowH = 26;
  const treeH = 40 + rows.length * rowH;
  const treeY = (340 - treeH) / 2;
  panel(ctx, treeX, treeY, treeW, treeH);
  text(ctx, "EXPLORER", treeX + 14, treeY + 22, { font: `600 9.5px ${MONO}`, color: FAINT });

  let activeY = 0;
  rows.forEach((row, i) => {
    const y = treeY + 34 + i * rowH;
    const on = row.scene === idx;
    const x = treeX + 14 + (row.depth > 0 ? (row.depth - 1) * 14 + 12 : 0);
    if (on) {
      activeY = y + rowH / 2;
      const a = easeOut(progress(local, 0, 0.3));
      rr(ctx, treeX + 6, y + 2, treeW - 12, rowH - 4, 6);
      ctx.fillStyle = withAlpha(GREEN, 0.12 * a);
      ctx.fill();
      ctx.fillStyle = withAlpha(GREEN, a);
      ctx.fillRect(treeX + 6, y + 6, 2, rowH - 12);
    }
    const color = on ? GREEN : row.dir ? MUTED : FAINT;
    fileIcon(ctx, x, y + 8, row.dir, color);
    text(ctx, row.dir ? `${row.name}/` : row.name, x + 18, y + 17, {
      font: `${on ? 600 : 400} 12px ${MONO}`,
      color: on ? WHITE : row.dir ? MUTED : "rgba(255,255,255,0.45)",
    });
  });

  // Browser preview.
  const bx = 226;
  const bw = 214;
  const bh = 200;
  const by = (340 - bh) / 2;
  windowChrome(ctx, bx, by, bw, bh, "", { stroke: LINE_STRONG });
  rr(ctx, bx + 52, by + 6, bw - 62, 15, 7.5);
  ctx.fillStyle = "rgba(255,255,255,0.05)";
  ctx.fill();
  const typed = scene.kind === "error" || scene.kind === "notfound" ? scene.url : scene.url;
  const shown = typed.slice(0, Math.ceil(typed.length * easeOut(progress(local, 0.15, 0.4))));
  ctx.font = `10px ${MONO}`;
  const host = "localhost:3000";
  text(ctx, host, bx + 60, by + 17, { font: `10px ${MONO}`, color: FAINT });
  const hostW = ctx.measureText(host).width;
  const urlPath = scene.url.startsWith("/") ? shown : "";
  text(ctx, urlPath, bx + 60 + hostW, by + 17, { font: `10px ${MONO}`, color: TEXT });

  const a = beatAlpha(local, BEAT, 0.3);
  ctx.globalAlpha = a;
  const cx = bx + 14;
  const cy = by + 40;
  const cw = bw - 28;
  if (scene.kind === "layout") {
    rr(ctx, cx, cy, cw, bh - 54, 6);
    ctx.setLineDash([4, 3]);
    ctx.strokeStyle = withAlpha(GREEN, 0.7);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = withAlpha(GREEN, 0.15);
    ctx.fillRect(cx + 8, cy + 8, cw - 16, 14);
    ctx.fillRect(cx + 8, cy + bh - 54 - 22, cw - 16, 14);
    rr(ctx, cx + 8, cy + 30, cw - 16, bh - 54 - 60, 4);
    ctx.fillStyle = "rgba(255,255,255,0.03)";
    ctx.fill();
    text(ctx, "{children}", cx + cw / 2, cy + (bh - 54) / 2 + 4, { font: `11px ${MONO}`, color: FAINT, align: "center" });
  } else if (scene.kind === "route") {
    text(ctx, "{", cx, cy + 16, { font: `12px ${MONO}`, color: MUTED });
    text(ctx, '"status": "ok"', cx + 14, cy + 36, { font: `12px ${MONO}`, color: GREEN_LIGHT });
    text(ctx, "}", cx, cy + 56, { font: `12px ${MONO}`, color: MUTED });
    pill(ctx, "application/json", cx, cy + 84, CYAN);
  } else if (scene.kind === "error") {
    rr(ctx, cx, cy, cw, 54, 6);
    ctx.fillStyle = withAlpha(ROSE, 0.08);
    ctx.fill();
    ctx.strokeStyle = withAlpha(ROSE, 0.35);
    ctx.stroke();
    text(ctx, "Something went wrong", cx + 12, cy + 22, { font: `600 12px ${SANS}`, color: ROSE });
    text(ctx, "error.OutOfMemory", cx + 12, cy + 40, { font: `11px ${MONO}`, color: MUTED });
    ctx.fillStyle = "rgba(255,255,255,0.06)";
    ctx.fillRect(cx, cy + 70, cw * 0.7, 8);
    ctx.fillRect(cx, cy + 86, cw * 0.5, 8);
  } else if (scene.kind === "notfound") {
    text(ctx, "404", cx + cw / 2, cy + 70, { font: `700 44px ${SANS}`, color: "rgba(255,255,255,0.9)", align: "center" });
    text(ctx, "Page not found", cx + cw / 2, cy + 96, { font: `12px ${SANS}`, color: MUTED, align: "center" });
  } else {
    ctx.fillStyle = withAlpha(GREEN, 0.75);
    ctx.fillRect(cx, cy + 4, 40, 6);
    text(ctx, scene.url === "/" ? "Home" : scene.url.slice(1).replace(/^\w/, (c) => c.toUpperCase()), cx, cy + 36, {
      font: `700 18px ${SANS}`,
      color: WHITE,
    });
    ctx.fillStyle = "rgba(255,255,255,0.08)";
    [0.95, 0.8, 0.88, 0.6].forEach((f, i) => ctx.fillRect(cx, cy + 52 + i * 14, cw * f, 6));
  }
  ctx.globalAlpha = 1;

  text(ctx, scene.note, bx + bw / 2, by + bh + 26, { font: `12px ${SANS}`, color: MUTED, align: "center" });

  const from = { x: treeX + treeW, y: activeY };
  const to = { x: bx, y: by + bh / 2 };
  curve(ctx, from, to, withAlpha(GREEN, 0.35), { dash: [3, 4], offset: -t * 20 });
  const pp = easeInOut(progress(local, 0.1, 0.8));
  if (pp > 0 && pp < 1) {
    const pt = bezierPoint(from, to, pp);
    glowDot(ctx, pt.x, pt.y, GREEN, 2.5);
  }
}

const METHOD_COLORS: Record<string, string> = { GET: GREEN, POST: CYAN, PUT: AMBER, PATCH: AMBER, DELETE: ROSE };

function drawApiRoutes(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const methods = data.api.methods;
  if (methods.length === 0) return;
  const BEAT = 3.2;
  const idx = Math.floor(t / BEAT) % methods.length;
  const local = t % BEAT;
  const req = methods[idx];
  const color = METHOD_COLORS[req.method] ?? GREEN;
  const W = 420;
  const fade = beatAlpha(local, BEAT, 0.25);

  // Request bar.
  panel(ctx, 0, 0, W, 44, { stroke: withAlpha(color, 0.35) });
  ctx.globalAlpha = fade;
  const mw = pill(ctx, req.method, 12, 13, color, { h: 18 });
  text(ctx, req.path, 12 + mw + 10, 26, { font: `13px ${MONO}`, color: WHITE });
  ctx.globalAlpha = 1;
  text(ctx, "fetch", W - 14, 26, { font: `11px ${MONO}`, color: FAINT, align: "right" });

  // Route handler file.
  const fy = 78;
  const fh = 30 + methods.length * 28 + 10;
  windowChrome(ctx, 0, fy, W, fh, data.api.file);
  methods.forEach((m, i) => {
    const y = fy + 36 + i * 28;
    const on = i === idx;
    const mc = METHOD_COLORS[m.method] ?? GREEN;
    if (on) {
      const a = easeOut(progress(local, 0.35, 0.3)) * fade;
      rr(ctx, 8, y, W - 16, 24, 5);
      ctx.fillStyle = withAlpha(mc, 0.1 * a);
      ctx.fill();
      ctx.fillStyle = withAlpha(mc, a);
      ctx.fillRect(8, y + 5, 2, 14);
    }
    ctx.font = `12px ${MONO}`;
    let x = 22;
    const put = (s: string, c: string) => {
      ctx.fillStyle = c;
      ctx.fillText(s, x, y + 16);
      x += ctx.measureText(s).width;
    };
    put("pub fn ", on ? ROSE : withAlpha(ROSE, 0.4));
    put(m.method, on ? mc : withAlpha(mc, 0.45));
    put(data.api.signature, on ? TEXT : FAINT);
  });

  // Connectors with travelling packets.
  const midX = W / 2;
  line(ctx, { x: midX, y: 44 }, { x: midX, y: fy }, LINE_STRONG);
  const reqP = progress(local, 0.05, 0.35);
  if (reqP > 0 && reqP < 1) glowDot(ctx, midX, 44 + reqP * (fy - 44), color, 2.5);

  const ry = fy + fh + 34;
  line(ctx, { x: midX, y: fy + fh }, { x: midX, y: ry }, LINE_STRONG);
  const resP = progress(local, 0.8, 0.35);
  if (resP > 0 && resP < 1) glowDot(ctx, midX, fy + fh + resP * 34, GREEN, 2.5);

  // Response.
  panel(ctx, 0, ry, W, 50);
  const shownA = easeOut(progress(local, 1.1, 0.3)) * fade;
  ctx.globalAlpha = shownA;
  const statusColor = req.status.startsWith("2") ? GREEN : ROSE;
  const sw = pill(ctx, req.status, 12, ry + 16, statusColor, { h: 18 });
  if (req.body) {
    const chars = Math.ceil(req.body.length * progress(local, 1.25, 0.6));
    codeLine(ctx, req.body.slice(0, chars), 12 + sw + 12, ry + 29, { size: 12 });
  } else {
    text(ctx, "(empty body)", 12 + sw + 12, ry + 29, { font: `12px ${MONO}`, color: FAINT });
  }
  ctx.globalAlpha = 1;
  text(ctx, "response", W - 14, ry + 29, { font: `11px ${MONO}`, color: FAINT, align: "right" });
}

function node(ctx: Ctx, label: string, cx: number, cy: number, on: boolean, color: string, opts: { mono?: boolean; minW?: number } = {}) {
  ctx.font = `${on ? 600 : 500} 12px ${MONO}`;
  const w = Math.max(opts.minW ?? 0, ctx.measureText(label).width + 26);
  const h = 30;
  panel(ctx, cx - w / 2, cy - h / 2, w, h, {
    r: 8,
    fill: on ? withAlpha(color, 0.12) : SURFACE_RAISED,
    stroke: on ? withAlpha(color, 0.75) : LINE,
    glow: on ? withAlpha(color, 0.45) : undefined,
    glowBlur: 20,
  });
  text(ctx, label, cx, cy + 4, { font: `${on ? 600 : 500} 12px ${MONO}`, color: on ? color : MUTED, align: "center" });
  return w;
}

function drawControlFlow(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const cf = data.control_flow;
  const scenes = cf.scenes;
  if (scenes.length === 0) return;
  const BEAT = 3.6;
  const idx = Math.floor(t / BEAT) % scenes.length;
  const local = t % BEAT;
  const kind = scenes[idx].id;
  const W = 440;
  const cx = W / 2;
  const fade = beatAlpha(local, BEAT, 0.3);

  // Tabs.
  ctx.font = `600 11px ${MONO}`;
  const tabW = scenes.map((s) => ctx.measureText(s.id).width + 28);
  const totalTabs = tabW.reduce((a, b) => a + b, 0) + 6 * (scenes.length - 1) + 8;
  let tx = cx - totalTabs / 2;
  rr(ctx, tx, 0, totalTabs, 30, 15);
  ctx.fillStyle = "rgba(255,255,255,0.03)";
  ctx.fill();
  ctx.strokeStyle = LINE;
  ctx.stroke();
  tx += 4;
  scenes.forEach((s, i) => {
    const on = i === idx;
    if (on) {
      rr(ctx, tx, 4, tabW[i], 22, 11);
      ctx.fillStyle = withAlpha(GREEN, 0.15);
      ctx.fill();
    }
    text(ctx, s.id, tx + tabW[i] / 2, 19, { font: `600 11px ${MONO}`, color: on ? GREEN : FAINT, align: "center" });
    tx += tabW[i] + 6;
  });

  ctx.globalAlpha = fade;
  const top = 90;
  const flow = -t * 24;

  if (kind === "if") {
    const branch = Math.floor(local / 1.4) % 2 === 0;
    const dy = top + 20;
    ctx.save();
    ctx.translate(cx, dy);
    ctx.rotate(Math.PI / 4);
    panel(ctx, -22, -22, 44, 44, { r: 6, fill: withAlpha(GREEN, 0.1), stroke: withAlpha(GREEN, 0.7), glow: withAlpha(GREEN, 0.35) });
    ctx.restore();
    text(ctx, "if", cx, dy + 4, { font: `600 12px ${MONO}`, color: GREEN, align: "center" });

    const arms = [cf.if_arms[0] || "<Ok/>", cf.if_arms[1] || "<Err/>"];
    const armY = top + 120;
    arms.forEach((label, i) => {
      const ax = cx + (i === 0 ? -110 : 110);
      const on = i === 0 ? branch : !branch;
      const from = { x: cx + (i === 0 ? -31 : 31), y: dy };
      const to = { x: ax, y: armY - 15 };
      ctx.save();
      ctx.strokeStyle = on ? withAlpha(GREEN, 0.7) : LINE_STRONG;
      ctx.lineWidth = on ? 1.5 : 1;
      if (on) {
        ctx.setLineDash([4, 4]);
        ctx.lineDashOffset = flow;
      }
      ctx.beginPath();
      ctx.moveTo(from.x, from.y);
      ctx.lineTo(ax, from.y);
      ctx.lineTo(to.x, to.y);
      ctx.stroke();
      ctx.restore();
      text(ctx, i === 0 ? "true" : "false", (from.x + ax) / 2, dy - 8, { font: `10px ${MONO}`, color: on ? GREEN : FAINT, align: "center" });
      node(ctx, label, ax, armY, on, GREEN, { minW: 84 });
    });
  } else if (kind === "for") {
    const ly = top + 20;
    const r = 22;
    ctx.save();
    ctx.strokeStyle = withAlpha(GREEN, 0.75);
    ctx.lineWidth = 1.5;
    ctx.shadowColor = withAlpha(GREEN, 0.4);
    ctx.shadowBlur = 14;
    const spin = t * 2.4;
    ctx.beginPath();
    ctx.arc(cx, ly, r, spin, spin + Math.PI * 1.6);
    ctx.stroke();
    const hx = cx + Math.cos(spin + Math.PI * 1.6) * r;
    const hy = ly + Math.sin(spin + Math.PI * 1.6) * r;
    ctx.fillStyle = GREEN;
    ctx.beginPath();
    ctx.arc(hx, hy, 2.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    text(ctx, "for", cx, ly + 4, { font: `600 12px ${MONO}`, color: GREEN, align: "center" });

    const count = Math.max(1, cf.for_count || 3);
    const label = cf.for_item || "<Row/>";
    const rowW = 220;
    const rowH = 30;
    const rowsTop = top + 62;
    const active = Math.floor(local * 1.4) % count;
    const built = Math.min(count, Math.floor(local * 2.2) + 1);
    line(ctx, { x: cx, y: ly + r + 2 }, { x: cx, y: rowsTop }, LINE_STRONG, { dash: [3, 3], offset: flow });
    for (let i = 0; i < count; i++) {
      const y = rowsTop + i * (rowH + 8);
      const appear = easeOut(progress(local, i * 0.45, 0.35));
      if (i >= built && appear <= 0) continue;
      ctx.globalAlpha = fade * appear;
      const on = i === active;
      panel(ctx, cx - rowW / 2, y + (1 - appear) * 8, rowW, rowH, {
        r: 7,
        fill: on ? withAlpha(GREEN, 0.1) : SURFACE_RAISED,
        stroke: on ? withAlpha(GREEN, 0.6) : LINE,
      });
      text(ctx, label, cx - rowW / 2 + 14, y + (1 - appear) * 8 + 19, { font: `12px ${MONO}`, color: on ? GREEN : MUTED });
      text(ctx, `item[${i}]`, cx + rowW / 2 - 14, y + (1 - appear) * 8 + 19, { font: `11px ${MONO}`, color: FAINT, align: "right" });
    }
    ctx.globalAlpha = fade;
  } else {
    const sy = top + 20;
    node(ctx, cf.switch_title, cx, sy, true, GREEN);
    const arms = cf.switch_arms;
    const active = Math.floor(local / 1.1) % Math.max(arms.length, 1);
    const armY = top + 120;
    const spread = 130;
    arms.forEach((label, i) => {
      const ax = cx + (i - (arms.length - 1) / 2) * spread;
      const on = i === active;
      ctx.save();
      ctx.strokeStyle = on ? withAlpha(GREEN, 0.7) : LINE_STRONG;
      ctx.lineWidth = on ? 1.5 : 1;
      if (on) {
        ctx.setLineDash([4, 4]);
        ctx.lineDashOffset = flow;
      }
      ctx.beginPath();
      ctx.moveTo(cx, sy + 15);
      ctx.bezierCurveTo(cx, sy + 60, ax, armY - 60, ax, armY - 15);
      ctx.stroke();
      ctx.restore();
      node(ctx, label, ax, armY, on, GREEN, { minW: 84 });
    });
  }

  // Snippet card.
  const snippet = scenes[idx].snippet;
  ctx.font = `12px ${MONO}`;
  const sw = Math.min(W, ctx.measureText(snippet).width + 32);
  panel(ctx, cx - sw / 2, 300, sw, 38, { r: 8 });
  codeLine(ctx, snippet, cx - sw / 2 + 16, 323, { size: 12 });
  ctx.globalAlpha = 1;
}

function drawHybrid(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const hy = data.hybrid;
  const BEAT = 3.0;
  const beat = Math.floor(t / BEAT) % 3;
  const local = t % BEAT;
  const W = 460;

  // Server.
  const sx = 0;
  const sy = 70;
  const sw = 136;
  const sh = 150;
  const serverOn = beat === 0;
  panel(ctx, sx, sy, sw, sh, {
    stroke: serverOn ? withAlpha(GREEN, 0.6) : LINE,
    glow: serverOn ? withAlpha(GREEN, 0.25) : undefined,
  });
  text(ctx, "SERVER", sx + 14, sy + 22, { font: `600 9.5px ${MONO}`, color: serverOn ? GREEN : FAINT });
  for (let i = 0; i < 3; i++) {
    const ry = sy + 36 + i * 18;
    rr(ctx, sx + 14, ry, sw - 28, 12, 3);
    ctx.fillStyle = "rgba(255,255,255,0.04)";
    ctx.fill();
    ctx.strokeStyle = LINE;
    ctx.stroke();
    const blink = serverOn && Math.floor(t * 4 + i) % 3 === 0;
    ctx.fillStyle = blink ? GREEN : withAlpha(GREEN, 0.35);
    ctx.beginPath();
    ctx.arc(sx + sw - 22, ry + 6, 2, 0, Math.PI * 2);
    ctx.fill();
  }
  hy.server_steps.forEach((s, i) => {
    const done = serverOn ? local > 0.3 + i * 0.5 : true;
    text(ctx, `${done ? "✓" : "·"} ${s}`, sx + 14, sy + 108 + i * 18, {
      font: `11px ${MONO}`,
      color: done ? (serverOn ? TEXT : MUTED) : FAINT,
    });
  });

  // Browser.
  const bx = 196;
  const by = 30;
  const bw = W - bx;
  const bh = 230;
  windowChrome(ctx, bx, by, bw, bh, "localhost:3000", {
    stroke: beat >= 1 ? withAlpha(CYAN, 0.45) : LINE_STRONG,
  });

  // Wire between server and browser.
  const wy = sy + sh / 2;
  line(ctx, { x: sx + sw, y: wy }, { x: bx, y: wy }, LINE_STRONG);
  if (beat === 0) {
    const p = easeInOut(progress(local, 0.9, 0.9));
    if (p > 0 && p < 1) {
      const px = sx + sw + p * (bx - sx - sw);
      ctx.save();
      ctx.shadowColor = withAlpha(GREEN, 0.6);
      ctx.shadowBlur = 14;
      pill(ctx, "HTML", px, wy - 9, GREEN, { filled: true, align: "center" });
      ctx.restore();
    }
  } else if (beat === 1) {
    const p = easeInOut(progress(local, 0.1, 0.7));
    if (p > 0 && p < 1) {
      const px = sx + sw + p * (bx - sx - sw);
      pill(ctx, "wasm", px, wy - 9, CYAN, { align: "center" });
    }
  }

  // Page content.
  const cx = bx + 18;
  const cy = by + 44;
  const cw = bw - 36;
  const pageA = beat === 0 ? easeOut(progress(local, 1.7, 0.5)) : 1;
  ctx.globalAlpha = pageA;
  ctx.fillStyle = "rgba(255,255,255,0.75)";
  ctx.fillRect(cx, cy, 90, 9);
  ctx.fillStyle = "rgba(255,255,255,0.09)";
  [0.92, 0.78, 0.85].forEach((f, i) => ctx.fillRect(cx, cy + 22 + i * 13, cw * f, 6));

  // Island.
  const ix = cx;
  const iy = cy + 72;
  const iw = cw;
  const ih = 88;
  const islandOn = beat >= 1;
  const hydrateP = beat === 1 ? easeOut(progress(local, 0.8, 0.6)) : beat === 2 ? 1 : 0;
  rr(ctx, ix, iy, iw, ih, 8);
  ctx.save();
  ctx.setLineDash(islandOn ? [] : [4, 4]);
  ctx.strokeStyle = islandOn ? withAlpha(CYAN, 0.35 + 0.4 * hydrateP) : LINE_STRONG;
  ctx.lineWidth = islandOn ? 1.25 : 1;
  if (islandOn) {
    ctx.shadowColor = withAlpha(CYAN, 0.4 * hydrateP);
    ctx.shadowBlur = 18;
  }
  ctx.stroke();
  ctx.restore();
  ctx.fillStyle = withAlpha(CYAN, 0.05 * hydrateP);
  ctx.fill();
  if (beat === 1) {
    const rp = progress(local, 0.8, 1.2);
    if (rp > 0 && rp < 1) {
      ctx.save();
      rr(ctx, ix, iy, iw, ih, 8);
      ctx.clip();
      ctx.strokeStyle = withAlpha(CYAN, 0.5 * (1 - rp));
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(ix + iw / 2, iy + ih / 2, rp * iw * 0.6, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
  }
  text(ctx, islandOn ? "client" : "static", ix + iw - 10, iy + 16, {
    font: `10px ${MONO}`,
    color: islandOn ? CYAN : FAINT,
    align: "right",
  });

  // Counter button.
  const clicks = beat === 2 ? Math.min(3, Math.floor(Math.max(0, local - 0.6) / 0.6)) : 0;
  const btnLabel = `${hy.button || "Click Me"}: ${clicks}`;
  ctx.font = `600 12px ${SANS}`;
  const btnW = ctx.measureText(btnLabel).width + 28;
  const btnX = ix + 14;
  const btnY = iy + 36;
  const pressed = beat === 2 && local > 0.6 && (local - 0.6) % 0.6 < 0.12;
  rr(ctx, btnX, btnY + (pressed ? 1 : 0), btnW, 30, 7);
  ctx.fillStyle = islandOn ? withAlpha(CYAN, pressed ? 0.3 : 0.18) : "rgba(255,255,255,0.06)";
  ctx.fill();
  ctx.strokeStyle = islandOn ? withAlpha(CYAN, 0.6) : LINE;
  ctx.stroke();
  text(ctx, btnLabel, btnX + btnW / 2, btnY + 20 + (pressed ? 1 : 0), {
    font: `600 12px ${SANS}`,
    color: islandOn ? CYAN : MUTED,
    align: "center",
  });
  ctx.globalAlpha = 1;

  if (beat === 2) {
    // Cursor glides onto the button, then clicks.
    const mp = easeInOut(progress(local, 0, 0.6));
    const tx = btnX + btnW * 0.7;
    const ty = btnY + 20;
    const mx = tx + (1 - mp) * 70;
    const my = ty + (1 - mp) * 40;
    ctx.save();
    ctx.translate(mx, my);
    ctx.fillStyle = WHITE;
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(0, 14);
    ctx.lineTo(3.5, 10.5);
    ctx.lineTo(6.5, 16);
    ctx.lineTo(8.5, 15);
    ctx.lineTo(5.5, 9.5);
    ctx.lineTo(10, 9.5);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  }

  // Footer: hint + caption.
  ctx.font = `11.5px ${MONO}`;
  const hw = ctx.measureText(hy.hint).width + 28;
  const hintOn = beat >= 1;
  panel(ctx, (W - hw) / 2, 282, hw, 30, { r: 7, stroke: hintOn ? withAlpha(CYAN, 0.4) : LINE });
  ctx.globalAlpha = hintOn ? 1 : 0.5;
  codeLine(ctx, hy.hint, (W - hw) / 2 + 14, 301, { size: 11.5 });
  ctx.globalAlpha = beatAlpha(local, BEAT, 0.3);
  text(ctx, hy.captions[beat] ?? "", W / 2, 338, { font: `12.5px ${SANS}`, color: MUTED, align: "center" });
  ctx.globalAlpha = 1;
}

function segs(ctx: Ctx, x: number, y: number, parts: [string, string, string?][]) {
  for (const [s, color, weight] of parts) {
    ctx.font = `${weight ?? 400} 12px ${MONO}`;
    ctx.fillStyle = color;
    ctx.fillText(s, x, y);
    x += ctx.measureText(s).width;
  }
}

function drawTooling(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const tl = data.tooling;
  if (tl.code.length === 0) return;
  const W = 460;
  const CYCLE = 7;
  const local = t % CYCLE;

  // Editor.
  const eh = 222;
  windowChrome(ctx, 0, 0, W, eh, "");
  rr(ctx, 54, 4, 120, 22, 5);
  ctx.fillStyle = "rgba(255,255,255,0.05)";
  ctx.fill();
  text(ctx, tl.file.split("/").pop() ?? tl.file, 66, 19, { font: `11px ${MONO}`, color: TEXT });
  ctx.fillStyle = GREEN;
  ctx.fillRect(54, 24, 120, 1.5);
  text(ctx, "zx lsp ●", W - 12, 18, { font: `10px ${MONO}`, color: withAlpha(GREEN, 0.8), align: "right" });

  const lh = 20;
  const codeTop = 48;
  const typeLine = tl.code.findIndex((l) => l.includes("@client"));
  const typeAt = typeLine >= 0 ? tl.code[typeLine].indexOf("@client") : -1;
  const typed = typeAt >= 0 ? Math.floor(clamp((local - 0.4) / 1.0) * 4) : 0;
  const accepted = local > 2.6;

  tl.code.forEach((src, i) => {
    const y = codeTop + i * lh;
    text(ctx, `${i + 1}`.padStart(2, " "), 12, y, { font: `11px ${MONO}`, color: i === typeLine ? MUTED : "rgba(255,255,255,0.2)" });
    if (i === typeLine) {
      rr(ctx, 34, y - 14, W - 42, 19, 3);
      ctx.fillStyle = "rgba(255,255,255,0.035)";
      ctx.fill();
    }
    let shown = src;
    if (i === typeLine && !accepted) {
      shown = src.slice(0, typeAt) + src.slice(typeAt, typeAt + 1 + typed);
    }
    const end = codeLine(ctx, shown, 40, y, { size: 11.5 });
    if (i === typeLine && !accepted && Math.floor(t * 2.2) % 2 === 0) {
      ctx.fillStyle = WHITE;
      ctx.fillRect(end + 1, y - 11, 1.5, 14);
    }
    if (i === typeLine && !accepted && local > 1.0) {
      // Completion popup.
      const pa = easeOut(progress(local, 1.0, 0.2));
      ctx.globalAlpha = pa;
      const px = Math.min(end - 20, W - 190);
      const py = y + 8;
      const items = tl.completions;
      panel(ctx, px, py, 180, items.length * 22 + 8, { r: 7, fill: "#181818", stroke: LINE_STRONG, glow: "rgba(0,0,0,0.6)", glowBlur: 20 });
      const sel = local > 2.0 ? 0 : Math.floor((local - 1.0) * 3) % items.length;
      items.forEach((it, j) => {
        const iy = py + 4 + j * 22;
        if (j === sel) {
          rr(ctx, px + 4, iy, 172, 22, 4);
          ctx.fillStyle = withAlpha(GREEN, 0.14);
          ctx.fill();
        }
        rr(ctx, px + 10, iy + 6, 10, 10, 2);
        ctx.fillStyle = withAlpha(it.startsWith("@") ? AMBER : CYAN, 0.25);
        ctx.fill();
        text(ctx, it, px + 28, iy + 15, { font: `11.5px ${MONO}`, color: j === sel ? WHITE : MUTED });
        if (j === sel) text(ctx, "attr", px + 168, iy + 15, { font: `10px ${MONO}`, color: FAINT, align: "right" });
      });
      ctx.globalAlpha = 1;
    }
  });

  // Terminal, mirroring `zx dev` output.
  const ty = eh + 14;
  const th = 112;
  panel(ctx, 0, ty, W, th, { fill: "#0d0d0d" });
  text(ctx, "TERMINAL", 14, ty + 20, { font: `600 9.5px ${MONO}`, color: FAINT });
  const row = (i: number) => ty + 44 + i * 18;
  const banner = (y: number) =>
    segs(ctx, 14, y, [
      ["Ziex", WHITE, "700"],
      [` - v${tl.version}`, FAINT],
      [` | ${tl.url}`, TEXT],
    ]);
  segs(ctx, 14, row(0), [["$ ", GREEN], [tl.command, TEXT]]);
  banner(row(1));
  const rebuildAt = 2.7;
  const restartAt = 3.3;
  if (local > rebuildAt && local <= restartAt) {
    const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    const f = frames[Math.floor(t * 12) % frames.length];
    segs(ctx, 14, row(2), [[`${f} `, CYAN], ["Rebuilding...", CYAN, "700"]]);
  } else if (local > restartAt) {
    ctx.globalAlpha = easeOut(progress(local, restartAt, 0.2));
    segs(ctx, 14, row(2), [["╭─", FAINT], ["[", FAINT], ["App Logs", VIOLET], ["]", FAINT], [` ↻ ${tl.restart_time}`, FAINT]]);
    banner(row(3));
    ctx.globalAlpha = 1;
  }
}

const ARTIFACT_COLORS: Record<string, string> = { binary: GREEN, wasi: CYAN, static: AMBER };

function drawDeploy(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const targets = data.deploy;
  const artifacts = data.deploy_artifacts;
  if (targets.length === 0 || artifacts.length === 0) return;
  const BEAT = 2.8;
  const ai = Math.floor(t / BEAT) % artifacts.length;
  const local = t % BEAT;
  const active = artifacts[ai];
  const H = 330;

  // Source.
  const srcW = 160;
  const srcH = 56;
  const srcY = H / 2 - srcH / 2 - 14;
  const srcColor = ARTIFACT_COLORS[active.id] ?? GREEN;
  panel(ctx, 0, srcY, srcW, srcH, { stroke: withAlpha(srcColor, 0.4), glow: withAlpha(srcColor, 0.15) });
  ctx.globalAlpha = beatAlpha(local, BEAT, 0.2);
  segs(ctx, 14, srcY + 24, [["$ ", srcColor], [active.command, WHITE, "600"]]);
  text(ctx, active.flag, 14, srcY + 42, { font: `11px ${MONO}`, color: MUTED });
  ctx.globalAlpha = 1;

  // Artifacts.
  const artX = 194;
  const artW = 112;
  const artH = 40;
  const artGap = 22;
  const artTop = H / 2 - 14 - (artifacts.length * artH + (artifacts.length - 1) * artGap) / 2;
  const artPos = artifacts.map((a, i) => ({ a, y: artTop + i * (artH + artGap) }));

  // Targets.
  const tgX = 328;
  const tgW = 132;
  const tgH = 28;
  const tgGap = 8;
  const tgTop = H / 2 - 14 - (targets.length * tgH + (targets.length - 1) * tgGap) / 2;

  artPos.forEach(({ a, y }) => {
    const on = a.id === active.id;
    const c = ARTIFACT_COLORS[a.id] ?? GREEN;
    const from = { x: srcW, y: srcY + srcH / 2 };
    const to = { x: artX, y: y + artH / 2 };
    curve(ctx, from, to, on ? withAlpha(c, 0.7) : LINE, { width: on ? 1.5 : 1, dash: on ? [4, 4] : undefined, offset: -t * 24 });
    if (on) {
      const p = easeInOut(progress(local, 0, 0.6));
      if (p > 0 && p < 1) {
        const pt = bezierPoint(from, to, p);
        glowDot(ctx, pt.x, pt.y, c, 2.5);
      }
    }
  });

  targets.forEach((tg, i) => {
    const y = tgTop + i * (tgH + tgGap);
    const ap = artPos.find((p) => p.a.id === tg.artifact);
    const on = tg.artifact === active.id;
    const c = ARTIFACT_COLORS[tg.artifact] ?? GREEN;
    if (ap) {
      const from = { x: artX + artW, y: ap.y + artH / 2 };
      const to = { x: tgX, y: y + tgH / 2 };
      curve(ctx, from, to, on ? withAlpha(c, 0.6) : "rgba(255,255,255,0.06)", { width: on ? 1.25 : 1 });
      if (on) {
        const p = easeInOut(progress(local, 0.55 + i * 0.04, 0.7));
        if (p > 0 && p < 1) {
          const pt = bezierPoint(from, to, p);
          glowDot(ctx, pt.x, pt.y, c, 2);
        }
      }
    }
    const lit = on ? easeOut(progress(local, 1.1, 0.3)) : 0;
    panel(ctx, tgX, y, tgW, tgH, {
      r: 7,
      fill: lit > 0 ? withAlpha(c, 0.08 * lit) : SURFACE_RAISED,
      stroke: on ? withAlpha(c, 0.25 + 0.4 * lit) : LINE,
    });
    ctx.fillStyle = on ? c : "rgba(255,255,255,0.2)";
    ctx.beginPath();
    ctx.arc(tgX + 13, y + tgH / 2, 3, 0, Math.PI * 2);
    ctx.fill();
    text(ctx, tg.name, tgX + 24, y + 18, { font: `${on ? 600 : 500} 12px ${SANS}`, color: on ? WHITE : MUTED });
  });

  artPos.forEach(({ a, y }) => {
    const on = a.id === active.id;
    const c = ARTIFACT_COLORS[a.id] ?? GREEN;
    panel(ctx, artX, y, artW, artH, {
      r: 8,
      fill: on ? withAlpha(c, 0.1) : SURFACE_RAISED,
      stroke: on ? withAlpha(c, 0.7) : LINE,
      glow: on ? withAlpha(c, 0.35) : undefined,
      glowBlur: 18,
    });
    text(ctx, a.label, artX + artW / 2, y + 25, { font: `600 12px ${MONO}`, color: on ? c : MUTED, align: "center" });
  });

  ctx.globalAlpha = beatAlpha(local, BEAT, 0.3);
  text(ctx, active.caption, 230, H - 2, { font: `12.5px ${SANS}`, color: MUTED, align: "center" });
  ctx.globalAlpha = 1;
}

function drawMemory(ctx: Ctx, t: number, data: FeatureCanvasData) {
  const mem = data.memory;
  if (mem.code.length === 0 || mem.allocs.length === 0) return;
  const W = 440;
  const CYCLE = 6.4;
  const local = t % CYCLE;
  const allocs = mem.allocs;
  const cap = mem.capacity || allocs.reduce((a, b) => a + b.size, 0);

  // Phase timeline: init, allocations, render, deinit.
  const allocStart = 0.6;
  const allocStep = 0.7;
  const deinitAt = allocStart + allocs.length * allocStep + 0.9;
  const freed = local > deinitAt;
  const allocated = allocs.filter((_, i) => local > allocStart + i * allocStep).length;

  let activeLine = 0;
  if (freed) activeLine = mem.code.length - 1;
  else if (allocated > 0) activeLine = Math.min(mem.code.length - 2, allocated);

  // Code panel.
  const lh = 22;
  const ch = 40 + mem.code.length * lh;
  windowChrome(ctx, 0, 0, W, ch, mem.file);
  mem.code.forEach((src, i) => {
    const y = 50 + i * lh;
    const on = i === activeLine;
    if (on) {
      rr(ctx, 8, y - 15, W - 16, 21, 4);
      ctx.fillStyle = withAlpha(freed ? ROSE : GREEN, 0.1);
      ctx.fill();
      ctx.fillStyle = freed ? ROSE : GREEN;
      ctx.fillRect(8, y - 11, 2, 13);
    }
    codeLine(ctx, src, 20, y, { size: 11, dim: !on });
  });

  // Arena strip.
  const sy = ch + 36;
  const sh = 40;
  text(ctx, "CTX.ARENA · PER REQUEST", 0, sy - 10, { font: `600 9.5px ${MONO}`, color: FAINT });
  panel(ctx, 0, sy, W, sh, { r: 8, fill: "#0e0e0e" });
  const inner = W - 12;
  let x = 6;
  let used = 0;
  allocs.forEach((a, i) => {
    const w = (a.size / cap) * inner;
    const appear = easeOut(progress(local, allocStart + i * allocStep, 0.35));
    const gone = freed ? 1 - easeOut(progress(local, deinitAt, 0.4)) : 1;
    const vis = appear * gone;
    if (vis > 0) {
      const colors = [GREEN, CYAN, VIOLET, AMBER];
      const c = colors[i % colors.length];
      ctx.globalAlpha = vis;
      rr(ctx, x, sy + 6, Math.max(2, (w - 3) * appear), sh - 12, 5);
      ctx.fillStyle = withAlpha(c, 0.22);
      ctx.fill();
      ctx.strokeStyle = withAlpha(c, 0.7);
      ctx.stroke();
      if (appear > 0.6) {
        ctx.font = `600 11px ${MONO}`;
        const roomy = w > ctx.measureText(a.label).width + 52;
        text(ctx, a.label, roomy ? x + 8 : x + w / 2 - 1.5, sy + 24, {
          font: `600 11px ${MONO}`,
          color: c,
          align: roomy ? "left" : "center",
        });
        if (roomy) {
          text(ctx, `${a.size}B`, x + w - 9, sy + 24, { font: `10px ${MONO}`, color: withAlpha(c, 0.7), align: "right" });
        }
      }
      ctx.globalAlpha = 1;
      used += a.size * vis;
    }
    x += w;
  });
  if (freed) {
    const fp = progress(local, deinitAt, 0.6);
    if (fp < 1) {
      ctx.save();
      ctx.globalAlpha = 1 - fp;
      ctx.strokeStyle = ROSE;
      ctx.lineWidth = 1.5;
      rr(ctx, 0.5, sy + 0.5, W - 1, sh - 1, 8);
      ctx.stroke();
      ctx.restore();
    }
  }

  // Usage meter.
  const my = sy + sh + 32;
  text(ctx, `${Math.round(used)} / ${cap} B`, 0, my, { font: `12px ${MONO}`, color: TEXT });
  text(ctx, freed ? "response sent, arena reset" : allocated > 0 ? "no hidden allocations" : "request started", W, my, {
    font: `12px ${SANS}`,
    color: freed ? ROSE : MUTED,
    align: "right",
  });
  rr(ctx, 0, my + 12, W, 4, 2);
  ctx.fillStyle = "rgba(255,255,255,0.06)";
  ctx.fill();
  rr(ctx, 0, my + 12, Math.max(0, (used / cap) * W), 4, 2);
  ctx.fillStyle = GREEN;
  ctx.fill();
}

const SCENES: Record<string, Scene> = {
  performance: { w: 440, h: 330, draw: drawPerformance },
  routing: { w: 440, h: 340, draw: drawRouting },
  "api-routes": { w: 420, h: 300, draw: drawApiRoutes },
  "control-flow": { w: 440, h: 340, draw: drawControlFlow },
  hybrid: { w: 460, h: 345, draw: drawHybrid },
  tooling: { w: 460, h: 348, draw: drawTooling },
  deploy: { w: 460, h: 335, draw: drawDeploy },
  memory: { w: 440, h: 310, draw: drawMemory },
};

const ACCENTS: Record<string, string> = { hybrid: CYAN, deploy: CYAN };

export function setupFeatureCanvases() {
  const canvases = Array.from(document.querySelectorAll<HTMLCanvasElement>(".feature-canvas"));
  if (canvases.length === 0) return;
  const data = loadCanvasData();
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const state = new Map<HTMLCanvasElement, { visible: boolean; running: boolean; raf: number; start: number }>();

  const resize = (canvas: HTMLCanvasElement) => {
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    const cw = Math.max(1, Math.round(rect.width * dpr));
    const ch = Math.max(1, Math.round(rect.height * dpr));
    if (canvas.width !== cw || canvas.height !== ch) {
      canvas.width = cw;
      canvas.height = ch;
    }
    return { w: rect.width, h: rect.height, dpr };
  };

  const drawOnce = (canvas: HTMLCanvasElement, t: number) => {
    const id = canvas.dataset.feature || "";
    const scene = SCENES[id];
    if (!scene) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const { w, h, dpr } = resize(canvas);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    backdrop(ctx, w, h, ACCENTS[id] ?? GREEN);
    const pad = Math.min(36, w * 0.06);
    const s = Math.min((w - pad * 2) / scene.w, (h - pad * 2) / scene.h, 1.2);
    ctx.save();
    ctx.translate((w - scene.w * s) / 2, (h - scene.h * s) / 2);
    ctx.scale(s, s);
    ctx.textBaseline = "alphabetic";
    // rAF timestamps can precede the recorded start, giving a negative t.
    scene.draw(ctx, Math.max(0, t), data);
    ctx.restore();
  };

  const stop = (canvas: HTMLCanvasElement) => {
    const s = state.get(canvas);
    if (!s) return;
    s.running = false;
    if (s.raf) cancelAnimationFrame(s.raf);
    s.raf = 0;
  };

  const start = (canvas: HTMLCanvasElement) => {
    const s = state.get(canvas);
    if (!s || s.running || reduced) return;
    s.running = true;
    s.start = performance.now();
    const tick = (now: number) => {
      if (!s.running || !s.visible) {
        s.running = false;
        return;
      }
      drawOnce(canvas, (now - s.start) / 1000);
      s.raf = requestAnimationFrame(tick);
    };
    s.raf = requestAnimationFrame(tick);
  };

  // Reduced motion gets a representative still frame instead of t=0.
  const still = reduced ? 2.4 : 0;
  canvases.forEach((canvas) => {
    state.set(canvas, { visible: false, running: false, raf: 0, start: 0 });
    drawOnce(canvas, still);
  });

  const redrawAll = () => {
    canvases.forEach((canvas) => {
      const s = state.get(canvas);
      drawOnce(canvas, reduced ? still : s && s.start ? (performance.now() - s.start) / 1000 : 0);
    });
  };
  window.addEventListener("resize", redrawAll);
  if (reduced) return;

  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const canvas = entry.target as HTMLCanvasElement;
        const s = state.get(canvas);
        if (!s) continue;
        s.visible = entry.isIntersecting && entry.intersectionRatio > 0.2;
        if (s.visible) start(canvas);
        else stop(canvas);
      }
    },
    { threshold: [0, 0.2, 0.5] },
  );
  canvases.forEach((canvas) => io.observe(canvas));
}
