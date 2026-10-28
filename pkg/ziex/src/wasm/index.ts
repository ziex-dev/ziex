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
    jsz,
    storeValueGetRef,
    loadValueFromRef,
    releaseValueRef,
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
export type { CallbackTypeValue, WasmAllocRef } from "./core";

import {
    ZxBridgeCore,
    jsz,
    storeValueGetRef,
    loadValueFromRef,
    releaseValueRef,
    wrapPromisingExport,
    resetSuspendGate,
    invokeWasmExport,
    readString,
    writeBytes,
    textDecoder,
    textEncoder,
    getMemoryView,
} from "./core";
import { bindWasmAlloc, type WasmAllocRef } from "./core";
import {
    CallbackType_WebSocketOpen,
    CallbackType_WebSocketMessage,
    CallbackType_WebSocketError,
    CallbackType_WebSocketClose,
} from "./constants";
import { flushDomCmds } from "./dom_cmd";
import { createFetchImports } from "../runtime/fetch";
import { createIoImports } from "../runtime/io";
import { createKVImports } from "../runtime/kv/extern";
import { createBrowserKVBindings, type KVNamespace } from "../runtime/kv";
import { DELEGATED_EVENTS } from "./generated/events";
import { HIGH_FREQ_EVENT_BITS } from "./generated/event_bits";

/**
 * Browser Ziex Bridge - extends ZxBridgeCore with DOM, WebSocket, and form-action support.
 * Import this from environments that have access to browser globals.
 * For edge runtimes, import ZxBridgeCore from ./core instead.
 */
export class ZxBridge extends ZxBridgeCore {
    #websockets: Map<bigint, WebSocket> = new Map();

    // Every handler may suspend (fetch, sleep); the gate keeps suspended handlers safe.
    readonly #eventbridge: ((velementId: bigint, eventTypeId: number, eventRef: bigint) => void) | undefined;

