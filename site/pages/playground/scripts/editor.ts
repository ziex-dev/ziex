import { appendTerminalLine, revealOutputWindow, setTerminalCollapsed, clearTerminal, appendStatusStep, completeStatusStep } from "./terminal.ts";
import { EditorState, Prec } from "@codemirror/state"
import { keymap } from "@codemirror/view"
import { EditorView, basicSetup } from "codemirror"
import { JsonRpcMessage, LspClient } from "./lsp";
import { indentWithTab } from "@codemirror/commands";
import { indentUnit } from "@codemirror/language";
import { editorTheme, editorHighlightStyle } from "./theme.ts";
import zigMainSource from './template/main.zig' with { type: "text" };
import zxModSource from './template/Playground.zx' with { type: "text" };
import zxstylecss from './template/style.css' with { type: "text" };
import { fileManager, PlaygroundFile } from "./file";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { javascript } from "@codemirror/lang-javascript";

export default class ZlsClient extends LspClient {
    public worker: Worker;

    constructor(worker: Worker) {
        super("file:///", []);
        this.worker = worker;
        this.autoClose = false;

        this.worker.addEventListener("message", this.messageHandler);
    }

    private messageHandler = (ev: MessageEvent) => {
        const data = JSON.parse(ev.data);

        if (data.method == "window/logMessage") {
            if (!data.stderr) {
                switch (data.params.type) {
                    case 5:
                        console.debug("ZLS --- ", data.params.message);
                        break;
                    case 4:
                        console.log("ZLS --- ", data.params.message);
                        break;
                    case 3:
                        console.info("ZLS --- ", data.params.message);
                        break;
                    case 2:
                        console.warn("ZLS --- ", data.params.message);
                        break;
                    case 1:
                        console.error("ZLS --- ", data.params.message);
                        break;
                    default:
                        console.error(data.params.message);
                        break;
                }
            }
        } else {
            console.debug("LSP <<-", data);
        }
        this.handleMessage(data);
    };

    public async sendMessage(message: JsonRpcMessage): Promise<void> {
        console.debug("LSP ->>", message);
        if (this.worker) {
            this.worker.postMessage(JSON.stringify(message));
        }
    }

    public async close(): Promise<void> {
        super.close();
        this.worker.terminate();
    }
}

let client = new ZlsClient(new Worker('/assets/playground/workers/zls.js'));


interface EditorFile {
    name: string;
    state: EditorState;
    hidden?: boolean;
    locked?: boolean; // if true, file cannot be renamed or deleted
}

let files: EditorFile[] = [];
let activeFileIndex = -1;
let editorView: EditorView;

function createEditorState(filename: string, content: string) {
    const extensions = [
        basicSetup,
        editorTheme,
        editorHighlightStyle,
        indentUnit.of("    "),
        keymap.of([
            indentWithTab,
            {
                key: "F5",
                run: () => {
                    outputsRun.click();
                    return true;
                },
            },
        ]),
    ];

    if (filename.endsWith('.zig') || filename.endsWith('.zx') || filename.endsWith('.zon')) {
        extensions.push(client.createPlugin(`file:///${filename}`, "zig", true));
    }

    if (filename.endsWith(".zx") || filename.endsWith(".html")) {
        if (filename.endsWith(".zx")) {
            extensions.push(Prec.highest(EditorState.languageData.of(() => [{ commentTokens: { line: "//" } }])));
        }
        extensions.push(html());
    } else if (filename.endsWith(".css")) {
        extensions.push(css());
    } else if (filename.endsWith(".js") || filename.endsWith(".jsx")) {
        extensions.push(javascript({ jsx: true }));
    } else if (filename.endsWith(".ts") || filename.endsWith(".tsx")) {
        extensions.push(javascript({ jsx: true, typescript: true }));
    }
    return EditorState.create({
        doc: content,
        extensions,
    });
}

function getFileClass(filename: string): string {
    if (filename.endsWith('.zig')) return 'zig';
    if (filename.endsWith('.zx')) return 'zx';
    if (filename.endsWith('.css')) return 'css';
    if (filename.endsWith('.html')) return 'html';
    if (filename.endsWith('.md')) return 'md';
    if (filename.endsWith('.jsx')) return 'jsx';
    if (filename.endsWith('.tsx')) return 'tsx';
    if (filename.endsWith('.js')) return 'js';
    if (filename.endsWith('.ts')) return 'ts';
    return 'file';
}

