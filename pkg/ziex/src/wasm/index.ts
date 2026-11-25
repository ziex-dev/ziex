export {
    CallbackType_Event,
    CallbackType_FetchSuccess,
    CallbackType_FetchError,
    CallbackType_Timeout,
    CallbackType_Interval,
    CallbackType_WebSocketOpen,
    CallbackType_WebSocketMessage,
    CallbackType_WebSocketError,
    CallbackType_WebSocketClose,
} from "./constants";
export {
    wasm,
    textDecoder,
    textEncoder,
    getMemoryView,
    readString,
    writeBytes,
    writeBytesOut,
    writeJsonOut,
    bindWasmAlloc,
    ZxBridgeCore,
} from "./core";
export type { CallbackHandler, WasmAllocRef } from "./core";
export { R, ref, deref, unref } from "./js";

import {
    ZxBridgeCore,
    wasm,
    mem,
    wrapPromisingExport,
    invokeWasmExport,
    readString,
    textDecoder,
    textEncoder,
    getMemoryView,
} from "./core";
import { bindWasmAlloc, type WasmAllocRef } from "./core";
import { ref, deref, unref, resetRefs, webHelpers, bindCallbacks, type WebHelpers } from "./js";
import {
    CallbackType_WebSocketOpen,
    CallbackType_WebSocketMessage,
    CallbackType_WebSocketError,
    CallbackType_WebSocketClose,
} from "./constants";
import { flushDomCmds } from "./dom_cmd";
import { createKvHandlers } from "../runtime/kv/extern";
import type { Handlers } from "../runtime/host";
import { createBrowserKVBindings, type KVNamespace } from "../runtime/kv";
import { createFsHandlers, mountBrowserFs, type Store, type Vfs } from "../runtime/fs";
import { DELEGATED_EVENTS } from "./generated/events";
import { EVENT_FLAGS } from "./generated/event_bits";

/**
 * Browser Ziex Bridge - extends ZxBridgeCore with DOM, WebSocket, and form-action support.
 * Import this from environments that have access to browser globals.
 * For edge runtimes, import ZxBridgeCore from ./core instead.
 */
export class ZxBridge extends ZxBridgeCore {
    #websockets: Map<bigint, WebSocket> = new Map();

    // Every handler may suspend (fetch, sleep); the gate keeps suspended handlers safe.
    readonly #eventbridge: ((velementId: bigint, eventTypeId: number, eventRef: number) => void) | undefined;

