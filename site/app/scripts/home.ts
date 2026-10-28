import {
  createDocsSnippetFilesFromEntries,
  createPlaygroundShareUrl,
  isPlaygroundOpenable,
  type SnippetEntry,
} from "./playground_share";

import { setupFeatureCanvases } from "./feature_canvas";

// Side-effect scripts: copy buttons, the section runners and Ziggy (the last two from the branding repo).
import "../assets/clipboard";
import "@branding/runner";
import "@branding/ziggy-crawler";

declare global {
  interface Window {
    ZiggyCrawler: {
      attach(target: Element, options: { src: string; size?: number }): unknown;
    };
  }
}

const ZIGGY_SRC = "/assets/branding/mascots/ziggy/ziggy-animated.svg";
const ZIGGY_WINDOWS = "#control-flow-tabs, .code-preview-example";

function setupZiggy() {
  for (const el of document.querySelectorAll(ZIGGY_WINDOWS)) {
    Promise.resolve(window.ZiggyCrawler.attach(el, { src: ZIGGY_SRC, size: 72 })).catch((err) => console.warn(err));
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

function filenameFromSection(section: string | undefined, fallback: string): string {
  if (!section) return fallback;
  const lower = section.toLowerCase();
  if (lower.includes("layout")) return "layout.zx";
  if (lower.includes("websocket")) return "routes/ws/route.zig";
  if (lower.includes("api route") || /(^|:\s*)route\b/.test(lower)) return "route.zig";
  if (lower.includes("dynamic path")) return "pages/[id]/page.zx";
  if (lower.endsWith(": page") || lower.includes("routing: page")) return "page.zx";
  if (lower.includes("client-side")) return "page.zx";
  return fallback;
}

function filenameFromTitle(title: string | null | undefined): string {
  const raw = (title ?? "").trim();
  if (!raw) return "example.zx";
  return raw;
}

function collectHomeSnippetEntries(container: Element): SnippetEntry[] {
  const title = container.querySelector(".code-example-title")?.textContent?.trim() ?? "";

  if (container.classList.contains("code-example--tabs")) {
    const panels = Array.from(container.querySelectorAll<HTMLElement>(".code-example-panel"));
    const labels = Array.from(container.querySelectorAll<HTMLLabelElement>(".code-example-tab-label"));
    const entries: SnippetEntry[] = [];

    for (let i = 0; i < panels.length; i++) {
      const panel = panels[i];
      const code = extractCodeFromPanel(panel);
      if (!code) continue;
      const section = panel.dataset.section;
      const label = labels[i]?.textContent?.trim() ?? "example";
      const filename = filenameFromSection(section, `${label.toLowerCase().replace(/\s+/g, "-")}.zx`);
      entries.push({ code, filename });
    }

    const hasPageFile = entries.some((e) => e.filename === "page.zx");
    const hasLayoutFile = entries.some((e) => e.filename === "layout.zx");
    // File-system routing demos ship page + layout together; open both in app mode.
    if (hasPageFile && hasLayoutFile) {
      return entries.filter((e) => e.filename === "page.zx" || e.filename === "layout.zx");
    }

    const visible = getVisibleCodePanel(container);
    if (!visible) return entries.slice(0, 1);
    const code = extractCodeFromPanel(visible);
    if (!code) return [];
    const section = visible.dataset.section;
    const idx = panels.indexOf(visible);
    const label = labels[idx]?.textContent?.trim() ?? "example";
    return [
      {
        code,
        filename: filenameFromSection(section, `${label.toLowerCase().replace(/\s+/g, "-")}.zx`),
      },
    ];
  }

  if (container.classList.contains("code-preview-example")) {
    const panel =
      container.querySelector<HTMLElement>(".code-preview-code .code-example-panel") ||
      container.querySelector<HTMLElement>("pre code");
    const code = panel?.textContent?.trim() || "";
    if (!code) return [];
    return [{ code, filename: filenameFromTitle(title) || "page.zx" }];
  }

  const code = container.querySelector("pre code")?.textContent?.trim() || "";
  if (!code) return [];
  return [{ code, filename: filenameFromTitle(title) }];
}

function setupHomeCodeExampleButtons() {
  const buttons = document.querySelectorAll<HTMLButtonElement>(".code-example-open-playground");
  if (buttons.length === 0) return;

  buttons.forEach((button) => {
    button.addEventListener("click", async (event) => {
      event.preventDefault();
      const container = button.closest(".code-example, .code-preview-example");
      if (!container) return;

      const entries = collectHomeSnippetEntries(container).filter((entry) =>
        isPlaygroundOpenable(entry.filename, entry.code)
      );
      if (entries.length === 0) return;

      const files = createDocsSnippetFilesFromEntries(entries);
      const url = await createPlaygroundShareUrl(files, `${window.location.origin}/playground`);
      window.open(url, "_blank", "noopener,noreferrer");
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
  setupZiggy();
});
