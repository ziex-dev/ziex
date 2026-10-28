import { get, put, del, list } from "../../../../pkg/ziex/src/runtime/kv/localstorage";
import { init } from "../../../../pkg/ziex/src/wasm";
import { reportErrors, type EvalRequest, type EvalResponse, type PanelNavigationMessage } from "../../extension/shared";

const HOST_STORAGE_KEY = "zx-devtool-host-v2";
const PATH_STORAGE_KEY = "zx-devtool-path-v1";

const kvBindings = { default: { get, put, del, list } };

// Inside the extension, surface panel errors in the background worker's console.
if ((globalThis as any).chrome?.runtime?.id) reportErrors("panel");
const defaultKV = kvBindings.default;

function persistLocation(origin: string, pathname: string): boolean {
    if (!origin) return false;
    try {
        // Write plain, un-namespaced keys via synchronous localStorage so the
        // wasm side (data.zig `lsGet`) reads them back under the same keys.
        // Must NOT go through zx.kv: its keys are namespaced and its wasm reads
        // are async (JSPI), which the devtool's settings persistence avoids.
        localStorage.setItem(HOST_STORAGE_KEY, origin);
        localStorage.setItem(PATH_STORAGE_KEY, pathname || "/");
        return true;
    } catch {
        return false;
    }
}

async function syncInspectedPageLocation(): Promise<boolean> {
    if (!defaultKV) return false;
    const location = await evalInInspectedWindow<{ origin?: unknown; pathname?: unknown } | null>(
        `(() => {
            const hook = window.__ZIEX_DEVTOOLS_GLOBAL_HOOK__;
            return hook ? hook.location : null;
        })()`
    );
    if (!location) return false;
    const origin = typeof location.origin === "string" ? location.origin : "";
    const pathname = typeof location.pathname === "string" ? location.pathname : "/";
    return persistLocation(origin, pathname);
}

async function syncLocationFromUrl(href: string): Promise<boolean> {
    try {
        const url = new URL(href);
        return await persistLocation(url.origin, url.pathname || "/");
    } catch {
        return false;
    }
}

async function refreshFromNavigation(href?: string): Promise<void> {
    // A navigation drops the page-injected picker listeners, so leave pick mode.
    await exitPickMode();
    await clearInspectedComponentHighlight();
    const updatedFromUrl = typeof href === "string" ? await syncLocationFromUrl(href) : false;
    if (!updatedFromUrl) {
        await syncInspectedPageLocation();
    }
    await window.__zx_dev_reinit?.();
}

// Relayed through the devtools page (extension/devtools.ts); Safari kills a panel
// that calls devtools APIs itself.
function evalInInspectedWindow<T = unknown>(expression: string): Promise<T | undefined> {
    const chromeApi = (globalThis as any).chrome;
    const tabId = chromeApi?.devtools?.inspectedWindow?.tabId;
    if (typeof tabId !== 'number' || !chromeApi?.runtime?.sendMessage) return Promise.resolve(undefined);

    const request: EvalRequest = { type: 'zx-eval', tabId, expression };
    return chromeApi.runtime
        .sendMessage(request)
        .then((response?: EvalResponse) => (response && !response.error ? (response.result as T) : undefined))
        .catch(() => undefined);
}

/**
 * Build a script that, when eval'd in the inspected page, positions a highlight
 * overlay over a component's root element.
 *
 * The devtool derives a CSS `selector` and an `occurrence` index for each
 * component from the serialized tree (see data.zig). The inspected page needs no
 * special markup: we locate the element with
 * `document.querySelectorAll(selector)[occurrence]`. Pass a null/empty selector
 * to hide the overlay.
 */
