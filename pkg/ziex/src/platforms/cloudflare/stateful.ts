import { newHttpState } from "../../runtime/http";
import { acceptWebSocketPair, deliverToWasm, newWsState, type WsState } from "../../runtime/ws";
import { defaultKV, instantiate, isProcExit, type ImportsFactory } from "../../runtime/instance";
import { hasJspi, promising } from "../../runtime/jspi";
import type { KVNamespace } from "../../runtime/kv";
import type { Database } from "../../runtime/db";

type ConnState = WsState & { topics: Set<string> };

const textDecoder = new TextDecoder();

function newConnection(connections: Map<WebSocket, ConnState>): ConnState {
    const conn: ConnState = {
        ...newWsState(),
        topics: new Set(),
        subscribe: (topic) => conn.topics.add(topic),
        unsubscribe: (topic) => conn.topics.delete(topic),
        isSubscribed: (topic) => conn.topics.has(topic),
        publish: (topic, data) => {
            let count = 0;
            const text = textDecoder.decode(data);
            for (const [sock, other] of connections) {
                if (!other.topics.has(topic)) continue;
                try {
                    sock.send(text);
                    count++;
                } catch {
                    /* closed */
                }
            }
            // Publishing from `socket_open`: deliver on attach.
            if (!conn.server && conn.topics.has(topic)) {
                conn.pendingWrites.push(data.slice());
                count++;
            }
            return count;
        },
    };
    return conn;
}

function attachConnection(conn: ConnState): WebSocket {
    const pending = conn.pendingWrites;
    conn.pendingWrites = [];
    const { client, server } = acceptWebSocketPair(conn);

    // Flush after the 101 is returned so the client has completed the handshake.
    queueMicrotask(() => {
        for (const data of pending) {
            try {
                server.send(textDecoder.decode(data));
            } catch {
                /* closed */
            }
        }
    });

    return client;
}

/** @internal Prefer {@link stateful}. */
export function createStatefulFetch(
    module: WebAssembly.Module,
    options?: {
        kv?: (env: any) => Record<string, KVNamespace>;
        db?: (env: any) => Record<string, Database>;
        imports?: ImportsFactory;
    },
) {
    return class StatefulFetch {
        readonly state: any;
        readonly env: any;
        readonly connections = new Map<WebSocket, ConnState>();

        constructor(state: any, env: any) {
            this.state = state;
            this.env = env;
        }

        async fetch(request: Request): Promise<Response> {
            if (!hasJspi) {
                return new Response("Sticky WebSocket fetch requires WebAssembly JSPI", { status: 501 });
            }

            const isUpgrade = request.headers.get("upgrade")?.toLowerCase() === "websocket";
            const stdinData = !isUpgrade && request.body
                ? new Uint8Array(await request.arrayBuffer())
                : undefined;

            const conn = newConnection(this.connections);
            const { instance } = instantiate({
                module,
                request,
                stdinData,
                kv: options?.kv?.(this.env) ?? defaultKV(),
                db: options?.db?.(this.env) ?? {},
                imports: options?.imports,
                http: newHttpState(),
                ws: conn,
            });

            // Runs synchronously until the first Suspending import (`__zx_ws.recv`).
            const done = promising!(instance.exports._start as () => void)()
                .then(() => {}, (e: unknown) => {
                    if (!isProcExit(e)) console.error("[StatefulFetch] WASM error:", e);
                })
                .finally(() => {
                    if (conn.server) this.connections.delete(conn.server);
                    deliverToWasm(conn, null);
                });

            if (!conn.upgraded) {
                await done;
                return new Response("WebSocket upgrade expected", { status: 426 });
            }

            const client = attachConnection(conn);
            this.connections.set(conn.server!, conn);
            this.state.waitUntil(done);

            return new Response(null, { status: 101, webSocket: client } as ResponseInit);
        }
    };
}
