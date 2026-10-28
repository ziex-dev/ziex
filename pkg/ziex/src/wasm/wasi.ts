/**
 * WASI/edge WASM bridge - zero dependencies on ZigJS (jsz) or browser globals.
 *
 * Import this (and only this) from edge/server runtimes. It provides the
 * minimal __zx import namespace needed by server-side WASM: log, fetch, and
 * timers. The jsz importObject is intentionally omitted - the server binary
 * does not use jsz value-passing.
 */

import {
    CallbackType_FetchSuccess,
    CallbackType_FetchError,
    CallbackType_Timeout,
    CallbackType_Interval,
} from "./constants";
import { fetchMeta, performFetch } from "../runtime/fetch";

type CallbackHandler = (type: number, id: bigint, a: bigint, b: bigint, c: bigint) => void;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export class ZxWasiBridge {
    readonly #alloc: (size: number) => number;
    readonly #memory: WebAssembly.Memory;
    readonly #cb: CallbackHandler | undefined;
    readonly #intervals: Map<bigint, ReturnType<typeof setInterval>> = new Map();

    // Cached memory view - invalidated when the WASM buffer grows.
    #memView: Uint8Array | null = null;
    #memBuf: ArrayBufferLike | null = null;

    constructor(exports: WebAssembly.Exports) {
        this.#memory = exports.memory as WebAssembly.Memory;
        this.#alloc = exports.__zx_alloc as (size: number) => number;
        this.#cb = exports.__zx_cb as CallbackHandler | undefined;
    }

    #view(): Uint8Array {
        const buf = this.#memory.buffer;
        if (buf !== this.#memBuf) {
            this.#memBuf = buf;
            this.#memView = new Uint8Array(buf);
        }
        return this.#memView!;
    }

    #readString(ptr: number, len: number): string {
        const start = ptr >>> 0;
        const length = len >>> 0;
        if (length === 0) return "";
        const view = this.#view();
        if (start + length > view.byteLength) return "";
        return decoder.decode(view.subarray(start, start + length));
    }

    #writeBytes(ptr: number, data: Uint8Array): void {
        const start = ptr >>> 0;
        const view = this.#view();
        if (start + data.length > view.byteLength) return;
        view.set(data, start);
    }

    #invoke(type: number, id: bigint, a: bigint = 0n, b: bigint = 0n, c: bigint = 0n): void {
        this.#cb?.(type, id, a, b, c);
    }

    log(level: number, ptr: number, len: number): void {
        const msg = decoder.decode(this.#view().subarray(ptr, ptr + len));
        switch (level) {
            case 0: console.error(msg); break;
            case 1: console.warn(msg); break;
            case 3: console.debug(msg); break;
            default: console.log(msg); break;
        }
    }

    fetchAsync(
        urlPtr: number, urlLen: number,
        methodPtr: number, methodLen: number,
        headersPtr: number, headersLen: number,
        bodyPtr: number, bodyLen: number,
        timeoutMs: number,
        redirect: number,
        fetchId: bigint
    ): void {
        performFetch({
            url: this.#readString(urlPtr, urlLen),
            method: methodLen > 0 ? this.#readString(methodPtr, methodLen) : 'GET',
            headersJson: this.#readString(headersPtr, headersLen),
            body: bodyLen > 0 ? this.#view().slice(bodyPtr, bodyPtr + bodyLen) : undefined,
            timeoutMs,
            redirect,
        })
            .then((res) => this.#notifyFetchComplete(fetchId, res.status, res.bytes, false, res.headLen))
            .catch((err) => {
                const msg = err === 'timeout' ? 'Request timeout' : (err?.message ?? 'Fetch failed');
                this.#notifyFetchComplete(fetchId, 0, msg, true);
            });
    }

    #notifyFetchComplete(fetchId: bigint, status: number, body: string | Uint8Array, isError: boolean, headLen = 0): void {
        const encoded = typeof body === 'string' ? encoder.encode(body) : body;
        const ptr = this.#alloc(encoded.length);
        this.#writeBytes(ptr, encoded);
        const type = isError ? CallbackType_FetchError : CallbackType_FetchSuccess;
        this.#invoke(type, fetchId, fetchMeta(status, headLen), BigInt(ptr), BigInt(encoded.length));
    }

    setTimeout(callbackId: bigint, delayMs: number): void {
        setTimeout(() => this.#invoke(CallbackType_Timeout, callbackId), delayMs);
    }

    setInterval(callbackId: bigint, intervalMs: number): void {
        const handle = setInterval(() => this.#invoke(CallbackType_Interval, callbackId), intervalMs);
        this.#intervals.set(callbackId, handle);
    }

    clearInterval(callbackId: bigint): void {
        const handle = this.#intervals.get(callbackId);
        if (handle !== undefined) {
            clearInterval(handle);
            this.#intervals.delete(callbackId);
        }
    }

    /**
     * Create the WASI import object for WASM instantiation.
     *
     * Returns only the `__zx` namespace (log, fetch, timers).
     * Does NOT include jsz.importObject() - the server binary does not use jsz.
     */
    static createImportObject(bridgeRef: [ZxWasiBridge | null]): WebAssembly.Imports {
        return {
            __zx: {
                _log: (level: number, ptr: number, len: number) => {
                    bridgeRef[0]?.log(level, ptr, len);
                },
                _fetchAsync: (
                    urlPtr: number, urlLen: number,
                    methodPtr: number, methodLen: number,
                    headersPtr: number, headersLen: number,
                    bodyPtr: number, bodyLen: number,
                    timeoutMs: number,
                    redirect: number,
                    fetchId: bigint
                ) => {
                    bridgeRef[0]?.fetchAsync(
                        urlPtr, urlLen, methodPtr, methodLen,
                        headersPtr, headersLen, bodyPtr, bodyLen,
                        timeoutMs, redirect, fetchId
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
