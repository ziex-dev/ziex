// Timers, callback fetch and logging shared by the browser and edge bridges.
import {
    CallbackType_FetchSuccess,
    CallbackType_FetchError,
    CallbackType_Timeout,
    CallbackType_Interval,
} from "./constants";
import { fetchMeta, performFetch } from "../runtime/fetch";
import { logMessage, textEncoder, type MemoryIO } from "./mem";

/** Unified host→guest callback: (type, id, a, b, c). Extra args are msg-specific. */
export type CallbackHandler = (callbackType: number, id: bigint, a: bigint, b: bigint, c: bigint) => unknown;

export class BaseBridge {
    readonly #intervals: Map<bigint, ReturnType<typeof setInterval>> = new Map();
    readonly #cb: CallbackHandler | undefined;
    protected readonly mem: MemoryIO;
    protected readonly _alloc: (size: number) => number;

    constructor(mem: MemoryIO, alloc: (size: number) => number, cb: CallbackHandler | undefined) {
        this.mem = mem;
        this._alloc = alloc;
        this.#cb = cb;
        if (!cb) console.warn("__zx_cb not exported from WASM");
    }

    protected _invoke(type: number, id: bigint, a: bigint = 0n, b: bigint = 0n, c: bigint = 0n): void {
        const result = this.#cb?.(type, id, a, b, c);
        // JSPI-wrapped callbacks return a promise.
        if (result && typeof (result as PromiseLike<unknown>).then === "function") {
            void (result as PromiseLike<unknown>).then(undefined, (error) => console.error(error));
        }
    }

    log(level: number, ptr: number, len: number): void {
        logMessage(level, this.mem.readString(ptr, len));
    }

    /** Completes via `__zx_cb(fetch_success|fetch_error, ...)`. */
    fetchAsync(
        urlPtr: number, urlLen: number,
        methodPtr: number, methodLen: number,
        headersPtr: number, headersLen: number,
        bodyPtr: number, bodyLen: number,
        timeoutMs: number,
        redirect: number,
        fetchId: bigint,
    ): void {
        const { readString } = this.mem;
        const bodyStart = bodyPtr >>> 0;
        performFetch({
            url: readString(urlPtr, urlLen),
            method: methodLen > 0 ? readString(methodPtr, methodLen) : "GET",
            headersJson: readString(headersPtr, headersLen),
            body: bodyLen > 0 ? this.mem.view().slice(bodyStart, bodyStart + (bodyLen >>> 0)) : undefined,
            timeoutMs,
            redirect,
        })
            .then((res) => this._notifyFetchComplete(fetchId, res.status, res.bytes, false, res.headLen))
            .catch((error) => {
                const msg = error === "timeout" ? "Request timeout" : (error?.message ?? "Fetch failed");
                this._notifyFetchComplete(fetchId, 0, msg, true);
            });
    }

    /** `body` is raw bytes on success, text on error. */
    protected _notifyFetchComplete(
        fetchId: bigint,
        statusCode: number,
        body: string | Uint8Array,
        isError: boolean,
        headLen = 0,
    ): void {
        const encoded = typeof body === "string" ? textEncoder.encode(body) : body;
        const ptr = this._alloc(encoded.length) >>> 0;
        if (!ptr && encoded.length > 0) return;
        this.mem.writeBytes(ptr, encoded);
        const type = isError ? CallbackType_FetchError : CallbackType_FetchSuccess;
        this._invoke(type, fetchId, fetchMeta(statusCode, headLen), BigInt(ptr), BigInt(encoded.length));
    }

    setTimeout(callbackId: bigint, delayMs: number): void {
        setTimeout(() => this._invoke(CallbackType_Timeout, callbackId), delayMs);
    }

    setInterval(callbackId: bigint, intervalMs: number): void {
        const handle = setInterval(() => this._invoke(CallbackType_Interval, callbackId), intervalMs);
        this.#intervals.set(callbackId, handle);
    }

    clearInterval(callbackId: bigint): void {
        const handle = this.#intervals.get(callbackId);
        if (handle === undefined) return;
        clearInterval(handle);
        this.#intervals.delete(callbackId);
    }

    dispose(): void {
        for (const handle of this.#intervals.values()) clearInterval(handle);
        this.#intervals.clear();
    }

    /** Copies `data` into a fresh `__zx_alloc` buffer, returning `[ptr, len]`. */
    writeBytesToWasm(data: Uint8Array): [number, number] {
        if (data.length === 0) return [0, 0];
        const ptr = this._alloc(data.length) >>> 0;
        if (!ptr) return [0, 0];
        this.mem.writeBytes(ptr, data);
        return [ptr, data.length];
    }

    protected _writeStringToWasm(str: string): [number, number] {
        return this.writeBytesToWasm(textEncoder.encode(str));
    }
}

/** The `__zx` imports every bridge provides. */
export function baseImports(bridgeRef: [BaseBridge | null]) {
    return {
        _log: (level: number, ptr: number, len: number) => bridgeRef[0]?.log(level, ptr, len),
        _fetchAsync: (
            urlPtr: number, urlLen: number,
            methodPtr: number, methodLen: number,
            headersPtr: number, headersLen: number,
            bodyPtr: number, bodyLen: number,
            timeoutMs: number,
            redirect: number,
            fetchId: bigint,
        ) => bridgeRef[0]?.fetchAsync(
            urlPtr, urlLen, methodPtr, methodLen, headersPtr, headersLen,
            bodyPtr, bodyLen, timeoutMs, redirect, fetchId,
        ),
        _setTimeout: (callbackId: bigint, delayMs: number) => bridgeRef[0]?.setTimeout(callbackId, delayMs),
        _setInterval: (callbackId: bigint, intervalMs: number) => bridgeRef[0]?.setInterval(callbackId, intervalMs),
        _clearInterval: (callbackId: bigint) => bridgeRef[0]?.clearInterval(callbackId),
    };
}