    constructor(exports: WebAssembly.Exports) {
        super(exports);
        this.#eventbridge = wrapPromisingExport(
            exports.__zx_eventbridge as ((velementId: bigint, eventTypeId: number, eventRef: number) => void) | undefined
        );
    }

    hasEventHandler(velementId: number, eventTypeId: number): boolean {
        return hasBit(eventHandlersPresent.get(velementId), eventTypeId);
    }

    registerEventHandler(velementId: number, eventTypeId: number): void {
        let present = eventHandlersPresent.get(velementId);
        if (!present) eventHandlersPresent.set(velementId, present = new Uint32Array(EVENT_WORDS));
        present[eventTypeId >>> 5]! |= 1 << (eventTypeId & 31);
        ensureDelegatedListener(eventTypeId);
    }

    clearEventHandlers(velementId: number): void {
        const present = eventHandlersPresent.get(velementId);
        eventHandlersPresent.delete(velementId);
        // Drop high-freq listeners when no vnode still needs them.
        if (present) releaseHighFreq(present);
    }

    /** Submit a form action with bound-state round-trip. */
    submitFormActionAsync(form: HTMLFormElement, actionId: number, statesJson: string, fetchId: bigint): void {
        const formData = new FormData(form);
        formData.append('__$states', statesJson);
        fetch(window.location.href, {
            method: 'POST',
            // `>>> 0` reinterprets the i32 from wasm as u32 (ids can exceed 2^31).
            headers: { 'x-action': String(actionId >>> 0) },
            body: formData,
        })
        .then(async (response) => {
            const text = await response.text();
            this._notifyFetchComplete(fetchId, response.status, text, false);
        })
        .catch((error: unknown) => {
            const msg = error instanceof Error ? error.message : 'Fetch failed';
            this._notifyFetchComplete(fetchId, 0, msg, true);
        });
    }

    /**
     * Create and connect a WebSocket.
     * Completes via `__zx_cb(ws_open|ws_message|ws_error|ws_close, ...)`.
     */
    wsConnect(
        wsId: bigint,
        urlPtr: number,
        urlLen: number,
        protocolsPtr: number,
        protocolsLen: number
    ): void {
        const url = readString(urlPtr, urlLen);
        const protocolsStr = protocolsLen > 0 ? readString(protocolsPtr, protocolsLen) : '';
        const protocols = protocolsStr ? protocolsStr.split(',').map(p => p.trim()).filter(Boolean) : undefined;

        try {
            const ws = protocols && protocols.length > 0
                ? new WebSocket(url, protocols)
                : new WebSocket(url);

            ws.binaryType = 'arraybuffer';

            ws.onopen = () => {
                const protocol = ws.protocol || '';
                const [ptr, len] = this._writeStringToWasm(protocol);
                this._invoke(CallbackType_WebSocketOpen, wsId, BigInt(ptr), BigInt(len));
            };

            ws.onmessage = (event: MessageEvent) => {
                const isBinary = event.data instanceof ArrayBuffer;
                const data: Uint8Array = isBinary
                    ? new Uint8Array(event.data as ArrayBuffer)
                    : textEncoder.encode(event.data as string);
                const [ptr, len] = this.writeBytesToWasm(data);
                this._invoke(CallbackType_WebSocketMessage, wsId, BigInt(ptr), BigInt(len), BigInt(isBinary ? 1 : 0));
            };

            ws.onerror = (_event: Event) => {
                const [ptr, len] = this._writeStringToWasm('WebSocket error');
                this._invoke(CallbackType_WebSocketError, wsId, BigInt(ptr), BigInt(len));
            };

            ws.onclose = (event: CloseEvent) => {
                const reason = event.reason || '';
                const [ptr, len] = this._writeStringToWasm(reason);
                const c = BigInt(len) | (BigInt(event.wasClean ? 1 : 0) << 32n);
                this._invoke(CallbackType_WebSocketClose, wsId, BigInt(event.code), BigInt(ptr), c);
                this.#websockets.delete(wsId);
            };

            this.#websockets.set(wsId, ws);
        } catch (error) {
            const msg = error instanceof Error ? error.message : 'WebSocket connection failed';
            const [ptr, len] = this._writeStringToWasm(msg);
            this._invoke(CallbackType_WebSocketError, wsId, BigInt(ptr), BigInt(len));
        }
    }

    /** Send data over WebSocket */
    wsSend(wsId: bigint, dataPtr: number, dataLen: number, isBinary: number): void {
        const ws = this.#websockets.get(wsId);
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        const memory = getMemoryView();
        const start = dataPtr >>> 0;
        const length = dataLen >>> 0;
        if (start + length > memory.byteLength) return;
        if (isBinary) {
            ws.send(memory.slice(start, start + length));
        } else {
            ws.send(textDecoder.decode(memory.subarray(start, start + length)));
        }
    }

    /** Close WebSocket connection */
    wsClose(wsId: bigint, code: number, reasonPtr: number, reasonLen: number): void {
        const ws = this.#websockets.get(wsId);
        if (!ws) return;
        const reason = reasonLen > 0 ? readString(reasonPtr, reasonLen) : undefined;
        try {
            if (reason) ws.close(code, reason);
            else ws.close(code);
        } catch {
            ws.close();
        }
    }

    override dispose(): void {
        super.dispose();
        eventHandlersPresent.clear();
        for (const ws of this.#websockets.values()) {
            try {
                ws.close();
            } catch {
                // Ignore shutdown races during hot-reinit.
            }
        }
        this.#websockets.clear();
    }

    /**
     * Dispatch to WASM for one vnode. Caller owns `eventRef` lifetime
     * (store once per bubble, release after sync/async work completes).
     */
    eventbridge(velementId: number, eventTypeId: number, eventRef: number): void | Promise<void> {
        const run = this.#eventbridge;
        if (!run) return;
        const result = run(BigInt(velementId >>> 0), eventTypeId, eventRef) as void | Promise<void>;
        // Returned so the caller keeps `eventRef` alive until a suspended handler finishes.
        return result?.catch((error) => console.error(error));
    }

    /** Create the full browser import object for WASM instantiation (includes DOM + WebSocket). */
    static override createImportObject(bridgeRef: [ZxBridge | null], handlers: Handlers = {}) {
        const base = ZxBridgeCore.createImportObject(bridgeRef, handlers);
        return {
            ...base,
            __zx: {
                ...base.__zx,
                _registerEventHandler: (vnodeId: bigint, eventTypeId: number) => {
                    bridgeRef[0]?.registerEventHandler(Number(vnodeId), eventTypeId);
                },
                _clearEventHandlers: (vnodeId: bigint) => {
                    bridgeRef[0]?.clearEventHandlers(Number(vnodeId));
                },
                // WebSocket API
                _wsConnect: (
                    wsId: bigint,
                    urlPtr: number,
                    urlLen: number,
                    protocolsPtr: number,
                    protocolsLen: number
                ) => {
                    bridgeRef[0]?.wsConnect(wsId, urlPtr, urlLen, protocolsPtr, protocolsLen);
                },
                _wsSend: (wsId: bigint, dataPtr: number, dataLen: number, isBinary: number) => {
                    bridgeRef[0]?.wsSend(wsId, dataPtr, dataLen, isBinary);
                },
                _wsClose: (wsId: bigint, code: number, reasonPtr: number, reasonLen: number) => {
                    bridgeRef[0]?.wsClose(wsId, code, reasonPtr, reasonLen);
                },
                _flush: (ptr: number, len: number): void => {
                    flushDomCmds(ptr, len, {
                        domNodes,
                        cleanupDomNodes,
                    });
                },
                _getLocationHref: (bufPtr: number, bufLen: number): number => {
                    const bytes = textEncoder.encode(window.location.href);
                    const len = Math.min(bytes.length, bufLen);
                    mem.writeBytes(bufPtr, bytes.subarray(0, len));
                    return len;
                },
                _getFormData: (eventRef: number, outPtrAddr: number): number => {
                    const event = deref(eventRef) as Event | undefined;
                    const el = event?.target as Element | null | undefined;
                    const form = el instanceof HTMLFormElement
                        ? el
                        : el?.closest?.('form') ?? null;
                    if (!form) return 0;

                    // Flat ZXON/JSON array: [k1, v1, k2, v2, ...]
                    const entries: string[] = [];
                    for (const [k, v] of new FormData(form).entries()) {
                        entries.push(k, String(v));
                    }
                    const bytes = textEncoder.encode(JSON.stringify(entries));
                    const [ptr, len] = bridgeRef[0]!.writeBytesToWasm(bytes);
                    mem.data().setUint32(outPtrAddr >>> 0, ptr, true);
                    return len;
                },
                _submitFormAction: (vnodeId: bigint, actionId: number): void => {
                    const form = domNodes.get(Number(vnodeId)) as HTMLFormElement | undefined;
                    if (!form || !(form instanceof HTMLFormElement)) return;
                    const formData = new FormData(form);
                    fetch(window.location.href, {
                        method: 'POST',
                        // `>>> 0` reinterprets the i32 from wasm as u32 (ids can exceed 2^31).
                        headers: { 'x-action': String(actionId >>> 0) },
                        body: formData,
                    }).catch(() => {});
                },
                _submitFormActionAsync: (vnodeId: bigint, actionId: number, statesPtr: number, statesLen: number, fetchId: bigint): void => {
                    const form = domNodes.get(Number(vnodeId)) as HTMLFormElement | undefined;
                    if (!form || !(form instanceof HTMLFormElement)) return;
                    const statesJson = statesLen > 0 ? readString(statesPtr, statesLen) : '[]';
                    bridgeRef[0]?.submitFormActionAsync(form, actionId, statesJson, fetchId);
                },
                _formReset: (vnodeId: bigint): void => {
                    const form = domNodes.get(Number(vnodeId));
                    if (form instanceof HTMLFormElement) form.reset();
                },
            },
        };
    }
}

