// TODO: Migrate this to Ziex later for Dogfooding
(() => {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const WS_URL = `${proto}//${location.host}/.well-known/_zx/devsocket`;
  const DEV_SCRIPT_PATH = "_zx/devscript";
  const OVERLAY_ID = "_zx_overlay";
  const STATUS_ID = "_zx_status";
  const BUILD_RETRY_LIMIT = 10;
  const BUILD_RETRY_DELAY_MS = 200;
  const PRESERVE_ATTR = "data-zx-preserve";

  const state = {
    ws: null,
    reconnectTimer: null,
    everConnected: false,
    overlayEl: null,
    statusEl: null,
    currentDiagnostics: null,
    overlayDismissed: false,
    isShellPage: document.title === "Ziex Dev",
    lastAppliedHtml: null,
    isRefreshing: false,
    pendingMessage: null, // deferred message while tab is hidden
  };

  function log(type, payload) {
    console.log("[zx dev]", type, payload);
  }

  function connect() {
    clearTimeout(state.reconnectTimer);

    const ws = new WebSocket(WS_URL);
    state.ws = ws;

    ws.addEventListener("open", () => {
      setConnectionStatus("connected");
      if (state.everConnected) {
        if (document.hidden) {
          // Defer reconnect reload until tab is visible
          state.pendingMessage = { type: "reload" };
        } else if (state.isShellPage) {
          location.reload();
          return;
        } else {
          refreshDocument();
        }
      }
      state.everConnected = true;
    });

    ws.addEventListener("message", (event) => {
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch (_) {
        return;
      }

      log(msg.type, msg);

      if (document.hidden) {
        // Defer actions while tab is hidden; keep only the latest pending message
        // so we apply the final state when the user switches back.
        // "connected" and "building" are status-only - always store them but
        // don't discard a more important pending action (reload/error/asset_update).
        if (msg.type === "connected" || msg.type === "building") {
          if (!state.pendingMessage) state.pendingMessage = msg;
        } else {
          state.pendingMessage = msg;
        }
        return;
      }

      handleMessage(msg);
    });

    ws.addEventListener("close", () => {
      if (state.ws === ws) {
        state.ws = null;
      }
      setConnectionStatus("reconnecting");
      state.reconnectTimer = setTimeout(connect, 500);
    });

    ws.addEventListener("error", () => {
      if (state.ws === ws) {
        ws.close();
      }
    });
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case "connected":
        setConnectionStatus("connected");
        return;
      case "reload":
        if (state.isShellPage) {
          location.reload();
          return;
        }
        hideOverlay(true);
        refreshDocument();
        return;
      case "error": {
        const diagnostics =
          msg.diagnostics ||
          (msg.message
            ? [{ file: "", line: 0, col: 0, kind: "error", message: msg.message }]
            : null);

        if (!diagnostics) return;

        if (sameDiagnostics(state.currentDiagnostics, diagnostics)) {
          if (state.overlayDismissed) showErrorIndicator();
          return;
        }

        state.overlayDismissed = false;
        showErrorOverlay(diagnostics);
        return;
      }
      case "clear":
        hideOverlay(true);
        return;
      case "building":
        showBuildingOverlay();
        return;
      case "asset_update":
        hideOverlay(true);
        reloadAssets(msg.files || []);
        return;
    }
  }

  function sameDiagnostics(a, b) {
    return !!a && JSON.stringify(a) === JSON.stringify(b);
  }

  async function refreshDocument(attempt = 0) {
    if (state.isRefreshing) return;
    state.isRefreshing = true;

    try {
      const response = await fetch(location.href, {
        cache: "no-store",
        headers: { Accept: "text/html" },
      });
      if (!response.ok) throw new Error("bad response");

      const html = await response.text();
      if (state.lastAppliedHtml === html) return;

      const nextDoc = new DOMParser().parseFromString(html, "text/html");
      applyDocumentUpdate(nextDoc, html);
    } catch (_) {
      if (attempt < BUILD_RETRY_LIMIT) {
        setTimeout(() => refreshDocument(attempt + 1), BUILD_RETRY_DELAY_MS);
        return;
      }
      location.reload();
    } finally {
      state.isRefreshing = false;
    }
  }

  function reloadAssets(files) {
    const timestamp = Date.now();
    let cssReloaded = false;

    const links = document.querySelectorAll('link[rel="stylesheet"]');
    for (const link of links) {
      const href = link.getAttribute("href");
      if (!href) continue;

      try {
        const pathname = new URL(href, location.origin).pathname;
        const matches =
          files.length === 0 || files.some((f) => pathname === f || pathname.endsWith(f));
        if (matches) {
          const url = new URL(href, location.origin);
          url.searchParams.set("_zx_t", timestamp);
          link.setAttribute("href", url.pathname + url.search);
          cssReloaded = true;
        }
      } catch (_) {}
    }

    if (!cssReloaded && files.length > 0) {
      // Non-CSS assets changed (images, fonts, etc.) - bust cache on matching elements
      const selectors = files
        .filter((f) => !f.endsWith(".css"))
        .map((f) => `img[src*="${f}"],source[srcset*="${f}"]`)
        .join(",");
      if (selectors) {
        for (const el of document.querySelectorAll(selectors)) {
          const attr = el.hasAttribute("srcset") ? "srcset" : "src";
          const val = el.getAttribute(attr);
          if (val) {
            try {
              const url = new URL(val, location.origin);
              url.searchParams.set("_zx_t", timestamp);
              el.setAttribute(attr, url.pathname + url.search);
            } catch (_) {}
          }
        }
      }
    }

    log("asset_update", { files, cssReloaded });
    runClientReinitializers();
  }

  function applyDocumentUpdate(nextDoc, html) {
    const nextBody = nextDoc.body;
    const currentBody = document.body;
    if (!nextBody || !currentBody) {
      location.reload();
      return;
    }

    syncDocumentElement(document.documentElement, nextDoc.documentElement);
    syncHead(document.head, nextDoc.head);
    morphElement(currentBody, nextBody);

    if (document.title !== nextDoc.title) {
      document.title = nextDoc.title;
      state.isShellPage = document.title === "Ziex Dev";
    }

    state.lastAppliedHtml = html;
    runClientReinitializers();
  }

  function runClientReinitializers() {
    try {
      if (typeof window.__zx_dev_reinit === "function") {
        window.__zx_dev_reinit();
      }
    } catch (error) {
      console.warn("[zx dev] reinit failed", error);
    }

    try {
      window.dispatchEvent(new CustomEvent("__zx_dev_after_update"));
    } catch (_) {}
  }

  function syncDocumentElement(currentRoot, nextRoot) {
    syncAttributes(currentRoot, nextRoot);
  }

  function syncHead(currentHead, nextHead) {
    morphChildren(currentHead, nextHead);
  }

  function morphElement(currentEl, nextEl) {
    if (shouldPreserveElement(currentEl, nextEl)) return;

    syncAttributes(currentEl, nextEl);
    syncFormState(currentEl, nextEl);
    morphChildren(currentEl, nextEl);
  }

  function morphChildren(currentParent, nextParent) {
    const nextChildren = Array.from(nextParent.childNodes);
    const keyed = buildKeyedLookup(currentParent);
    let cursor = currentParent.firstChild;

    for (const nextChild of nextChildren) {
      if (isDevOverlayNode(nextChild)) continue;

      let match = null;
      if (cursor && canMorph(cursor, nextChild)) {
        match = cursor;
      } else {
        const key = getNodeKey(nextChild);
        if (key && keyed.has(key)) {
          const candidate = keyed.get(key);
          if (candidate && candidate.parentNode === currentParent && canMorph(candidate, nextChild)) {
            match = candidate;
          }
        }
      }

      if (match) {
        const nextCursor = match === cursor ? cursor.nextSibling : cursor;
        if (match !== cursor) {
          currentParent.insertBefore(match, cursor);
        }
        morphNode(match, nextChild);
        cursor = nextCursor;
      } else {
        currentParent.insertBefore(createLiveNode(nextChild), cursor);
      }
    }

    while (cursor) {
      const nextCursor = cursor.nextSibling;
      if (!isDevOverlayNode(cursor)) {
        currentParent.removeChild(cursor);
      }
      cursor = nextCursor;
    }
  }

  function morphNode(currentNode, nextNode) {
    if (currentNode.nodeType !== nextNode.nodeType) {
      currentNode.replaceWith(createLiveNode(nextNode));
      return;
    }

    if (currentNode.nodeType === Node.TEXT_NODE || currentNode.nodeType === Node.COMMENT_NODE) {
      if (currentNode.textContent !== nextNode.textContent) {
        currentNode.textContent = nextNode.textContent;
      }
      return;
    }

    if (currentNode.tagName !== nextNode.tagName) {
      currentNode.replaceWith(createLiveNode(nextNode));
      return;
    }

    if (currentNode.tagName === "SCRIPT") {
      syncScriptNode(currentNode, nextNode);
      return;
    }

    morphElement(currentNode, nextNode);
  }

  function syncScriptNode(currentScript, nextScript) {
    if (isDevScript(currentScript) || isDevScript(nextScript)) return;

    const currentSignature = scriptSignature(currentScript);
    const nextSignature = scriptSignature(nextScript);
    if (currentSignature === nextSignature) return;

    currentScript.replaceWith(createLiveScript(nextScript));
  }

  function createLiveNode(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return node.cloneNode(true);
    }

    if (node.tagName === "SCRIPT") {
      return createLiveScript(node);
    }

    const clone = node.cloneNode(false);
    const children = Array.from(node.childNodes);
    for (const child of children) {
      clone.appendChild(createLiveNode(child));
    }
    return clone;
  }

  function createLiveScript(sourceScript) {
    const fresh = document.createElement("script");
    for (const attr of sourceScript.attributes) {
      fresh.setAttribute(attr.name, attr.value);
    }
    fresh.textContent = sourceScript.textContent;
    return fresh;
  }

  function buildKeyedLookup(parent) {
    const keyed = new Map();
    for (const child of parent.childNodes) {
      const key = getNodeKey(child);
      if (key) keyed.set(key, child);
    }
    return keyed;
  }

  function canMorph(currentNode, nextNode) {
    if (currentNode.nodeType !== nextNode.nodeType) return false;

    if (currentNode.nodeType !== Node.ELEMENT_NODE) return true;

    if (currentNode.tagName !== nextNode.tagName) return false;

    const currentKey = getNodeKey(currentNode);
    const nextKey = getNodeKey(nextNode);
    if (currentKey || nextKey) return currentKey === nextKey;

    return true;
  }

  function getNodeKey(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    if (node.id) return `id:${node.id}`;

    if (node.tagName === "SCRIPT") return `script:${scriptSignature(node)}`;
    if (node.tagName === "LINK") {
      const rel = node.getAttribute("rel") || "";
      const href = node.getAttribute("href") || "";
      if (rel || href) return `link:${rel}:${href}`;
    }
    if (node.tagName === "META") {
      const name = node.getAttribute("name") || node.getAttribute("property") || node.getAttribute("charset") || "";
      if (name) return `meta:${name}`;
    }
    return null;
  }

  function scriptSignature(script) {
    const src = script.getAttribute("src") || "";
    const type = script.getAttribute("type") || "";
    const text = src ? "" : script.textContent || "";
    return `${type}:${src}:${text}`;
  }

  function syncAttributes(currentEl, nextEl) {
    const currentAttrs = Array.from(currentEl.attributes);
    for (const attr of currentAttrs) {
      if (!nextEl.hasAttribute(attr.name)) {
        currentEl.removeAttribute(attr.name);
      }
    }

    for (const attr of Array.from(nextEl.attributes)) {
      if (currentEl.getAttribute(attr.name) !== attr.value) {
        currentEl.setAttribute(attr.name, attr.value);
      }
    }
  }

  function syncFormState(currentEl, nextEl) {
    if (currentEl.tagName === "INPUT") {
      if (currentEl.type === "checkbox" || currentEl.type === "radio") {
        currentEl.checked = nextEl.checked;
      } else if (document.activeElement !== currentEl && currentEl.value !== nextEl.value) {
        currentEl.value = nextEl.value;
      }
    } else if (currentEl.tagName === "TEXTAREA") {
      if (document.activeElement !== currentEl && currentEl.value !== nextEl.value) {
        currentEl.value = nextEl.value;
      }
    } else if (currentEl.tagName === "SELECT") {
      currentEl.value = nextEl.value;
    }
  }

  function shouldPreserveElement(currentEl, nextEl) {
    return currentEl.nodeType === Node.ELEMENT_NODE &&
      nextEl.nodeType === Node.ELEMENT_NODE &&
      currentEl.hasAttribute(PRESERVE_ATTR) &&
      nextEl.hasAttribute(PRESERVE_ATTR);
  }

  function isDevOverlayNode(node) {
    return node &&
      node.nodeType === Node.ELEMENT_NODE &&
      (node.id === OVERLAY_ID || node.id === STATUS_ID);
  }

  function isDevScript(node) {
    return (
      node &&
      node.nodeType === Node.ELEMENT_NODE &&
      node.tagName === "SCRIPT" &&
      typeof node.src === "string" &&
      node.src.indexOf(DEV_SCRIPT_PATH) !== -1
    );
  }

  const OVERLAY_STYLES = [
    "position:fixed;inset:0;z-index:2147483647;",
    "background:rgba(0,0,0,0.92);color:#e8e8e8;",
    "font-family:'Inter',system-ui,-apple-system,sans-serif;font-size:14px;",
    "display:flex;flex-direction:column;overflow:hidden;",
  ].join("");

  const HEADER_STYLES = [
    "display:flex;align-items:center;gap:12px;padding:16px 20px;",
    "background:#1a1a1a;border-bottom:1px solid #333;",
    "flex-shrink:0;",
  ].join("");

  const ERROR_BADGE_STYLES = [
    "display:inline-flex;align-items:center;gap:6px;",
    "background:rgba(239,68,68,0.15);color:#ef4444;",
    "padding:4px 10px;border-radius:6px;font-weight:600;font-size:13px;",
    "border:1px solid rgba(239,68,68,0.25);",
  ].join("");

  const DISMISS_BTN_STYLES = [
    "margin-left:auto;background:transparent;",
    "border:1px solid #444;color:#999;",
    "cursor:pointer;padding:6px 14px;border-radius:6px;",
    "font-size:12px;font-family:inherit;transition:all 0.15s;",
  ].join("");

  function ensureStatusEl() {
    if (state.statusEl && state.statusEl.isConnected) return state.statusEl;

    const el = document.createElement("div");
    el.id = STATUS_ID;
    el.style.cssText = [
      "position:fixed;top:16px;right:16px;z-index:2147483647;",
      "display:none;align-items:center;gap:8px;",
      "padding:8px 12px;border-radius:999px;",
      "background:rgba(17,24,39,0.9);color:#d1d5db;",
      "border:1px solid rgba(107,114,128,0.35);",
      "font:600 12px/1.2 system-ui,sans-serif;",
      "backdrop-filter:blur(12px);",
    ].join("");
    document.body.appendChild(el);
    state.statusEl = el;
    return el;
  }

  function setConnectionStatus(kind) {
    const el = ensureStatusEl();
    if (kind === "connected") {
      el.style.display = "none";
      return;
    }

    el.style.display = "inline-flex";
    el.innerHTML =
      '<span style="width:8px;height:8px;border-radius:999px;background:#f59e0b;display:inline-block"></span>' +
      '<span>Reconnecting dev server...</span>';
  }

  function showBuildingOverlay() {
    hideOverlay(true);

    const el = document.createElement("div");
    el.id = OVERLAY_ID;
    el.style.cssText = [
      "position:fixed;bottom:20px;right:20px;z-index:2147483647;",
      "background:#1a1a1a;color:#a3a3a3;border:1px solid #333;",
      "padding:10px 16px;border-radius:8px;font-family:system-ui,sans-serif;",
      "font-size:13px;display:flex;align-items:center;gap:8px;",
      "box-shadow:0 4px 12px rgba(0,0,0,0.4);",
    ].join("");

    el.innerHTML =
      '<svg width="16" height="16" viewBox="0 0 16 16" style="animation:_zx_spin 1s linear infinite"><circle cx="8" cy="8" r="6" fill="none" stroke="#666" stroke-width="2"/><path d="M8 2a6 6 0 0 1 6 6" fill="none" stroke="#3b82f6" stroke-width="2" stroke-linecap="round"/></svg>' +
      '<style>@keyframes _zx_spin{to{transform:rotate(360deg)}}</style>' +
      "<span>Rebuilding...</span>";
    document.body.appendChild(el);
    state.overlayEl = el;
  }

  function showErrorOverlay(diagnostics) {
    hideOverlay(true);
    state.currentDiagnostics = diagnostics;
    if (!diagnostics || diagnostics.length === 0) return;

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.style.cssText = OVERLAY_STYLES;

    const header = document.createElement("div");
    header.style.cssText = HEADER_STYLES;

    const badge = document.createElement("span");
    badge.style.cssText = ERROR_BADGE_STYLES;
    const errorCount = diagnostics.filter((d) => d.kind === "error").length;
    badge.innerHTML =
      '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/><path d="M8 4v5M8 11v1" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>' +
      (errorCount === 1 ? "1 Error" : `${errorCount} Errors`);
    header.appendChild(badge);

    if (!state.isShellPage) {
      const button = document.createElement("button");
      button.style.cssText = DISMISS_BTN_STYLES;
      button.textContent = "Dismiss";
      button.onmouseenter = () => {
        button.style.borderColor = "#666";
        button.style.color = "#ccc";
      };
      button.onmouseleave = () => {
        button.style.borderColor = "#444";
        button.style.color = "#999";
      };
      button.onclick = () => hideOverlay();
      header.appendChild(button);
    }

    const body = document.createElement("div");
    body.style.cssText = "padding:0;overflow:auto;flex:1;";

    let primaryError = null;
    const notes = [];
    for (const diagnostic of diagnostics) {
      if (!primaryError && diagnostic.kind === "error") {
        primaryError = diagnostic;
      } else {
        notes.push(diagnostic);
      }
    }

    if (primaryError) {
      body.appendChild(buildErrorCard(primaryError, true));
    }

    for (const note of notes) {
      body.appendChild(buildErrorCard(note, false));
    }

    overlay.appendChild(header);
    overlay.appendChild(body);
    document.body.appendChild(overlay);
    state.overlayEl = overlay;

    if (!state.isShellPage) {
      overlay._keyHandler = (event) => {
        if (event.key === "Escape") hideOverlay();
      };
      document.addEventListener("keydown", overlay._keyHandler);
    }
  }

  function buildErrorCard(diag, isPrimary) {
    const card = document.createElement("div");
    card.style.cssText = [
      "margin:0;padding:20px 24px;",
      isPrimary ? "" : "border-top:1px solid #262626;",
    ].join("");

    if (diag.file && diag.file.length > 0) {
      const loc = document.createElement("div");
      loc.style.cssText = "margin-bottom:12px;display:flex;align-items:center;gap:8px;";

      const fileEl = document.createElement("a");
      fileEl.style.cssText = [
        "font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;",
        "color:#3b82f6;cursor:pointer;text-decoration:none;",
      ].join("");
      fileEl.onmouseenter = () => {
        fileEl.style.textDecoration = "underline";
      };
      fileEl.onmouseleave = () => {
        fileEl.style.textDecoration = "none";
      };
      fileEl.onclick = (event) => {
        event.preventDefault();
        const url = `/.well-known/_zx/open-in-editor?file=${encodeURIComponent(diag.file)}&line=${diag.line}&col=${diag.col}`;
        fetch(url);
      };

      fileEl.textContent = diag.file;
      if (diag.line > 0) {
        fileEl.textContent += `:${diag.line}`;
        if (diag.col > 0) fileEl.textContent += `:${diag.col}`;
      }

      const kindBadge = document.createElement("span");
      const kindColor =
        diag.kind === "error" ? "#ef4444" : diag.kind === "warning" ? "#f59e0b" : "#6b7280";
      kindBadge.style.cssText = [
        "font-size:11px;font-weight:600;text-transform:uppercase;",
        "padding:2px 6px;border-radius:4px;",
        `background:${kindColor}20;color:${kindColor};`,
      ].join("");
      kindBadge.textContent = diag.kind;

      loc.appendChild(fileEl);
      loc.appendChild(kindBadge);
      card.appendChild(loc);
    }

    const msgEl = document.createElement("div");
    msgEl.style.cssText = [
      `font-size:${isPrimary ? "18px" : "15px"};`,
      `font-weight:${isPrimary ? "600" : "500"};`,
      `color:${diag.kind === "error" ? "#fca5a5" : diag.kind === "warning" ? "#fcd34d" : "#9ca3af"};`,
      "line-height:1.5;margin-bottom:12px;",
      "font-family:ui-monospace,Menlo,Consolas,monospace;",
    ].join("");
    msgEl.textContent = diag.message;
    card.appendChild(msgEl);

    if (diag.source_html || diag.source) {
      const sourceBlock = document.createElement("div");
      sourceBlock.style.cssText = [
        "background:#111;border:1px solid #262626;border-radius:8px;",
        "overflow:hidden;margin-top:8px;",
      ].join("");

      const pre = document.createElement("pre");
      pre.style.cssText = [
        "margin:0;padding:16px;overflow-x:auto;",
        "font-family:ui-monospace,Menlo,Consolas,monospace;",
        "font-size:13px;line-height:1.7;color:#d4d4d4;tab-size:2;",
      ].join("");
      if (diag.source_html) {
        pre.className = "zx-dev-code";
        pre.innerHTML =
          '<style>' +
          '.zx-dev-code{background:#111}.zx-code-line{display:grid;grid-template-columns:auto 1fr;gap:16px;margin:0 -16px;padding:0 16px}.zx-code-line-error{background:rgba(239,68,68,0.1);border-left:3px solid #ef4444;padding-left:13px}.zx-code-line-no{color:#6b7280;user-select:none;text-align:right;min-width:2.5rem}.zx-code-line-text{white-space:pre}.keyword,.conditional,.repeat,.operator,.keyword.function,.storageclass,.label{color:#f472b6}.string,.string.special{color:#86efac}.number,.constant.builtin,.boolean{color:#fbbf24}.function,.function.call,.constructor{color:#60a5fa}.type,.type.builtin{color:#22d3ee}.comment{color:#6b7280}.tag,.tag.delimiter,.punctuation.bracket{color:#cbd5e1}.attribute{color:#93c5fd}.property{color:#c084fc}' +
          "</style>" +
          diag.source_html;
      } else {
        const lines = diag.source.split("\n");
        let html = "";
        for (let index = 0; index < lines.length; index += 1) {
          const line = lines[index];
          if (!line && index === lines.length - 1) continue;

          const lineNum = parseInt(line.trim().split("|")[0], 10);
          const isErrorLine = lineNum === diag.line;
          if (isErrorLine) {
            html += '<span style="display:block;background:rgba(239,68,68,0.1);margin:0 -16px;padding:0 16px;border-left:3px solid #ef4444;">';
          }
          html += escapeHtml(line);
          html += isErrorLine ? "</span>" : "\n";
        }
        pre.innerHTML = html;
      }
      sourceBlock.appendChild(pre);
      card.appendChild(sourceBlock);
    }

    return card;
  }

  function escapeHtml(value) {
    return value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function showErrorIndicator() {
    if (state.overlayEl) state.overlayEl.remove();

    const el = document.createElement("div");
    el.id = OVERLAY_ID;
    el.style.cssText = [
      "position:fixed;bottom:20px;right:20px;z-index:2147483647;",
      "background:#1a1a1a;color:#ef4444;border:1px solid rgba(239,68,68,0.3);",
      "padding:10px 16px;border-radius:8px;font-family:system-ui,sans-serif;",
      "font-size:13px;display:flex;align-items:center;gap:8px;cursor:pointer;",
      "box-shadow:0 4px 12px rgba(0,0,0,0.4);transition:transform 0.1s;",
    ].join("");
    el.onmouseenter = () => {
      el.style.transform = "scale(1.05)";
    };
    el.onmouseleave = () => {
      el.style.transform = "scale(1)";
    };
    el.onclick = () => showErrorOverlay(state.currentDiagnostics);

    const errorCount = state.currentDiagnostics.filter((d) => d.kind === "error").length;
    el.innerHTML =
      '<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/><path d="M8 4v5M8 11v1" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>' +
      `<span>${errorCount === 1 ? "1 Error" : `${errorCount} Errors`}</span>`;
    document.body.appendChild(el);
    state.overlayEl = el;
  }

  function hideOverlay(completely) {
    if (state.overlayEl) {
      if (state.overlayEl._keyHandler) {
        document.removeEventListener("keydown", state.overlayEl._keyHandler);
      }
      state.overlayEl.remove();
      state.overlayEl = null;
    }

    if (completely) {
      state.currentDiagnostics = null;
      state.overlayDismissed = false;
    } else if (state.currentDiagnostics) {
      state.overlayDismissed = true;
      showErrorIndicator();
    }
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && state.pendingMessage) {
      const msg = state.pendingMessage;
      state.pendingMessage = null;
      log(msg.type + " (deferred)", msg);
      handleMessage(msg);
    }
  });

  connect();
})();
