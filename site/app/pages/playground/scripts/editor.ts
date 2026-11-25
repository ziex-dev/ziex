import { appendTerminalLine, revealOutputWindow, setTerminalCollapsed, clearTerminal, appendStatusStep, completeStatusStep, onOutput, setShellHooks, showPanelTab } from "./terminal.ts";
import type { DevBuildResult, Shell, ShellHost, ZigExecResult, ZxExecResult } from "./shell.ts";
import { EditorState, Prec } from "@codemirror/state"
import { keymap, ViewPlugin, type ViewUpdate } from "@codemirror/view"
import { EditorView, basicSetup } from "codemirror"
import { createZlsClient, setPlaygroundLspUiHooks, workerTransport, type LocalFileTarget } from "./lsp";
import { formatDocument } from "@codemirror/lsp-client";
import { LSPPlugin } from "@codemirror/lsp-client";
import { indentWithTab } from "@codemirror/commands";
import { indentUnit } from "@codemirror/language";
import { editorTheme, editorHighlightStyle } from "./theme.ts";
import { flattenDirectory, isGeneratedPlaygroundPath, CLIENT_WASM_PLACEHOLDER, type PlaygroundBuildArtifacts } from "./csr.ts";
import {
    type PlaygroundMode,
    defaultTemplateId,
    getTemplate,
    loadTemplates,
    templatesForMode,
} from "./templates.ts";
// @ts-ignore
import stubZxInfo from './template/stubs/zx_info.zig' with { type: "text" };
// @ts-ignore
import stubAppOpts from './template/stubs/app_opts.zig' with { type: "text" };
// @ts-ignore
import stubManifest from './template/stubs/manifest.zon' with { type: "text" };
// @ts-ignore
import stubBuildInjections from './template/stubs/build_injections.zon' with { type: "text" };
import { fileManager, PlaygroundFile } from "./file";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { javascript } from "@codemirror/lang-javascript";
import { createPlaygroundShareUrl, decodeFilesFromQuery } from "../../../scripts/playground_share";
import { getLatestZigArchive, getZxArchive } from "./utils";

declare const VERSION: string;
declare const ZIG_VERSION: string;

let client = createZlsClient(workerTransport(new Worker(`/assets/playground/workers/zls.js?v=${VERSION}`)));
setPlaygroundLspUiHooks({
    openLocalFile: (target) => {
        void openLinkedFile(target);
    },
});
const PLAYGROUND_NOTICE_STORAGE_KEY = "playground_feature_notice_dismissed_v1";
const MODE_STORAGE_KEY = "playground_mode_v1";
const TEMPLATE_STORAGE_KEY = "playground_template_v2";
const PERSIST_FILES_KEY = "playground_persist_files_v1";
const FILES_IDB_NAME = "ziex-playground-files-v1";
const BUILDS_IDB_NAME = `ziex-playground-builds-${VERSION}`;
const IDB_STORE = "data";

let persistFilesEnabled = false;
try {
    persistFilesEnabled = localStorage.getItem(PERSIST_FILES_KEY) === "1";
} catch { /* ignore */ }

let playgroundMode: PlaygroundMode = "playground";
let activeTemplateId = "playground";

try {
    const savedMode = localStorage.getItem(MODE_STORAGE_KEY);
    if (savedMode === "app" || savedMode === "playground") playgroundMode = savedMode;
    const savedTemplate = localStorage.getItem(TEMPLATE_STORAGE_KEY);
    if (savedTemplate) activeTemplateId = savedTemplate;
    else activeTemplateId = playgroundMode === "app" ? "app" : "playground";
} catch { /* ignore */ }

function resolveActiveTemplateId() {
    if (getTemplate(activeTemplateId)?.mode === playgroundMode) return;
    activeTemplateId = defaultTemplateId(playgroundMode);
}

window.addEventListener("message", (ev: MessageEvent) => {
    if (ev.data?.type === "pg-hydrate-error" && typeof ev.data.message === "string") {
        appendTerminalLine(ev.data.message, "pg-terminal-error");
        setTerminalCollapsed(false);
        revealOutputWindow();
    }
});


interface EditorFile {
    name: string;
    state: EditorState;
    hidden?: boolean;
    locked?: boolean; // if true, file cannot be renamed or deleted
    readonly?: boolean;
    ephemeral?: boolean; // if true, exclude from build/persistence and treat as preview-only
    sourceName?: string; // original file path for ephemeral/readonly tabs
}

let files: EditorFile[] = [];
let activeFileIndex = -1;
let editorView: EditorView;
let formatting = false;
let metaImplementationClickInstalled = false;

function languageLabel(filename: string): string {
    if (filename.endsWith(".zx") || filename.endsWith(".mdzx")) return "ZX";
    if (filename.endsWith(".zig") || filename.endsWith(".zon")) return "Zig";
    if (filename.endsWith(".css")) return "CSS";
    if (filename.endsWith(".html")) return "HTML";
    if (filename.endsWith(".ts") || filename.endsWith(".tsx")) return "TS";
    if (filename.endsWith(".js") || filename.endsWith(".jsx")) return "JS";
    if (filename.endsWith(".md")) return "MD";
    return "File";
}

function updateEditorStatus(view: EditorView, filename: string) {
    const pos = view.state.selection.main.head;
    const line = view.state.doc.lineAt(pos);
    const col = pos - line.from + 1;
    const cursorEl = document.getElementById("pg-cursor-pos");
    if (cursorEl) cursorEl.textContent = `Ln ${line.number}, Col ${col}`;
    const langEl = document.getElementById("pg-file-lang");
    if (langEl) langEl.textContent = languageLabel(filename);
}

function editorStatusPlugin(filename: string) {
    return ViewPlugin.fromClass(class {
        constructor(view: EditorView) {
            updateEditorStatus(view, filename);
        }
        update(update: ViewUpdate) {
            if (update.selectionSet || update.docChanged || update.focusChanged) {
                updateEditorStatus(update.view, filename);
            }
            if (update.docChanged) schedulePersistFiles();
        }
    });
}

