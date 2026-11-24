import { createFetchHandlers } from "../runtime/fetch";
import { createIoHandlers } from "../runtime/io";
import { createHostImports, type Handlers, type HostImports } from "../runtime/host";
import { createSuspendGate, type SuspendGate } from "../runtime/jspi";
import { BaseBridge, baseImports, type CallbackHandler } from "./base";
import { createJsImports } from "./js";
import { memoryIO, textEncoder } from "./mem";

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
export { textDecoder, textEncoder } from "./mem";
export type { CallbackHandler } from "./base";

/** The single client wasm instance (browser). */
export const wasm: { memory: WebAssembly.Memory | null; alloc: ((size: number) => number) | null } = {
    memory: null,
    alloc: null,
};

export const mem = memoryIO(() => wasm.memory);
export const getMemoryView = (): Uint8Array => mem.view();
export const readString = mem.readString;
export const writeBytes = mem.writeBytes;

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

/** Client bridge core: fetch, timers and logging over the shared `wasm` instance. */
export class ZxBridgeCore extends BaseBridge {
    constructor(exports: WebAssembly.Exports) {
        if (exports.memory) wasm.memory = exports.memory as WebAssembly.Memory;
        wasm.alloc = exports.__zx_alloc as (size: number) => number;
        super(mem, wasm.alloc, wrapPromisingExport(exports.__zx_cb as CallbackHandler | undefined));
    }

    /** `__zx.call`/`__zx.wait` with the io and fetch ops plus `handlers`. */
    static createHostImports(handlers: Handlers): HostImports {
        const memory = () => {
            if (!wasm.memory) throw new Error("WASM memory is not ready");
            return wasm.memory;
        };
        return createHostImports(
            { ...createIoHandlers(memory), ...createFetchHandlers(memory), ...handlers },
            resetSuspendGate(),
        );
    }

    /** `__zx` (log, fetch, timers, host ops) plus `__zx_js` (dynamic JS interop). */
    static createImportObject(bridgeRef: [ZxBridgeCore | null], handlers: Handlers = {}) {
        return {
            __zx: {
                ...ZxBridgeCore.createHostImports(handlers),
                ...baseImports(bridgeRef),
            } as Record<string, unknown>,
            __zx_js: createJsImports(mem, () => wasm.alloc),
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
