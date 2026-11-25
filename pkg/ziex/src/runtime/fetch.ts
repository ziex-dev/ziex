import { Suspending } from "./jspi";
import type { Handlers } from "./host";
import { type WasmAllocRef, writeBytesOut } from "../wasm/core";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Request headers arrive as JSON `[[name, value], ...]` (older builds sent an object). */
export function parseRequestHeaders(json: string): [string, string][] {
    if (!json) return [];
    try {
        const parsed = JSON.parse(json);
        return Array.isArray(parsed) ? parsed : Object.entries(parsed);
    } catch {
        return [];
    }
}

/** Resolves `""` to the current page, as `fetch("")` would in a document. */
export function resolveFetchUrl(url: string): string {
    return url === "" && typeof location !== "undefined" ? location.href : url;
}

export type FetchRequest = {
    url: string;
    method: string;
    headersJson: string;
    body: Uint8Array | undefined;
    timeoutMs: number;
    /** 0 follows redirects, 1 returns them as is. */
    redirect: number;
};

export type EncodedResponse = {
    status: number;
    /** HTTP/1.1 response head followed by the body. */
    bytes: Uint8Array;
    headLen: number;
};

/** Performs the request and encodes the response for `Client.Result.parse`. Rejects with `"timeout"` on abort. */
export async function performFetch(req: FetchRequest): Promise<EncodedResponse> {
    const controller = new AbortController();
    const timeout = req.timeoutMs > 0 ? setTimeout(() => controller.abort(), req.timeoutMs) : null;
    try {
        const response = await fetch(resolveFetchUrl(req.url), {
            method: req.method,
            headers: parseRequestHeaders(req.headersJson),
            body: req.method !== "GET" && req.method !== "HEAD" ? req.body as BodyInit | undefined : undefined,
            redirect: req.redirect === 1 ? "manual" : "follow",
            signal: controller.signal,
        });
        const body = new Uint8Array(await response.arrayBuffer());
        return encodeResponse(response.status, response.statusText, response.headers, body);
    } catch (err) {
        if (err instanceof Error && err.name === "AbortError") throw "timeout";
        throw err;
    } finally {
        if (timeout) clearTimeout(timeout);
    }
}

export function encodeResponse(status: number, statusText: string, headers: Headers, body: Uint8Array): EncodedResponse {
    let head = `HTTP/1.1 ${status} ${statusText}\r\n`;
    headers.forEach((value, name) => {
        head += `${name}: ${value}\r\n`;
    });
    head += "\r\n";
    const headBytes = encoder.encode(head);
    const bytes = new Uint8Array(headBytes.length + body.length);
    bytes.set(headBytes, 0);
    bytes.set(body, headBytes.length);
    return { status, bytes, headLen: headBytes.length };
}

/** `__zx_cb` packs the status into the low 16 bits and the head length above it. */
export function fetchMeta(status: number, headLen: number): bigint {
    return BigInt(status) | (BigInt(headLen) << 16n);
}

/**
 * Host ops for blocking wasm fetch via JSPI: `net_fetch` holds the response and
 * returns its length, `net_take` copies it into wasm memory. `net_open`/`net_read`/
 * `net_close` stream a body chunk by chunk instead. Without JSPI `net_fetch` and
 * `net_open` return -1 (network error).
 */