/** JS-side DOM node registry: vnode_id → Node. Number keys avoid BigInt allocs. */
const domNodes = new Map<number, Node>();

const F_HIGH_FREQ = 1, F_CAPTURE = 2, F_PASSIVE = 4;
const EVENT_WORDS = Math.ceil(DELEGATED_EVENTS.length / 32);
const HIGH_FREQ_WORDS = new Uint32Array(EVENT_WORDS);
for (let id = 0; id < EVENT_FLAGS.length; id++) {
    if (EVENT_FLAGS[id]! & F_HIGH_FREQ) HIGH_FREQ_WORDS[id >>> 5]! |= 1 << (id & 31);
}

function hasBit(set: Uint32Array | undefined, id: number): boolean {
    return set !== undefined && (set[id >>> 5]! & (1 << (id & 31))) !== 0;
}

/** Bitset per vnode: which event types have a handler. */
const eventHandlersPresent = new Map<number, Uint32Array>();

/** Detach high-freq listeners in `set` that no vnode needs any more. */
function releaseHighFreq(set: Uint32Array): void {
    for (let w = 0; w < EVENT_WORDS; w++) {
        for (let bits = set[w]! & HIGH_FREQ_WORDS[w]!; bits !== 0; bits &= bits - 1) {
            maybeRemoveHighFreqListener(w * 32 + 31 - Math.clz32(bits & -bits));
        }
    }
}