function inspectedHighlightScript(selector: string | null, occurrence: number): string {
    const selLiteral = JSON.stringify(selector);
    const occLiteral = JSON.stringify(occurrence | 0);
    return `(() => {
        const key = '__ZX_DEVTOOL_HOVER_OVERLAY__';
        const root = window;
        const state = root[key] || (root[key] = { overlay: null, activeId: null });

        const ensureOverlay = () => {
            if (state.overlay && state.overlay.isConnected) return state.overlay;
            const overlay = document.createElement('div');
            overlay.style.position = 'fixed';
            overlay.style.zIndex = '2147483647';
            overlay.style.pointerEvents = 'none';
            // Use outline (drawn OUTSIDE the box) not border, so the highlight
            // wraps the element's exact bounds instead of sitting 2px inside it.
            // No border-radius: square elements must align at the corners.
            overlay.style.outline = '2px solid #41b883';
            overlay.style.background = 'rgba(65, 184, 131, 0.18)';
            overlay.style.boxSizing = 'border-box';
            overlay.style.display = 'none';
            document.documentElement.appendChild(overlay);
            state.overlay = overlay;
            return overlay;
        };

        const hideOverlay = () => {
            if (state.overlay) state.overlay.style.display = 'none';
            state.activeId = null;
            return false;
        };

        const selector = ${selLiteral};
        const occurrence = ${occLiteral};
        if (!selector) return hideOverlay();

        let nodes;
        try { nodes = document.querySelectorAll(selector); } catch { return hideOverlay(); }
        const el = nodes[occurrence];
        if (!el) return hideOverlay();

        const rect = el.getBoundingClientRect();
        if (!rect || (rect.width <= 0 && rect.height <= 0)) return hideOverlay();

        const overlay = ensureOverlay();
        overlay.style.display = 'block';
        overlay.style.left = rect.left + 'px';
        overlay.style.top = rect.top + 'px';
        overlay.style.width = Math.max(1, rect.width) + 'px';
        overlay.style.height = Math.max(1, rect.height) + 'px';
        state.activeId = selector + '#' + occurrence;
        return true;
    })()`;
}

// Hovering fires faster than evals round-trip through the devtools page, so only
// the latest highlight is sent; intermediate ones are dropped.
let pendingHighlight: string | null = null;
let highlightInFlight: Promise<void> | null = null;

function queueHighlight(script: string): Promise<void> {
    pendingHighlight = script;
    highlightInFlight ??= (async () => {
        while (pendingHighlight !== null) {
            const next = pendingHighlight;
            pendingHighlight = null;
            await evalInInspectedWindow(next);
        }
        highlightInFlight = null;
    })();
    return highlightInFlight;
}

async function highlightInspectedComponent(selector: string, occurrence: number): Promise<void> {
    await queueHighlight(inspectedHighlightScript(selector, occurrence));
}

async function clearInspectedComponentHighlight(): Promise<void> {
    await queueHighlight(inspectedHighlightScript(null, 0));
}

/**
 * Build a script that, when eval'd in the inspected page, scrolls a component's
 * root element into view (only when it isn't already fully visible) and pins the
 * highlight overlay onto it while the smooth scroll settles.
 *
 * Reuses the same locator scheme and overlay as {@link inspectedHighlightScript}
 * so clicking a component in the tree focuses the exact element the hover
 * highlight points at.
 */
function inspectedFocusScript(selector: string, occurrence: number): string {
    const selLiteral = JSON.stringify(selector);
    const occLiteral = JSON.stringify(occurrence | 0);
    return `(() => {
        const key = '__ZX_DEVTOOL_HOVER_OVERLAY__';
        const root = window;
        const state = root[key] || (root[key] = { overlay: null, activeId: null });

        const ensureOverlay = () => {
            if (state.overlay && state.overlay.isConnected) return state.overlay;
            const overlay = document.createElement('div');
            overlay.style.position = 'fixed';
            overlay.style.zIndex = '2147483647';
            overlay.style.pointerEvents = 'none';
            // Use outline (drawn OUTSIDE the box) not border, so the highlight
            // wraps the element's exact bounds instead of sitting 2px inside it.
            // No border-radius: square elements must align at the corners.
            overlay.style.outline = '2px solid #41b883';
            overlay.style.background = 'rgba(65, 184, 131, 0.18)';
            overlay.style.boxSizing = 'border-box';
            overlay.style.display = 'none';
            document.documentElement.appendChild(overlay);
            state.overlay = overlay;
            return overlay;
        };

        const selector = ${selLiteral};
        const occurrence = ${occLiteral};
        if (!selector) return false;

        let nodes;
        try { nodes = document.querySelectorAll(selector); } catch { return false; }
        const el = nodes[occurrence];
        if (!el) return false;

        const overlay = ensureOverlay();
        const place = () => {
            const rect = el.getBoundingClientRect();
            if (!rect || (rect.width <= 0 && rect.height <= 0)) {
                overlay.style.display = 'none';
                return;
            }
            overlay.style.display = 'block';
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.width = Math.max(1, rect.width) + 'px';
            overlay.style.height = Math.max(1, rect.height) + 'px';
        };

        const rect = el.getBoundingClientRect();
        const vh = window.innerHeight || document.documentElement.clientHeight;
        const vw = window.innerWidth || document.documentElement.clientWidth;
        const fullyVisible = rect.top >= 0 && rect.left >= 0 && rect.bottom <= vh && rect.right <= vw;

        place();
        state.activeId = selector + '#' + occurrence;

        if (!fullyVisible) {
            el.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' });
            // Keep the overlay pinned to the element until the smooth scroll
            // actually settles. A fixed timer often ends mid-animation, leaving
            // the overlay at a stale position; instead track the element until
            // its rect stops moving for a few frames (or a safety cap is hit).
            const start = Date.now();
            let lastTop = null;
            let lastLeft = null;
            let stableFrames = 0;
            const tick = () => {
                place();
                const r = el.getBoundingClientRect();
                if (lastTop !== null &&
                    Math.abs(r.top - lastTop) < 0.5 &&
                    Math.abs(r.left - lastLeft) < 0.5) {
                    stableFrames++;
                } else {
                    stableFrames = 0;
                }
                lastTop = r.top;
                lastLeft = r.left;
                // ~5 still frames means the scroll finished; 2s is a hard cap.
                if (stableFrames >= 5 || Date.now() - start > 2000) {
                    place();
                    return;
                }
                requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
        }
        return true;
    })()`;
}

