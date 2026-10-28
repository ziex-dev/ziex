import { ZigJS } from "../../../../vendor/jsz/js/src";
import { createFetchImports, fetchMeta, performFetch } from "../runtime/fetch";
import { createIoImports } from "../runtime/io";
import { createSuspendGate, type SuspendGate } from "../runtime/jspi";
import {
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

export type CallbackTypeValue =
    | typeof CallbackType_Event
    | typeof CallbackType_FetchSuccess
    | typeof CallbackType_FetchError
    | typeof CallbackType_Timeout
    | typeof CallbackType_Interval
    | typeof CallbackType_WebSocketOpen
    | typeof CallbackType_WebSocketMessage
    | typeof CallbackType_WebSocketError
    | typeof CallbackType_WebSocketClose;
/** Unified host→guest callback: (type, id, a, b, c). Extra args are msg-specific. */
export type CallbackHandler = (callbackType: number, id: bigint, a: bigint, b: bigint, c: bigint) => void;

/**
 * Core WASM bridge - environment-agnostic (browser + edge).
 * No references to browser globals (document, window, WebSocket, HTMLFormElement).
 */
export const jsz = new ZigJS();

// Temporary buffer for reading back references from storeValue
const tempRefBuffer = new ArrayBuffer(8);
const tempRefView = new DataView(tempRefBuffer);

/** Store a value using jsz.storeValue and get the 64-bit reference. */
export function storeValueGetRef(val: any): bigint {
    const originalMemory = jsz.memory;
    jsz.memory = { buffer: tempRefBuffer } as WebAssembly.Memory;
    jsz.storeValue(0, val);
    jsz.memory = originalMemory;
    return tempRefView.getBigUint64(0, true);
}

/** Resolve a NaN-boxed 64-bit reference back to the JS value. */
export function loadValueFromRef(ref: bigint): any {
    tempRefView.setBigUint64(0, ref, true);
    const originalMemory = jsz.memory;
    jsz.memory = { buffer: tempRefBuffer } as WebAssembly.Memory;
    const val = jsz.loadRef(0);
    jsz.memory = originalMemory;
    return val;
}

/** Release a NaN-boxed jsz ref (no-op for numbers / predefined ids). */
export function releaseValueRef(ref: bigint): void {
    tempRefView.setBigUint64(0, ref, true);
    if (!Number.isNaN(tempRefView.getFloat64(0, true))) return;
    const id = tempRefView.getUint32(0, true);
    if (id > 6) jsz.deleteValue(id);
}

/** Shared encoder/decoder - avoids allocating new instances on every call. */
export const textDecoder = new TextDecoder();
export const textEncoder = new TextEncoder();

/** Cached Uint8Array view of WASM memory. Invalidated when the buffer grows. */
let memoryView: Uint8Array | null = null;
let memoryBuffer: ArrayBufferLike | null = null;

export function getMemoryView(): Uint8Array {
    const buf = jsz.memory!.buffer;
    if (buf !== memoryBuffer) {
        memoryBuffer = buf;
        memoryView = new Uint8Array(buf);
    }
    return memoryView!;
}

/** Read a string from WASM memory. Treats ptr/len as u32 (WASM i32 is signed in JS). */
export function readString(ptr: number, len: number): string {
    const start = ptr >>> 0;
    const length = len >>> 0;
    if (length === 0) return "";
    const view = getMemoryView();
    if (start + length > view.byteLength) return "";
    return textDecoder.decode(view.subarray(start, start + length));
}

/** Write bytes to WASM memory at a specific location */
export function writeBytes(ptr: number, data: Uint8Array): void {
    const start = ptr >>> 0;
    const view = getMemoryView();
    if (start + data.length > view.byteLength) return;
    view.set(data, start);
}

let gate: SuspendGate | null = null;

/** Starts the gate for a new wasm instance. Call it before building that instance's imports. */
export function resetSuspendGate(): SuspendGate | null {
    gate = createSuspendGate();
    return gate;
}

/** Lets `fn` suspend (JSPI), ordered by the instance's `SuspendGate`. */
export function wrapPromisingExport<F extends (...args: any[]) => any>(fn: F | undefined): F | undefined {
    if (!fn) return undefined;
    return gate ? (gate.promising(fn) as unknown as F) : fn;
}

export function invokeWasmExport<F extends (...args: any[]) => any>(
    fn: F | undefined,
    ...args: Parameters<F>
): void {
    if (!fn) return;
    const result = fn(...args);
    if (result && typeof (result as PromiseLike<unknown>).then === "function") {
        void (result as PromiseLike<unknown>).then(undefined, (error) => {
            console.error(error);
        });
    }
}

/**
 * Core ZX Bridge - works in both browser and edge runtimes.
 * Contains fetch, timers, and logging. No DOM or browser-WebSocket references.
 *
 * Extend this class in browser environments to add DOM and WebSocket support.
 */
export class ZxBridgeCore {
    #intervals: Map<bigint, number> = new Map();

    protected readonly _alloc: (size: number) => number;
    readonly #handler: CallbackHandler | undefined;

    constructor(exports: WebAssembly.Exports) {
        this._alloc = exports.__zx_alloc as (size: number) => number;
        this.#handler = wrapPromisingExport(exports.__zx_cb as CallbackHandler | undefined);
        if (!this.#handler) {
            console.warn("__zx_cb not exported from WASM");
        }
        if (exports.memory) jsz.memory = exports.memory as WebAssembly.Memory;
    }

    /** Invoke the unified callback handler */
    protected _invoke(type: CallbackTypeValue, id: bigint, a: bigint = 0n, b: bigint = 0n, c: bigint = 0n): void {
        const handler = this.#handler;
        if (!handler) {
            console.warn("__zx_cb not exported from WASM");
            return;
        }
        invokeWasmExport(handler, type, id, a, b, c);
    }

    /**
     * Async fetch with full options support.
     * Completes via `__zx_cb(fetch_success|fetch_error, ...)`.
     */
    fetchAsync(
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
    ): void {
        performFetch({
            url: readString(urlPtr, urlLen),
            method: methodLen > 0 ? readString(methodPtr, methodLen) : 'GET',
            headersJson: readString(headersPtr, headersLen),
            body: bodyLen > 0 ? getMemoryView().slice(bodyPtr, bodyPtr + bodyLen) : undefined,
            timeoutMs,
            redirect,
        })
            .then((res) => this._notifyFetchComplete(fetchId, res.status, res.bytes, false, res.headLen))
            .catch((error) => {
                const errorMsg = error === 'timeout' ? 'Request timeout' : (error?.message ?? 'Fetch failed');
                this._notifyFetchComplete(fetchId, 0, errorMsg, true);
            });
    }

    /** Notify WASM that a fetch completed. `body` is raw bytes on success, text on error. */
    protected _notifyFetchComplete(
        fetchId: bigint,
        statusCode: number,
        body: string | Uint8Array,
        isError: boolean,
        headLen = 0,
    ): void {
        const encoded = typeof body === 'string' ? textEncoder.encode(body) : body;
        const ptr = this._alloc(encoded.length) >>> 0;
        if (!ptr && encoded.length > 0) return;
        writeBytes(ptr, encoded);
        const type = isError ? CallbackType_FetchError : CallbackType_FetchSuccess;
        this._invoke(type, fetchId, fetchMeta(statusCode, headLen), BigInt(ptr), BigInt(encoded.length));
    }

    /** Set a timeout and callback when it fires */
    setTimeout(callbackId: bigint, delayMs: number): void {
        setTimeout(() => {
            this._invoke(CallbackType_Timeout, callbackId);
        }, delayMs);
    }

    /** Set an interval and callback each time it fires */
    setInterval(callbackId: bigint, intervalMs: number): void {
        const handle = setInterval(() => {
            this._invoke(CallbackType_Interval, callbackId);
        }, intervalMs) as unknown as number;
        this.#intervals.set(callbackId, handle);
    }

    /** Clear an interval */
    clearInterval(callbackId: bigint): void {
        const handle = this.#intervals.get(callbackId);
        if (handle !== undefined) {
            clearInterval(handle);
            this.#intervals.delete(callbackId);
        }
    }

    dispose(): void {
        for (const handle of this.#intervals.values()) {
            clearInterval(handle);
        }
        this.#intervals.clear();
    }

    /** Write a string to WASM memory, returning `[ptr, len]`. */
    protected _writeStringToWasm(str: string): [number, number] {
        return this.writeBytesToWasm(textEncoder.encode(str));
    }

    writeBytesToWasm(data: Uint8Array): [number, number] {
        if (data.length === 0) return [0, 0];
        const ptr = this._alloc(data.length) >>> 0;
        if (!ptr) return [0, 0];
        writeBytes(ptr, data);
        return [ptr, data.length];
    }

    /** Log a message from WASM at the given level (0=error, 1=warn, 2=info, 3=debug) */
    static log(level: number, ptr: number, len: number): void {
        const start = ptr >>> 0;
        const length = len >>> 0;
        const view = getMemoryView();
        if (start + length > view.byteLength) return;
        const msg = textDecoder.decode(view.subarray(start, start + length));
        switch (level) {
            case 0: console.error(msg); break;
            case 1: console.warn(msg); break;
            case 3: console.debug(msg); break;
            default: console.log(msg); break;
        }
    }

    /**
     * Create the core import object for WASM instantiation.
     * Includes only environment-agnostic bindings: log, fetch, and timers.
     * Use ZxBridge.createImportObject (from wasm/index.ts) in browser contexts
     * to additionally include DOM and WebSocket bindings.
     */
    static createImportObject(bridgeRef: [ZxBridgeCore | null]): WebAssembly.Imports {
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
            },
        };
    }
}

/** Mutable slot for `__zx_alloc` - array so the slot name itself can minify. */
export type WasmAllocRef = [((size: number) => number) | null];

export function writeBytesOut(
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
    outPtrAddr: number,
    data: Uint8Array,
): number {
    if (data.length === 0) {
        new DataView(getMemory().buffer).setUint32(outPtrAddr, 0, true);
        return 0;
    }
    const alloc = allocRef[0];
    if (!alloc) return -1;
    const ptr = alloc(data.length) >>> 0;
    if (!ptr) return -1;
    const buffer = getMemory().buffer;
    if (ptr + data.length > buffer.byteLength) return -1;
    new Uint8Array(buffer, ptr, data.length).set(data);
    new DataView(buffer).setUint32(outPtrAddr >>> 0, ptr, true);
    return data.length;
}

export function writeJsonOut(
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
    outPtrAddr: number,
    value: unknown,
): number {
    return writeBytesOut(getMemory, allocRef, outPtrAddr, textEncoder.encode(JSON.stringify(value)));
}

export function bindWasmAlloc(allocRef: WasmAllocRef, exports: WebAssembly.Exports): void {
    allocRef[0] = exports.__zx_alloc as (size: number) => number;
}
