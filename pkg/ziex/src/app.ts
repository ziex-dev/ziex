import { run } from "./runtime";
import type { StickyNamespace } from "./runtime";
import type { KVNamespace } from "./runtime/kv";
import type { Database } from "./runtime/db";
import type { EmailBinding } from "./runtime/email";
import type { BucketBinding } from "./runtime/bucket";
import type { WASI } from "./runtime/wasi";

/**
 * Anything that can be resolved to a `WebAssembly.Module`:
 * - `WebAssembly.Module` - already compiled (Cloudflare Workers, wrangler)
 * - `ArrayBuffer` / `ArrayBufferView` - raw WASM bytes
 * - `Response` - a fetch() response whose body is the WASM binary
 * - `string` - an HTTP(S) URL or an absolute file path (Bun)
 * - `URL` - a URL object
 */
export type WasmInput =
    | WebAssembly.Module
    | ArrayBuffer
    | ArrayBufferView
    | Response
    | string
    | URL;

/**
 * Resolve any supported WASM input to a compiled `WebAssembly.Module`.
 * The result is NOT cached here - cache it at the call site if needed.
 */
export async function resolveModule(input: WasmInput): Promise<WebAssembly.Module> {
    if (typeof input === "string") {
        if (input.startsWith("http://") || input.startsWith("https://")) {
            return (WebAssembly as any).compileStreaming(fetch(input));
        }
        const url = input.startsWith("/") ? `file://${input}` : input;
        return (WebAssembly as any).compile(await fetch(url).then((r) => r.arrayBuffer()));
    }

    if (input instanceof URL) {
        return (WebAssembly as any).compileStreaming(fetch(input));
    }

    if (input instanceof Response) {
        return (WebAssembly as any).compileStreaming(input);
    }

    if (input instanceof ArrayBuffer) {
        return (WebAssembly as any).compile(input);
    }
    if (ArrayBuffer.isView(input)) {
        return (WebAssembly as any).compile((input as ArrayBufferView).buffer);
    }

    // Anything else is assumed to be an already-compiled WebAssembly.Module.
    // Intentionally avoid `instanceof WebAssembly.Module` - it fails across
    // different VM contexts (e.g. Vercel's edge runtime simulator).
    return input as unknown as WebAssembly.Module;
}

/** Keys of `Env` with a KV-like binding (host KV types rarely `extends` our interface). */
type KVKey<Env> = {
    [K in keyof Env]-?: Env[K] extends { get(...args: any[]): any; put(...args: any[]): any } ? K : never;
}[keyof Env];

/** Keys of `Env` whose value is a sticky long-lived fetch namespace. */
export type StickyKey<Env> = {
    [K in keyof Env]-?: Env[K] extends {
        idFromName(name: string): any;
        get(id: any, ...args: any[]): any;
    }
        ? K
        : never;
}[keyof Env];

/** Keys of `Env` with a SQL prepare() binding (e.g. D1). */
type DBKey<Env> = {
    [K in keyof Env]-?: Env[K] extends { prepare(query: string): any } ? K : never;
}[keyof Env];

/** Keys of `Env` with an object storage binding (e.g. Cloudflare R2). */
type BucketKey<Env> = {
    [K in keyof Env]-?: Env[K] extends { head(key: string): any; list(...args: any[]): any } ? K : never;
}[keyof Env];

/** Keys of `Env` with an email `send()` binding (e.g. Cloudflare `send_email`). */
type EmailKey<Env> = {
    [K in keyof Env]-?: Env[K] extends { send(message: any): any } ? K : never;
}[keyof Env];