function updateTabs() {
    const tabsContainer = document.getElementById("pg-tabs")!;
    // Remove all tab buttons but keep the add-file button
    const addBtn = document.getElementById("pg-add-file");
    tabsContainer.innerHTML = "";

    files.forEach((file, index) => {
        if (file.hidden) return;
        const tab = document.createElement("button");
        tab.className = `pg-tab${index === activeFileIndex ? " pg-tab--active" : ""}`;
        tab.setAttribute("data-file", file.name);
        tab.id = `pg-tab-${index}`;

        const iconSpan = document.createElement("span");
        iconSpan.className = `pg-tab-icon type-${getFileClass(file.name)}`;
        const template = document.getElementById("pg-icons-template") as HTMLTemplateElement;
        if (template) {
            iconSpan.appendChild(template.content.cloneNode(true));
        }
        tab.appendChild(iconSpan);

        tab.appendChild(document.createTextNode(file.name));

        const closeBtn = document.createElement("span");
        closeBtn.className = "pg-tab-close";
        closeBtn.setAttribute("aria-label", "Close tab");
        closeBtn.innerHTML = "×";
        if (file.locked) {
            closeBtn.style.opacity = "0.3";
            closeBtn.style.pointerEvents = "none";
            closeBtn.title = "Main playground file: cannot rename or close, and fn Playground must exist in it";
        } else {
            closeBtn.onclick = (e) => {
                e.stopPropagation();
                removeFile(index);
            };
        }
        tab.appendChild(closeBtn);

        tab.onclick = () => switchFile(index);
        if (!file.locked) {
            tab.ondblclick = () => renameFile(index);
        } else {
            tab.ondblclick = null;
            tab.title = "Main playground file: cannot rename or close, and fn Playground must exist in it";
        }

        tabsContainer.appendChild(tab);
    });

    if (addBtn) {
        tabsContainer.appendChild(addBtn);
    } else {
        const newAddBtn = document.createElement("button");
        newAddBtn.className = "pg-tab-add";
        newAddBtn.id = "pg-add-file";
        newAddBtn.setAttribute("aria-label", "Add new file");
        newAddBtn.title = "New file";
        newAddBtn.textContent = "+";
        newAddBtn.addEventListener("click", addFile);
        tabsContainer.appendChild(newAddBtn);
    }
}

async function switchFile(index: number) {
    if (index === activeFileIndex) return;

    if (activeFileIndex !== -1 && editorView) {
        files[activeFileIndex].state = editorView.state;
        fileManager.updateContent(files[activeFileIndex].name, editorView.state.doc.toString());
    }

    activeFileIndex = index;
    const file = files[index];

    if (!editorView) {
        editorView = new EditorView({
            state: file.state,
            parent: document.getElementById("pg-code-area")!,
        });
    } else {
        editorView.setState(file.state);
    }

    updateTabs();
}

function addFile() {
    let name = "untitled.zx";
    let counter = 0;
    while (fileManager.hasFile(name)) {
        counter++;
        name = `untitled${counter}.zx`;
    }

    const promptedName = prompt("File name:", name);
    if (!promptedName) return;

    if (fileManager.hasFile(promptedName)) {
        alert("File already exists!");
        return;
    }

    fileManager.addFile(promptedName, "");
    const newFile: EditorFile = {
        name: promptedName,
        state: createEditorState(promptedName, ""),
    };
    files.push(newFile);
    switchFile(files.length - 1);
}

function removeFile(index: number) {
    if (files[index].locked) {
        alert("This file is locked and cannot be deleted.");
        return;
    }

    const removedFileWasActive = (index === activeFileIndex);
    fileManager.removeFile(files[index].name);
    files.splice(index, 1);

    if (removedFileWasActive) {
        activeFileIndex = -1;

        // Find the next visible (non-hidden) file
        let nextIndex = index;
        if (nextIndex >= files.length)  nextIndex = files.length - 1;
        while (nextIndex >= 0 && files[nextIndex]?.hidden) nextIndex--;
        if (nextIndex >= 0) switchFile(nextIndex);
        else updateTabs();
        
    } else {
        if (index < activeFileIndex) activeFileIndex--;
        updateTabs();
    }
}

