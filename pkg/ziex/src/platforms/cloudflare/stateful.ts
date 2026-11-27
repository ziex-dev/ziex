import { newHttpState } from "../../runtime/http";
import { acceptWebSocketPair, deliverToWasm, newWsState, waitForUpgrade, type WsState } from "../../runtime/ws";
import { defaultKV, instantiate, isProcExit, type ImportsFactory } from "../../runtime/instance";
import { hasJspi, promising } from "../../runtime/jspi";
import type { KVNamespace } from "../../runtime/kv";
import type { Database } from "../../runtime/db";
import type { EmailBinding } from "../../runtime/email";
import type { BucketBinding } from "../../runtime/bucket";

type ConnState = WsState & {
    topics: Set<string>;
    /** Bun default: publish() excludes the sender unless configured. */
    publishToSelf: boolean;
};

const textDecoder = new TextDecoder("utf-8", { fatal: true });

/** Text frame when payload is valid UTF-8; otherwise a binary frame. */
function frameFor(data: Uint8Array): string | Uint8Array {
    try {
        return textDecoder.decode(data);
    } catch {
        return data;
    }
}

function send(sock: WebSocket, payload: string | Uint8Array): boolean {
    try {
        sock.send(payload);
        return true;
    } catch {
        return false;
    }
}

function newConnection(connections: Map<WebSocket, ConnState>): ConnState {
    const conn: ConnState = {
        ...newWsState(),
        topics: new Set(),
        publishToSelf: false,
        subscribe: (topic) => {
            if (topic.length === 0 || topic.length > 256) return;
            if (conn.topics.size >= 128) return;
            conn.topics.add(topic);
        },
        unsubscribe: (topic) => {
            conn.topics.delete(topic);
        },
        isSubscribed: (topic) => conn.topics.has(topic),
        setPublishToSelf: (value) => {
            conn.publishToSelf = value;
        },
        publish: (topic, data) => {
            if (topic.length === 0 || topic.length > 256) return 0;

            let count = 0;
            const payload = frameFor(data);

            for (const [sock, other] of connections) {
                if (!other.topics.has(topic)) continue;
                if (other === conn && !conn.publishToSelf) continue;
                if (send(sock, payload)) count++;
            }

            // Pre-attach (`socket_open`): this conn is not in `connections` yet.
            if (!conn.server && conn.publishToSelf && conn.topics.has(topic)) {
                conn.pendingWrites.push(payload);
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
            send(server, data as string | Uint8Array);
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
        email?: (env: any) => Record<string, EmailBinding> | undefined;
        bucket?: (env: any) => Record<string, BucketBinding> | undefined;
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
                env: this.env,
                kv: options?.kv?.(this.env) ?? defaultKV(),
                db: options?.db?.(this.env) ?? {},
                email: options?.email?.(this.env),
                bucket: options?.bucket?.(this.env),
                imports: options?.imports,
                http: newHttpState(),
                ws: conn,
            });

            // Runs until the first Suspending import (often KV/cache before upgrade).
            const done = promising!(instance.exports._start as () => void)()
                .then(() => {}, (e: unknown) => {
                    if (!isProcExit(e)) console.error("[StatefulFetch] WASM error:", e);
                })
                .finally(() => {
                    if (conn.server) this.connections.delete(conn.server);
                    conn.topics.clear();
                    deliverToWasm(conn, null);
                });

            // JSPI may suspend on KV/IO before `ws_upgrade`; don't await `done`
            // (that is the whole socket lifetime).
            await waitForUpgrade(conn, done);
            if (!conn.upgraded) {
                return new Response("WebSocket upgrade expected", { status: 426 });
            }

            const client = attachConnection(conn);
            this.connections.set(conn.server!, conn);
            this.state.waitUntil(done);

            return new Response(null, { status: 101, webSocket: client } as ResponseInit);
        }
    };
}