export type ZiexOptions<Env = Record<string, unknown>> = {
    /** WASM module - accepts any {@link WasmInput}. Resolved and cached on first request. */
    module: WasmInput;
    /** Optional pre-configured WASI instance. */
    wasi?: WASI;
    /** Extra WASM import namespaces. */
    imports?: (mem: () => WebAssembly.Memory) => WebAssembly.Imports;
    /**
     * KV namespace bindings. Two forms are supported:
     *
     * - **Env key**: a single key from `Env` whose value is a `KVNamespace` - used as the `"default"` binding.
     * - **Name map**: `{ [bindingName]: envKey }` - map namespace names to env keys.
     *
     * @example Single env key (becomes the "default" binding)
     * ```ts
     * kv: "MY_KV"
     * ```
     * @example Name map
     * ```ts
     * kv: { default: "MY_KV", users: "USERS_KV" }
     * ```
     */
    kv?: KVKey<Env> | Record<string, KVKey<Env>>;
    /**
     * SQL database bindings (D1 / Postgres / etc. via the same interface). Same shape as `kv`:
     *
     * - `"DB"` maps `env.DB` to the `"default"` database binding.
     * - `{ default: "DB", analytics: "ANALYTICS_DB" }` maps multiple bindings.
     */
    db?: DBKey<Env> | Record<string, DBKey<Env>>;
    /**
     * Email bindings behind `zx.email` with the wasm provider. Same shape as `kv`:
     *
     * - `"EMAIL"` maps `env.EMAIL` to the `"default"` binding.
     * - `{ default: "EMAIL", alerts: "ALERTS_EMAIL" }` maps multiple bindings.
     *
     * A Cloudflare `send_email` binding works as is; elsewhere provide any
     * {@link EmailBinding} on `env`.
     */
    email?: EmailKey<Env> | Record<string, EmailKey<Env>>;
    /**
     * Bucket bindings behind `zx.bucket` with the wasm provider. Same shape as `kv`:
     *
     * - `"BUCKET"` maps `env.BUCKET` to the `"default"` binding.
     * - `{ default: "BUCKET", media: "MEDIA_BUCKET" }` maps multiple bindings.
     *
     * A Cloudflare R2 binding works as is; elsewhere provide any
     * {@link BucketBinding} on `env`.
     */
    bucket?: BucketKey<Env> | Record<string, BucketKey<Env>>;
    /**
     * Keep initialized instances alive and serve later requests on them instead of
     * instantiating the module per request. Needs JSPI and a module that exports
     * `__zx_serve` (current builds); otherwise falls back. Default `true`.
     */
    reuse?: boolean;
    /**
     * Env binding for sticky long-lived fetch (WebSocket upgrades, etc.).
     * Prefer platform helpers (e.g. `stateful(app, binding)` on Cloudflare) over setting this directly.
     */
    sticky?: StickyKey<Env>;
};

/**
 * Main Ziex application class. Mirrors the Hono API style - construct once,
 * export as default, and the runtime calls `fetch` for you.
 *
 * Works on Cloudflare Workers, Bun, and Vercel Edge out of the box.
 *
 * @example Cloudflare Workers / wrangler
 * ```ts
 * import { Ziex } from "ziex";
 * import { stateful } from "ziex/cloudflare";
 * import module from "./app.wasm";
 *
 * const app = new Ziex<Env>({ module, kv: "KV", db: "DB" });
 * export const ChatRoom = stateful(app, { binding: "CHAT_ROOM" });
 * export default app;
 * ```
 *
 * @example Bun
 * ```ts
 * import { Ziex } from "ziex";
 * import wasmPath from "./app.wasm" with { type: "wasm" };
 *
 * const app = new Ziex({ module: wasmPath });
 * export default app;
 * ```
 *
 * @example Vercel Edge
 * ```ts
 * import { Ziex } from "ziex";
 * import { handle } from "ziex/vercel";
 *
 * const app = new Ziex({ module: "https://example.com/app.wasm" });
 * export default handle(app);
 * ```
 */
export class Ziex<Env = Record<string, unknown>> {
    /** @internal Platform adapters read shared config from here. */
    protected readonly options: ZiexOptions<Env>;
    private resolved: WebAssembly.Module | null = null;

    constructor(options: ZiexOptions<Env>) {
        this.options = options;
    }