function renameFile(index: number) {
    const file = files[index];
    if (file.locked) {
        alert("This file is locked and cannot be renamed.");
        return;
    }
    const newName = prompt("Rename file:", file.name);
    if (newName && newName !== file.name) {
        if (fileManager.hasFile(newName)) {
            alert("File already exists!");
            return;
        }
        const content = file.state.doc.toString();
        if (fileManager.renameFile(file.name, newName)) {
            file.name = newName;
            file.state = createEditorState(newName, content);
            if (index === activeFileIndex) {
                editorView.setState(file.state);
            }
            updateTabs();
        } else {
            alert("Rename failed!");
        }
    }
}



async function encodeFilesToQuery(filesMap: { [filename: string]: string }): Promise<string> {
    const filtered: { [filename: string]: string } = {};
    for (const [name, content] of Object.entries(filesMap)) {
        filtered[name] = content;
    }
    const json = JSON.stringify(filtered);
    const stream = new Blob([json]).stream().pipeThrough(new CompressionStream("deflate"));
    const buffer = await new Response(stream).arrayBuffer();

    let binString = '';
    const bytes = new Uint8Array(buffer);
    const CHUNK_SIZE = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
        binString += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + CHUNK_SIZE)));
    }
    const b64 = btoa(binString);
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function decodeFilesFromQuery(query: string): Promise<{ [filename: string]: string } | null> {
    try {
        let b64 = query.replace(/-/g, '+').replace(/_/g, '/');
        while (b64.length % 4) {
            b64 += '=';
        }
        const binString = atob(b64);
        const bytes = Uint8Array.from(binString, (m) => m.codePointAt(0)!);

        const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
        const text = await new Response(stream).text();
        return JSON.parse(text);
    } catch {
        return null;
    }
}

async function copyText(text: string): Promise<boolean> {
    try {
        await navigator.clipboard.writeText(text);
        return true;
    } catch {
        const textArea = document.createElement('textarea');
        textArea.value = text;
        textArea.style.position = 'fixed';
        textArea.style.opacity = '0';
        document.body.appendChild(textArea);
        textArea.select();
        try {
            document.execCommand('copy');
            document.body.removeChild(textArea);
            return true;
        } catch {
            document.body.removeChild(textArea);
            return false;
        }
    }
}

function showShareSuccess() {
    const btn = document.getElementById("pg-share-btn");
    if (!btn) return;
    const orig = btn.innerHTML;
    btn.innerHTML = '<span style="vertical-align:middle;display:inline-block;width:1em;height:1em;margin-right:0.3em;"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" width="1em" height="1em"><path fill-rule="evenodd" d="M16.704 6.29a1 1 0 0 1 0 1.42l-6.004 6a1 1 0 0 1-1.416 0l-2.996-3a1 1 0 1 1 1.416-1.42l2.288 2.29 5.296-5.29a1 1 0 0 1 1.416 0z" clip-rule="evenodd"/></svg></span>Copied!';
    setTimeout(() => { btn.innerHTML = orig; }, 1200);
}

document.getElementById("pg-share-btn")?.addEventListener("click", async () => {
    const filesMap = getCurrentFilesMap();

    // Create the URL promise for ClipboardItem (Safari needs this pattern for async clipboard)
    const urlPromise = encodeFilesToQuery(filesMap).then(encoded =>
        `${location.origin}${location.pathname}#data=${encoded}`
    );

    // Try ClipboardItem with Promise first (Safari-friendly for async data)
    let success = false;
    if (navigator.clipboard && typeof ClipboardItem !== 'undefined') {
        try {
            const item = new ClipboardItem({
                'text/plain': urlPromise.then(url => new Blob([url], { type: 'text/plain' }))
            });
            await navigator.clipboard.write([item]);
            success = true;
        } catch {
            // Fall through to fallback
        }
    }

    // Fallback: await the URL then use execCommand
    if (!success) {
        const url = await urlPromise;
        success = await copyText(url);
    }

    const url = await urlPromise;
    if (url.length > 8000) {
        alert(`Warning: This share link is ${url.length} characters long. Older browsers, proxies, or chat apps max out at 2,000-8,000 bytes and might truncate it, breaking the link.`);
    }

    if (success) {
        showShareSuccess();
    } else {
        alert("Failed to copy link to clipboard. Please copy manually:\n\n" + url);
    }
});