function createEditorState(filename: string, content: string, opts: { readonly?: boolean } = {}) {
    const extensions = [
        basicSetup,
        editorTheme,
        editorHighlightStyle,
        indentUnit.of("    "),
        editorStatusPlugin(filename),
        Prec.highest(keymap.of([
            {
                key: "Shift-Alt-f",
                run: () => {
                    void formatActiveFile();
                    return true;
                },
            },
            {
                key: "Mod-s",
                run: () => {
                    void (async () => {
                        const formatted = await formatActiveFile({ silentSuccess: true });
                        if (formatted) await runCurrentFiles({ preservePreview: true });
                    })();
                    return true;
                },
            },
        ])),
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

    if (opts.readonly) {
        extensions.push(EditorState.readOnly.of(true));
        extensions.push(EditorView.editable.of(false));
    }

    if (filename.endsWith('.zig') || filename.endsWith('.zx') || filename.endsWith('.zon')) {
        // ZX wasm LSP (ZLS-backed when built with -Dzls=true).
        extensions.push(client.plugin(`file:///${filename}`, "zig"));
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

function filePath(file: EditorFile): string {
    return file.sourceName ?? file.name;
}

function fileTabLabel(file: EditorFile): string {
    const path = filePath(file);
    return path.includes("/") ? path.slice(path.lastIndexOf("/") + 1) : path;
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
        tab.className = `pg-tab${index === activeFileIndex ? " pg-tab--active" : ""}${file.readonly ? " pg-tab--readonly" : ""}`;
        tab.setAttribute("data-file", filePath(file));
        tab.id = `pg-tab-${index}`;
        tab.title = file.readonly ? `${filePath(file)}\nRead-only preview` : filePath(file);

        const iconSpan = document.createElement("span");
        iconSpan.className = `pg-tab-icon type-${getFileClass(file.name)}`;
        const template = document.getElementById("pg-icons-template") as HTMLTemplateElement;
        if (template) {
            iconSpan.appendChild(template.content.cloneNode(true));
        }
        tab.appendChild(iconSpan);

        const tabLabel = fileTabLabel(file);
        tab.appendChild(document.createTextNode(tabLabel));

        const closeBtn = document.createElement("span");
        closeBtn.className = "pg-tab-close";
        closeBtn.setAttribute("aria-label", "Close tab");
        closeBtn.innerHTML = "×";
        if (file.locked) {
            closeBtn.style.opacity = "0.3";
            closeBtn.style.pointerEvents = "none";
            closeBtn.title = "Locked framework entry file";
        } else {
            closeBtn.onclick = (e) => {
                e.stopPropagation();
                removeFile(index);
            };
        }
        tab.appendChild(closeBtn);

        tab.onclick = () => switchFile(index);
        if (!file.locked && !file.readonly) {
            tab.ondblclick = () => renameFile(index);
        } else {
            tab.ondblclick = null;
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

function getKnownFileContent(path: string): string | null {
    if (activeFileIndex !== -1 && files[activeFileIndex] && filePath(files[activeFileIndex]) === path && editorView) {
        return editorView.state.doc.toString();
    }
    const existing = files.find((file) => filePath(file) === path && !file.ephemeral);
    if (existing) return existing.state.doc.toString();
    const stored = fileManager.getAllFiles().find((file) => file.name === path);
    return stored?.content ?? null;
}

let zxArchiveFilesPromise: Promise<Record<string, Uint8Array>> | null = null;
let zigArchiveFilesPromise: Promise<Record<string, Uint8Array>> | null = null;

async function getZxArchiveFiles(): Promise<Record<string, Uint8Array>> {
    if (!zxArchiveFilesPromise) {
        zxArchiveFilesPromise = getZxArchive().then((dir) => flattenDirectory(dir));
    }
    return zxArchiveFilesPromise;
}

async function getZigArchiveFiles(): Promise<Record<string, Uint8Array>> {
    if (!zigArchiveFilesPromise) {
        zigArchiveFilesPromise = getLatestZigArchive().then((dir) => flattenDirectory(dir));
    }
    return zigArchiveFilesPromise;
}

function pathsEqual(a: string, b: string): boolean {
    const norm = (p: string) => p.replace(/^\/+/, "");
    return norm(a) === norm(b);
}

function findOpenFileIndex(path: string): number {
    return files.findIndex((file) => pathsEqual(filePath(file), path) || pathsEqual(file.name, path));
}

function goToLine(line: number, character = 0) {
    if (!editorView) return;
    const doc = editorView.state.doc;
    const cmLine = doc.line(Math.min(Math.max(line, 0) + 1, doc.lines));
    const cursorPos = Math.min(cmLine.from + Math.max(character, 0), cmLine.to);
    editorView.dispatch({
        selection: { anchor: cursorPos, head: cursorPos },
        scrollIntoView: true,
        effects: EditorView.scrollIntoView(cursorPos, { y: "center" }),
    });
    editorView.focus();
}

async function resolveReadonlyLinkedFile(path: string): Promise<string | null> {
    const known = getKnownFileContent(path);
    if (known != null) return known;

    if (path.startsWith("zx/") || path.startsWith("src/")) {
        const archiveFiles = await getZxArchiveFiles();
        const bytes =
            archiveFiles[path] ??
            archiveFiles[path.replace(/^zx\//, "")] ??
            archiveFiles[`zx/${path}`] ??
            archiveFiles[path.startsWith("src/") ? path : `src/${path.replace(/^zx\//, "")}`];
        if (bytes) return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
    }

    // WASI / hover links: file:///lib/std/... → zig stdlib tar (lib/ prefix stripped in archive).
    if (path.startsWith("lib/") || path.startsWith("std/")) {
        const archiveFiles = await getZigArchiveFiles();
        const rel = path.replace(/^lib\//, "");
        const bytes = archiveFiles[rel] ?? archiveFiles[path] ?? archiveFiles[`lib/${rel}`];
        if (bytes) return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
    }
    return null;
}

async function openLinkedFile(target: LocalFileTarget | string): Promise<boolean> {
    const path = typeof target === "string" ? target : target.path;
    const line = typeof target === "string" ? undefined : target.line;
    const character = typeof target === "string" ? undefined : target.character;

    const existingIndex = findOpenFileIndex(path);
    if (existingIndex >= 0) {
        await switchFile(existingIndex);
        if (line != null) goToLine(line, character ?? 0);
        return true;
    }

    const content = await resolveReadonlyLinkedFile(path);
    if (content == null) return false;

    const file: EditorFile = {
        name: path,
        sourceName: path,
        state: createEditorState(path, content, { readonly: true }),
        readonly: true,
        ephemeral: true,
    };
    files.push(file);
    updateTabs();
    await switchFile(files.length - 1);
    if (line != null) goToLine(line, character ?? 0);
    return true;
}

/** @deprecated Prefer openLinkedFile */
async function openReadonlyLinkedFile(path: string): Promise<boolean> {
    return openLinkedFile(path);
}

async function switchFile(index: number) {
    if (index !== activeFileIndex) {
        if (activeFileIndex !== -1 && editorView) {
            files[activeFileIndex].state = editorView.state;
            if (!files[activeFileIndex].ephemeral) {
                fileManager.updateContent(files[activeFileIndex].name, editorView.state.doc.toString());
            }
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
    }

    if (!editorView) return;

    if (!metaImplementationClickInstalled) {
        metaImplementationClickInstalled = true;
        editorView.dom.addEventListener(
            "click",
            (ev) => {
                // Cmd/Ctrl-click on a symbol -> request implementations and navigate.
                if (!("metaKey" in ev) || !(ev as MouseEvent).metaKey) return;
                const e = ev as MouseEvent;
                if (e.button != null && e.button !== 0) return;

                const plugin = LSPPlugin.get(editorView);
                if (!plugin) return;

                const pos = editorView.posAtCoords({ x: e.clientX, y: e.clientY });
                if (pos == null) return;

                void (async () => {
                    try {
                        const impl = await plugin.client.request<any, any>("textDocument/implementation", {
                            textDocument: { uri: plugin.uri },
                            position: plugin.toPosition(pos),
                        });
                        if (!impl) return;
                        const locations = Array.isArray(impl) ? impl : impl.locations;
                        const location = locations?.[0];
                        const start = location?.range?.start;
                        const uri = location?.uri;
                        if (!start || !uri) return;

                        let path: string | null = null;
                        if (typeof uri === "string" && uri.startsWith("file://")) {
                            try {
                                path = decodeURIComponent(new URL(uri).pathname).replace(/^\/+/, "");
                            } catch {
                                path = uri.replace(/^file:\/+/, "").split("#")[0].replace(/^\/+/, "");
                            }
                        } else if (typeof uri === "string") {
                            path = uri.split("#")[0].replace(/^\/+/, "");
                        }
                        if (!path) return;

                        await openLinkedFile({
                            path,
                            line: start.line,
                            character: start.character,
                        });
                    } catch {
                        // ignore
                    }
                })();
            },
            true,
        );
    }

    updateEditorStatus(editorView, files[activeFileIndex]?.name ?? "");
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
    schedulePersistFiles();
}

function removeFile(index: number) {
    if (files[index].locked) {
        alert("This file is locked and cannot be deleted.");
        return;
    }

    const removedFileWasActive = (index === activeFileIndex);
    if (!files[index].ephemeral) {
        fileManager.removeFile(files[index].name);
    }
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
    schedulePersistFiles();
}

function renameFile(index: number) {
    const file = files[index];
    if (file.locked || file.readonly) {
        alert(file.readonly ? "This preview tab is read-only and cannot be renamed." : "This file is locked and cannot be renamed.");
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
            schedulePersistFiles();
        } else {
            alert("Rename failed!");
        }
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
    const urlPromise = createPlaygroundShareUrl(filesMap, `${location.origin}${location.pathname}`);

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

function persistModeState() {
    try {
        localStorage.setItem(MODE_STORAGE_KEY, playgroundMode);
        localStorage.setItem(TEMPLATE_STORAGE_KEY, activeTemplateId);
    } catch { /* ignore */ }
}

function updateModeNotice() {
    const el = document.getElementById("pg-feature-notice-text");
    if (!el) return;
    el.textContent = playgroundMode === "app"
        ? "App mode: SSR + client hydrate. Not all framework features are supported in the playground."
        : "Toggle App for client-side rendering. Not all framework features are supported in the playground yet.";
}

function refreshTemplateSelect() {
    const select = document.getElementById("pg-template-select") as HTMLSelectElement | null;
    if (!select) return;
    const options = templatesForMode(playgroundMode);
    select.innerHTML = "";
    for (const t of options) {
        const opt = document.createElement("option");
        opt.value = t.id;
        opt.textContent = t.label;
        select.appendChild(opt);
    }
    if (!options.some((t) => t.id === activeTemplateId)) {
        activeTemplateId = defaultTemplateId(playgroundMode);
    }
    select.value = activeTemplateId;
}

function loadFilesFromMap(fileMap: { [filename: string]: string }) {
    fileManager.getAllFiles().forEach((f) => fileManager.removeFile(f.name));
    Object.entries(fileMap).forEach(([name, content]) => fileManager.addFile(name, content));
    const newFiles = fileManager.getAllFiles().map((f) => ({
        name: f.name,
        state: createEditorState(f.name, f.content),
        hidden: isHiddenPlaygroundFile(f.name),
        locked: isLockedPlaygroundFile(f.name),
    }));
    files.length = 0;
    files.push(...newFiles);
    activeFileIndex = -1;
    let initialFileIndex = files.findIndex((f) => !f.hidden && (f.name.endsWith("page.zx") || f.name === "Playground.zx"));
    if (initialFileIndex < 0) initialFileIndex = files.findIndex((f) => !f.hidden);
    if (initialFileIndex < 0) initialFileIndex = 0;
    updateTabs();
    void switchFile(initialFileIndex);
    transpileCache.clear();
    buildCache.clear();
    resetPreviewNavigation();
    resetPreviewPlaceholder();
}

function loadTemplateFiles(templateId = activeTemplateId) {
    const template = getTemplate(templateId) ?? getTemplate(defaultTemplateId(playgroundMode))!;
    activeTemplateId = template.id;
    playgroundMode = template.mode;
    persistModeState();
    loadFilesFromMap(template.files);
    schedulePersistFiles();
}

function ensureBaselinePlaygroundFiles(filesDecoded: { [filename: string]: string }): { [filename: string]: string } {
    const normalized: { [filename: string]: string } = { ...filesDecoded };
    const looksLikeApp = Boolean(
        normalized["app/main.zig"] ||
            Object.keys(normalized).some(
                (name) =>
                    name.startsWith("app/pages/") ||
                    name.startsWith("app/routes/") ||
                    name === "app/main.zig",
            ),
    );

    if (looksLikeApp) {
        playgroundMode = "app";
        activeTemplateId = defaultTemplateId("app");
        // Shared snippets often ship a minimal shell (page/layout/route only).
        const appMain =
            getTemplate("app")?.files["app/main.zig"] ??
            getTemplate(activeTemplateId)?.files["app/main.zig"];
        if (appMain && !normalized["app/main.zig"]) {
            normalized["app/main.zig"] = appMain;
        }
        return normalized;
    }

    playgroundMode = "playground";
    if (!normalized["Playground.zx"]) {
        const firstZx = Object.keys(normalized).find((name) => name.endsWith(".zx"));
        if (firstZx) {
            normalized["Playground.zx"] = normalized[firstZx];
            if (firstZx !== "Playground.zx") delete normalized[firstZx];
        }
    }
    const fallback = getTemplate(defaultTemplateId("playground"))!.files;
    for (const [name, content] of Object.entries(fallback)) {
        if (!normalized[name]) normalized[name] = content;
    }
    activeTemplateId = defaultTemplateId("playground");
    return normalized;
}

function isLockedPlaygroundFile(name: string): boolean {
    return playgroundMode === "app"
        ? name === "app/main.zig"
        : name === "Playground.zx" || name === "main.zig";
}

function isHiddenPlaygroundFile(name: string): boolean {
    if (playgroundMode === "app") {
        return isGeneratedPlaygroundPath(name) || name === "app/main.zig";
    }
    return name.endsWith(".zig");
}

function clearSharedDataHashFromUrl() {
    if (!location.hash.startsWith("#data=")) return;
    history.replaceState(null, "", `${location.pathname}${location.search}`);
}

function setupFeatureNotice() {
    const notice = document.getElementById("pg-feature-notice");
    if (!notice) return;

    let dismissed = false;
    try {
        dismissed = localStorage.getItem(PLAYGROUND_NOTICE_STORAGE_KEY) === "1";
    } catch {
        dismissed = false;
    }

    if (dismissed) {
        notice.classList.add("is-hidden");
        return;
    }

    // Show after initial layout is stable to avoid immediate content jump on load.
    window.setTimeout(() => {
        notice.classList.remove("is-hidden");
    }, 450);

    const closeBtn = document.getElementById("pg-feature-notice-close");
    closeBtn?.addEventListener("click", () => {
        notice.classList.add("is-hidden");
        try {
            localStorage.setItem(PLAYGROUND_NOTICE_STORAGE_KEY, "1");
        } catch {
            // Ignore storage failures (private mode/quota).
        }
    });
}


window.addEventListener("DOMContentLoaded", async () => {
    setupFeatureNotice();
    setupModeControls();
    setupSettingsMenu();
    try {
        await loadTemplates();
        resolveActiveTemplateId();
    } catch (err) {
        console.error("Failed to load playground templates", err);
        appendTerminalLine("Failed to load templates. Refresh to retry.", "pg-terminal-error");
        setTerminalCollapsed(false);
        revealOutputWindow();
    }
    await Promise.race([
        client.initializing,
        new Promise<void>((resolve) => setTimeout(resolve, 2500)),
    ]);
    let code = null;
    if (location.hash.startsWith("#data=")) {
        code = location.hash.slice(6);
    }
    if (code) {
        const filesDecoded = await decodeFilesFromQuery(code);
        if (filesDecoded) {
            const filesWithDefaults = ensureBaselinePlaygroundFiles(filesDecoded);
            loadFilesFromMap(filesWithDefaults);
            clearSharedDataHashFromUrl();
            syncModeUi();
            enableChromeButtons();
            return;
        }
    }
    if (persistFilesEnabled) {
        const saved = await loadPersistedFiles();
        if (saved?.files && Object.keys(saved.files).length > 0) {
            if (saved.mode === "app" || saved.mode === "playground") playgroundMode = saved.mode;
            if (saved.templateId && getTemplate(saved.templateId)?.mode === playgroundMode) {
                activeTemplateId = saved.templateId;
            } else {
                activeTemplateId = defaultTemplateId(playgroundMode);
            }
            loadFilesFromMap(ensureBaselinePlaygroundFiles(saved.files));
            syncModeUi();
            enableChromeButtons();
            return;
        }
    }
    loadTemplateFiles();
    syncModeUi();
    enableChromeButtons();
});

function enableChromeButtons() {
    document.getElementById("pg-run-btn")?.removeAttribute("disabled");
    document.getElementById("pg-share-btn")?.removeAttribute("disabled");
    document.getElementById("pg-format-btn")?.removeAttribute("disabled");
}

function syncModeUi() {
    const appToggle = document.getElementById("pg-app-toggle") as HTMLButtonElement | null;
    if (appToggle) {
        const on = playgroundMode === "app";
        appToggle.classList.toggle("is-active", on);
        appToggle.setAttribute("aria-pressed", on ? "true" : "false");
    }
    refreshTemplateSelect();
    updateModeNotice();
    syncBrowserToolbar();
}

const PREVIEW_HOST = "playground.local";
const PREVIEW_ORIGIN = `https://${PREVIEW_HOST}`;

type PreviewLocation = { pathname: string; search: string; url: string; display: string };
type PreviewResponseMeta = { status?: number; headers?: [string, string][]; streaming?: boolean };

let previewLocation: PreviewLocation = normalizePreviewLocation("/");
let previewHistory: PreviewLocation[] = [previewLocation];
let previewHistoryIndex = 0;
let lastAppArtifacts: PlaygroundBuildArtifacts | null = null;
let previewNavigating = false;

function normalizePreviewLocation(input: string): PreviewLocation {
    let raw = input.trim();
    if (!raw) raw = "/";

    try {
        if (/^https?:\/\//i.test(raw)) {
            const u = new URL(raw);
            const pathname = u.pathname || "/";
            const search = u.search || "";
            return {
                pathname,
                search,
                url: `${PREVIEW_ORIGIN}${pathname}${search}`,
                display: `${PREVIEW_HOST}${pathname}${search}`,
            };
        }
    } catch { /* fall through */ }

    raw = raw.replace(/^(https?:\/\/)?(playground\.local|localhost(?::\d+)?)/i, "");
    if (!raw.startsWith("/")) raw = `/${raw}`;
    const q = raw.indexOf("?");
    const pathname = (q >= 0 ? raw.slice(0, q) : raw) || "/";
    const search = q >= 0 ? raw.slice(q) : "";
    return {
        pathname,
        search,
        url: `${PREVIEW_ORIGIN}${pathname}${search}`,
        display: `${PREVIEW_HOST}${pathname}${search}`,
    };
}

function setPreviewLocation(loc: PreviewLocation, mode: "replace" | "push" | "none" = "replace") {
    previewLocation = loc;
    if (mode === "push") {
        previewHistory = previewHistory.slice(0, previewHistoryIndex + 1);
        const prev = previewHistory[previewHistory.length - 1];
        if (!prev || prev.url !== loc.url) {
            previewHistory.push(loc);
            previewHistoryIndex = previewHistory.length - 1;
        }
    } else if (mode === "replace") {
        previewHistory = [loc];
        previewHistoryIndex = 0;
    }
    const input = document.getElementById("pg-browser-url-input") as HTMLInputElement | null;
    if (input && document.activeElement !== input) input.value = loc.display;
    updateBrowserNavButtons();
}

function resetPreviewNavigation() {
    lastAppArtifacts = null;
    setPreviewLocation(normalizePreviewLocation("/"), "replace");
}

function updateBrowserNavButtons() {
    const back = document.getElementById("pg-browser-back") as HTMLButtonElement | null;
    const forward = document.getElementById("pg-browser-forward") as HTMLButtonElement | null;
    if (back) back.disabled = previewHistoryIndex <= 0;
    if (forward) forward.disabled = previewHistoryIndex >= previewHistory.length - 1;
}

function syncBrowserToolbar() {
    const toolbar = document.getElementById("pg-browser-toolbar");
    if (!toolbar) return;
    toolbar.classList.toggle("is-hidden", playgroundMode !== "app");
    const input = document.getElementById("pg-browser-url-input") as HTMLInputElement | null;
    if (input && document.activeElement !== input) input.value = previewLocation.display;
    updateBrowserNavButtons();
}

function setupBrowserToolbar() {
    const form = document.getElementById("pg-browser-url-form") as HTMLFormElement | null;
    form?.addEventListener("submit", (ev) => {
        ev.preventDefault();
        const input = document.getElementById("pg-browser-url-input") as HTMLInputElement | null;
        void navigatePreview(input?.value ?? "/", { history: "push" });
    });

    document.getElementById("pg-browser-refresh")?.addEventListener("click", () => {
        void navigatePreview(previewLocation.display, { history: "none" });
    });
    document.getElementById("pg-browser-back")?.addEventListener("click", () => {
        if (previewHistoryIndex <= 0) return;
        previewHistoryIndex -= 1;
        const loc = previewHistory[previewHistoryIndex]!;
        void navigatePreview(loc.display, { history: "none", location: loc });
    });
    document.getElementById("pg-browser-forward")?.addEventListener("click", () => {
        if (previewHistoryIndex >= previewHistory.length - 1) return;
        previewHistoryIndex += 1;
        const loc = previewHistory[previewHistoryIndex]!;
        void navigatePreview(loc.display, { history: "none", location: loc });
    });

    window.addEventListener("message", (ev) => {
        const data = ev.data;
        if (!data || typeof data !== "object") return;
        if (data.type === "pg-navigate" && typeof data.href === "string") {
            void navigatePreview(data.href, { history: "push" });
        }
    });
}

async function navigatePreview(
    input: string,
    opts: { history?: "push" | "replace" | "none"; location?: PreviewLocation } = {},
) {
    if (playgroundMode !== "app") return;
    if (!lastAppArtifacts) {
        appendTerminalLine("Run the app first, then use the URL bar to navigate.", "pg-terminal-error");
        setTerminalCollapsed(false);
        revealOutputWindow();
        return;
    }
    if (previewNavigating) return;

    const loc = opts.location ?? normalizePreviewLocation(input);
    const historyMode = opts.history ?? "push";
    if (historyMode === "push") setPreviewLocation(loc, "push");
    else if (historyMode === "replace") setPreviewLocation(loc, "replace");
    else {
        previewLocation = loc;
        const urlInput = document.getElementById("pg-browser-url-input") as HTMLInputElement | null;
        if (urlInput && document.activeElement !== urlInput) urlInput.value = loc.display;
        updateBrowserNavButtons();
    }

    previewNavigating = true;
    setRunButtonLoading(true);
    try {
        await runAppArtifacts(lastAppArtifacts, loc);
    } finally {
        previewNavigating = false;
        setRunButtonLoading(false);
    }
}

function setupModeControls() {
    setupBrowserToolbar();
    document.getElementById("pg-app-toggle")?.addEventListener("click", () => {
        const next: PlaygroundMode = playgroundMode === "app" ? "playground" : "app";
        playgroundMode = next;
        activeTemplateId = defaultTemplateId(next);
        persistModeState();
        loadTemplateFiles(activeTemplateId);
        syncModeUi();
    });
    document.getElementById("pg-template-select")?.addEventListener("change", (ev) => {
        const id = (ev.target as HTMLSelectElement).value;
        const template = getTemplate(id);
        if (!template || template.mode !== playgroundMode) return;
        activeTemplateId = id;
        persistModeState();
        loadTemplateFiles(id);
        syncModeUi();
    });
}

// Client connects on construction; file loading is handled in DOMContentLoaded.

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


let zigWorker = new Worker(`/assets/playground/workers/zig.js?v=${VERSION}`);
let zxWorker = new Worker(`/assets/playground/workers/zx.js?v=${VERSION}`);

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

function openIdb(name: string): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
        const req = indexedDB.open(name, 1);
        req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(IDB_STORE)) db.createObjectStore(IDB_STORE);
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error("indexedDB.open failed"));
    });
}

function idbReq<T>(req: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error("indexedDB request failed"));
    });
}

async function idbGet<T>(dbName: string, key: string): Promise<T | undefined> {
    try {
        const db = await openIdb(dbName);
        const tx = db.transaction(IDB_STORE, "readonly");
        const value = await idbReq(tx.objectStore(IDB_STORE).get(key)) as T | undefined;
        db.close();
        return value;
    } catch {
        return undefined;
    }
}

async function idbPut(dbName: string, key: string, value: unknown): Promise<void> {
    try {
        const db = await openIdb(dbName);
        const tx = db.transaction(IDB_STORE, "readwrite");
        tx.objectStore(IDB_STORE).put(value, key);
        await new Promise<void>((resolve, reject) => {
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error ?? new Error("idb put failed"));
        });
        db.close();
    } catch { /* ignore */ }
}

async function idbClearDb(dbName: string): Promise<void> {
    try {
        await new Promise<void>((resolve, reject) => {
            const req = indexedDB.deleteDatabase(dbName);
            req.onsuccess = () => resolve();
            req.onerror = () => reject(req.error ?? new Error("idb delete failed"));
            req.onblocked = () => resolve();
        });
    } catch { /* ignore */ }
}

type PersistedFilesPayload = {
    mode: PlaygroundMode;
    templateId: string;
    files: { [filename: string]: string };
};

type StoredBuild =
    | { mode: "playground"; wasm: ArrayBuffer; duration: number }
    | { mode: "app"; ssrWasm: ArrayBuffer; clientWasm: ArrayBuffer; webGlue?: string; duration: number };

function copyBuffer(bytes: Uint8Array): ArrayBuffer {
    const buf = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buf).set(bytes);
    return buf;
}

