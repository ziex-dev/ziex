// The playground's editor island: CodeMirror plus LSP features. This is the only
// hand-written JS on the page. Everything else (files, tabs, build, preview) is the Zig
// component in ../page.zx, which mounts the editor through `globalThis.PlaygroundEditor`
// and receives edits through the hooks it passes in. The language server (tree-sitter
// highlighting via semantic tokens, ZLS completion, hover, diagnostics) runs in the Zig
// worker; `hooks.lsp` forwards each JSON-RPC message there and resolves with its replies.
import { EditorState, Prec, RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, keymap, type DecorationSet, type ViewUpdate } from "@codemirror/view";
import { basicSetup } from "codemirror";
import { autocompletion } from "@codemirror/autocomplete";
import { indentWithTab } from "@codemirror/commands";
import { indentUnit } from "@codemirror/language";
import { setDiagnostics } from "@codemirror/lint";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import {
    LSPClient,
    LSPPlugin,
    hoverTooltips,
    serverCompletionSource,
    signatureHelp,
    type LSPClientExtension,
    type Transport,
} from "@codemirror/lsp-client";
import { editorHighlightStyle, editorTheme } from "./theme";

/** Zig callbacks (see `mountEditor` in page.zx). */
type Hooks = {
    change(name: string, text: string): void;
    cursor(line: number, col: number): void;
    run(): void;
    format(): void;
    /** Returns the server's replies to one message. */
    lsp(message: string): Promise<string[]>;
    /** A file linked from a tooltip; `line`/`col` are 0-based. */
    openFile(path: string, line: number, col: number): void;
};

/** What the page calls. */
type Editor = {
    open(name: string, text: string, readonly?: boolean): void;
    /** Moves the cursor to a 0-based line and column and scrolls it into view. */
    goto(line: number, col: number): void;
    setText(name: string, text: string): void;
    close(name: string): void;
    focus(): void;
};

function mount(parent: HTMLElement, hooks: Hooks): Editor {
    const client = new LSPClient({
        rootUri: "file:///",
        timeout: 60_000,
        extensions: [
            // The Zig worker answers the server's configuration requests itself.
            { clientCapabilities: { workspace: { configuration: true } } },
            hoverTooltips(),
            signatureHelp(),
            diagnostics(),
        ],
    }).connect(zigTransport(hooks));

    const states = new Map<string, EditorState>();
    let active = "";

    const stateFor = (name: string, text: string, readonly: boolean) => {
        const extensions = extensionsFor(name, hooks, client, () => active);
        if (readonly) extensions.push(EditorState.readOnly.of(true), EditorView.editable.of(false));
        return EditorState.create({ doc: text, extensions });
    };

    const view = new EditorView({ parent, state: EditorState.create({ doc: "" }) });
    followTooltipLinks(hooks);

    return {
        open(name, text, readonly = false) {
            if (active) states.set(active, view.state);
            let state = states.get(name);
            if (!state || state.doc.toString() !== text) state = stateFor(name, text, readonly);
            active = name;
            view.setState(state);
        },
        goto(line, col) {
            const doc = view.state.doc;
            const target = doc.line(Math.min(Math.max(line, 0) + 1, doc.lines));
            const pos = Math.min(target.from + Math.max(col, 0), target.to);
            view.dispatch({
                selection: { anchor: pos },
                effects: EditorView.scrollIntoView(pos, { y: "center" }),
            });
            view.focus();
        },
        setText(name, text) {
            if (name !== active) {
                states.delete(name);
                return;
            }
            const doc = view.state.doc;
            if (doc.toString() === text) return;
            const head = Math.min(view.state.selection.main.head, text.length);
            view.dispatch({ changes: { from: 0, to: doc.length, insert: text }, selection: { anchor: head } });
        },
        close(name) {
            states.delete(name);
        },
        focus() {
            view.focus();
        },
    };
}