function loadTemplateFiles() {
    fileManager.addFile("Playground.zx", zxModSource);
    fileManager.addFile("main.zig", zigMainSource);
    fileManager.addFile("style.css", zxstylecss);
}

function clearSharedDataHashFromUrl() {
    if (!location.hash.startsWith("#data=")) return;
    history.replaceState(null, "", `${location.pathname}${location.search}`);
}


window.addEventListener("DOMContentLoaded", async () => {
    await client.initialize();
    let code = null;
    if (location.hash.startsWith("#data=")) {
        code = location.hash.slice(6);
    }
    let initialFileIndex = 0;
    if (code) {
        const filesDecoded = await decodeFilesFromQuery(code);
        if (filesDecoded) {
            fileManager.getAllFiles().forEach(f => fileManager.removeFile(f.name));
            Object.entries(filesDecoded).forEach(([name, content]) => fileManager.addFile(name, content));
            const newFiles = fileManager.getAllFiles().map(f => ({
                name: f.name,
                state: createEditorState(f.name, f.content),
                hidden: f.name === "main.zig",
                locked: f.name === "Playground.zx" || f.name === "main.zig",
            }));
            files.length = 0;
            files.push(...newFiles);
            updateTabs();
            await switchFile(initialFileIndex);
            // Force re-setting the state to trigger LSP plugin
            if (editorView && files[initialFileIndex]) {
                editorView.setState(files[initialFileIndex].state);
            }
            clearSharedDataHashFromUrl();
            return;
        }
    }
    loadTemplateFiles();
    const newFiles = fileManager.getAllFiles().map(f => ({
        name: f.name,
        state: createEditorState(f.name, f.content),
        hidden: f.name === "main.zig",
        locked: f.name === "Playground.zx" || f.name === "main.zig",
    }));
    files.length = 0;
    files.push(...newFiles);
    updateTabs();
    await switchFile(initialFileIndex);
    if (editorView && files[initialFileIndex]) {
        editorView.setState(files[initialFileIndex].state);
    }
});

// Only initialize client here, file loading is handled in DOMContentLoaded
(async () => {
    // await client.initialize();
})();

document.getElementById("pg-add-file")?.addEventListener("click", addFile);

// Convert vertical mouse wheel to horizontal scroll on the tabs bar
const tabsEl = document.getElementById("pg-tabs")!;
tabsEl.addEventListener("wheel", (e) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        e.preventDefault();
        tabsEl.scrollLeft += e.deltaY;
    }
}, { passive: false });

// Show/hide right scroll shadow when tabs overflow
function updateTabsScrollShadow() {
    const hasOverflowRight = tabsEl.scrollLeft + tabsEl.clientWidth < tabsEl.scrollWidth - 1;
    tabsEl.classList.toggle("scroll-shadow-right", hasOverflowRight);
}
tabsEl.addEventListener("scroll", updateTabsScrollShadow);
new ResizeObserver(updateTabsScrollShadow).observe(tabsEl);
new MutationObserver(updateTabsScrollShadow).observe(tabsEl, { childList: true });


let zigWorker = new Worker('/assets/playground/workers/zig.js');
let zxWorker = new Worker('/assets/playground/workers/zx.js');

function setRunButtonLoading(loading: boolean) {
    const btn = document.getElementById("pg-run-btn")!;
    if (loading) {
        btn.classList.add("pg-nav-btn--loading");
        btn.setAttribute("disabled", "true");
        btn.innerHTML = '<span class="pg-spinner"></span>';
    } else {
        btn.classList.remove("pg-nav-btn--loading");
        btn.removeAttribute("disabled");
        btn.innerHTML = 'Run';
    }
}

/** Restore the preview pane to the idle "Press Run" state. */
function resetPreviewPlaceholder() {
    const viewport = document.getElementById("pg-browser-viewport")!;
    while (viewport.firstChild) viewport.removeChild(viewport.firstChild);
    const placeholder = document.createElement("div");
    placeholder.className = "pg-browser-placeholder";
    const icon = document.createElement("div");
    icon.className = "pg-browser-placeholder-icon";
    icon.textContent = "";
    placeholder.appendChild(icon);
    placeholder.appendChild(document.createTextNode("Press Run to see preview"));
    viewport.appendChild(placeholder);
}