/** Remove a detached DOM subtree from domNodes + handler bitsets */
function cleanupDomNodes(node: Node): void {
    let removed: Uint32Array | undefined;
    // Pre-order walk via sibling links: no stack array or NodeList access.
    let n: Node | null = node;
    while (n !== null) {
        const ref = (n as any).__zx_ref;
        if (typeof ref === "number") {
            const present = eventHandlersPresent.get(ref);
            if (present !== undefined) {
                removed ??= new Uint32Array(EVENT_WORDS);
                for (let w = 0; w < EVENT_WORDS; w++) removed[w]! |= present[w]!;
                eventHandlersPresent.delete(ref);
            }
            domNodes.delete(ref);
        }
        if (n.firstChild !== null) {
            n = n.firstChild;
            continue;
        }
        while (n !== node && n!.nextSibling === null) n = n!.parentNode;
        n = n === node ? null : n!.nextSibling;
    }
    if (removed) releaseHighFreq(removed);
}

type DelegatedListenerState = {
    root: Element;
    bridge: ZxBridge;
    attached: Map<number, { listener: EventListener; options: AddEventListenerOptions }>;
};

let delegationState: DelegatedListenerState | null = null;

function makeDelegatedListener(bridge: ZxBridge, eventTypeId: number, targetOnly: boolean): EventListener {
    return (event: Event) => {
        let eventRef: number | undefined;
        const pending: Promise<unknown>[] = [];
        let target = event.target as HTMLElement | null;
        while (target && target !== document.body) {
            const zxRef = (target as any).__zx_ref;
            if (typeof zxRef === "number" && bridge.hasEventHandler(zxRef, eventTypeId)) {
                if (eventRef === undefined) eventRef = ref(event);
                const result = bridge.eventbridge(zxRef, eventTypeId, eventRef);
                if (result && typeof (result as Promise<unknown>).then === "function") {
                    pending.push(result as Promise<unknown>);
                }
                if (event.cancelBubble) break;
            }
            // Non-bubbling events fire separately on each element that wants them.
            if (targetOnly) break;
            target = target.parentElement;
        }
        if (eventRef !== undefined) {
            const handle = eventRef;
            if (pending.length > 0) {
                Promise.all(pending).finally(() => unref(handle));
            } else {
                unref(handle);
            }
        }
    };
}

function ensureDelegatedListener(eventTypeId: number): void {
    const state = delegationState;
    if (!state || state.attached.has(eventTypeId)) return;
    const domType = DELEGATED_EVENTS[eventTypeId];
    if (!domType) return;
    const flags = EVENT_FLAGS[eventTypeId] ?? 0;
    const capture = (flags & F_CAPTURE) !== 0;
    const options: AddEventListenerOptions = { passive: (flags & F_PASSIVE) !== 0, capture };
    const listener = makeDelegatedListener(state.bridge, eventTypeId, capture);
    state.root.addEventListener(domType, listener, options);
    state.attached.set(eventTypeId, { listener, options });
}