async function focusInspectedComponent(selector: string, occurrence: number): Promise<void> {
    if (!selector) return;
    await evalInInspectedWindow(inspectedFocusScript(selector, occurrence));
}

// ---------------------------------------------------------------------------
// Element picker ("inspect" mode)
//
// The inverse of tree-hover highlighting: the user arms the picker, then hovers
// the *inspected page* to highlight elements and clicks one to select the
// matching component in the tree. Chrome DevTools' native element picker works
// the same way.
//
// Implemented with the same `inspectedWindow.eval` bridge as the highlight
// helpers: an injected page script draws the hover overlay and, on click,
// records the clicked element's ancestor chain (each as the same
// `selector`/`occurrence` pair the tree uses). The panel polls for that result
// and clicks the matching tree button. The selector/occurrence scheme must stay
// identical to `data.zig`'s `buildSelector` + document-order counting.
// ---------------------------------------------------------------------------

/**
 * Build a script that toggles the in-page picker. When `enable`, it installs
 * (once) capture-phase mouse/keyboard listeners that draw the shared overlay on
 * hover and, on click, swallow the event and stash the clicked element's
 * selector chain on the shared overlay state for the panel to poll. When
 * disabled, it deactivates those listeners and restores the cursor/overlay.
 */
function inspectedPickerScript(enable: boolean): string {
    const enableLiteral = JSON.stringify(!!enable);
    return `(() => {
        const key = '__ZX_DEVTOOL_HOVER_OVERLAY__';
        const state = window[key] || (window[key] = { overlay: null, activeId: null });
        const enable = ${enableLiteral};

        const ensureOverlay = () => {
            if (state.overlay && state.overlay.isConnected) return state.overlay;
            const overlay = document.createElement('div');
            overlay.style.position = 'fixed';
            overlay.style.zIndex = '2147483647';
            overlay.style.pointerEvents = 'none';
            // Use outline (drawn OUTSIDE the box) not border, so the highlight
            // wraps the element's exact bounds instead of sitting 2px inside it.
            // No border-radius: square elements must align at the corners.
            overlay.style.outline = '2px solid #41b883';
            overlay.style.background = 'rgba(65, 184, 131, 0.18)';
            overlay.style.boxSizing = 'border-box';
            overlay.style.display = 'none';
            document.documentElement.appendChild(overlay);
            state.overlay = overlay;
            return overlay;
        };
        const hideOverlay = () => { if (state.overlay) state.overlay.style.display = 'none'; };
        const restoreCursor = () => {
            if (state.prevCursor !== undefined && state.prevCursor !== null) {
                document.body.style.cursor = state.prevCursor;
            }
            state.prevCursor = null;
        };

        const buildSelector = (el) => {
            const tag = el.tagName.toLowerCase();
            const id = el.getAttribute && el.getAttribute('id');
            if (id) return tag + '[id="' + id + '"]';
            const cls = el.getAttribute && el.getAttribute('class');
            if (cls) return tag + '[class="' + cls + '"]';
            return tag;
        };
        const occurrenceOf = (el, selector) => {
            let nodes;
            try { nodes = document.querySelectorAll(selector); } catch { return -1; }
            for (let i = 0; i < nodes.length; i++) if (nodes[i] === el) return i;
            return -1;
        };
        // Walk from the clicked element up to <html>, emitting each ancestor's
        // (selector, occurrence). The panel picks the deepest one that maps to a
        // visible tree node, so hovering nested content still selects the right
        // component even when native elements are hidden.
        const chainOf = (el) => {
            const chain = [];
            let node = el;
            while (node && node.nodeType === 1 && node !== document.documentElement) {
                const selector = buildSelector(node);
                const occurrence = occurrenceOf(node, selector);
                if (occurrence >= 0) chain.push({ selector, occurrence });
                node = node.parentElement;
            }
            return chain;
        };
        const drawFor = (el) => {
            if (!el || el.nodeType !== 1) return hideOverlay();
            const rect = el.getBoundingClientRect();
            if (!rect || (rect.width <= 0 && rect.height <= 0)) return hideOverlay();
            const overlay = ensureOverlay();
            overlay.style.display = 'block';
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.width = Math.max(1, rect.width) + 'px';
            overlay.style.height = Math.max(1, rect.height) + 'px';
        };

        if (!enable) {
            state.pickerActive = false;
            hideOverlay();
            restoreCursor();
            return false;
        }

        state.pickerActive = true;
        state.picked = null;
        state.cancelled = false;
        if (state.prevCursor === undefined || state.prevCursor === null) {
            state.prevCursor = document.body.style.cursor || '';
        }
        document.body.style.cursor = 'crosshair';

        if (!state.pickerInstalled) {
            state.pickerInstalled = true;
            const onMove = (e) => {
                if (!state.pickerActive) return;
                drawFor(e.target);
            };
            const onClick = (e) => {
                if (!state.pickerActive) return;
                e.preventDefault();
                e.stopPropagation();
                const el = e.target;
                state.picked = (el && el.nodeType === 1) ? chainOf(el) : [];
                state.pickerActive = false;
                hideOverlay();
                restoreCursor();
            };
            const onKey = (e) => {
                if (!state.pickerActive || e.key !== 'Escape') return;
                e.preventDefault();
                e.stopPropagation();
                state.cancelled = true;
                state.pickerActive = false;
                hideOverlay();
                restoreCursor();
            };
            document.addEventListener('mousemove', onMove, true);
            document.addEventListener('click', onClick, true);
            document.addEventListener('keydown', onKey, true);
        }
        return true;
    })()`;
}