function storeBuildArtifact(compiled: PlaygroundBuildArtifacts | Uint8Array, duration: number): StoredBuild {
    if (compiled instanceof Uint8Array) {
        return { mode: "playground", wasm: copyBuffer(compiled), duration };
    }
    return {
        mode: "app",
        ssrWasm: copyBuffer(compiled.ssrWasm),
        clientWasm: copyBuffer(compiled.clientWasm),
        webGlue: compiled.webGlue,
        duration,
    };
}

function restoreBuildArtifact(stored: StoredBuild): PlaygroundBuildArtifacts | Uint8Array {
    if (stored.mode === "playground") return new Uint8Array(stored.wasm);
    return {
        ssrWasm: new Uint8Array(stored.ssrWasm),
        clientWasm: new Uint8Array(stored.clientWasm),
        webGlue: stored.webGlue,
    };
}

let persistFilesTimer: number | null = null;

const filesChangedListeners = new Set<() => void>();

function schedulePersistFiles() {
    for (const listener of filesChangedListeners) listener();
    if (!persistFilesEnabled) return;
    if (persistFilesTimer != null) window.clearTimeout(persistFilesTimer);
    persistFilesTimer = window.setTimeout(() => {
        persistFilesTimer = null;
        void savePersistedFiles();
    }, 400);
}