    constructor(exports: WebAssembly.Exports) {
        super(exports);
        this.#eventbridge = wrapPromisingExport(
            exports.__zx_eventbridge as ((velementId: bigint, eventTypeId: number, eventRef: bigint) => void) | undefined
        );
    }

    hasEventHandler(velementId: number, eventTypeId: number): boolean {
        return !!((eventHandlersPresent.get(velementId) ?? 0) & (1 << eventTypeId));
    }

    registerEventHandler(velementId: number, eventTypeId: number): void {
        const present = (eventHandlersPresent.get(velementId) ?? 0) | (1 << eventTypeId);
        eventHandlersPresent.set(velementId, present);
        ensureDelegatedListener(eventTypeId);
    }

    clearEventHandlers(velementId: number): void {
        const present = eventHandlersPresent.get(velementId) ?? 0;
        eventHandlersPresent.delete(velementId);
        // Drop high-freq listeners when no vnode still needs them.
        // Drop high-freq listeners when no vnode still needs them.
        for (let bits = present & HIGH_FREQ_EVENT_BITS; bits !== 0; bits &= bits - 1) {
            maybeRemoveHighFreqListener(31 - Math.clz32(bits));
        }
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
    eventbridge(velementId: number, eventTypeId: number, eventRef: bigint): void | Promise<void> {
        const run = this.#eventbridge;
        if (!run) return;
        const result = run(BigInt(velementId >>> 0), eventTypeId, eventRef) as void | Promise<void>;
        // Returned so the caller keeps `eventRef` alive until a suspended handler finishes.
        return result?.catch((error) => console.error(error));
    }

    /** Create the full browser import object for WASM instantiation (includes DOM + WebSocket). */
    static override createImportObject(bridgeRef: [ZxBridge | null]): WebAssembly.Imports {
        const gate = resetSuspendGate();
        return {
            ...jsz.importObject(),
            __zx_io: createIoImports(() => {
                if (!jsz.memory) throw new Error("WASM memory is not ready");
                return jsz.memory;
            }, gate) as WebAssembly.ModuleImports,
            __zx_net: createFetchImports(() => {
                if (!jsz.memory) throw new Error("WASM memory is not ready");
                return jsz.memory;
            }, gate) as WebAssembly.ModuleImports,
            __zx: {
                _log: (level: number, ptr: number, len: number) => ZxBridgeCore.log(level, ptr, len),
                _registerEventHandler: (vnodeId: bigint, eventTypeId: number) => {
                    bridgeRef[0]?.registerEventHandler(Number(vnodeId), eventTypeId);
                },
                _clearEventHandlers: (vnodeId: bigint) => {
                    bridgeRef[0]?.clearEventHandlers(Number(vnodeId));
                },
                _fetchAsync: (
                    urlPtr: number,
                    urlLen: number,
                    methodPtr: number,
                    methodLen: number,
                    headersPtr: number,
                    headersLen: number,
                    bodyPtr: number,
                    bodyLen: number,
                    timeoutMs: number,
                    redirect: number,
                    fetchId: bigint
                ) => {
                    bridgeRef[0]?.fetchAsync(
                        urlPtr, urlLen,
                        methodPtr, methodLen,
                        headersPtr, headersLen,
                        bodyPtr, bodyLen,
                        timeoutMs,
                        redirect,
                        fetchId
                    );
                },
                _setTimeout: (callbackId: bigint, delayMs: number) => {
                    bridgeRef[0]?.setTimeout(callbackId, delayMs);
                },
                _setInterval: (callbackId: bigint, intervalMs: number) => {
                    bridgeRef[0]?.setInterval(callbackId, intervalMs);
                },
                _clearInterval: (callbackId: bigint) => {
                    bridgeRef[0]?.clearInterval(callbackId);
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
                    writeBytes(bufPtr, bytes.subarray(0, len));
                    return len;
                },
                _getFormData: (eventRef: bigint, outPtrAddr: number): number => {
                    const event = loadValueFromRef(eventRef) as Event | undefined;
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
                    new DataView(jsz.memory!.buffer).setUint32(outPtrAddr, ptr, true);
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

/** Bitset: which event types have a handler for each vnode. */
const eventHandlersPresent = new Map<number, number>();

/** Remove a detached DOM subtree from domNodes + handler bitsets */
function cleanupDomNodes(node: Node): void {
    const stack: Node[] = [node];
    let highFreqBits = 0;
    while (stack.length > 0) {
        const n = stack.pop()!;
        const ref = (n as any).__zx_ref;
        if (typeof ref === "number") {
            const present = eventHandlersPresent.get(ref);
            if (present !== undefined) {
                highFreqBits |= present;
                eventHandlersPresent.delete(ref);
            }
            domNodes.delete(ref);
        }
        const children = n.childNodes;
        for (let i = 0; i < children.length; i++) stack.push(children[i]!);
    }
    for (let bits = highFreqBits & HIGH_FREQ_EVENT_BITS; bits !== 0; bits &= bits - 1) {
        maybeRemoveHighFreqListener(31 - Math.clz32(bits));
    }
}

type DelegatedListenerState = {
    root: Element;
    bridge: ZxBridge;
    attached: Map<number, { listener: EventListener; options: AddEventListenerOptions }>;
};

let delegationState: DelegatedListenerState | null = null;

function makeDelegatedListener(bridge: ZxBridge, eventTypeId: number): EventListener {
    return (event: Event) => {
        let eventRef: bigint | undefined;
        const pending: Promise<unknown>[] = [];
        let target = event.target as HTMLElement | null;
        while (target && target !== document.body) {
            const zxRef = (target as any).__zx_ref;
            if (typeof zxRef === "number" && bridge.hasEventHandler(zxRef, eventTypeId)) {
                if (eventRef === undefined) eventRef = storeValueGetRef(event);
                const result = bridge.eventbridge(zxRef, eventTypeId, eventRef);
                if (result && typeof (result as Promise<unknown>).then === "function") {
                    pending.push(result as Promise<unknown>);
                }
                if (event.cancelBubble) break;
            }
            target = target.parentElement;
        }
        if (eventRef !== undefined) {
            const ref = eventRef;
            if (pending.length > 0) {
                Promise.all(pending).finally(() => releaseValueRef(ref));
            } else {
                releaseValueRef(ref);
            }
        }
    };
}

function ensureDelegatedListener(eventTypeId: number): void {
    const state = delegationState;
    if (!state || state.attached.has(eventTypeId)) return;
    const domType = DELEGATED_EVENTS[eventTypeId];
    if (!domType) return;
    const passive = domType.startsWith('touch') || domType === 'scroll';
    const options: AddEventListenerOptions = { passive };
    const listener = makeDelegatedListener(state.bridge, eventTypeId);
    state.root.addEventListener(domType, listener, options);
    state.attached.set(eventTypeId, { listener, options });
}

function anyHandlerForType(eventTypeId: number): boolean {
    const bit = 1 << eventTypeId;
    for (const mask of eventHandlersPresent.values()) {
        if (mask & bit) return true;
    }
    return false;
}

function maybeRemoveHighFreqListener(eventTypeId: number): void {
    if ((HIGH_FREQ_EVENT_BITS & (1 << eventTypeId)) === 0) return;
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

    delegationState = { root, bridge, attached: new Map() };

    // Always-on bubbling events (cheap). High-freq attach lazily via ensureDelegatedListener.
    for (let eventTypeId = 0; eventTypeId < DELEGATED_EVENTS.length; eventTypeId++) {
        if ((HIGH_FREQ_EVENT_BITS & (1 << eventTypeId)) !== 0) continue;
        ensureDelegatedListener(eventTypeId);
    }

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
};

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
        if (jsz.memory) return jsz.memory;
        throw new Error("WASM memory is not ready");
    };

    const importObject: WebAssembly.Imports = {
        ...ZxBridge.createImportObject(bridgeRef),
        ...options.importObject,
    };
    if (typeof __FEAT_KV__ === "undefined" || __FEAT_KV__) {
        importObject.__zx_kv = createKVImports(
            options.kv ?? createBrowserKVBindings(),
            getMemory,
            allocRef,
            { writes: "background" },
        );
    }

    const source = await WebAssembly.instantiateStreaming(fetch(url), importObject);
    const { instance } = source;

    wasmMemory = instance.exports.memory as WebAssembly.Memory;
    jsz.memory = wasmMemory;
    bindWasmAlloc(allocRef, instance.exports);

    const bridge = new ZxBridge(instance.exports);
    bridgeRef[0] = bridge;

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
