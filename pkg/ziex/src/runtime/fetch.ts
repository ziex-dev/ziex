import { Suspending } from "./jspi";

/**
 * Create a `fetch` import object for blocking WASM fetch via JSPI.
 * When JSPI is unavailable the import always returns -1 (network error).
 */
export function createFetchImports(
    getMemory: () => WebAssembly.Memory,
): WebAssembly.ModuleImports {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    function readStr(ptr: number, len: number): string {
        if (len === 0) return "";
        return decoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
    }

    function writeBytes(buf_ptr: number, buf_max: number, data: Uint8Array): number {
        if (data.length > buf_max) return -2;
        new Uint8Array(getMemory().buffer, buf_ptr, data.length).set(data);
        return data.length;
    }

    function readBytes(ptr: number, len: number): Uint8Array {
        return new Uint8Array(getMemory().buffer, ptr, len);
    }

    function parseHeaders(headersJson: string): Record<string, string> {
        let headers: Record<string, string> = {};
        try {
            headers = JSON.parse(headersJson);
        } catch {
            for (const line of headersJson.split('\n')) {
                const colonIdx = line.indexOf(':');
                if (colonIdx > 0) {
                    headers[line.slice(0, colonIdx)] = line.slice(colonIdx + 1);
                }
            }
        }
        return headers;
    }

    async function doFetch(
        url_ptr: number,
        url_len: number,
        method_ptr: number,
        method_len: number,
        headers_ptr: number,
        headers_len: number,
        body_ptr: number,
        body_len: number,
        timeout_ms: number,
        status_out: number,
        buf_ptr: number,
        buf_max: number,
    ): Promise<number> {
        const url = readStr(url_ptr, url_len);
        const method = method_len > 0 ? readStr(method_ptr, method_len) : 'GET';
        const headersJson = headers_len > 0 ? readStr(headers_ptr, headers_len) : '{}';
        const body = body_len > 0 ? readBytes(body_ptr, body_len) : undefined;
        const headers = parseHeaders(headersJson);

        const controller = new AbortController();
        const timeout = timeout_ms > 0 ? setTimeout(() => controller.abort(), timeout_ms) : null;

        try {
            const response = await fetch(url, {
                method,
                headers: Object.keys(headers).length > 0 ? headers : undefined,
                body: method !== 'GET' && method !== 'HEAD' ? body as BodyInit : undefined,
                signal: controller.signal,
            });
            if (timeout) clearTimeout(timeout);
            new DataView(getMemory().buffer).setUint16(status_out, response.status, true);
            const bytes = new Uint8Array(await response.arrayBuffer());
            return writeBytes(buf_ptr, buf_max, bytes);
        } catch (err) {
            if (timeout) clearTimeout(timeout);
            const msg = err instanceof Error ? err.message : String(err);
            console.error(`wasm fetch failed: ${url} (${msg})`);
            return -1;
        }
    }

    if (!Suspending) {
        return {
            fetch: (
                _url_ptr: number, _url_len: number,
                _method_ptr: number, _method_len: number,
                _headers_ptr: number, _headers_len: number,
                _body_ptr: number, _body_len: number,
                _timeout_ms: number,
                _status_out: number,
                _buf_ptr: number, _buf_max: number,
            ): number => -1,
        };
    }

    return {
        fetch: new Suspending(doFetch),
    };
}