async function savePersistedFiles() {
    if (!persistFilesEnabled) return;
    const filesMap = getCurrentFilesMap();
    // Drop generated zig outputs from persistence; they are rebuilt on run.
    const persisted: { [filename: string]: string } = {};
    for (const [name, content] of Object.entries(filesMap)) {
        if (isGeneratedPlaygroundPath(name)) continue;
        if (playgroundMode !== "app" && name.endsWith(".zig") && name !== "main.zig") continue;
        persisted[name] = content;
    }
    await idbPut(FILES_IDB_NAME, "snapshot", {
        mode: playgroundMode,
        templateId: activeTemplateId,
        files: persisted,
    } satisfies PersistedFilesPayload);
}

async function loadPersistedFiles(): Promise<PersistedFilesPayload | null> {
    const snap = await idbGet<PersistedFilesPayload>(FILES_IDB_NAME, "snapshot");
    if (!snap?.files || typeof snap.files !== "object") return null;
    return snap;
}

async function clearAllPlaygroundCaches() {
    transpileCache.clear();
    buildCache.clear();
    await Promise.all([
        idbClearDb(BUILDS_IDB_NAME),
        idbClearDb(`ziex-zig-cache-${ZIG_VERSION}`),
        new Promise<void>((resolve) => {
            const onMsg = (ev: MessageEvent) => {
                if (ev.data?.cacheCleared) {
                    zigWorker.removeEventListener("message", onMsg);
                    resolve();
                }
            };
            zigWorker.addEventListener("message", onMsg);
            zigWorker.postMessage({ clearCache: true });
            window.setTimeout(() => {
                zigWorker.removeEventListener("message", onMsg);
                resolve();
            }, 1500);
        }),
    ]);
}