/** Update the preview pane's in-progress placeholder to reflect the current pipeline step. */
function updatePreviewStatus(emoji: string, label: string, stepId: string) {
    const iconEl = document.getElementById("pg-preview-step-icon");
    const textEl = document.getElementById("pg-preview-step-label");
    if (iconEl) {
        iconEl.textContent = emoji;
        iconEl.dataset.step = stepId;
    }
    if (textEl) textEl.textContent = label;
}

// ─── Content hash (fast djb2 variant) ───────────────────────────────────────
function hashFiles(map: { [name: string]: string }): string {
    const s = JSON.stringify(Object.entries(map).sort(([a], [b]) => a.localeCompare(b)));
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = Math.imul(h, 33) ^ s.charCodeAt(i);
    return (h >>> 0).toString(36);
}

// ─── In-memory LRU caches (max 8 entries each) ──────────────────────────────
const MAX_CACHE = 8;
function cachePut<V>(cache: Map<string, V>, key: string, value: V) {
    if (cache.size >= MAX_CACHE) cache.delete(cache.keys().next().value!);
    cache.set(key, value);
}

interface CacheEntry<V> {
    value: V;
    duration: number;
    isPrefetch: boolean;
}

const transpileCache = new Map<string, CacheEntry<{ [name: string]: string }>>();
const buildCache = new Map<string, CacheEntry<unknown>>();

// ─── Promisified transpile ───────────────────────────────────────────────────
let transpile_start_time: number | null = null;
function transpileZxFileAsync(zxName: string, zxContent: string): Promise<{ [filename: string]: string }> {
    return new Promise((resolve, reject) => {
        function handler(ev: MessageEvent) {
            const d = ev.data;
            if (d && d.filename && d.transpiled) {
                zxWorker.removeEventListener('message', handler);
                resolve({ [d.filename]: d.transpiled });
            } else if (d && d.failed) {
                zxWorker.removeEventListener('message', handler);
                reject({ stderr: d.stderr || 'Transpile failed' });
            } else if (d && d.stdout) {
                zxWorker.removeEventListener('message', handler);
                resolve({ [zxName.replace(/\.zx$/, '.zig')]: d.stdout });
            }
        }
        zxWorker.addEventListener('message', handler);
        transpile_start_time = performance.now();
        zxWorker.postMessage({ filename: zxName, content: zxContent });
    });
}

// ─── Promisified build ───────────────────────────────────────────────────────
let build_start_time = performance.now();
function buildFilesAsync(filesMap: { [name: string]: string }): Promise<unknown> {
    return new Promise((resolve, reject) => {
        function handler(ev: MessageEvent) {
            zigWorker.removeEventListener('message', handler);
            const d = ev.data;
            console.info('Build finished in', (performance.now() - build_start_time).toFixed(2), 'ms');
            if (d.stderr) reject({ type: 'stderr', stderr: d.stderr });
            else if (d.failed) reject({ type: 'failed' });
            else if (d.compiled) resolve(d.compiled);
        }
        zigWorker.addEventListener('message', handler);
        build_start_time = performance.now();
        zigWorker.postMessage({ files: filesMap });
    });
}

