import { Suspending, type SuspendGate } from "./jspi";

/**
 * Host functions behind `__zx.call` (never suspends) and `__zx.wait` (may suspend
 * via JSPI). Mirrors `Op` in `src/runtime/wasm/imports.zig`; append only.
 */
export const ops = [
    "io_now",
    "io_resolution",
    "io_sleep",
    "io_random",
    "net_fetch",
    "net_take",
    "net_open",
    "net_read",
    "net_close",
    "http_commit",
    "http_write",
    "http_end",
    "ws_upgrade",
    "ws_write",
    "ws_close",
    "ws_recv",
    "ws_subscribe",
    "ws_unsubscribe",
    "ws_publish",
    "ws_is_subscribed",
    "sys_park",
    "kv_get",
    "kv_put",
    "kv_delete",
    "kv_list",
    "db_open",
    "db_run",
    "db_get",
    "db_all",
    "db_values",
    "env_call",
    "email_send",
    "fs_open",
    "fs_close",
    "fs_read",
    "fs_write",
    "fs_stat",
    "fs_set_len",
    "fs_seek",
    "fs_mkdir",
    "fs_remove",
    "fs_rename",
    "fs_readdir",
    "fs_sync",
    "worker_call",
] as const;

export type Op = (typeof ops)[number];

/** Seven u32 argument slots; slices arrive as (ptr, len), 64-bit ints as (lo, hi). */
export type Handler = (
    a: number, b: number, c: number, d: number, e: number, f: number, g: number,
) => number | void | Promise<number | void>;

export type Handlers = Partial<Record<Op, Handler>>;

export type HostImports = { call: Function; wait: Function };

/** Returned for ops this host doesn't implement. */
export const unsupported = -38;

/** Joins the (lo, hi) halves of an i64 argument. */
export function i64(lo: number, hi: number): number {
    return hi * 0x1_0000_0000 + (lo >>> 0);
}

export function createHostImports(handlers: Handlers, gate: SuspendGate | null = null): HostImports {
    const table = ops.map((name) => handlers[name]);

    const dispatch = (op: number, a: number, b: number, c: number, d: number, e: number, f: number, g: number) => {
        const handler = table[op];
        return handler ? handler(a, b, c, d, e, f, g) : unsupported;
    };

    const sync = (reason: string) =>
        (op: number, a: number, b: number, c: number, d: number, e: number, f: number, g: number) => {
            const result = dispatch(op, a, b, c, d, e, f, g);
            if (result instanceof Promise) throw new Error(`zx: ${ops[op]} ${reason}`);
            return result;
        };

    const call = sync("must not suspend");
    const wait = gate
        ? gate.suspending(dispatch)
        : Suspending
            ? new Suspending(dispatch)
            : sync("requires WebAssembly JSPI");
    return { call, wait };
}
