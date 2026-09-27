import { createDocsSnippetFiles, createPlaygroundShareUrl } from "./playground_share";

const GREEN = "#4ade80";
const GREEN_DIM = "rgba(74, 222, 128, 0.45)";
const WHITE = "#ffffff";
const WHITE_DIM = "rgba(255, 255, 255, 0.55)";
const WHITE_SOFT = "rgba(255, 255, 255, 0.14)";
const CYAN = "#7dd3fc";

type PerfBar = { label: string; value: number; display: string; self?: boolean };
type RoutingScene = { file: string; kind: string; url: string; note: string };
type DeployTarget = { name: string; artifact: "wasi" | "binary" | string };
type ApiMethod = { method: string; path: string; status: string; body: string };
type ControlScene = { id: string; snippet: string };
type FeatureCanvasData = {
  performance: PerfBar[];
  routing: RoutingScene[];
  deploy: DeployTarget[];
  api: { file: string; handler: string; methods: ApiMethod[] };
  control_flow: {
    eyebrow: string;
    scenes: ControlScene[];
    if_arms: string[];
    for_item: string;
    for_count: number;
    switch_title: string;
    switch_arms: string[];
  };
  hybrid: {
    server_label: string;
    client_label: string;
    server_lines: string[];
    hydrate_lines: string[];
    rendering_hint: string;
    captions: string[];
  };
  tooling: { command: string; subtitle: string };
  deploy_captions: { wasi: string; binary: string };
  memory: { cols: number; rows: number; caption: string };
};

type DrawFn = (ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) => void;