function anyHandlerForType(eventTypeId: number): boolean {
    for (const set of eventHandlersPresent.values()) {
        if (hasBit(set, eventTypeId)) return true;
    }
    return false;
}

function maybeRemoveHighFreqListener(eventTypeId: number): void {
    if (((EVENT_FLAGS[eventTypeId] ?? 0) & F_HIGH_FREQ) === 0) return;
    if (anyHandlerForType(eventTypeId)) return;
    const state = delegationState;
    if (!state) return;
    const entry = state.attached.get(eventTypeId);
    if (!entry) return;
    const domType = DELEGATED_EVENTS[eventTypeId]!;
    state.root.removeEventListener(domType, entry.listener, entry.options);
    state.attached.delete(eventTypeId);
}

/** Initialize event delegation */
export function initEventDelegation(bridge: ZxBridge, rootSelector: string = 'body'): () => void {
    const root = document.querySelector(rootSelector);
    if (!root) return () => {};

    // Listeners attach on the first handler of each type (`registerEventHandler`).
    delegationState = { root, bridge, attached: new Map() };

    return () => {
        if (!delegationState) return;
        for (const [eventTypeId, entry] of delegationState.attached) {
            const domType = DELEGATED_EVENTS[eventTypeId]!;
            delegationState.root.removeEventListener(domType, entry.listener, entry.options);
        }
        delegationState.attached.clear();
        delegationState = null;
    };
}

export type InitOptions = {
    url?: string;
    eventDelegationRoot?: string;
    importObject?: WebAssembly.Imports;
    kv?: Record<string, KVNamespace>;
    /** Store behind the client's `std.Io.Dir.cwd()` (OPFS by default); `false` disables files. */
    fs?: Store | false;
};

// Mounted once per page, so a dev reinit keeps unflushed writes.
let browserFs: Promise<Vfs> | null = null;

type ActiveRuntime = {
    dispose: () => void;
    options: InitOptions;
};

type ZiexDevtoolsHook = {
    location: {
        href: string;
        origin: string;
        host: string;
        pathname: string;
    };
    reinit: () => Promise<{ source: WebAssembly.WebAssemblyInstantiatedSource; bridge: ZxBridge }>;
};

let activeRuntime: ActiveRuntime | null = null;

function buildDevtoolsLocation(): ZiexDevtoolsHook["location"] {
    return {
        href: window.location.href,
        origin: window.location.origin,
        host: window.location.host,
        pathname: window.location.pathname,
    };
}

function normalizeOptions(options: InitOptions = {}): InitOptions {
    return {
        url: options.url,
        eventDelegationRoot: options.eventDelegationRoot,
        importObject: options.importObject,
        kv: options.kv,
        fs: options.fs,
    };
}

function registerDevReinit(options: InitOptions): void {
    if (typeof window === 'undefined') return;
    const reinit = () => init(options);
    window.__zx_dev_reinit = reinit;
    window.__ZIEX_DEVTOOLS_GLOBAL_HOOK__ = {
        location: buildDevtoolsLocation(),
        reinit,
    };
}

type WebShims = (helpers: WebHelpers) => Record<string, Function>;
type WebGlobal = { __zx_web?: WebShims | false };

/**
 * Loads `<wasm>.web.js` (written beside the wasm) unless the build prepended
 * the glue to this script, which always defines `globalThis.__zx_web`.
 * Started before the wasm fetch so both download in parallel.
 */
function loadWebGlue(wasmUrl: string): Promise<void> {
    if ((globalThis as WebGlobal).__zx_web !== undefined) return Promise.resolve();
    const glue = new URL(wasmUrl, location.href);
    if (!glue.pathname.endsWith(".wasm")) return Promise.resolve();
    glue.pathname = glue.pathname.replace(/\.wasm$/, ".web.js");
    if (typeof __DEV__ !== "undefined" && __DEV__) glue.searchParams.set("t", String(Date.now()));
    return import(/* @vite-ignore */ glue.href).then(
        () => {},
        (error) => console.error(`ziex: failed to load browser bindings from ${glue.href}`, error),
    );
}

