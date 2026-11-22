import { Suspending, type SuspendGate } from "./jspi";

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
 * Create the `__zx_net` imports for blocking WASM fetch via JSPI: `fetch` holds the
 * response and returns its length, `take` copies it into wasm memory.
 * `open`/`read`/`close` stream a response body chunk by chunk instead.
 * When JSPI is unavailable `fetch` and `open` always return -1 (network error).
 */
export function createFetchImports(
    getMemory: () => WebAssembly.Memory,
    gate: SuspendGate | null = null,
): WebAssembly.ModuleImports {
    const held = new Map<number, Uint8Array>();
    let nextHandle = 1;

    const readStr = (ptr: number, len: number): string =>
        len === 0 ? "" : decoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
    const readBytes = (ptr: number, len: number): Uint8Array =>
        new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);

    async function doFetch(
        url_ptr: number, url_len: number,
        method_ptr: number, method_len: number,
        headers_ptr: number, headers_len: number,
        body_ptr: number, body_len: number,
        timeout_ms: number,
        redirect: number,
        status_out: number,
        head_len_out: number,
        handle_out: number,
    ): Promise<number> {
        const url = readStr(url_ptr, url_len);
        try {
            const res = await performFetch({
                url,
                method: method_len > 0 ? readStr(method_ptr, method_len) : "GET",
                headersJson: readStr(headers_ptr, headers_len),
                // Copy: the guest may reuse this memory once it resumes.
                body: body_len > 0 ? readBytes(body_ptr, body_len).slice() : undefined,
                timeoutMs: timeout_ms,
                redirect,
            });
            const handle = nextHandle++;
            held.set(handle, res.bytes);
            const view = new DataView(getMemory().buffer);
            view.setUint16(status_out >>> 0, res.status, true);
            view.setUint32(head_len_out >>> 0, res.headLen, true);
            view.setUint32(handle_out >>> 0, handle, true);
            return res.bytes.length;
        } catch (err) {
            if (err === "timeout") return -3;
            const msg = err instanceof Error ? err.message : String(err);
            console.error(`wasm fetch failed: ${url} (${msg})`);
            return -1;
        }
    }

    type Body = { reader: ReadableStreamDefaultReader<Uint8Array>; pending: Uint8Array };
    const bodies = new Map<number, Body>();

    // Resolves once the head arrives; the body is then pulled with `read`.
    async function open(
        url_ptr: number, url_len: number,
        method_ptr: number, method_len: number,
        headers_ptr: number, headers_len: number,
        body_ptr: number, body_len: number,
        redirect: number,
        status_out: number,
        handle_out: number,
    ): Promise<number> {
        const url = readStr(url_ptr, url_len);
        const method = method_len > 0 ? readStr(method_ptr, method_len) : "GET";
        try {
            const response = await fetch(resolveFetchUrl(url), {
                method,
                headers: parseRequestHeaders(readStr(headers_ptr, headers_len)),
                body: method !== "GET" && method !== "HEAD" && body_len > 0 ? readBytes(body_ptr, body_len).slice() : undefined,
                redirect: redirect === 1 ? "manual" : "follow",
            });
            const handle = nextHandle++;
            const reader = (response.body ?? new Blob().stream()).getReader();
            bodies.set(handle, { reader, pending: new Uint8Array(0) });
            const view = new DataView(getMemory().buffer);
            view.setUint16(status_out >>> 0, response.status, true);
            view.setUint32(handle_out >>> 0, handle, true);
            return 0;
        } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            console.error(`wasm fetch failed: ${url} (${msg})`);
            return -1;
        }
    }

    // Copies up to `buf_len` body bytes; 0 at the end, -1 on error.
    async function read(handle: number, buf_ptr: number, buf_len: number): Promise<number> {
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
        const n = Math.min(buf_len, body.pending.length);
        new Uint8Array(getMemory().buffer, buf_ptr >>> 0, n).set(body.pending.subarray(0, n));
        body.pending = body.pending.subarray(n);
        return n;
    }

    const close = (handle: number): void => {
        const body = bodies.get(handle);
        if (!body) return;
        bodies.delete(handle);
        body.reader.cancel().catch(() => {});
    };

    const take = (handle: number, buf_ptr: number): void => {
        const bytes = held.get(handle);
        if (!bytes) return;
        held.delete(handle);
        new Uint8Array(getMemory().buffer, buf_ptr >>> 0, bytes.length).set(bytes);
    };

    if (!Suspending) {
        return { fetch: (): number => -1, take, open: (): number => -1, read: (): number => -1, close };
    }

    const suspending = <T extends (...args: any[]) => Promise<number>>(fn: T) => gate ? gate.suspending(fn) : new Suspending(fn);
    return { fetch: suspending(doFetch), take, open: suspending(open), read: suspending(read), close };
}
