import "../assets/clipboard";
import {
  createDocsSnippetFilesFromEntries,
  createPlaygroundShareUrl,
  isPlaygroundOpenable,
  type SnippetEntry,
} from "./playground_share";
import { setupDocsSearch } from "./search";
// import "./routing";

// Dynamic import to reduce initial bundle size
async function formatHTML(html: string, printWidth: number): Promise<string> {
  const prettier = await import("prettier");
  const prettierPluginHtml = await import("prettier/plugins/html.js");
  
  return await prettier.format(html, {
    parser: "html",
    plugins: [prettierPluginHtml],
    printWidth: printWidth,
    singleAttributePerLine: false,
    htmlWhitespaceSensitivity: "css",
  });
}

// Calculate printWidth based on window width
function getPrintWidth(): number {
  const width = window.innerWidth;
  
  // Responsive breakpoints for printWidth
  if (width < 640) {
    // Mobile: ~30 chars
    return 30;
  } else if (width < 768) {
    // Small tablet: ~40 chars
    return 40;
  } else if (width < 1024) {
    // Tablet: ~60 chars
    return 60;
  } else if (width < 1280) {
    // Desktop: ~80 chars
    return 80;
  } else {
    // Large desktop: ~100 chars
    return 100;
  }
}

// Simple lightweight HTML syntax highlighter
function highlightHTML(html: string): string {
  let result = html;
  
  // HTML comments (must be first to avoid matching inside tags)
  result = result.replace(/&lt;!--[\s\S]*?--&gt;/g, '<span class="comment">$&</span>');
  
  // Doctype
  result = result.replace(/&lt;!DOCTYPE[^&]*&gt;/gi, '<span class="keyword">$&</span>');
  
  // HTML tags with attributes
  result = result.replace(/&lt;(\/?)([\w-]+)([^&]*?)&gt;/g, (match, closing, tagName, attrs) => {
    // Highlight attributes: name="value" or name='value' or name=value
    const attrsHighlighted = attrs.replace(/([\w-]+)(\s*=\s*)("([^"]*)"|'([^']*)'|([^\s>]+))/g, 
      '<span class="attribute">$1</span><span class="punctuation">$2</span><span class="string">$3</span>');
    return `<span class="punctuation">&lt;</span><span class="tag">${closing}${tagName}</span>${attrsHighlighted}<span class="punctuation">&gt;</span>`;
  });
  
  return result;
}

// Find and format HTML code snippets
document.addEventListener("DOMContentLoaded", async () => {
  setupSectionAnchors();
  setupOpenInPlaygroundButtons();
  setupDocsNavActive();
  setupDocsSearch();

  const htmlCodeElements = document.querySelectorAll<HTMLPreElement>('code.language-markup');

  for (const codeElement of htmlCodeElements) {
    const htmlContent = codeElement.textContent || codeElement.innerText;
    
    if (htmlContent.trim()) {
      try {
        const formatted = await formatHTML(htmlContent, getPrintWidth());
        
        // Escape HTML for highlighting, then apply syntax highlighting
        const escaped = formatted
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;');
        
        const highlighted = highlightHTML(escaped);
        
        // Update the code element with highlighted HTML
        codeElement.innerHTML = highlighted;
        
      } catch (error) {
        // console.error("Error formatting HTML:", error);
      }
    }
  }
});

function normalizeFileName(raw: string | null): string {
  if (!raw) return "Playground.zx";
  const compact = raw.replace(/\s+/g, " ").trim();
  return compact || "Playground.zx";
}

function getSandboxSnippetEntries(sandbox: Element): SnippetEntry[] {
  const radios = Array.from(sandbox.querySelectorAll<HTMLInputElement>(".file-radio"));

  if (radios.length > 0) {
    const codeBlocks = Array.from(
      sandbox.querySelectorAll<HTMLElement>(".sandbox-editor .file-content code")
    );
    const labels = Array.from(
      sandbox.querySelectorAll<HTMLLabelElement>(".sandbox-file-tabs .sandbox-tab")
    );

    const entries: SnippetEntry[] = [];
    for (let i = 0; i < radios.length; i++) {
      const code = codeBlocks[i]?.textContent?.trim() ?? "";
      const filename = normalizeFileName(labels[i]?.textContent ?? null);
      if (code) entries.push({ code, filename });
    }
    return entries;
  }

  const codeNode = sandbox.querySelector<HTMLElement>(".sandbox-code code");
  if (!codeNode) return [];

  const code = codeNode.textContent?.trim() ?? "";
  if (!code) return [];

  const filenameNode = sandbox.querySelector<HTMLElement>(".sandbox-editor-header .sandbox-tab");
  const filename = normalizeFileName(filenameNode?.textContent ?? null);
  return [{ code, filename }];
}