/** `__zx_web` imports from the loaded glue; missing ones throw a descriptive error when called. */
function createWebImports(module: WebAssembly.Module): Record<string, Function> {
    const imports = WebAssembly.Module.imports(module).filter((imp) => imp.module === "__zx_web");
    const factory = (globalThis as WebGlobal).__zx_web;
    const shims = factory ? factory(webHelpers(mem, () => wasm.alloc)) : {};
    for (const imp of imports) {
        if (imp.name in shims) continue;
        console.warn(`ziex: no JS glue for browser binding "${imp.name}"; rebuild the client assets`);
        shims[imp.name] = () => {
            throw new Error(`ziex: browser binding "${imp.name}" is missing from the JS glue`);
        };
    }
    return shims;
}

/** Initialize WASM with the Ziex Bridge */
export async function init(options: InitOptions = {}): Promise<{ source: WebAssembly.WebAssemblyInstantiatedSource; bridge: ZxBridge }> {
    const normalizedOptions = normalizeOptions(options);
    if (activeRuntime) {
        activeRuntime.dispose();
        activeRuntime = null;
    }

    const url = options.url ?? (document.getElementById("__$wasmlink") as HTMLLinkElement | null)?.href;
    if (!url) throw new Error("WASM URL is not set");
    const bridgeRef: [ZxBridge | null] = [null];
    let wasmMemory: WebAssembly.Memory | null = null;

    const allocRef: WasmAllocRef = [null];
    const getMemory = () => {
        if (wasmMemory) return wasmMemory;
        if (wasm.memory) return wasm.memory;
        throw new Error("WASM memory is not ready");
    };

    const handlers: Handlers = typeof __FEAT_KV__ === "undefined" || __FEAT_KV__
        ? createKvHandlers(options.kv ?? createBrowserKVBindings(), getMemory, allocRef, { writes: "background" })
        : {};
    const glueLoaded = loadWebGlue(url);
    // Streaming requires `application/wasm`, which some hosts (e.g. Safari extension pages) don't send
    const response = await fetch(url);
    const module = response.headers.get("content-type")?.startsWith("application/wasm")
        ? await WebAssembly.compileStreaming(response)
        : await WebAssembly.compile(await response.arrayBuffer());

    // Only for wasm built with the `fs` feature (it exports `__zx_fs`).
    const fsEnabled = (typeof __FEAT_FS__ === "undefined" || __FEAT_FS__) && options.fs !== false
        && WebAssembly.Module.exports(module).some((e) => e.name === "__zx_fs");
    if (fsEnabled) {
        browserFs ??= mountBrowserFs(options.fs || undefined);
        Object.assign(handlers, createFsHandlers(await browserFs, getMemory));
    }

    const importObject: WebAssembly.Imports = {
        ...ZxBridge.createImportObject(bridgeRef, handlers),
        __zx_web: (await glueLoaded, createWebImports(module)),
        ...options.importObject,
    };
    const instance = await WebAssembly.instantiate(module, importObject);
    const source: WebAssembly.WebAssemblyInstantiatedSource = { module, instance };

    wasmMemory = instance.exports.memory as WebAssembly.Memory;
    wasm.memory = wasmMemory;
    bindWasmAlloc(allocRef, instance.exports);
    resetRefs();

    const bridge = new ZxBridge(instance.exports);
    bridgeRef[0] = bridge;
    bindCallbacks(wrapPromisingExport(instance.exports.__zx_js_cb as Parameters<typeof bindCallbacks>[0]));

    domNodes.clear();

    const disposeDelegation = initEventDelegation(bridge, options.eventDelegationRoot ?? 'body');

    const main = wrapPromisingExport(instance.exports.mainClient as (() => void) | undefined);
    invokeWasmExport(main);

    activeRuntime = {
        options: normalizedOptions,
        dispose: () => {
            disposeDelegation();
            bridge.dispose();
            domNodes.clear();
        },
    };

    if (typeof __DEV__ !== "undefined" && __DEV__) registerDevReinit(normalizedOptions);

    return { source, bridge };
}

// Global type declarations
declare global {
    interface HTMLElement {
        __zx_ref?: number;
    }

    interface Window {
        __zx_dev_reinit?: () => Promise<{ source: WebAssembly.WebAssemblyInstantiatedSource; bridge: ZxBridge }>;
        __ZIEX_DEVTOOLS_GLOBAL_HOOK__?: ZiexDevtoolsHook;
    }
}