function setPersistFilesEnabled(enabled: boolean) {
    persistFilesEnabled = enabled;
    try {
        localStorage.setItem(PERSIST_FILES_KEY, enabled ? "1" : "0");
    } catch { /* ignore */ }
    const checkbox = document.getElementById("pg-persist-files") as HTMLInputElement | null;
    if (checkbox) checkbox.checked = enabled;
    if (enabled) void savePersistedFiles();
}

function setupSettingsMenu() {
    const root = document.getElementById("pg-settings");
    const btn = document.getElementById("pg-settings-btn") as HTMLButtonElement | null;
    const popover = document.getElementById("pg-settings-popover");
    const persistCb = document.getElementById("pg-persist-files") as HTMLInputElement | null;
    const resetBtn = document.getElementById("pg-reset-template");
    const clearBtn = document.getElementById("pg-clear-cache");
    if (!root || !btn || !popover) return;

    if (persistCb) persistCb.checked = persistFilesEnabled;

    const setOpen = (open: boolean) => {
        popover.classList.toggle("is-hidden", !open);
        btn.setAttribute("aria-expanded", open ? "true" : "false");
    };

    btn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        setOpen(popover.classList.contains("is-hidden"));
    });

    persistCb?.addEventListener("change", () => {
        setPersistFilesEnabled(!!persistCb.checked);
    });

    resetBtn?.addEventListener("click", () => {
        loadTemplateFiles(activeTemplateId);
        if (persistFilesEnabled) void savePersistedFiles();
        setOpen(false);
        appendTerminalLine("Template reset.", "pg-terminal-muted");
    });

    clearBtn?.addEventListener("click", () => {
        void (async () => {
            clearBtn.setAttribute("disabled", "true");
            try {
                await clearAllPlaygroundCaches();
                appendTerminalLine("Build cache cleared.", "pg-terminal-muted");
            } finally {
                clearBtn.removeAttribute("disabled");
                setOpen(false);
            }
        })();
    });

    document.addEventListener("click", (ev) => {
        if (!root.contains(ev.target as Node)) setOpen(false);
    });
    document.addEventListener("keydown", (ev) => {
        if (ev.key === "Escape") setOpen(false);
    });
}

// Content hash (fast djb2 variant)
function hashFiles(map: { [name: string]: string }): string {
    const s = JSON.stringify(Object.entries(map).sort(([a], [b]) => a.localeCompare(b)));
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = Math.imul(h, 33) ^ s.charCodeAt(i);
    return (h >>> 0).toString(36);
}

function transpileInputHash(filesMap: { [name: string]: string }): string {
    if (playgroundMode === "app") {
        const relevant = Object.fromEntries(
            Object.entries(filesMap).filter(([name]) => !isGeneratedPlaygroundPath(name)),
        );
        return hashFiles(relevant) + `|${playgroundMode}`;
    }

    const zxOnly = Object.fromEntries(
        Object.entries(filesMap).filter(([name]) => name.endsWith(".zx")),
    );
    return hashFiles(zxOnly) + `|${playgroundMode}`;
}

// In-memory LRU caches (max 8 entries each)
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
const buildCache = new Map<string, CacheEntry<PlaygroundBuildArtifacts>>();

function stubFiles(): { [name: string]: string } {
    return {
        "stubs/zx_info.zig": stubZxInfo,
        "stubs/app_opts.zig": stubAppOpts,
        "stubs/manifest.zon": stubManifest,
        "stubs/build_injections.zon": stubBuildInjections,
    };
}

function transpileAppAsync(filesMap: { [name: string]: string }): Promise<{ [filename: string]: string }> {
    return new Promise((resolve, reject) => {
        function handler(ev: MessageEvent) {
            const d = ev.data;
            if (d?.failed) {
                zxWorker.removeEventListener("message", handler);
                reject({ stderr: d.stderr || "Transpile failed" });
            } else if (d?.transpiled) {
                zxWorker.removeEventListener("message", handler);
                resolve(d.transpiled);
            }
        }
        zxWorker.addEventListener("message", handler);
        zxWorker.postMessage({
            files: { ...filesMap, ...stubFiles() },
            path: "app",
            buildInjections: "stubs/build_injections.zon",
        });
    });
}

function transpileZxFileAsync(zxName: string, zxContent: string): Promise<{ [filename: string]: string }> {
    return new Promise((resolve, reject) => {
        function handler(ev: MessageEvent) {
            const d = ev.data;
            if (d && d.failed) {
                zxWorker.removeEventListener('message', handler);
                reject({ stderr: d.stderr || 'Transpile failed' });
            } else if (d && d.stdout) {
                zxWorker.removeEventListener('message', handler);
                resolve({ [zxName.replace(/\.zx$/, '.zig')]: d.stdout });
            }
        }
        zxWorker.addEventListener('message', handler);
        zxWorker.postMessage({ filename: zxName, content: zxContent });
    });
}

function formatZxFileAsync(zxName: string, zxContent: string): Promise<string> {
    return new Promise((resolve, reject) => {
        function handler(ev: MessageEvent) {
            const d = ev.data;
            if (d && d.failed) {
                zxWorker.removeEventListener("message", handler);
                reject({ stderr: d.stderr || "Format failed" });
            } else if (d && typeof d.stdout === "string") {
                zxWorker.removeEventListener("message", handler);
                resolve(d.stdout);
            }
        }
        zxWorker.addEventListener("message", handler);
        zxWorker.postMessage({ filename: zxName, content: zxContent, subcommand: "fmt" });
    });
}

function setFormatButtonLoading(loading: boolean) {
    const btn = document.getElementById("pg-format-btn") as HTMLButtonElement | null;
    if (!btn) return;
    if (loading) {
        btn.classList.add("pg-editor-status-btn--loading");
        btn.setAttribute("disabled", "true");
        btn.setAttribute("aria-busy", "true");
        btn.title = "Formatting…";
    } else {
        btn.classList.remove("pg-editor-status-btn--loading");
        btn.removeAttribute("disabled");
        btn.removeAttribute("aria-busy");
        btn.title = "Format file (Shift+Alt+F)";
    }
}

function applyFormattedContent(formatted: string) {
    if (!editorView || activeFileIndex < 0) return;
    const file = files[activeFileIndex];
    const current = editorView.state.doc.toString();
    if (current === formatted) return;

    const selection = editorView.state.selection.main;
    const nextPos = Math.min(selection.head, formatted.length);
    editorView.dispatch({
        changes: { from: 0, to: current.length, insert: formatted },
        selection: { anchor: nextPos, head: nextPos },
    });
    file.state = editorView.state;
    fileManager.updateContent(file.name, formatted);
    transpileCache.clear();
}