function setupOpenInPlaygroundButtons() {
  const buttons = document.querySelectorAll<HTMLButtonElement>(".sandbox-open-playground-btn");
  if (buttons.length === 0) return;

  buttons.forEach((button) => {
    const sandbox = button.closest(".sandbox");
    if (sandbox) {
      const entries = getSandboxSnippetEntries(sandbox);
      const openable = entries.filter((entry) => isPlaygroundOpenable(entry.filename, entry.code));
      if (openable.length === 0) {
        button.hidden = true;
        return;
      }
    }

    button.addEventListener("click", async (event) => {
      event.preventDefault();

      const targetSandbox = button.closest(".sandbox");
      if (!targetSandbox) return;

      const entries = getSandboxSnippetEntries(targetSandbox);
      const openable = entries.filter((entry) => isPlaygroundOpenable(entry.filename, entry.code));
      if (openable.length === 0) return;

      const files = createDocsSnippetFilesFromEntries(openable);
      const url = await createPlaygroundShareUrl(files, `${window.location.origin}/playground`);
      window.open(url, "_blank", "noopener,noreferrer");
    });
  });
}

function setupDocsNavActive() {
  // Highlight the current section in the left nav and right TOC while scrolling.
  const navLinks = Array.from(
    document.querySelectorAll<HTMLAnchorElement>(
      ".sidebar a[href*='#'], .right-sidebar a[href*='#']"
    )
  );
  if (navLinks.length === 0) return;

  const path = window.location.pathname.replace(/\/$/, "") || "/";
  const pageLinks = Array.from(
    document.querySelectorAll<HTMLAnchorElement>(".sidebar a[href]")
  ).filter((link) => {
    if (link.classList.contains("sidebar-tab")) return false;
    try {
      const url = new URL(link.href, window.location.origin);
      const linkPath = url.pathname.replace(/\/$/, "") || "/";
      return linkPath === path && !url.hash;
    } catch {
      return false;
    }
  });

  type NavTarget = { id: string; links: HTMLAnchorElement[] };
  const targets = new Map<string, NavTarget>();

  for (const link of navLinks) {
    let hash = "";
    try {
      hash = new URL(link.href, window.location.origin).hash.slice(1);
    } catch {
      const idx = link.getAttribute("href")?.indexOf("#") ?? -1;
      hash = idx >= 0 ? link.getAttribute("href")!.slice(idx + 1) : "";
    }
    if (!hash || !document.getElementById(hash)) continue;

    const existing = targets.get(hash);
    if (existing) existing.links.push(link);
    else targets.set(hash, { id: hash, links: [link] });
  }

  const ordered = Array.from(targets.values()).sort((a, b) => {
    const aEl = document.getElementById(a.id);
    const bEl = document.getElementById(b.id);
    if (!aEl || !bEl) return 0;
    return (aEl.compareDocumentPosition(bEl) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
      ? -1
      : 1;
  });

  let currentId = "";

  const setActive = (id: string | null) => {
    const next = id ?? "";
    if (next === currentId) return;
    currentId = next;

    for (const link of navLinks) link.classList.remove("active");
    for (const link of pageLinks) link.classList.remove("active");

    if (!next) {
      for (const link of pageLinks) link.classList.add("active");
      return;
    }

    const target = targets.get(next);
    if (!target) return;

    for (const link of target.links) {
      link.classList.add("active");
      const details = link.closest("details");
      if (details) details.open = true;
    }
  };

  const updateFromScroll = () => {
    const offset = 120;
    let activeId: string | null = null;

    for (const target of ordered) {
      const el = document.getElementById(target.id);
      if (!el) continue;
      if (el.getBoundingClientRect().top - offset <= 0) activeId = target.id;
      else break;
    }

    // Near the page top, prefer the page root link (e.g. Quick Start).
    if (!activeId || window.scrollY < 48) {
      setActive(null);
      return;
    }

    setActive(activeId);
  };

  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      updateFromScroll();
      ticking = false;
    });
  };

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("hashchange", () => {
    const hash = window.location.hash.slice(1);
    if (hash && targets.has(hash)) setActive(hash);
    else updateFromScroll();
  });

  const initialHash = window.location.hash.slice(1);
  if (initialHash && targets.has(initialHash)) {
    setActive(initialHash);
  } else {
    updateFromScroll();
  }
}