let pickMode = false;
let pickPollTimer: ReturnType<typeof setInterval> | null = null;

function setPickButtonActive(active: boolean): void {
    const btn = document.getElementById('zx-devtool-pick-btn');
    if (!btn) return;
    btn.classList.toggle('picker-btn-active', active);
    btn.setAttribute('aria-pressed', active ? 'true' : 'false');
}

function findTreeButton(selector: string, occurrence: number): HTMLElement | null {
    const btns = document.querySelectorAll('.component-select-btn, .component-select-btn-leaf');
    for (const b of Array.from(btns)) {
        if (
            b.getAttribute('data-sel') === selector &&
            (parseInt(b.getAttribute('data-idx') || '0', 10) || 0) === occurrence
        ) {
            return b as HTMLElement;
        }
    }
    return null;
}

/**
 * Given the clicked element's ancestor chain (deepest first), select the first
 * ancestor that maps to a tree node by clicking its button
 */
function selectComponentFromChain(chain: Array<{ selector: string; occurrence: number }>): boolean {
    for (const item of chain) {
        const btn = findTreeButton(item.selector, item.occurrence);
        if (btn) {
            btn.click();
            btn.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            return true;
        }
    }
    return false;
}

async function pollPick(): Promise<void> {
    const result = await evalInInspectedWindow<
        { cancelled?: boolean; chain?: Array<{ selector: string; occurrence: number }> } | null
    >(`(() => {
        const s = window['__ZX_DEVTOOL_HOVER_OVERLAY__'];
        if (!s) return null;
        if (s.cancelled) { s.cancelled = false; return { cancelled: true }; }
        const p = s.picked;
        s.picked = null;
        return p ? { chain: p } : null;
    })()`);

    if (!result) return;
    if (result.cancelled) {
        await exitPickMode();
        return;
    }
    if (result.chain) {
        selectComponentFromChain(result.chain);
        await exitPickMode();
    }
}