async function formatActiveFile(opts: { silentSuccess?: boolean } = {}): Promise<boolean> {
    if (formatting || activeFileIndex < 0 || !editorView) return false;

    const file = files[activeFileIndex];
    if (file.readonly) return false;
    const name = file.name;
    const content = editorView.state.doc.toString();

    if (name.endsWith(".zx") || name.endsWith(".mdzx")) {
        formatting = true;
        setFormatButtonLoading(true);
        try {
            const formatted = await formatZxFileAsync(name, content);
            applyFormattedContent(formatted);
            if (!opts.silentSuccess) {
                appendTerminalLine(`Formatted ${name}`, "pg-terminal-success");
                setTerminalCollapsed(false);
                revealOutputWindow();
            }
            return true;
        } catch (err: any) {
            const message = err?.stderr || `Failed to format ${name}`;
            appendTerminalLine(message, "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            return false;
        } finally {
            formatting = false;
            setFormatButtonLoading(false);
        }
    }

    if (name.endsWith(".zig") || name.endsWith(".zon")) {
        // Prefer ZLS formatting when the language server is available.
        return formatDocument(editorView);
    }

    appendTerminalLine(`No formatter for ${name}`, "pg-terminal-info");
    return false;
}

document.getElementById("pg-format-btn")?.addEventListener("click", () => {
    void formatActiveFile();
});

// Promisified build
let build_start_time = performance.now();
function buildFilesAsync(filesMap: { [name: string]: string }): Promise<PlaygroundBuildArtifacts | Uint8Array> {
    return new Promise((resolve, reject) => {
        let stderrAcc = "";
        function handler(ev: MessageEvent) {
            const d = ev.data;
            if (d.stderr) {
                stderrAcc += (stderrAcc ? "\n" : "") + d.stderr;
            }
            if (d.stderr && !d.compiled && !d.failed) return;
            if (d.failed) {
                zigWorker.removeEventListener("message", handler);
                reject({ type: "failed", stderr: d.stderr || stderrAcc });
            } else if (d.compiled) {
                zigWorker.removeEventListener("message", handler);
                console.info("Build finished in", (performance.now() - build_start_time).toFixed(2), "ms");
                resolve(d.compiled as PlaygroundBuildArtifacts | Uint8Array);
            }
        }
        zigWorker.addEventListener("message", handler);
        build_start_time = performance.now();
        const payload = playgroundMode === "app"
            ? { files: { ...filesMap, ...stubFiles() }, mode: "app" }
            : { files: filesMap, mode: "playground" };
        zigWorker.postMessage(payload);
    });
}

let lastClientWasmUrl: string | null = null;

function showHtmlPreview(html: string) {
    const vp = document.getElementById("pg-browser-viewport")!;
    vp.innerHTML = "";
    const iframe = document.createElement("iframe");
    iframe.style.cssText = "width:100%;height:100%;border:none;background-color:white";
    vp.appendChild(iframe);
    iframe.contentDocument?.open();
    iframe.contentDocument?.write(html);
    iframe.contentDocument?.close();
}

function responseHeader(meta: PreviewResponseMeta | undefined, name: string): string | null {
    const header = meta?.headers?.find(([key]) => key.toLowerCase() === name.toLowerCase());
    return header?.[1] ?? null;
}

function showResponsePreview(body: string, meta?: PreviewResponseMeta) {
    const vp = document.getElementById("pg-browser-viewport")!;
    vp.innerHTML = "";

    const wrap = document.createElement("div");
    wrap.className = "pg-browser-response";

    const head = document.createElement("div");
    head.className = "pg-browser-response-head";
    const contentType = responseHeader(meta, "content-type") ?? "";
    head.textContent = `HTTP ${meta?.status ?? 200}${contentType ? ` • ${contentType}` : ""}`;
    wrap.appendChild(head);

    const pre = document.createElement("pre");
    pre.className = "pg-browser-response-body";
    let displayBody = body;
    const trimmed = body.trim();
    const looksJson = contentType.toLowerCase().includes("json") || (trimmed.startsWith("{") || trimmed.startsWith("["));
    if (looksJson) {
        try {
            displayBody = JSON.stringify(JSON.parse(trimmed), null, 2);
        } catch {
            // fall back to raw body
        }
    }
    pre.textContent = displayBody;
    wrap.appendChild(pre);

    vp.appendChild(wrap);
}

function showHydratedPreview(html: string, clientWasm: Uint8Array, webGlue = "") {
    if (lastClientWasmUrl) URL.revokeObjectURL(lastClientWasmUrl);
    const wasmBytes = clientWasm.slice();
    lastClientWasmUrl = URL.createObjectURL(new Blob([wasmBytes.buffer], { type: "application/wasm" }));

    const baseHref = `${location.origin}/`;
    let doc = html;
    if (!/__PLAYGROUND_CLIENT_WASM__|#__\$wasmlink|id=["']__\$wasmlink["']/.test(doc)) {
        doc = doc.replace(
            /<\/head>/i,
            `<link id="__$wasmlink" rel="preload" as="fetch" href="${CLIENT_WASM_PLACEHOLDER}" crossorigin></link>\n` +
            `<script defer src="/assets/playground/init.js"></script>\n</head>`,
        );
    }
    doc = doc.split(CLIENT_WASM_PLACEHOLDER).join(lastClientWasmUrl);
    // Browser bindings for this wasm; must run before the deferred init.js.
    if (webGlue) doc = doc.replace(/<head([^>]*)>/i, (m) => `${m}<script>${webGlue}</script>`);
    if (/<base\s/i.test(doc)) {
        doc = doc.replace(/<base\b[^>]*>/i, `<base href="${baseHref}">`);
    } else {
        doc = doc.replace(/<head([^>]*)>/i, `<head$1><base href="${baseHref}">`);
    }

    const previewBridge = `<script>
(function(){
  function report(err) {
    var msg = (err && err.stack) ? String(err.stack) : String(err);
    if (window.__pgHydrateReported === msg) return;
    window.__pgHydrateReported = msg;
    console.error('[playground hydrate]', msg);
    try { parent.postMessage({ type: 'pg-hydrate-error', message: msg }, '*'); } catch (_) {}
  }
  window.addEventListener('error', function(e) { report(e.error || e.message); });
  window.addEventListener('unhandledrejection', function(e) { report(e.reason); });
  var origErr = console.error.bind(console);
  console.error = function() {
    origErr.apply(console, arguments);
    try {
      var a = arguments[0];
      if (a && (a instanceof Error || (typeof a === 'object' && a.message))) report(a);
    } catch (_) {}
  };
  if (typeof WebAssembly.promising === 'function') {
    var origP = WebAssembly.promising.bind(WebAssembly);
    WebAssembly.promising = function(fn) {
      var wrapped = origP(fn);
      return function() {
        var ret = wrapped.apply(this, arguments);
        if (ret && typeof ret.then === 'function') {
          return ret.then(undefined, function(err) { report(err); throw err; });
        }
        return ret;
      };
    };
  }

  var SITE_ORIGIN = ${JSON.stringify(location.origin)};
  var PREVIEW_HOST = ${JSON.stringify(PREVIEW_HOST)};

  function previewPathForAnchor(a) {
    var raw = a.getAttribute('href') || '';
    if (!raw || raw.charAt(0) === '#' || /^(javascript:|mailto:|tel:)/i.test(raw)) return null;
    try {
      var resolved = new URL(a.href);
      if (resolved.origin === SITE_ORIGIN || resolved.hostname === PREVIEW_HOST) {
        return resolved.pathname + resolved.search;
      }
    } catch (_) {}
    if (raw.charAt(0) === '/') return raw.split('#')[0];
    return null;
  }

  function onNavClick(e) {
    if (e.defaultPrevented) return;
    if (e.button != null && e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var t = e.target;
    if (!t || !t.closest) return;
    var a = t.closest('a[href]');
    if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
    var path = previewPathForAnchor(a);
    if (path == null) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    try { parent.postMessage({ type: 'pg-navigate', href: path }, '*'); } catch (_) {}
  }
  document.addEventListener('click', onNavClick, true);
})();
</script>`;

    if (/<\/head>/i.test(doc)) {
        doc = doc.replace(/<\/head>/i, previewBridge + "\n</head>");
    } else {
        doc = previewBridge + doc;
    }

    const vp = document.getElementById("pg-browser-viewport")!;
    vp.innerHTML = "";
    const iframe = document.createElement("iframe");
    iframe.style.cssText = "width:100%;height:100%;border:none;background-color:white";
    iframe.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms");
    vp.appendChild(iframe);
    iframe.srcdoc = doc;
}

function runCompiled(compiled: PlaygroundBuildArtifacts | Uint8Array, opts: { preservePreview?: boolean } = {}): Promise<void> {
    appendStatusStep("run", "Running\u2026");
    updatePreviewStatus("", "Running\u2026", "run");

    if (compiled instanceof Uint8Array) {
        lastAppArtifacts = null;
        return runPlaygroundWasm(compiled, opts);
    }

    lastAppArtifacts = compiled;
    const input = document.getElementById("pg-browser-url-input") as HTMLInputElement | null;
    const loc = normalizePreviewLocation(input?.value || previewLocation.display);
    setPreviewLocation(loc, "replace");
    return runAppArtifacts(compiled, loc, opts);
}

function runPlaygroundWasm(compiled: Uint8Array, opts: { preservePreview?: boolean } = {}): Promise<void> {
    return new Promise((resolve) => {
        const runnerWorker = new Worker(`/assets/playground/workers/runner.js?v=${Date.now()}`);
        runnerWorker.onerror = (ev) => {
            completeStatusStep("run", "error");
            appendTerminalLine(`runner worker error: ${ev.message}`, "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            setRunButtonLoading(false);
            if (!opts.preservePreview) resetPreviewPlaceholder();
            runnerWorker.terminate();
            resolve();
        };
        runnerWorker.onmessage = (rev: MessageEvent) => {
            if (rev.data?.stderr) appendTerminalLine(rev.data.stderr, "pg-terminal-error");
            if (rev.data?.failed) {
                completeStatusStep("run", "error");
                setTerminalCollapsed(false);
                revealOutputWindow();
                setRunButtonLoading(false);
                if (!opts.preservePreview) resetPreviewPlaceholder();
                runnerWorker.terminate();
                resolve();
                return;
            }
            if (rev.data?.preview != null) {
                showHtmlPreview(rev.data.preview);
                if (rev.data?.done) {
                    completeStatusStep("run", "done");
                    runnerWorker.terminate();
                    setRunButtonLoading(false);
                    resolve();
                }
                return;
            }
            if (rev.data?.done) {
                completeStatusStep("run", "done");
                runnerWorker.terminate();
                setRunButtonLoading(false);
                resolve();
            }
        };
        const copy = compiled.slice();
        runnerWorker.postMessage({ run: copy }, [copy.buffer]);
    });
}

function runAppArtifacts(compiled: PlaygroundBuildArtifacts, loc: PreviewLocation, opts: { preservePreview?: boolean } = {}): Promise<void> {
    return new Promise((resolve) => {
        const runnerWorker = new Worker(`/assets/playground/workers/runner.js?v=${Date.now()}`);
        const clientWasm = compiled.clientWasm;
        const ssr = compiled.ssrWasm;

        runnerWorker.onerror = (ev) => {
            completeStatusStep("run", "error");
            appendTerminalLine(`runner worker error: ${ev.message}`, "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            setRunButtonLoading(false);
            if (!opts.preservePreview) resetPreviewPlaceholder();
            runnerWorker.terminate();
            resolve();
        };

        runnerWorker.onmessage = (rev: MessageEvent) => {
            if (rev.data?.stderr) appendTerminalLine(rev.data.stderr, "pg-terminal-error");
            if (rev.data?.failed) {
                completeStatusStep("run", "error");
                setTerminalCollapsed(false);
                revealOutputWindow();
                setRunButtonLoading(false);
                if (!opts.preservePreview) resetPreviewPlaceholder();
                runnerWorker.terminate();
                resolve();
                return;
            }
            if (rev.data?.preview != null) {
                const meta = rev.data?.meta as PreviewResponseMeta | undefined;
                const contentType = responseHeader(meta, "content-type")?.toLowerCase() ?? "";
                const isHtml = contentType === "" || contentType.includes("text/html") || contentType.includes("application/xhtml+xml");

                if (!isHtml) {
                    showResponsePreview(rev.data.preview, meta);
                } else if (clientWasm instanceof Uint8Array) {
                    showHydratedPreview(rev.data.preview, clientWasm, compiled.webGlue);
                } else {
                    showHtmlPreview(rev.data.preview);
                }
                if (rev.data?.done) {
                    completeStatusStep("run", "done");
                    runnerWorker.terminate();
                    setRunButtonLoading(false);
                    resolve();
                }
                return;
            }
            if (rev.data?.done) {
                completeStatusStep("run", "done");
                runnerWorker.terminate();
                setRunButtonLoading(false);
                resolve();
            }
        };

        if (!(ssr instanceof Uint8Array) || ssr.byteLength < 8) {
            completeStatusStep("run", "error");
            appendTerminalLine("Invalid SSR wasm artifact", "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            setRunButtonLoading(false);
            if (!opts.preservePreview) resetPreviewPlaceholder();
            runnerWorker.terminate();
            resolve();
            return;
        }
        if (!(clientWasm instanceof Uint8Array) || clientWasm.byteLength < 8) {
            completeStatusStep("run", "error");
            appendTerminalLine("Invalid client wasm artifact", "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            setRunButtonLoading(false);
            if (!opts.preservePreview) resetPreviewPlaceholder();
            runnerWorker.terminate();
            resolve();
            return;
        }

        const ssrCopy = ssr.slice();
        runnerWorker.postMessage({
            run: {
                ssrWasm: ssrCopy,
                pathname: loc.pathname,
                search: loc.search,
                method: "GET",
                url: loc.url,
            },
        }, [ssrCopy.buffer]);
    });
}

function getCurrentFilesMap(): { [filename: string]: string } {
    if (activeFileIndex !== -1 && editorView) {
        if (!files[activeFileIndex].ephemeral) {
            fileManager.updateContent(files[activeFileIndex].name, editorView.state.doc.toString());
        }
    }
    const map: { [filename: string]: string } = {};
    fileManager.getAllFiles().forEach((f) => {
        if (playgroundMode === "app") {
            if (isGeneratedPlaygroundPath(f.name)) return;
        } else if (f.name.endsWith(".zig") && f.name !== "main.zig") {
            return;
        }
        map[f.name] = f.content;
    });
    if (playgroundMode === "app") {
        const appMain = getTemplate("app")?.files["app/main.zig"];
        if (!map["app/main.zig"] && appMain) map["app/main.zig"] = appMain;
    } else {
        const pgMain = getTemplate("playground")?.files["main.zig"];
        if (!map["main.zig"] && pgMain) map["main.zig"] = pgMain;
    }
    return map;
}

async function runTranspileAndBuild(
    visible: boolean,
    opts: { preservePreview?: boolean; onError?: (stderr: string, files: { [name: string]: string }) => void } = {},
): Promise<PlaygroundBuildArtifacts | Uint8Array | null> {
    let filesMap = getCurrentFilesMap();
    const zxEntries = Object.entries(filesMap).filter(([n]) => n.endsWith(".zx"));
    const zxHash = transpileInputHash(filesMap);
    let transpiledFiles: { [name: string]: string } = {};

    const emptyZxFiles = zxEntries.filter(([_, content]) => !content.trim());
    if (emptyZxFiles.length > 0) {
        opts.onError?.("One or more .zx files are empty. Please add code or remove the empty file(s).", filesMap);
        if (visible) {
            completeStatusStep("transpile", "error");
            appendTerminalLine("One or more .zx files are empty. Please add code or remove the empty file(s).", "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            if (!opts.preservePreview) resetPreviewPlaceholder();
            setRunButtonLoading(false);
        }
        return null;
    }

    if (zxEntries.length > 0) {
        const hit = transpileCache.get(zxHash);
        if (hit) {
            transpiledFiles = hit.value;
            if (visible) {
                appendStatusStep("transpile", "Transpiling\u2026");
                if (hit.isPrefetch) {
                    completeStatusStep("transpile", "prefetched", hit.duration);
                    hit.isPrefetch = false;
                } else {
                    completeStatusStep("transpile", "cached");
                }
                updatePreviewStatus("", "Transpiling\u2026 (cached)", "transpile");
            }
        } else {
            if (visible) {
                appendStatusStep("transpile", "Transpiling\u2026");
                updatePreviewStatus("", "Transpiling\u2026", "transpile");
            }
            const start = performance.now();
            try {
                if (playgroundMode === "app") {
                    transpiledFiles = await transpileAppAsync(filesMap);
                } else {
                    for (const [name, content] of zxEntries) {
                        Object.assign(transpiledFiles, await transpileZxFileAsync(name, content));
                    }
                }
                const duration = performance.now() - start;
                cachePut(transpileCache, zxHash, { value: { ...transpiledFiles }, duration, isPrefetch: !visible });
                if (visible) completeStatusStep("transpile", "done");
            } catch (err: any) {
                opts.onError?.(err.stderr || "Transpile failed", filesMap);
                if (visible) {
                    completeStatusStep("transpile", "error");
                    appendTerminalLine(err.stderr || "Transpile failed", "pg-terminal-error");
                    setTerminalCollapsed(false);
                    revealOutputWindow();
                    if (!opts.preservePreview) resetPreviewPlaceholder();
                    setRunButtonLoading(false);
                }
                return null;
            }
        }
    } else if (visible) {
        updatePreviewStatus("", "Building\u2026", "build");
    }

    for (const [zigName, zigContent] of Object.entries(transpiledFiles)) {
        if (playgroundMode === "app" && zigName.endsWith(".zon")) {
            filesMap[zigName === "app/app.zon" ? "stubs/manifest.zon" : zigName] = zigContent;
            continue;
        }
        filesMap[zigName] = zigContent;
        const hide = isGeneratedPlaygroundPath(zigName) ||
            (playgroundMode !== "app" && zigName.endsWith(".zig"));
        if (fileManager.hasFile(zigName)) {
            if (hide) {
                fileManager.updateContent(zigName, zigContent);
                const f = files.find((x) => x.name === zigName);
                if (f) {
                    f.state = createEditorState(zigName, zigContent);
                    f.hidden = true;
                }
            }
        } else {
            fileManager.addFile(zigName, zigContent);
            files.push({
                name: zigName,
                state: createEditorState(zigName, zigContent),
                hidden: hide || isHiddenPlaygroundFile(zigName),
            });
        }
    }

    if (playgroundMode === "app" && !filesMap["app/app.zig"]) {
        opts.onError?.("Transpile did not produce app/app.zig", filesMap);
        if (visible) {
            completeStatusStep("build", "error");
            appendTerminalLine("Transpile did not produce app/app.zig", "pg-terminal-error");
            setTerminalCollapsed(false);
            revealOutputWindow();
            if (!opts.preservePreview) resetPreviewPlaceholder();
            setRunButtonLoading(false);
        }
        return null;
    }

    const buildKey = hashFiles(filesMap) + `|${playgroundMode}|v5`;
    const buildHit = buildCache.get(buildKey);
    if (buildHit) {
        if (visible) {
            appendStatusStep("build", "Building\u2026");
            if (buildHit.isPrefetch) {
                completeStatusStep("build", "prefetched", buildHit.duration);
                buildHit.isPrefetch = false;
            } else {
                completeStatusStep("build", "cached");
            }
            updatePreviewStatus("", "Building\u2026 (cached)", "build");
        }
        return buildHit.value as PlaygroundBuildArtifacts | Uint8Array;
    }

    const idbHit = await idbGet<StoredBuild>(BUILDS_IDB_NAME, buildKey);
    if (idbHit && (idbHit.mode === "playground" || idbHit.mode === "app")) {
        const restored = restoreBuildArtifact(idbHit);
        cachePut(buildCache, buildKey, { value: restored, duration: idbHit.duration ?? 0, isPrefetch: false });
        if (visible) {
            appendStatusStep("build", "Building\u2026");
            completeStatusStep("build", "cached");
            updatePreviewStatus("", "Building\u2026 (cached)", "build");
        }
        return restored;
    }

    if (visible) {
        appendStatusStep("build", "Building\u2026");
        updatePreviewStatus("", "Building\u2026", "build");
    }
    const bStart = performance.now();
    try {
        const compiled = await buildFilesAsync(filesMap);
        const bDuration = performance.now() - bStart;
        cachePut(buildCache, buildKey, { value: compiled, duration: bDuration, isPrefetch: !visible });
        void idbPut(BUILDS_IDB_NAME, buildKey, storeBuildArtifact(compiled, bDuration));
        if (visible) completeStatusStep("build", "done");
        return compiled;
    } catch (err: any) {
        opts.onError?.(err.stderr || "Compilation failed.", filesMap);
        if (visible) {
            completeStatusStep("build", "error");
            if (err.stderr) {
                const lines = err.stderr.split("\n").filter((l: string) => l.length > 0);
                for (const l of lines) appendTerminalLine(l, "pg-terminal-error");
            } else {
                appendTerminalLine("Compilation failed.", "pg-terminal-error");
            }
            setTerminalCollapsed(false);
            revealOutputWindow();
            if (!opts.preservePreview) resetPreviewPlaceholder();
            setRunButtonLoading(false);
        }
        return null;
    }
}

let prefetchPromise: Promise<void> | null = null;
const outputsRun = document.getElementById('pg-run-btn')! as HTMLButtonElement;
async function runCurrentFiles(opts: { preservePreview?: boolean } = {}) {
    setRunButtonLoading(true);
    clearTerminal();

    if (!opts.preservePreview) {
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
    }

    // If a background prefetch is in flight, wait - result will be in cache
    if (prefetchPromise) await prefetchPromise;

    const compiled = await runTranspileAndBuild(true, opts);
    if (compiled == null) return;
    await runCompiled(compiled, opts);
}

outputsRun.addEventListener('click', async () => {
    showPanelTab("output");
    await runCurrentFiles();
});

function projectFiles(): { [filename: string]: string } {
    if (activeFileIndex !== -1 && editorView && !files[activeFileIndex].ephemeral) {
        fileManager.updateContent(files[activeFileIndex].name, editorView.state.doc.toString());
    }
    const map: { [filename: string]: string } = {};
    for (const f of fileManager.getAllFiles()) map[f.name] = f.content;
    return map;
}

function writeProjectFile(name: string, content: string) {
    const index = files.findIndex((f) => f.name === name && !f.ephemeral);
    if (!fileManager.hasFile(name)) {
        fileManager.addFile(name, content);
        files.push({ name, state: createEditorState(name, content), hidden: isHiddenPlaygroundFile(name) });
        updateTabs();
    } else {
        fileManager.updateContent(name, content);
        if (index === activeFileIndex && editorView) {
            const current = editorView.state.doc.toString();
            if (current !== content) {
                editorView.dispatch({ changes: { from: 0, to: current.length, insert: content } });
            }
            files[index].state = editorView.state;
        } else if (index !== -1) {
            files[index].state = createEditorState(name, content);
        }
    }
    schedulePersistFiles();
}

function removeProjectFile(name: string): boolean {
    const index = files.findIndex((f) => f.name === name && !f.ephemeral);
    if (index === -1) {
        fileManager.removeFile(name);
        return true;
    }
    if (files[index].locked) return false;
    removeFile(index);
    return true;
}

function execWorkerAsync<T>(worker: Worker, payload: unknown): Promise<T> {
    return new Promise((resolve) => {
        function handler(ev: MessageEvent) {
            if (!ev.data?.exec) return;
            worker.removeEventListener("message", handler);
            resolve(ev.data.exec);
        }
        worker.addEventListener("message", handler);
        worker.postMessage({ exec: payload });
    });
}

function runProgramAsync(wasm: Uint8Array, args: string[], onOutput: (text: string) => void, signal?: AbortSignal): Promise<number> {
    return new Promise((resolve) => {
        const worker = new Worker(`/assets/playground/workers/runner.js?v=${VERSION}`);
        const finish = (code: number) => {
            worker.terminate();
            signal?.removeEventListener("abort", onAbort);
            resolve(code);
        };
        const onAbort = () => finish(130);
        signal?.addEventListener("abort", onAbort);
        worker.onerror = (ev) => {
            onOutput(`${ev.message}\n`);
            finish(1);
        };
        worker.onmessage = (ev: MessageEvent) => {
            if (typeof ev.data?.out === "string") onOutput(ev.data.out);
            if (typeof ev.data?.exit === "number") finish(ev.data.exit);
        };
        worker.postMessage({ program: { wasm, args } });
    });
}

async function devBuild(): Promise<DevBuildResult> {
    let failure = null as { stderr: string; files: { [name: string]: string } } | null;
    const compiled = await runTranspileAndBuild(false, {
        preservePreview: true,
        onError: (stderr, files) => {
            failure = { stderr, files };
        },
    });
    if (compiled) return { ok: true, compiled };
    return { ok: false, stderr: failure?.stderr ?? "Build failed", files: failure?.files ?? {} };
}

const shellHost: ShellHost = {
    files: projectFiles,
    writeFile: writeProjectFile,
    removeFile: removeProjectFile,
    build: () => runTranspileAndBuild(true, { preservePreview: true }),
    run: () => runCurrentFiles(),
    devBuild,
    preview: (compiled) => runCompiled(compiled, { preservePreview: true }),
    onFilesChanged(listener) {
        filesChangedListeners.add(listener);
        return () => filesChangedListeners.delete(listener);
    },
    zx: (args, files, opts = {}) => execWorkerAsync<ZxExecResult>(zxWorker, { args, files, ...opts }),
    zig: (args, files, emit) => execWorkerAsync<ZigExecResult>(zigWorker, { args, files, emit }),
    runProgram: runProgramAsync,
    onOutput,
};

let shellPromise: Promise<Shell> | null = null;
setShellHooks({
    open(container) {
        if (!shellPromise) {
            const url = `/assets/playground/shell.js?v=${VERSION}`;
            shellPromise = import(url).then((m) => m.mountShell(container, shellHost));
            shellPromise.catch((err) => {
                shellPromise = null;
                container.textContent = `Failed to start terminal: ${err}`;
            });
        }
        void shellPromise.then((shell) => shell.focus());
    },
    clear() {
        void shellPromise?.then((shell) => shell.clear());
    },
});

function maybePrefetchBuild() {
    if (prefetchPromise) return;

    const snap = getCurrentFilesMap();
    const zxEntries = Object.entries(snap).filter(([n]) => n.endsWith('.zx'));
    const zxHash = transpileInputHash(snap);
    const transpiled = transpileCache.get(zxHash) ?? (zxEntries.length === 0 ? { value: {} } : null);
    if (transpiled !== null && buildCache.has(hashFiles({ ...snap, ...transpiled.value }) + `|${playgroundMode}|v5`)) return;

    prefetchPromise = (async () => {
        try { await runTranspileAndBuild(false); } catch { /* silent */ }
    })().finally(() => { prefetchPromise = null; });
}

// Prefetch when the pointer nears or hovers the Run button (not on every editor leave).
const RUN_PREFETCH_PROXIMITY_PX = 72;
outputsRun.addEventListener('mouseenter', maybePrefetchBuild);
outputsRun.addEventListener('focus', maybePrefetchBuild);
document.addEventListener('mousemove', (ev) => {
    const rect = outputsRun.getBoundingClientRect();
    const pad = RUN_PREFETCH_PROXIMITY_PX;
    if (
        ev.clientX >= rect.left - pad &&
        ev.clientX <= rect.right + pad &&
        ev.clientY >= rect.top - pad &&
        ev.clientY <= rect.bottom + pad
    ) {
        maybePrefetchBuild();
    }
}, { passive: true });