// ─── Run compiled binary ─────────────────────────────────────────────────────
function runCompiled(compiled: unknown) {
    appendStatusStep('run', 'Running\u2026');
    updatePreviewStatus('', 'Running\u2026', 'run');

    const runnerWorker = new Worker('/assets/playground/workers/runner.js');
    runnerWorker.postMessage({ run: compiled });
    runnerWorker.onmessage = (rev: MessageEvent) => {
        if (rev.data.stderr) {
            completeStatusStep('run', 'error');
            const lines = rev.data.stderr.split('\n').filter((l: string) => l.length > 0);
            for (const l of lines) appendTerminalLine(l, 'pg-terminal-error');
            setTerminalCollapsed(false);
            revealOutputWindow();
            setRunButtonLoading(false);
            resetPreviewPlaceholder();
            return;
        }
        if (rev.data.preview) {
            const vp = document.getElementById('pg-browser-viewport')!;
            let iframe = vp.querySelector('iframe') as HTMLIFrameElement;
            if (!iframe) {
                vp.innerHTML = '';
                iframe = document.createElement('iframe');
                iframe.style.cssText = 'width:100%;height:100%;border:none;background-color:white';
                vp.appendChild(iframe);
                iframe.contentDocument?.open();
            }
            iframe.contentDocument?.write(rev.data.preview);
            return;
        }
        if (rev.data.done) {
            completeStatusStep('run', 'done');
            const iframe = document.getElementById('pg-browser-viewport')!.querySelector('iframe') as HTMLIFrameElement;
            if (iframe) iframe.contentDocument?.close();
            runnerWorker.terminate();
            setRunButtonLoading(false);
        }
    };
}

// ─── getCurrentFilesMap ──────────────────────────────────────────────────────
function getCurrentFilesMap(): { [filename: string]: string } {
    if (activeFileIndex !== -1 && editorView) {
        fileManager.updateContent(files[activeFileIndex].name, editorView.state.doc.toString());
    }
    const map: { [filename: string]: string } = {};
    fileManager.getAllFiles().forEach(f => {
        if (!files.find(x => x.name === f.name)?.hidden) map[f.name] = f.content;
    });
    return map;
}

// ─── Core pipeline (shared by Run click + silent prefetch) ───────────────────
async function runTranspileAndBuild(visible: boolean): Promise<unknown | null> {
    let filesMap = getCurrentFilesMap();
    if (!filesMap['main.zig']) filesMap['main.zig'] = zigMainSource;

    const zxEntries = Object.entries(filesMap).filter(([n]) => n.endsWith('.zx'));

    // ── Transpile ────────────────────────────────────────────────────────────
    const zxHash = hashFiles(Object.fromEntries(zxEntries));
    let transpiledFiles: { [name: string]: string } = {};

    // Check for empty zx files
    const emptyZxFiles = zxEntries.filter(([_, content]) => !content.trim());
    if (emptyZxFiles.length > 0) {
        if (visible) {
            completeStatusStep('transpile', 'error');
            appendTerminalLine('One or more .zx files are empty. Please add code or remove the empty file(s).', 'pg-terminal-error');
            setTerminalCollapsed(false);
            revealOutputWindow();
            resetPreviewPlaceholder();
            setRunButtonLoading(false);
        }
        return null;
    }

    if (zxEntries.length > 0) {
        const hit = transpileCache.get(zxHash);
        if (hit) {
            transpiledFiles = hit.value;
            if (visible) {
                appendStatusStep('transpile', 'Transpiling\u2026');
                if (hit.isPrefetch) {
                    completeStatusStep('transpile', 'prefetched', hit.duration);
                    hit.isPrefetch = false; // Next run will just be 'cached'
                } else {
                    completeStatusStep('transpile', 'cached');
                }
                updatePreviewStatus('', 'Transpiling\u2026 (cached)', 'transpile');
            }
        } else {
            if (visible) {
                appendStatusStep('transpile', 'Transpiling\u2026');
                updatePreviewStatus('', 'Transpiling\u2026', 'transpile');
            }
            const start = performance.now();
            try {
                for (const [name, content] of zxEntries) {
                    const result = await transpileZxFileAsync(name, content);
                    Object.assign(transpiledFiles, result);
                }
                const duration = performance.now() - start;
                cachePut(transpileCache, zxHash, { value: { ...transpiledFiles }, duration, isPrefetch: !visible });
                if (visible) completeStatusStep('transpile', 'done');
            } catch (err: any) {
                if (visible) {
                    completeStatusStep('transpile', 'error');
                    appendTerminalLine(err.stderr || 'Transpile failed', 'pg-terminal-error');
                    setTerminalCollapsed(false);
                    revealOutputWindow();
                    resetPreviewPlaceholder();
                    setRunButtonLoading(false);
                }
                return null;
            }
        }
    } else if (visible) {
        updatePreviewStatus('', 'Building\u2026', 'build');
    }

    // Merge transpiled zig files into filesMap + file manager
    for (const [zigName, zigContent] of Object.entries(transpiledFiles)) {
        filesMap[zigName] = zigContent;
        if (fileManager.hasFile(zigName)) {
            fileManager.updateContent(zigName, zigContent);
            const f = files.find(x => x.name === zigName);
            if (f) { f.state = createEditorState(zigName, zigContent); f.hidden = true; }
        } else {
            fileManager.addFile(zigName, zigContent);
            files.push({ name: zigName, state: createEditorState(zigName, zigContent), hidden: true });
        }
    }

    // ── Build ─────────────────────────────────────────────────────────────────
    const buildKey = hashFiles(filesMap);
    const buildHit = buildCache.get(buildKey);
    if (buildHit) {
        if (visible) {
            appendStatusStep('build', 'Building\u2026');
            if (buildHit.isPrefetch) {
                completeStatusStep('build', 'prefetched', buildHit.duration);
                buildHit.isPrefetch = false;
            } else {
                completeStatusStep('build', 'cached');
            }
            updatePreviewStatus('', 'Building\u2026 (cached)', 'build');
        }
        return buildHit.value;
    }

    if (visible) {
        appendStatusStep('build', 'Building\u2026');
        updatePreviewStatus('', 'Building\u2026', 'build');
    }
    const bStart = performance.now();
    try {
        const compiled = await buildFilesAsync(filesMap);
        const bDuration = performance.now() - bStart;
        cachePut(buildCache, buildKey, { value: compiled, duration: bDuration, isPrefetch: !visible });
        if (visible) completeStatusStep('build', 'done');
        return compiled;
    } catch (err: any) {
        if (visible) {
            completeStatusStep('build', 'error');
            if (err.stderr) {
                const lines = err.stderr.split('\n').filter((l: string) => l.length > 0);
                for (const l of lines) appendTerminalLine(l, 'pg-terminal-error');
            } else {
                appendTerminalLine('Compilation failed.', 'pg-terminal-error');
            }
            setTerminalCollapsed(false);
            revealOutputWindow();
            resetPreviewPlaceholder();
            setRunButtonLoading(false);
        }
        return null;
    }
}