function emptyCanvasData(): FeatureCanvasData {
  return {
    performance: [],
    routing: [],
    deploy: [],
    api: { file: "", handler: "", methods: [] },
    control_flow: {
      eyebrow: "",
      scenes: [],
      if_arms: [],
      for_item: "",
      for_count: 0,
      switch_title: "",
      switch_arms: [],
    },
    hybrid: {
      server_label: "server",
      client_label: "client",
      server_lines: [],
      hydrate_lines: [],
      rendering_hint: "",
      captions: ["", "", ""],
    },
    tooling: { command: "", subtitle: "" },
    deploy_captions: { wasi: "", binary: "" },
    memory: { cols: 5, rows: 3, caption: "" },
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

function getVisibleCodePanel(container: Element): HTMLElement | null {
  const panels = Array.from(container.querySelectorAll<HTMLElement>(".code-example-panel"));
  const containerRadios = Array.from(container.querySelectorAll<HTMLInputElement>(".code-example-tab-radio"));
  const checkedRadio = containerRadios.find((radio) => radio.checked);

  if (checkedRadio) {
    const checkedIndex = containerRadios.indexOf(checkedRadio);
    if (checkedIndex >= 0 && checkedIndex < panels.length) {
      return panels[checkedIndex];
    }
  }

  return panels.find((panel) => window.getComputedStyle(panel).display !== "none") || panels[0] || null;
}

function extractCodeFromPanel(panel: HTMLElement | null): string {
  if (!panel) return "";
  const codeElement = panel.querySelector("code");
  if (!codeElement) return "";
  return codeElement.textContent?.trim() || "";
}

function setupHomeCodeExampleButtons() {
  const buttons = document.querySelectorAll<HTMLButtonElement>(".code-example-open-playground");
  if (buttons.length === 0) return;

  buttons.forEach((button) => {
    button.addEventListener("click", async (event) => {
      event.preventDefault();
      const container = button.closest(".code-example, .code-preview-example");
      if (!container) return;

      let code = "";
      if (container.classList.contains("code-example--tabs")) {
        code = extractCodeFromPanel(getVisibleCodePanel(container));
      } else if (container.classList.contains("code-preview-example")) {
        const panel =
          container.querySelector<HTMLElement>(".code-preview-code .code-example-panel") ||
          container.querySelector<HTMLElement>("pre code");
        if (panel) code = panel.textContent?.trim() || "";
      }
      if (!code) return;

      const files = createDocsSnippetFiles(code, "example.zx");
      const url = await createPlaygroundShareUrl(files, `${window.location.origin}/playground`);
      window.open(url, "_blank", "noopener,noreferrer");
    });
  });
}

const MONO = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace";
const SANS = "system-ui, -apple-system, sans-serif";

function clear(ctx: CanvasRenderingContext2D, w: number, h: number) {
  ctx.clearRect(0, 0, w, h);
}

/** Sharp technical frame — corner ticks or hairline box, optional left accent. No soft fills. */
function frame(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  rw: number,
  rh: number,
  color: string,
  opts: { accent?: boolean; corners?: boolean } = {},
) {
  const { accent = false, corners = true } = opts;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  const c = Math.min(10, rw * 0.22, rh * 0.28);
  if (corners) {
    ctx.beginPath();
    ctx.moveTo(x, y + c);
    ctx.lineTo(x, y);
    ctx.lineTo(x + c, y);
    ctx.moveTo(x + rw - c, y);
    ctx.lineTo(x + rw, y);
    ctx.lineTo(x + rw, y + c);
    ctx.moveTo(x + rw, y + rh - c);
    ctx.lineTo(x + rw, y + rh);
    ctx.lineTo(x + rw - c, y + rh);
    ctx.moveTo(x + c, y + rh);
    ctx.lineTo(x, y + rh);
    ctx.lineTo(x, y + rh - c);
    ctx.stroke();
  } else {
    ctx.strokeRect(x + 0.5, y + 0.5, rw - 1, rh - 1);
  }
  if (accent) {
    ctx.fillStyle = color;
    ctx.fillRect(x, y, 2, rh);
  }
}

function chip(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  label: string,
  on: boolean,
  color: string,
) {
  ctx.font = `12px ${MONO}`;
  const tw = ctx.measureText(label).width;
  const padX = 10;
  const bw = tw + padX * 2;
  const bh = 28;
  const bx = x - bw / 2;
  const by = y;
  if (on) {
    frame(ctx, bx, by, bw, bh, color, { accent: true, corners: false });
    ctx.fillStyle = color;
  } else {
    ctx.strokeStyle = WHITE_SOFT;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(bx, by + bh);
    ctx.lineTo(bx + bw, by + bh);
    ctx.stroke();
    ctx.fillStyle = WHITE_SOFT;
  }
  ctx.textAlign = "center";
  ctx.fillText(label, x, by + 18);
}

function drawPerformance(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const bars = data.performance.slice(0, 4);
  if (bars.length === 0) return;

  const max = Math.max(...bars.map((b) => b.value), 1);
  const blockW = Math.min(360, w * 0.72);
  const rowH = 42;
  const gap = 12;
  const blockH = bars.length * (rowH + gap) - gap + 28;
  const left = (w - blockW) / 2;
  const top = (h - blockH) / 2;
  const barMax = blockW * 0.62;
  const labelW = blockW * 0.28;

  ctx.fillStyle = WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.fillText("req/sec", left + labelW, top);

  bars.forEach((bar, i) => {
    const y = top + 22 + i * (rowH + gap);
    const progress = Math.min(1, Math.max(0, (t - i * 0.12) / 0.65));
    const eased = 1 - Math.pow(1 - progress, 3);
    const bw = Math.max(4, (bar.value / max) * barMax * eased);
    const barX = left + labelW;

    ctx.fillStyle = bar.self ? WHITE : WHITE_DIM;
    ctx.font = `500 13px ${SANS}`;
    ctx.textAlign = "right";
    ctx.fillText(bar.label, barX - 12, y + 18);
    ctx.textAlign = "left";

    ctx.fillStyle = "rgba(255,255,255,0.06)";
    ctx.fillRect(barX, y + 8, barMax, 6);

    ctx.fillStyle = bar.self ? GREEN : "rgba(255,255,255,0.28)";
    ctx.fillRect(barX, y + 8, bw, 6);

    ctx.fillStyle = bar.self ? GREEN : WHITE_DIM;
    ctx.font = `12px ${MONO}`;
    ctx.fillText(bar.display, barX + barMax + 10, y + 16);
  });
}

function drawRouting(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const scenes = data.routing;
  if (scenes.length === 0) return;
  const idx = Math.floor(t / 2.2) % scenes.length;
  const scene = scenes[idx];
  const fade = Math.min(1, (t % 2.2) / 0.25);

  const lineH = 28;
  const colGap = 56;
  const leftColW = 150;
  const rightColW = 120;
  const blockW = leftColW + colGap + rightColW;
  const blockH = 24 + scenes.length * lineH;
  const ox = (w - blockW) / 2;
  const oy = (h - blockH) / 2;
  const left = ox;
  const right = ox + leftColW + colGap;

  ctx.fillStyle = WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.fillText("pages/", left, oy + 10);
  ctx.fillText("route", right, oy + 10);

  const listTop = oy + 28;
  scenes.forEach((s, i) => {
    const y = listTop + i * lineH;
    const active = i === idx;
    ctx.globalAlpha = active ? fade : 0.35;
    ctx.fillStyle = active ? GREEN : WHITE_DIM;
    ctx.font = `${active ? "600" : "400"} 13px ${MONO}`;
    ctx.fillText(s.file, left, y + 14);
    if (active) {
      ctx.fillStyle = GREEN;
      ctx.fillRect(left - 10, y + 2, 3, 16);
    }
  });

  ctx.globalAlpha = fade;
  const ay = listTop + idx * lineH + 8;
  ctx.strokeStyle = GREEN_DIM;
  ctx.lineWidth = 1.25;
  ctx.beginPath();
  ctx.moveTo(left + leftColW + 4, ay);
  ctx.lineTo(right - 12, ay);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(right - 18, ay - 4);
  ctx.lineTo(right - 12, ay);
  ctx.lineTo(right - 18, ay + 4);
  ctx.stroke();

  ctx.fillStyle = WHITE;
  ctx.font = `600 22px ${MONO}`;
  ctx.fillText(scene.url, right, ay + 6);
  ctx.fillStyle = GREEN_DIM;
  ctx.font = `12px ${SANS}`;
  ctx.fillText(scene.note, right, ay + 28);
  ctx.globalAlpha = 1;
}

function drawApiRoutes(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const methods = data.api.methods;
  if (methods.length === 0) return;
  const idx = Math.floor(t / 2.6) % methods.length;
  const local = t % 2.6;
  const fade = Math.min(1, local / 0.22);
  const req = methods[idx];

  const cardW = Math.min(300, w * 0.68);
  const cardH = 148;
  const ox = (w - cardW) / 2;
  const oy = (h - cardH) / 2;

  ctx.globalAlpha = fade;
  ctx.fillStyle = WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.fillText(data.api.file, ox, oy + 14);

  frame(ctx, ox, oy + 28, cardW, 48, GREEN, { accent: true, corners: true });

  ctx.fillStyle = GREEN;
  ctx.font = `600 13px ${MONO}`;
  ctx.fillText(req.method, ox + 16, oy + 48);
  ctx.fillStyle = WHITE;
  ctx.font = `14px ${MONO}`;
  ctx.fillText(req.path, ox + 16 + ctx.measureText(req.method).width + 14, oy + 48);
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `11px ${MONO}`;
  ctx.fillText(data.api.handler, ox + 16, oy + 66);

  const p = Math.min(1, Math.max(0, (local - 0.35) / 1.1));
  const trackY = oy + 96;
  ctx.strokeStyle = WHITE_SOFT;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(ox + 8, trackY);
  ctx.lineTo(ox + cardW - 8, trackY);
  ctx.stroke();

  if (p > 0) {
    const px = ox + 8 + p * (cardW - 16);
    ctx.fillStyle = GREEN;
    ctx.fillRect(px - 2, trackY - 2, 4, 4);
  }

  if (p > 0.55) {
    ctx.fillStyle = GREEN;
    ctx.font = `11px ${MONO}`;
    ctx.fillText(req.status, ox + 16, oy + 128);
    if (req.body) {
      ctx.fillStyle = WHITE_DIM;
      ctx.font = `12px ${MONO}`;
      ctx.fillText(req.body, ox + 56, oy + 128);
    }
  }
  ctx.globalAlpha = 1;
}

function drawControlFlow(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const cf = data.control_flow;
  const scenes = cf.scenes;
  if (scenes.length === 0) return;
  const idx = Math.floor(t / 3.0) % scenes.length;
  const local = t % 3.0;
  const kind = scenes[idx].id;
  const cx = w * 0.5;
  const cy = h * 0.5;
  const fade = Math.min(1, local / 0.22);

  ctx.fillStyle = WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.textAlign = "center";
  ctx.fillText(cf.eyebrow, cx, cy - 128);

  const tabLabels = scenes.map((s) => s.id);
  ctx.font = `12px ${MONO}`;
  const tabGap = 36;
  const tabWidths = tabLabels.map((l) => ctx.measureText(l).width);
  const tabsW = tabWidths.reduce((a, b) => a + b, 0) + tabGap * (tabLabels.length - 1);
  let tabX = cx - tabsW / 2;
  const tabY = cy - 104;
  tabLabels.forEach((label, i) => {
    const active = i === idx;
    ctx.fillStyle = active ? GREEN : WHITE_SOFT;
    ctx.textAlign = "left";
    ctx.fillText(label, tabX, tabY);
    if (active) ctx.fillRect(tabX, tabY + 6, tabWidths[i], 1.5);
    tabX += tabWidths[i] + tabGap;
  });

  ctx.globalAlpha = fade;
  ctx.textAlign = "center";

  if (kind === "if") {
    const branch = Math.floor(local * 0.65) % 2 === 0;
    ctx.strokeStyle = GREEN;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(cx, cy - 40);
    ctx.lineTo(cx + 32, cy - 4);
    ctx.lineTo(cx, cy + 32);
    ctx.lineTo(cx - 32, cy - 4);
    ctx.closePath();
    ctx.stroke();
    ctx.fillStyle = WHITE;
    ctx.font = `12px ${MONO}`;
    ctx.fillText("if", cx, cy - 1);

    ctx.strokeStyle = WHITE_SOFT;
    ctx.lineWidth = 1.25;
    ctx.beginPath();
    ctx.moveTo(cx - 32, cy - 4);
    ctx.lineTo(cx - 100, cy - 4);
    ctx.lineTo(cx - 100, cy + 40);
    ctx.moveTo(cx + 32, cy - 4);
    ctx.lineTo(cx + 100, cy - 4);
    ctx.lineTo(cx + 100, cy + 40);
    ctx.stroke();

    const leftArm = cf.if_arms[0] || "<Ok/>";
    const rightArm = cf.if_arms[1] || "<Err/>";
    chip(ctx, cx - 100, cy + 40, leftArm, branch, GREEN);
    chip(ctx, cx + 100, cy + 40, rightArm, !branch, GREEN);
  } else if (kind === "for") {
    ctx.strokeStyle = GREEN;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(cx, cy - 12, 38, -Math.PI * 0.15, Math.PI * 1.5);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cx + 30, cy - 34);
    ctx.lineTo(cx + 38, cy - 24);
    ctx.lineTo(cx + 24, cy - 22);
    ctx.stroke();
    ctx.fillStyle = WHITE;
    ctx.font = `12px ${MONO}`;
    ctx.fillText("for", cx, cy - 8);

    const count = Math.max(1, cf.for_count || 3);
    const rowLabel = cf.for_item || "<Row/>";
    ctx.font = `12px ${MONO}`;
    const rowTw = ctx.measureText(rowLabel).width;
    const rowBw = Math.max(rowTw + 36, 72);
    const rowGap = 12;
    const rowSpan = count * rowBw + (count - 1) * rowGap;
    const activeItem = Math.floor(local * 1.6) % count;
    for (let i = 0; i < count; i++) {
      const x = cx - rowSpan / 2 + i * (rowBw + rowGap) + rowBw / 2;
      chip(ctx, x, cy + 30, rowLabel, i === activeItem, GREEN);
    }
  } else {
    ctx.fillStyle = WHITE;
    ctx.font = `12px ${MONO}`;
    ctx.fillText(cf.switch_title, cx, cy - 44);

    const arms = cf.switch_arms;
    const activeArm = Math.floor(local * 1.1) % Math.max(arms.length, 1);
    arms.forEach((label, i) => {
      const x = cx - 96 + i * 96;
      ctx.strokeStyle = i === activeArm ? GREEN_DIM : WHITE_SOFT;
      ctx.lineWidth = 1.25;
      ctx.beginPath();
      ctx.moveTo(cx, cy - 32);
      ctx.lineTo(x, cy + 12);
      ctx.stroke();
      chip(ctx, x, cy + 12, label, i === activeArm, GREEN);
    });
  }

  ctx.globalAlpha = Math.min(1, fade + 0.15);
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `11px ${MONO}`;
  ctx.fillText(scenes[idx].snippet, cx, cy + 108);
  ctx.globalAlpha = 1;
  ctx.textAlign = "left";
}

function drawHybrid(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const hy = data.hybrid;
  const beat = Math.floor(t / 2.4) % 3;
  const local = t % 2.4;
  const fade = Math.min(1, local / 0.2);
  const cardW = Math.min(132, w * 0.28);
  const cardH = 112;
  const gap = Math.min(56, w * 0.1);
  const totalW = cardW * 2 + gap;
  const ox = (w - totalW) / 2;
  const oy = (h - cardH) / 2 - 16;
  const left = ox;
  const right = ox + cardW + gap;
  const midY = oy + cardH / 2;
  const captions = hy.captions.length >= 3 ? hy.captions : ["", "", ""];

  const serverOn = beat === 0;
  const clientOn = beat >= 1;

  ctx.globalAlpha = fade;
  frame(ctx, left, oy, cardW, cardH, serverOn ? GREEN : WHITE_SOFT, {
    accent: serverOn,
    corners: true,
  });
  ctx.fillStyle = serverOn ? GREEN : WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.fillText(hy.server_label, left + 14, oy + 22);
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `12px ${MONO}`;
  if (hy.server_lines[0]) ctx.fillText(hy.server_lines[0], left + 14, oy + 50);
  if (hy.server_lines[1]) ctx.fillText(hy.server_lines[1], left + 14, oy + 72);
  ctx.fillStyle = WHITE_SOFT;
  ctx.font = `10px ${MONO}`;
  if (hy.server_lines[2]) ctx.fillText(hy.server_lines[2], left + 14, oy + 96);

  frame(ctx, right, oy, cardW, cardH, clientOn ? CYAN : WHITE_SOFT, {
    accent: clientOn && beat === 2,
    corners: true,
  });
  ctx.fillStyle = clientOn ? CYAN : WHITE_SOFT;
  ctx.font = `11px ${MONO}`;
  ctx.fillText(hy.client_label, right + 14, oy + 22);

  ctx.strokeStyle = WHITE_SOFT;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(left + cardW + 4, midY);
  ctx.lineTo(right - 4, midY);
  ctx.stroke();

  if (beat === 0) {
    const p = Math.min(1, local / 1.4);
    const px = left + cardW + 6 + p * (gap - 12);
    ctx.fillStyle = GREEN;
    ctx.fillRect(px - 22, midY - 9, 44, 18);
    ctx.fillStyle = "#04140a";
    ctx.font = `10px ${MONO}`;
    ctx.textAlign = "center";
    ctx.fillText("HTML", px, midY + 4);

    ctx.fillStyle = WHITE_DIM;
    ctx.font = `12px ${SANS}`;
    ctx.fillText(captions[0], w / 2, oy + cardH + 36);
  } else if (beat === 1) {
    const p = Math.min(1, local / 1.2);
    ctx.strokeStyle = GREEN_DIM;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(left + cardW + 4, midY);
    ctx.lineTo(left + cardW + 4 + p * (gap - 8), midY);
    ctx.stroke();
    ctx.setLineDash([]);

    ctx.fillStyle = WHITE;
    ctx.font = `12px ${MONO}`;
    ctx.textAlign = "left";
    if (hy.hydrate_lines[0]) ctx.fillText(hy.hydrate_lines[0], right + 14, oy + 56);
    ctx.fillStyle = GREEN_DIM;
    ctx.font = `10px ${MONO}`;
    if (hy.hydrate_lines[1]) ctx.fillText(hy.hydrate_lines[1], right + 14, oy + 76);

    ctx.fillStyle = WHITE_DIM;
    ctx.font = `12px ${SANS}`;
    ctx.textAlign = "center";
    ctx.fillText(captions[1], w / 2, oy + cardH + 36);
  } else {
    const count = Math.floor(local * 1.8) % 6;
    frame(ctx, right + 14, oy + 42, cardW - 28, 36, CYAN, { accent: true, corners: false });
    ctx.fillStyle = CYAN;
    ctx.font = `13px ${MONO}`;
    ctx.textAlign = "center";
    ctx.fillText(`count ${count}`, right + cardW / 2, oy + 65);

    ctx.fillStyle = WHITE_SOFT;
    ctx.font = `10px ${MONO}`;
    ctx.textAlign = "left";
    ctx.fillText(hy.rendering_hint, left + 14, oy + 96);

    ctx.fillStyle = WHITE_DIM;
    ctx.font = `12px ${SANS}`;
    ctx.textAlign = "center";
    ctx.fillText(captions[2], w / 2, oy + cardH + 36);
  }

  ctx.globalAlpha = 1;
  ctx.textAlign = "left";
}

function drawDeploy(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const platforms = data.deploy;
  if (platforms.length === 0) return;

  const targets: DeployTarget[] = platforms.map((p: DeployTarget | string) =>
    typeof p === "string"
      ? {
          name: p,
          artifact: /cloudflare|vercel|wasi|edge/i.test(p) ? ("wasi" as const) : ("binary" as const),
        }
      : p,
  );

  const cycle = Math.floor(t / 2.2) % targets.length;
  const local = t % 2.2;
  const fade = Math.min(1, local / 0.25);
  const active = targets[cycle];
  const cx = w * 0.5;
  const cy = h * 0.48;
  const orbitRx = Math.min(w * 0.28, 128);
  const orbitRy = Math.min(h * 0.26, 108);
  const hubW = 104;
  const hubH = 68;
  const artifact = active.artifact;
  const isWasi = artifact === "wasi";

  // Point on axis-aligned rect border in direction (dx, dy) from center
  const edgePoint = (ex: number, ey: number, hw: number, hh: number, dx: number, dy: number) => {
    const ax = Math.abs(dx);
    const ay = Math.abs(dy);
    if (ax < 1e-6 && ay < 1e-6) return { x: ex, y: ey };
    const scale = Math.min(hw / Math.max(ax, 1e-6), hh / Math.max(ay, 1e-6));
    return { x: ex + dx * scale, y: ey + dy * scale };
  };

  ctx.strokeStyle = isWasi ? CYAN : GREEN_DIM;
  ctx.lineWidth = 1;
  frame(ctx, cx - hubW / 2, cy - hubH / 2, hubW, hubH, isWasi ? CYAN : GREEN, {
    accent: true,
    corners: true,
  });
  ctx.fillStyle = isWasi ? CYAN : GREEN;
  ctx.font = `11px ${MONO}`;
  ctx.textAlign = "center";
  ctx.fillText("artifact", cx, cy - 10);
  ctx.fillStyle = WHITE;
  ctx.font = `600 15px ${MONO}`;
  ctx.fillText(artifact, cx, cy + 16);

  const layout = targets.map((target, i) => {
    const angle = -Math.PI / 2 + (i / targets.length) * Math.PI * 2;
    const dx = Math.cos(angle);
    const dy = Math.sin(angle);
    const tx = cx + dx * orbitRx;
    const ty = cy + dy * orbitRy;
    ctx.font = `600 12px ${SANS}`;
    const nameW = ctx.measureText(target.name).width;
    ctx.font = `10px ${MONO}`;
    const tagW = ctx.measureText(target.artifact).width;
    const boxW = Math.max(nameW, tagW) + 22;
    const boxH = 38;
    const start = edgePoint(cx, cy, hubW / 2 + 2, hubH / 2 + 2, dx, dy);
    const end = edgePoint(tx, ty, boxW / 2 + 6, boxH / 2 + 6, -dx, -dy);
    return { target, tx, ty, boxW, boxH, start, end, dx, dy };
  });

  layout.forEach((item, i) => {
    const on = i === cycle;
    const wasi = item.target.artifact === "wasi";
    const color = wasi ? CYAN : GREEN;
    const { tx, ty, boxW, boxH, start, end } = item;

    ctx.globalAlpha = on ? fade : 0.35;
    ctx.strokeStyle = on ? color : WHITE_SOFT;
    ctx.lineWidth = on ? 1.5 : 1;
    ctx.beginPath();
    ctx.moveTo(start.x, start.y);
    ctx.lineTo(end.x, end.y);
    ctx.stroke();

    if (on) {
      const p = Math.min(1, local / 1.3);
      const px = start.x + (end.x - start.x) * p;
      const py = start.y + (end.y - start.y) * p;
      ctx.fillStyle = color;
      ctx.fillRect(px - 2, py - 2, 4, 4);
    }

    const bx = tx - boxW / 2;
    const by = ty - boxH / 2;
    if (on) {
      frame(ctx, bx, by, boxW, boxH, color, { accent: true, corners: false });
      ctx.fillStyle = color;
    } else {
      ctx.fillStyle = WHITE_DIM;
    }
    ctx.font = `${on ? "600" : "400"} 12px ${SANS}`;
    ctx.textAlign = "center";
    ctx.fillText(item.target.name, tx, ty - 4);
    ctx.font = `10px ${MONO}`;
    ctx.fillStyle = on ? color : WHITE_SOFT;
    ctx.fillText(item.target.artifact, tx, ty + 12);
  });

  ctx.globalAlpha = 1;
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `12px ${SANS}`;
  ctx.textAlign = "center";
  ctx.fillText(
    isWasi ? data.deploy_captions.wasi : data.deploy_captions.binary,
    cx,
    cy + orbitRy + 42,
  );
  ctx.textAlign = "left";
}

function drawTooling(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const line1 = data.tooling.command;
  const line2 = data.tooling.subtitle;
  if (!line1) return;
  ctx.font = `15px ${MONO}`;
  const w1 = ctx.measureText(line1).width;
  ctx.font = `13px ${SANS}`;
  const w2 = ctx.measureText(line2).width;
  const blockW = Math.max(w1, w2);
  const ox = (w - blockW) / 2;
  const oy = h * 0.5 - 12;

  ctx.fillStyle = GREEN;
  ctx.font = `15px ${MONO}`;
  ctx.fillText(line1, ox, oy);
  if (Math.floor(t * 2) % 2 === 0) {
    ctx.fillRect(ox + w1 + 6, oy - 14, 8, 16);
  }
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `13px ${SANS}`;
  ctx.fillText(line2, ox, oy + 36);
}

function drawMemory(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, data: FeatureCanvasData) {
  clear(ctx, w, h);
  const cols = data.memory.cols || 5;
  const rows = data.memory.rows || 3;
  const cell = Math.min(36, w * 0.08);
  const gap = 10;
  const gridW = cols * cell + (cols - 1) * gap;
  const gridH = rows * cell + (rows - 1) * gap;
  const captionH = 28;
  const ox = (w - gridW) / 2;
  const oy = (h - gridH - captionH) / 2;
  const filled = Math.floor((Math.sin(t * 0.65) * 0.5 + 0.5) * cols * rows);

  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const i = r * cols + c;
      const x = ox + c * (cell + gap);
      const y = oy + r * (cell + gap);
      const active = i < filled;
      ctx.strokeStyle = active ? GREEN : WHITE_SOFT;
      ctx.lineWidth = 1;
      ctx.strokeRect(x + 0.5, y + 0.5, cell - 1, cell - 1);
      if (active) {
        ctx.fillStyle = GREEN;
        ctx.fillRect(x + 3, y + 3, cell - 6, cell - 6);
      }
    }
  }
  ctx.fillStyle = WHITE_DIM;
  ctx.font = `12px ${SANS}`;
  ctx.textAlign = "center";
  ctx.fillText(data.memory.caption, w / 2, oy + gridH + 24);
  ctx.textAlign = "left";
}