async function enterPickMode(): Promise<void> {
    if (pickMode) return;
    pickMode = true;
    setPickButtonActive(true);
    await stopHover();
    await evalInInspectedWindow(inspectedPickerScript(true));
    pickPollTimer = setInterval(() => {
        void pollPick();
    }, 120);
}

async function exitPickMode(): Promise<void> {
    if (!pickMode) return;
    pickMode = false;
    setPickButtonActive(false);
    if (pickPollTimer) {
        clearInterval(pickPollTimer);
        pickPollTimer = null;
    }
    await evalInInspectedWindow(inspectedPickerScript(false));
}

async function togglePickMode(): Promise<void> {
    if (pickMode) await exitPickMode();
    else await enterPickMode();
}

let hoveredKey: string | null = null;

function getHoveredComponentButton(target: EventTarget | null): HTMLElement | null {
    if (!(target instanceof Element)) return null;
    return target.closest('.component-select-btn, .component-select-btn-leaf');
}

async function startHover(selector: string, occurrence: number): Promise<void> {
    if (!selector) return;
    const key = selector + '#' + occurrence;
    if (hoveredKey === key) return;
    hoveredKey = key;
    await highlightInspectedComponent(selector, occurrence);
}

async function stopHover(): Promise<void> {
    if (!hoveredKey) return;
    hoveredKey = null;
    await clearInspectedComponentHighlight();
}

async function main() {
    const fromUrl = applyUrlConfig();
    if (!fromUrl) {
        await syncInspectedPageLocation();
    }
    await init({ kv: kvBindings });
}

/** Apply `?port=` / `?host=` into localStorage before WASM boots. */
function applyUrlConfig(): boolean {
    try {
        const params = new URLSearchParams(window.location.search);
        const host = params.get("host");
        if (host && host.trim()) {
            localStorage.setItem(HOST_STORAGE_KEY, host.trim());
            return true;
        }
        const portRaw = params.get("port");
        if (portRaw) {
            const port = Number.parseInt(portRaw, 10);
            if (Number.isFinite(port) && port > 0 && port < 65536) {
                localStorage.setItem(HOST_STORAGE_KEY, `localhost:${port}`);
                return true;
            }
        }
    } catch {
        // ignore
    }
    return false;
}

main();
// Full and SPA navigations of the inspected page, forwarded by extension/devtools.ts.
const chromeApi = (globalThis as any).chrome;
const inspectedTabId = chromeApi?.devtools?.inspectedWindow?.tabId;
chromeApi?.runtime?.onMessage?.addListener((msg: PanelNavigationMessage) => {
    if (msg?.type === 'zx-panel-navigation' && msg.tabId === inspectedTabId) {
        void refreshFromNavigation(msg.href);
    }
});

// Intercept clicks on route links and navigate the inspected page instead of
// opening a new tab, when running inside the Chrome DevTools extension.
document.addEventListener('click', (e: MouseEvent) => {
    const anchor = (e.target as Element)?.closest?.('[data-route-navigate]') as HTMLElement | null;
    if (!anchor) return;

    if (typeof inspectedTabId !== 'number') return;

    e.preventDefault();
    const path = anchor.getAttribute('data-route-navigate') || '/';
    void evalInInspectedWindow(`window.location.pathname = ${JSON.stringify(path)}`);
});

document.addEventListener('mouseover', async (e: MouseEvent) => {
    const btn = getHoveredComponentButton(e.target);
    if (!btn) return;
    const selector = btn.getAttribute('data-sel');
    if (!selector) return;
    const occurrence = parseInt(btn.getAttribute('data-idx') || '0', 10) || 0;
    await startHover(selector, occurrence);
});

document.addEventListener('mouseout', async (e: MouseEvent) => {
    const from = getHoveredComponentButton(e.target);
    if (!from) return;
    const to = getHoveredComponentButton(e.relatedTarget);
    if (to) return;
    await stopHover();
});

// Clicking a component in the tree focuses it in the inspected page, scrolling
// it into view when it isn't already visible. The framework's own onclick
// handler (handleComponentClick) still runs to update the selected component.
document.addEventListener('click', async (e: MouseEvent) => {
    const btn = getHoveredComponentButton(e.target);
    if (!btn) return;
    const selector = btn.getAttribute('data-sel');
    if (!selector) return;
    const occurrence = parseInt(btn.getAttribute('data-idx') || '0', 10) || 0;
    await focusInspectedComponent(selector, occurrence);
});

