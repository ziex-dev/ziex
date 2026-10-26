import { newHttpState, toResponse } from "./http";
import { attachWebSocket, deliverToWasm, newWsState, type WsState } from "./ws";
import { defaultKV, instantiate, isProcExit, type ImportsFactory } from "./instance";
import { serveReused, supportsReuse } from "./reuse";
import { hasJspi, promising } from "./jspi";
import type { WASI } from "./wasi";
import type { KVNamespace } from "./kv";
import type { Database } from "./db";

export { buildHttpImports } from "./http";
export { buildWsImports, attachWebSocket } from "./ws";
export type { WsState } from "./ws";

/** Minimal sticky long-lived fetch namespace shape (e.g. Cloudflare Durable Object binding). */
export type StickyNamespace = {
    idFromName(name: string): unknown;
    // Host stubs take a concrete id type; `any` keeps Env key inference workable.
    get(id: any): { fetch(request: Request): Promise<Response> };
};

export type RunOptions = {
    request: Request;
    env?: unknown;
    ctx?: { waitUntil(promise: Promise<unknown>): void };
    module: WebAssembly.Module;
    /** KV namespace bindings - `{ default: env.KV, otherName: env.OTHER_KV }` */
    kv?: Record<string, KVNamespace>;
    /** DB bindings - `{ default: env.DB, analytics: env.ANALYTICS_DB }` */
    db?: Record<string, Database>;
    imports?: ImportsFactory;
    wasi?: WASI;
    /**
     * Sticky namespace for long-lived fetch (WebSocket upgrades).
     * When provided, upgrade requests are forwarded so pub/sub works across clients.
     */
    sticky?: StickyNamespace;
    /**
     * Reuse initialized instances across requests when the module supports it
     * (exports `__zx_serve`). Each instance serves one request at a time.
     */
    reuse?: boolean;
};

/**
 * Run a WASM module for a single request using JSPI.
 *
 * Pass `kv` as a map of binding names → KV namespaces. The Zig side selects
 * a binding via `zx.kv.scoped("name")`; the top-level `zx.kv.*` functions use
 * `"default"`.
 *
 * @example
 * ```ts
 * return run({
 *   request, env, ctx, module,
 *   kv: { default: env.KV, users: env.USERS_KV },
 * });
 * ```
 */
export async function run({
    request,
    ctx,
    module,
    kv = defaultKV(),
    db = {},
    imports,
    wasi,
    sticky,
    reuse = true,
}: RunOptions): Promise<Response> {
    const isUpgrade = request.headers.get("upgrade")?.toLowerCase() === "websocket";

    // Route WebSocket upgrades to the sticky handler so pub/sub works
    // across all connected clients sharing the same instance.
    if (sticky && isUpgrade) {
        const id = sticky.idFromName(new URL(request.url).pathname);
        return sticky.get(id).fetch(request);
    }

    const stdinData = request.body
        ? new Uint8Array(await request.arrayBuffer())
        : undefined;

    if (reuse && hasJspi && !isUpgrade && supportsReuse(module)) {
        return serveReused({ module, request, stdinData, kv, db, imports, wasi });
    }

    const http = newHttpState();
    const ws = newWsState();
    const { instance } = instantiate({ module, request, stdinData, kv, db, imports, wasi, http, ws });
    const done = start(instance, ws);

    // start() runs synchronously until the first suspension (`__zx_ws.recv` for sockets),
    // so an upgrade is already visible here.
    if (ws.upgraded) {
        const { client } = attachWebSocket(ws);
        ctx?.waitUntil(done);
        return new Response(null, { status: 101, webSocket: client } as ResponseInit);
    }

    return toResponse(http, done);
}

function start(instance: WebAssembly.Instance, ws: WsState): Promise<void> {
    const entry = instance.exports._start as () => void;
    if (!hasJspi) {
        try {
            entry();
        } catch (e) {
            if (!isProcExit(e)) throw e;
        }
        return Promise.resolve();
    }

    return promising!(entry)()
        .then(() => {}, (e: unknown) => {
            if (!isProcExit(e)) throw e;
        })
        // Unblock a pending `__zx_ws.recv`.
        .finally(() => deliverToWasm(ws, null));
}