function extensionsFor(name: string, hooks: Hooks, client: LSPClient, active: () => string): Extension[] {
    const extensions: Extension[] = [
        basicSetup,
        editorTheme,
        editorHighlightStyle,
        indentUnit.of("    "),
        Prec.highest(keymap.of([
            { key: "F12", run: (view) => (void goToDefinition(view, hooks), true) },
            { key: "Mod-Enter", run: () => (hooks.run(), true) },
            { key: "F5", run: () => (hooks.run(), true) },
            { key: "Shift-Alt-f", run: () => (hooks.format(), true) },
        ])),
        keymap.of([indentWithTab]),
        // Cmd/Ctrl+click jumps to the definition, like F12.
        EditorView.domEventHandlers({
            mousedown(event, view) {
                if (!(event.metaKey || event.ctrlKey) || event.button !== 0) return false;
                const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
                if (pos == null) return false;
                view.dispatch({ selection: { anchor: pos } });
                void goToDefinition(view, hooks);
                event.preventDefault();
                return true;
            },
        }),
        EditorView.updateListener.of((update) => {
            if (active() !== name) return;
            if (update.docChanged) hooks.change(name, update.state.doc.toString());
            if (update.docChanged || update.selectionSet) {
                const head = update.state.selection.main.head;
                const line = update.state.doc.lineAt(head);
                hooks.cursor(line.number, head - line.from + 1);
            }
        }),
    ];
    // Lezer gives instant highlighting; semantic tokens from the zx server (tree-sitter) refine it.
    if (name.endsWith(".zx")) extensions.push(html());
    if (name.endsWith(".css")) extensions.push(css());
    if (/\.(zx|zig|zon)$/.test(name)) {
        // The server knows Zig and zx; Lezer's HTML tag suggestions would only get in the way.
        extensions.push(client.plugin(`file:///${name}`, "zig"), semanticTokens, autocompletion({ override: [serverCompletionSource] }));
    }
    return extensions;
}

type Location = { uri?: string; targetUri?: string; range?: Range; targetSelectionRange?: Range };

/** `textDocument/definition` at the cursor, opened through the page like a tooltip link. */
async function goToDefinition(view: EditorView, hooks: Hooks) {
    const plugin = LSPPlugin.get(view);
    if (!plugin) return;
    plugin.client.sync();
    const result = await plugin.client.request<object, Location | Location[] | null>("textDocument/definition", {
        textDocument: { uri: plugin.uri },
        position: plugin.toPosition(view.state.selection.main.head),
    });
    const loc = Array.isArray(result) ? result[0] : result;
    const uri = loc?.uri ?? loc?.targetUri;
    const range = loc?.targetSelectionRange ?? loc?.range;
    const target = uri ? localTarget(uri) : null;
    if (target && range) hooks.openFile(target.path, range.start.line, range.start.character);
}

/**
 * Links in hover tooltips: local sources (`file:///zx/src/x.zig#L12C5`, `lib/std/...`)
 * open in the editor at that position; anything else opens in a new tab.
 */
function followTooltipLinks(hooks: Hooks) {
    document.addEventListener("click", (event) => {
        const link = (event.target as Element | null)?.closest?.(".cm-tooltip a[href]");
        if (!link) return;
        event.preventDefault();
        event.stopPropagation();
        const href = link.getAttribute("href") ?? "";
        const target = localTarget(href);
        if (target) hooks.openFile(target.path, target.line, target.col);
        else window.open(href, "_blank", "noopener,noreferrer");
    }, true);
}

function localTarget(href: string): { path: string; line: number; col: number } | null {
    const [raw = "", hash = ""] = href.split("#");
    let path: string;
    if (raw.startsWith("file://")) {
        try {
            path = decodeURIComponent(new URL(raw).pathname);
        } catch {
            path = raw.replace(/^file:\/+/, "/");
        }
    } else if (/^[A-Za-z][\w+.-]*:/.test(raw) || raw === "") {
        return null;
    } else if (/\.(zig|zx|zon|mdzx|css|html|md)$/.test(raw)) {
        path = raw;
    } else {
        return null;
    }
    const m = hash.match(/^L(\d+)(?:C(\d+))?/i) ?? hash.match(/^(\d+)(?::(\d+))?$/);
    return {
        path: path.replace(/^\/+/, ""),
        line: m ? Math.max(0, Number(m[1]) - 1) : 0,
        col: m && m[2] != null ? Math.max(0, Number(m[2]) - 1) : 0,
    };
}

/** JSON-RPC over `hooks.lsp`, one message at a time so replies keep their order. */
function zigTransport(hooks: Hooks): Transport {
    const handlers = new Set<(message: string) => void>();
    let queue: Promise<unknown> = Promise.resolve();
    return {
        send(message) {
            queue = queue
                .then(() => hooks.lsp(message))
                .then((replies) => {
                    for (const reply of replies) for (const h of handlers) h(reply);
                })
                .catch((err) => console.error("playground lsp:", err));
        },
        subscribe: (h) => void handlers.add(h),
        unsubscribe: (h) => void handlers.delete(h),
    };
}

type Range = { start: { line: number; character: number }; end: { line: number; character: number } };
type Diagnostic = { range: Range; severity?: number; message: string | { value: string }; source?: string };