let prefetchPromise: Promise<void> | null = null;
const outputsRun = document.getElementById('pg-run-btn')! as HTMLButtonElement;
outputsRun.addEventListener('click', async () => {
    setRunButtonLoading(true);
    clearTerminal();

    // Animated "building" preview placeholder
    const viewport = document.getElementById('pg-browser-viewport')!;
    while (viewport.firstChild) viewport.removeChild(viewport.firstChild);
    const ph = document.createElement('div');
    ph.className = 'pg-browser-placeholder pg-browser-placeholder--building';
    const phIcon = document.createElement('div');
    phIcon.className = 'pg-browser-placeholder-icon';
    phIcon.id = 'pg-preview-step-icon';
    phIcon.dataset.step = 'transpile';
    phIcon.textContent = '';
    ph.appendChild(phIcon);
    const phLabel = document.createElement('span');
    phLabel.id = 'pg-preview-step-label';
    phLabel.textContent = 'Transpiling\u2026';
    ph.appendChild(phLabel);
    viewport.appendChild(ph);

    // If a background prefetch is in flight, wait — result will be in cache
    if (prefetchPromise) await prefetchPromise;

    const compiled = await runTranspileAndBuild(true);
    if (compiled == null) return;
    runCompiled(compiled);
});

// ─── Background building on editor mouseleave ────────────────────────────────
document.getElementById('pg-editor')?.addEventListener('mouseleave', () => {
    if (prefetchPromise) return; // already prefetching

    const snap = getCurrentFilesMap();
    if (!snap['main.zig']) snap['main.zig'] = zigMainSource;
    const zxEntries = Object.entries(snap).filter(([n]) => n.endsWith('.zx'));
    const zxHash = hashFiles(Object.fromEntries(zxEntries));
    const transpiled = transpileCache.get(zxHash) ?? (zxEntries.length === 0 ? { value: {} } : null);
    if (transpiled !== null && buildCache.has(hashFiles({ ...snap, ...transpiled.value }))) return;

    prefetchPromise = (async () => {
        try { await runTranspileAndBuild(false); } catch { /* silent */ }
    })().finally(() => { prefetchPromise = null; });
});