const FEATURE_DRAWERS: Record<string, DrawFn> = {
  performance: drawPerformance,
  routing: drawRouting,
  "api-routes": drawApiRoutes,
  hybrid: drawHybrid,
  "control-flow": drawControlFlow,
  tooling: drawTooling,
  deploy: drawDeploy,
  memory: drawMemory,
};

function setupFeatureCanvases() {
  const canvases = Array.from(document.querySelectorAll<HTMLCanvasElement>(".feature-canvas"));
  if (canvases.length === 0) return;
  const data = loadCanvasData();
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const state = new Map<HTMLCanvasElement, { visible: boolean; running: boolean; raf: number; start: number }>();

  const resize = (canvas: HTMLCanvasElement) => {
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const cw = Math.max(1, Math.floor(rect.width * dpr));
    const ch = Math.max(1, Math.floor(rect.height * dpr));
    if (canvas.width !== cw || canvas.height !== ch) {
      canvas.width = cw;
      canvas.height = ch;
    }
    return { w: rect.width, h: rect.height, dpr };
  };

  const drawOnce = (canvas: HTMLCanvasElement, t: number) => {
    const id = canvas.dataset.feature || "";
    const drawer = FEATURE_DRAWERS[id];
    if (!drawer) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const { w, h, dpr } = resize(canvas);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawer(ctx, w, h, t, data);
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

  canvases.forEach((canvas) => {
    state.set(canvas, { visible: false, running: false, raf: 0, start: 0 });
    drawOnce(canvas, 0);
  });
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
  window.addEventListener("resize", () => {
    canvases.forEach((canvas) => {
      const s = state.get(canvas);
      drawOnce(canvas, s ? (performance.now() - s.start) / 1000 : 0);
    });
  });
}

function setupFeatureStack() {
  const stack = document.querySelector<HTMLElement>(".features-stack");
  if (!stack) return;
  const panels = Array.from(stack.querySelectorAll<HTMLElement>(".feature-panel"));
  const navItems = Array.from(stack.querySelectorAll<HTMLElement>(".features-nav-item"));
  const navButtons = Array.from(stack.querySelectorAll<HTMLButtonElement>(".features-nav-btn"));
  if (panels.length === 0) return;

  let activeIndex = -1;
  const setActive = (index: number) => {
    if (index === activeIndex) return;
    activeIndex = index;
    navItems.forEach((item, i) => {
      const active = i === index;
      item.classList.toggle("is-active", active);
      const btn = item.querySelector<HTMLButtonElement>(".features-nav-btn");
      if (!btn) return;
      if (active) btn.setAttribute("aria-current", "true");
      else btn.removeAttribute("aria-current");
    });
  };
  setActive(0);

  navButtons.forEach((button) => {
    button.addEventListener("click", () => {
      const targetId = button.getAttribute("data-feature-target");
      if (!targetId) return;
      document.getElementById(targetId)?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  });

  if (!("IntersectionObserver" in window)) return;
  const ratios = new Map<Element, number>();
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        ratios.set(entry.target, entry.isIntersecting ? entry.intersectionRatio : 0);
      }
      let bestIndex = 0;
      let bestRatio = -1;
      panels.forEach((panel, index) => {
        const ratio = ratios.get(panel) ?? 0;
        if (ratio > bestRatio) {
          bestRatio = ratio;
          bestIndex = index;
        }
      });
      if (bestRatio > 0) setActive(bestIndex);
    },
    {
      root: null,
      threshold: Array.from({ length: 21 }, (_, i) => i / 20),
      rootMargin: "-30% 0px -40% 0px",
    },
  );
  panels.forEach((panel) => observer.observe(panel));
}

document.addEventListener("DOMContentLoaded", () => {
  setupHomeCodeExampleButtons();
  setupFeatureStack();
  setupFeatureCanvases();
});