    protected async getModule(): Promise<WebAssembly.Module> {
        if (!this.resolved) this.resolved = await resolveModule(this.options.module);
        return this.resolved;
    }

    /**
     * Enable sticky upgrade forwarding and return host config for platform adapters
     * (e.g. Cloudflare {@linkcode stateful}).
     *
     * Requires `options.module` to already be a compiled `WebAssembly.Module`.
     */
    stickyHost(binding: StickyKey<Env>) {
        this.options.sticky = binding;
        const mod = this.options.module;
        if (
            mod instanceof ArrayBuffer ||
            ArrayBuffer.isView(mod) ||
            mod instanceof Response ||
            mod instanceof URL ||
            typeof mod === "string"
        ) {
            throw new Error(
                "sticky handlers require a compiled WebAssembly.Module (e.g. `import module from \"./app.wasm\"` under wrangler)",
            );
        }
        return {
            module: mod as unknown as WebAssembly.Module,
            imports: this.options.imports,
            kv: (env: Env) => this.resolveKV(env),
            db: (env: Env) => this.resolveDB(env),
            email: (env: Env) => this.resolveEmail(env),
            bucket: (env: Env) => this.resolveBucket(env),
        };
    }

    private resolveKV(env: Env): Record<string, KVNamespace> | undefined {
        const { kv } = this.options;
        if (kv === undefined) return undefined;
        if (typeof kv === "object" && kv !== null) {
            const result: Record<string, KVNamespace> = {};
            for (const [name, key] of Object.entries(kv)) {
                result[name] = env[key as keyof Env] as unknown as KVNamespace;
            }
            return result;
        }
        return { default: env[kv as keyof Env] as unknown as KVNamespace };
    }

    private resolveDB(env: Env): Record<string, Database> | undefined {
        const { db } = this.options;
        if (db === undefined) return undefined;
        if (typeof db === "object" && db !== null) {
            const result: Record<string, Database> = {};
            for (const [name, key] of Object.entries(db)) {
                result[name] = env[key as keyof Env] as unknown as Database;
            }
            return result;
        }
        return { default: env[db as keyof Env] as unknown as Database };
    }

    private resolveEmail(env: Env): Record<string, EmailBinding> | undefined {
        const { email } = this.options;
        if (email === undefined) return undefined;
        if (typeof email === "object" && email !== null) {
            const result: Record<string, EmailBinding> = {};
            for (const [name, key] of Object.entries(email)) {
                result[name] = env[key as keyof Env] as unknown as EmailBinding;
            }
            return result;
        }
        return { default: env[email as keyof Env] as unknown as EmailBinding };
    }

    private resolveBucket(env: Env): Record<string, BucketBinding> | undefined {
        const { bucket } = this.options;
        if (bucket === undefined) return undefined;
        if (typeof bucket === "object" && bucket !== null) {
            const result: Record<string, BucketBinding> = {};
            for (const [name, key] of Object.entries(bucket)) {
                result[name] = env[key as keyof Env] as unknown as BucketBinding;
            }
            return result;
        }
        return { default: env[bucket as keyof Env] as unknown as BucketBinding };
    }

    /**
     * Fetch handler called by the runtime on every request.
     *
     * Arrow function so `this` is always the class instance, even when the
     * runtime extracts `fetch` from the exported object (e.g. Bun).
     */
    fetch = async (
        request: Request,
        env: Env,
        ctx?: { waitUntil(p: Promise<unknown>): void },
    ): Promise<Response> => {
        const module = await this.getModule();
        const { wasi, imports, sticky, reuse } = this.options;
        return run({
            reuse,
            request,
            env,
            ctx,
            module,
            wasi,
            imports,
            kv: this.resolveKV(env),
            db: this.resolveDB(env),
            email: this.resolveEmail(env),
            bucket: this.resolveBucket(env),
            sticky:
                sticky !== undefined
                    ? (env[sticky as keyof Env] as unknown as StickyNamespace)
                    : undefined,
        });
    };
}
