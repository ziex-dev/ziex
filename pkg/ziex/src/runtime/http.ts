import { mergeUint8Arrays } from "./wasi";

export type HttpState = {
    committed: boolean;
    ended: boolean;
    status: number;
    streaming: boolean;
    headers: Headers;
    bodyChunks: Uint8Array[];
    streamWriter: WritableStreamDefaultWriter<Uint8Array> | null;
    commitWaiters: Array<() => void>;
};

export function newHttpState(): HttpState {
    return {
        committed: false,
        ended: false,
        status: 200,
        streaming: false,
        headers: new Headers(),
        bodyChunks: [],
        streamWriter: null,
        commitWaiters: [],
    };
}

function notifyCommitted(http: HttpState): void {
    const waiters = http.commitWaiters;
    if (waiters.length === 0) return;
    http.commitWaiters = [];
    for (const resolve of waiters) resolve();
}

function whenCommitted(http: HttpState): Promise<void> {
    if (http.committed) return Promise.resolve();
    return new Promise((resolve) => {
        http.commitWaiters.push(resolve);
    });
}

export function buildHttpImports(
    mem: () => WebAssembly.Memory,
    http: HttpState,
): WebAssembly.ModuleImports {
    const decoder = new TextDecoder();
    return {
        commit: (status: number, meta_ptr: number, meta_len: number): void => {
            http.status = status >>> 0;
            http.committed = true;
            http.headers = new Headers();
            http.streaming = false;
            if (meta_len > 0) {
                try {
                    const raw = decoder.decode(new Uint8Array(mem().buffer, meta_ptr >>> 0, meta_len >>> 0));
                    const meta = JSON.parse(raw) as { streaming?: boolean; headers?: [string, string][] };
                    http.streaming = meta.streaming === true;
                    for (const [name, value] of meta.headers ?? []) http.headers.append(name, value);
                } catch {
                    // Keep defaults on malformed meta.
                }
            }
            notifyCommitted(http);
        },
        write: (ptr: number, len: number): void => {
            if (len <= 0) return;
            const chunk = new Uint8Array(mem().buffer, ptr >>> 0, len >>> 0).slice();
            if (http.streamWriter) void http.streamWriter.write(chunk);
            else http.bodyChunks.push(chunk);
        },
        end: (): void => {
            http.ended = true;
            // Unblock toResponse if the handler finished without committing.
            if (!http.committed) notifyCommitted(http);
            closeStream(http);
        },
    };
}

function closeStream(http: HttpState): void {
    if (!http.streamWriter) return;
    void http.streamWriter.close();
    http.streamWriter = null;
}

// Workers warns on an empty ArrayBuffer body for these.
const NULL_BODY_STATUSES = new Set([101, 204, 205, 304]);

export async function toResponse(http: HttpState, done: Promise<void>): Promise<Response> {
    await Promise.race([done, whenCommitted(http)]);

    if (http.committed && http.streaming) {
        const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
        http.streamWriter = writable.getWriter();
        for (const chunk of http.bodyChunks) void http.streamWriter.write(chunk);
        http.bodyChunks.length = 0;
        void done.finally(() => closeStream(http));
        return new Response(readable, { status: http.status, headers: http.headers });
    }

    await done;

    const { status, headers } = http;
    headers.delete("transfer-encoding");

    if (NULL_BODY_STATUSES.has(status)) {
        headers.delete("content-length");
        return new Response(null, { status, headers });
    }

    const body = mergeUint8Arrays(http.bodyChunks);
    if (!headers.has("content-length")) headers.set("content-length", String(body.byteLength));
    return new Response(body.buffer as ArrayBuffer, { status, headers });
}