// Convert section headings with IDs into clickable anchor links
function setupSectionAnchors() {
  const linkIcon = `<svg class="section-anchor-icon" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    <path d="M7.775 3.275a.75.75 0 0 0 1.06 1.06l1.25-1.25a2 2 0 1 1 2.83 2.83l-2.5 2.5a2 2 0 0 1-2.83 0 .75.75 0 0 0-1.06 1.06 3.5 3.5 0 0 0 4.95 0l2.5-2.5a3.5 3.5 0 0 0-4.95-4.95l-1.25 1.25Z"/>
    <path d="M8.225 12.725a.75.75 0 0 0-1.06-1.06l-1.25 1.25a2 2 0 1 1-2.83-2.83l2.5-2.5a2 2 0 0 1 2.83 0 .75.75 0 0 0 1.06-1.06 3.5 3.5 0 0 0-4.95 0l-2.5 2.5a3.5 3.5 0 0 0 4.95 4.95l1.25-1.25Z"/>
  </svg>`;

  function makeAnchor(heading: HTMLHeadingElement, id: string) {
    // Skip if already processed
    if (heading.querySelector('.section-anchor')) return;

    // Get the text content
    const textContent = heading.innerHTML;

    // Create the anchor link wrapper
    const anchor = document.createElement('a');
    anchor.href = `#${id}`;
    anchor.className = 'section-anchor';
    anchor.innerHTML = textContent + linkIcon;

    // Clear the heading and add the anchor
    heading.innerHTML = '';
    heading.appendChild(anchor);

    // Handle click to copy the link
    anchor.addEventListener('click', async () => {
      // Allow normal navigation but also copy the link
      const url = new URL(window.location.href);
      url.hash = id;
      
      try {
        await navigator.clipboard.writeText(url.toString());
      } catch {
        // Fallback - just let the browser handle the navigation
      }
    });
  }

  // Handle h2/h3 with IDs directly on them
  const headingsWithIds = document.querySelectorAll<HTMLHeadingElement>('.section h2[id], .section h3[id]');
  headingsWithIds.forEach((heading) => {
    const id = heading.id;
    if (id) makeAnchor(heading, id);
  });

  // Handle h2 that are direct children of sections with IDs (but h2 has no ID)
  const sections = document.querySelectorAll<HTMLElement>('.section[id]');
  sections.forEach((section) => {
    const sectionId = section.id;
    if (!sectionId) return;
    
    // Find the first h2 that's a direct child (or within a container div)
    const h2 = section.querySelector<HTMLHeadingElement>(':scope > h2, :scope > div > h2');
    if (h2 && !h2.id) {
      makeAnchor(h2, sectionId);
    }
  });
}

function getOS() {
  const userAgent = navigator.userAgent;
  if (/Windows NT/i.test(userAgent)) {
      return 'windows';
  } else if (/Macintosh|Mac OS X/i.test(userAgent)) {
      return 'macos';
  } else if (/Android/i.test(userAgent)) {
      return 'android';
  } else if (/iPhone|iPad|iPod/i.test(userAgent)) {
      return 'ios';
  } else if (/Linux/i.test(userAgent)) {
      return 'linux';
  }
  return 'unknown';
}

// Add OS class to body and auto-select appropriate tabs
const os = getOS();
document.body.classList.add(os);

// Auto-select tabs based on OS
const osTabs: Partial<Record<ReturnType<typeof getOS>, string[]>> = {
  windows: ['tab-windows', 'tab-zig-win'],
  linux: ['tab-zig-other']
};

(osTabs[os] || []).forEach((id: string) => {
  const tab = document.getElementById(id);
  if (tab && tab instanceof HTMLInputElement) tab.checked = true;
});