/** Pushes the server's diagnostics into the lint gutter; JSX confuses ZLS, so that error is dropped. */
function diagnostics(): LSPClientExtension {
    const autoSync = ViewPlugin.fromClass(class {
        pending = -1;
        update(update: ViewUpdate) {
            if (!update.docChanged) return;
            clearTimeout(this.pending);
            this.pending = window.setTimeout(() => LSPPlugin.get(update.view)?.client.sync(), 400);
        }
        destroy() {
            clearTimeout(this.pending);
        }
    });
    const severities = { 1: "error", 2: "warning", 3: "info", 4: "info" } as const;
    return {
        clientCapabilities: { textDocument: { publishDiagnostics: {} } },
        notificationHandlers: {
            "textDocument/publishDiagnostics": (client, params: { uri: string; diagnostics: Diagnostic[] }) => {
                const view = client.workspace.getFile(params.uri)?.getView();
                const plugin = view && LSPPlugin.get(view);
                if (!view || !plugin) return false;
                const pos = (p: Range["start"]) =>
                    plugin.unsyncedChanges.mapPos(plugin.fromPosition(p, plugin.syncedDoc));
                const list = params.diagnostics
                    .filter((d) => d.message !== "expected expression, found '<'")
                    .map((d) => ({
                        from: pos(d.range.start),
                        to: pos(d.range.end),
                        severity: severities[(d.severity ?? 1) as 1 | 2 | 3 | 4],
                        message: typeof d.message === "string" ? d.message : d.message.value,
                    }))
                    .sort((a, b) => a.from - b.from);
                view.dispatch(setDiagnostics(view.state, list));
                return true;
            },
            "window/logMessage": () => true,
        },
        editorExtension: autoSync,
    };
}

/** `textDocument/semanticTokens/full` as `st-<type> sm-<modifier>` classes (see playground.css). */
const semanticTokens = ViewPlugin.fromClass(
    class {
        decorations: DecorationSet = Decoration.none;
        timer = -1;
        generation = 0;

        constructor(view: EditorView) {
            this.schedule(view, 0);
        }

        update(update: ViewUpdate) {
            if (!update.docChanged) return;
            this.decorations = this.decorations.map(update.changes);
            this.schedule(update.view, 300);
        }

        destroy() {
            clearTimeout(this.timer);
        }

        schedule(view: EditorView, delay: number) {
            clearTimeout(this.timer);
            const gen = ++this.generation;
            this.timer = window.setTimeout(() => void this.refresh(view, gen), delay);
        }

        async refresh(view: EditorView, gen: number) {
            const plugin = LSPPlugin.get(view);
            if (!plugin) return;
            const { client, uri } = plugin;
            await client.initializing;
            const provider = client.serverCapabilities?.semanticTokensProvider;
            if (!provider || !("legend" in provider)) return;
            client.sync();
            const tokens = await client.request<{ textDocument: { uri: string } }, { data: number[] } | null>(
                "textDocument/semanticTokens/full",
                { textDocument: { uri } },
            );
            if (!tokens || gen !== this.generation || !view.dom.isConnected) return;

            const { tokenTypes, tokenModifiers } = provider.legend;
            const doc = plugin.syncedDoc;
            const builder = new RangeSetBuilder<Decoration>();
            let line = 0;
            let col = 0;
            const data = tokens.data;
            for (let i = 0; i < data.length; i += 5) {
                line += data[i]!;
                col = data[i] === 0 ? col + data[i + 1]! : data[i + 1]!;
                if (line + 1 > doc.lines) break;
                let cls = `st-${tokenTypes[data[i + 3]!]}`;
                for (let bits = data[i + 4]!, m = 0; bits !== 0; bits >>= 1, m++) {
                    if (bits & 1) cls += ` sm-${tokenModifiers[m]}`;
                }
                const { from: lineFrom, to: lineTo } = doc.line(line + 1);
                const from = plugin.unsyncedChanges.mapPos(Math.min(lineFrom + col, lineTo));
                const to = plugin.unsyncedChanges.mapPos(Math.min(lineFrom + col + data[i + 2]!, lineTo));
                if (to > from) builder.add(from, to, Decoration.mark({ class: cls }));
            }
            this.decorations = builder.finish();
            view.dispatch({});
        }
    },
    { decorations: (v) => v.decorations },
);

(globalThis as { PlaygroundEditor?: unknown }).PlaygroundEditor = { mount };
dispatchEvent(new Event("pg-editor-ready"));
