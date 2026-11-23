import { Suspending } from "./jspi";
import type { Handlers } from "./host";

export type WsState = {
    upgraded: boolean;
    server: WebSocket | null;
    // Written before `server` exists (e.g. in `socket_open`). Strings are text frames.
    pendingWrites: (string | Uint8Array)[];
    messageQueue: Uint8Array[];
    // `null` means closed.
    recvResolve: ((bytes: Uint8Array | null) => void) | null;
    // Pub/sub, set by sticky handlers.
    subscribe?: (topic: string) => void;
    unsubscribe?: (topic: string) => void;
    publish?: (topic: string, data: Uint8Array) => number;
    isSubscribed?: (topic: string) => boolean;
};

export function newWsState(): WsState {
    return {
        upgraded: false,
        server: null,
        pendingWrites: [],
        messageQueue: [],
        recvResolve: null,
    };
}

export function deliverToWasm(ws: WsState, data: Uint8Array | null): void {
    if (ws.recvResolve) {
        const resolve = ws.recvResolve;
        ws.recvResolve = null;
        resolve(data);
        return;
    }
    if (data) ws.messageQueue.push(data);
}

export function createWsHandlers(mem: () => WebAssembly.Memory, ws: WsState): Handlers {
    const decoder = new TextDecoder();
    const readBytes = (ptr: number, len: number) => new Uint8Array(mem().buffer, ptr, len);
    const readStr = (ptr: number, len: number) => decoder.decode(readBytes(ptr, len));

    const recv = async (buf_ptr: number, buf_max: number): Promise<number> => {
        const deliver = (bytes: Uint8Array | null): number => {
            if (bytes === null) return -1;
            const n = Math.min(bytes.length, buf_max);
            readBytes(buf_ptr, n).set(bytes.subarray(0, n));
            return n;
        };
        if (ws.messageQueue.length > 0) return deliver(ws.messageQueue.shift()!);
        return new Promise<number>((resolve) => {
            ws.recvResolve = (bytes) => resolve(deliver(bytes));
        });
    };

    return {
        ws_upgrade: () => { ws.upgraded = true; },
        ws_write: (ptr, len, binary) => {
            const data = binary ? readBytes(ptr, len).slice() : readStr(ptr, len);
            if (ws.server) ws.server.send(data);
            else ws.pendingWrites.push(data);
        },
        ws_close: (code, reason_ptr, reason_len) => {
            ws.server?.close(code, readStr(reason_ptr, reason_len));
        },
        // Without JSPI the guest cannot wait: report closed.
        ws_recv: (buf_ptr, buf_max) => Suspending ? recv(buf_ptr, buf_max) : -1,
        ws_subscribe: (ptr, len) => { ws.subscribe?.(readStr(ptr, len)); },
        ws_unsubscribe: (ptr, len) => { ws.unsubscribe?.(readStr(ptr, len)); },
        ws_publish: (topic_ptr, topic_len, data_ptr, data_len) =>
            ws.publish?.(readStr(topic_ptr, topic_len), readBytes(data_ptr, data_len).slice()) ?? 0,
        ws_is_subscribed: (ptr, len) => ws.isSubscribed?.(readStr(ptr, len)) ? 1 : 0,
    };
}

type WebSocketPair = { 0: WebSocket; 1: WebSocket & { accept(): void } };

export function acceptWebSocketPair(ws: WsState): { client: WebSocket; server: WebSocket } {
    const WebSocketPair = (globalThis as any).WebSocketPair as new () => WebSocketPair;
    const { 0: client, 1: server } = new WebSocketPair();
    ws.server = server;
    server.accept();

    server.addEventListener("message", (event: MessageEvent) => {
        const data = typeof event.data === "string"
            ? new TextEncoder().encode(event.data)
            : new Uint8Array(event.data as ArrayBuffer);
        deliverToWasm(ws, data);
    });
    server.addEventListener("close", () => deliverToWasm(ws, null));

    return { client, server };
}

export function attachWebSocket(ws: WsState): { client: WebSocket } {
    const pending = ws.pendingWrites;
    ws.pendingWrites = [];
    const { client, server } = acceptWebSocketPair(ws);
    for (const data of pending) server.send(data as string | BufferSource);
    return { client };
}