export function createFetchHandlers(getMemory: () => WebAssembly.Memory, allocRef?: WasmAllocRef): Handlers {
    const held = new Map<number, Uint8Array>();
    let nextHandle = 1;

    const readStr = (ptr: number, len: number): string =>
        len === 0 ? "" : decoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
    const readBytes = (ptr: number, len: number): Uint8Array =>
        new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);

    // Reads the guest's `Request` extern struct before suspending: the guest may
    // reuse this memory once it resumes.
    function readRequest(ptr: number): FetchRequest {
        const [urlPtr, urlLen, methodPtr, methodLen, headersPtr, headersLen, bodyPtr, bodyLen, timeoutMs, redirect] =
            new Uint32Array(getMemory().buffer, ptr >>> 0, 10);
        const method = methodLen! > 0 ? readStr(methodPtr!, methodLen!) : "GET";
        return {
            url: readStr(urlPtr!, urlLen!),
            method,
            headersJson: readStr(headersPtr!, headersLen!),
            body: bodyLen! > 0 ? readBytes(bodyPtr!, bodyLen!).slice() : undefined,
            timeoutMs: timeoutMs!,
            redirect: redirect!,
        };
    }

    function report(url: string, err: unknown): number {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`wasm fetch failed: ${url} (${msg})`);
        return -1;
    }

    async function doFetch(req: FetchRequest, statusOut: number, headLenOut: number, handleOut: number): Promise<number> {
        try {
            const res = await performFetch(req);
            const handle = nextHandle++;
            held.set(handle, res.bytes);
            const view = new DataView(getMemory().buffer);
            view.setUint16(statusOut >>> 0, res.status, true);
            view.setUint32(headLenOut >>> 0, res.headLen, true);
            view.setUint32(handleOut >>> 0, handle, true);
            return res.bytes.length;
        } catch (err) {
            if (err === "timeout") return -3;
            return report(req.url, err);
        }
    }

    type Body = { reader: ReadableStreamDefaultReader<Uint8Array>; pending: Uint8Array };
    const bodies = new Map<number, Body>();

    // Resolves once the head arrives; the body is then pulled with `net_read`.
    // With `headOut` set, the response head is written there and its length returned.
    async function open(req: FetchRequest, statusOut: number, handleOut: number, headOut: number): Promise<number> {
        try {
            const response = await fetch(resolveFetchUrl(req.url), {
                method: req.method,
                headers: parseRequestHeaders(req.headersJson),
                body: req.method !== "GET" && req.method !== "HEAD" ? req.body as BodyInit | undefined : undefined,
                redirect: req.redirect === 1 ? "manual" : "follow",
            });
            const handle = nextHandle++;
            const reader = (response.body ?? new Blob().stream()).getReader();
            bodies.set(handle, { reader, pending: new Uint8Array(0) });
            const view = new DataView(getMemory().buffer);
            view.setUint16(statusOut >>> 0, response.status, true);
            view.setUint32(handleOut >>> 0, handle, true);
            if (!headOut || !allocRef) return 0;
            const head = encodeResponse(response.status, response.statusText, response.headers, new Uint8Array(0));
            return Math.max(0, writeBytesOut(getMemory, allocRef, headOut, head.bytes));
        } catch (err) {
            return report(req.url, err);
        }
    }

    // Copies up to `bufLen` body bytes; 0 at the end, -1 on error.
    async function read(handle: number, bufPtr: number, bufLen: number): Promise<number> {
        const body = bodies.get(handle);
        if (!body) return -1;
        try {
            while (body.pending.length === 0) {
                const { done, value } = await body.reader.read();
                if (done) return 0;
                body.pending = value;
            }
        } catch {
            return -1;
        }
        const n = Math.min(bufLen, body.pending.length);
        new Uint8Array(getMemory().buffer, bufPtr >>> 0, n).set(body.pending.subarray(0, n));
        body.pending = body.pending.subarray(n);
        return n;
    }

    return {
        net_fetch: (req, statusOut, headLenOut, handleOut) =>
            Suspending ? doFetch(readRequest(req), statusOut, headLenOut, handleOut) : -1,
        net_take: (handle, bufPtr) => {
            const bytes = held.get(handle);
            if (!bytes) return;
            held.delete(handle);
            new Uint8Array(getMemory().buffer, bufPtr >>> 0, bytes.length).set(bytes);
        },
        net_open: (req, statusOut, handleOut, headOut) =>
            Suspending ? open(readRequest(req), statusOut, handleOut, headOut) : -1,
        net_read: (handle, bufPtr, bufLen) => Suspending ? read(handle, bufPtr, bufLen >>> 0) : -1,
        net_close: (handle) => {
            const body = bodies.get(handle);
            if (!body) return;
            bodies.delete(handle);
            body.reader.cancel().catch(() => {});
        },
    };
}