window.addEventListener('blur', async () => {
    await stopHover();
});

// Toggle the element picker from the sidebar button. The button is static
// (server-rendered), so delegation on document survives WASM re-renders.
document.addEventListener('click', (e: MouseEvent) => {
    const btn = (e.target as Element)?.closest?.('#zx-devtool-pick-btn');
    if (!btn) return;
    e.preventDefault();
    void togglePickMode();
});

// Escape cancels picking from the panel side (the page side handles Escape too,
// for when focus is in the inspected page).
document.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Escape' && pickMode) {
        void exitPickMode();
    }
});

function hostHttpBase(): string {
    const host = localStorage.getItem(HOST_STORAGE_KEY) || 'localhost:3000';
    if (host.startsWith('http://') || host.startsWith('https://')) return host.replace(/\/$/, '');
    return `http://${host}`;
}

function hostWsBase(): string {
    return hostHttpBase().replace(/^http/, 'ws');
}

// DevServer endpoints only exist on local `zx dev` hosts (also all the extension CSP allows).
function isLocalHost(): boolean {
    try {
        const { hostname } = new URL(hostHttpBase());
        return hostname === 'localhost' || hostname === '127.0.0.1';
    } catch {
        return false;
    }
}

// Open selected component source in the developer's editor via DevServer.
document.addEventListener('click', (e: MouseEvent) => {
    const btn = (e.target as Element)?.closest?.('[data-open-file]') as HTMLElement | null;
    if (!btn) return;
    const file = btn.getAttribute('data-open-file');
    if (!file || !isLocalHost()) return;
    e.preventDefault();
    const line = btn.getAttribute('data-open-line') || '1';
    const url = `${hostHttpBase()}/.well-known/_zx/open-in-editor?file=${encodeURIComponent(file)}&line=${encodeURIComponent(line)}&col=1`;
    void fetch(url, { method: 'GET' }).catch(() => {});
});

// Live-reload: subscribe to the inspected app's DevServer websocket and refresh
// the panel when the app rebuilds.
let devSocket: WebSocket | null = null;
let devSocketHost = '';
let devSocketRetry: ReturnType<typeof setTimeout> | null = null;

function disconnectDevSocket() {
    if (devSocketRetry) {
        clearTimeout(devSocketRetry);
        devSocketRetry = null;
    }
    if (devSocket) {
        try {
            devSocket.onclose = null;
            devSocket.close();
        } catch {
            // ignore
        }
        devSocket = null;
    }
    devSocketHost = '';
}

function connectDevSocket() {
    const host = localStorage.getItem(HOST_STORAGE_KEY) || 'localhost:3000';
    if (devSocket && devSocketHost === host && (devSocket.readyState === WebSocket.OPEN || devSocket.readyState === WebSocket.CONNECTING)) {
        return;
    }
    disconnectDevSocket();
    devSocketHost = host;
    if (!isLocalHost()) return;
    let ws: WebSocket;
    try {
        ws = new WebSocket(`${hostWsBase()}/.well-known/_zx/devsocket`);
    } catch {
        scheduleDevSocketRetry();
        return;
    }
    devSocket = ws;
    ws.onmessage = async (ev) => {
        try {
            const msg = JSON.parse(String(ev.data));
            const type = msg?.type;
            if (type === 'reload' || type === 'clear' || type === 'asset_update') {
                await window.__zx_dev_reinit?.();
            }
        } catch {
            // ignore malformed frames
        }
    };
    ws.onclose = () => {
        if (devSocket === ws) devSocket = null;
        scheduleDevSocketRetry();
    };
    ws.onerror = () => {
        try {
            ws.close();
        } catch {
            // ignore
        }
    };
}

function scheduleDevSocketRetry() {
    if (devSocketRetry) return;
    devSocketRetry = setTimeout(() => {
        devSocketRetry = null;
        connectDevSocket();
    }, 2000);
}

connectDevSocket();
window.addEventListener('storage', (e) => {
    if (e.key === HOST_STORAGE_KEY) connectDevSocket();
});
// Host changes from the WASM settings UI write localStorage in-page (no storage event).
setInterval(() => {
    const host = localStorage.getItem(HOST_STORAGE_KEY) || 'localhost:3000';
    if (host !== devSocketHost) connectDevSocket();
}, 3000);