import {
    type WasmAllocRef,
    textDecoder,
    writeBytesOut,
} from "../../wasm/core";
import type { KVNamespace, SyncKVNamespace } from "../kv";
import { type KVValue, textOrBytes, toBytes } from "./entry";
import { Suspending } from "../jspi";
import type { Handlers } from "../host";
import { encodeStrings } from "../wire";

export type { WasmAllocRef };

const jspi = Suspending !== undefined;
const miss = jspi ? -1 : 0;

function putOptions(ttlSeconds: number): { expirationTtl: number } | undefined {
    return ttlSeconds > 0 ? { expirationTtl: ttlSeconds } : undefined;
}

/** Our backends export `del`; Cloudflare KV uses `delete`. */
function kvDel(binding: KVNamespace, key: string): ReturnType<KVNamespace["del"]> {
    const b = binding as KVNamespace & { delete?: KVNamespace["del"] };
    return (b.del ?? b.delete)!.call(b, key);
}

function isSyncKVNamespace(binding: KVNamespace): binding is SyncKVNamespace {
    return typeof binding.get === "function" && binding.get.constructor.name !== "AsyncFunction";
}

function listOpts(prefix: string): { prefix: string } | undefined {
    return prefix.length > 0 ? { prefix } : undefined;
}

function maybeThen<T, R>(r: T | Promise<T>, f: (v: T) => R): R | Promise<R> {
    return r instanceof Promise ? r.then(f) : f(r);
}

function readStr(getMemory: () => WebAssembly.Memory, ptr: number, len: number): string {
    if (len === 0) return "";
    return textDecoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
}

function readBytes(getMemory: () => WebAssembly.Memory, ptr: number, len: number): Uint8Array {
    if (len === 0) return new Uint8Array(0);
    return new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0).slice();
}

function resolve(
    bindings: Record<string, KVNamespace>,
    ns: string,
): KVNamespace | null {
    const b = bindings[ns] ?? bindings["default"] ?? null;
    if (!b || jspi) return b;
    return isSyncKVNamespace(b) ? b : null;
}

function encodeGet(
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
    value: KVValue | null | undefined,
    out_ptr: number,
): number {
    if (value === null || value === undefined) return -1;
    return writeBytesOut(getMemory, allocRef, out_ptr, toBytes(value));
}

function encodeList(
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
    names: string[],
    out_ptr: number,
): number {
    if (names.length === 0) {
        new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
        return 0;
    }
    return writeBytesOut(getMemory, allocRef, out_ptr, encodeStrings(names));
}

function get(
    b: KVNamespace,
    key: string,
    out_ptr: number,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): number | Promise<number> {
    // Cloudflare KV returns text by default, which would mangle binary values.
    return maybeThen(b.get(key, "arrayBuffer"), (v) => encodeGet(getMemory, allocRef, v, out_ptr));
}

/** TTL is passed through as is; puts the binding rejects surface as `error.PutFailed`. */
function put(b: KVNamespace, key: string, val: KVValue, ttl: number): number | Promise<number> {
    try {
        const r = b.put(key, val, putOptions(ttl));
        return r instanceof Promise ? r.then(() => 0, () => -1) : 0;
    } catch {
        return -1;
    }
}

function del(b: KVNamespace, key: string): number | Promise<number> {
    return maybeThen(kvDel(b, key), () => 0);
}

function list(
    b: KVNamespace,
    prefix: string,
    out_ptr: number,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): number | Promise<number> {
    return maybeThen(b.list(listOpts(prefix)), (result) =>
        encodeList(getMemory, allocRef, result.keys.map((k) => k.name), out_ptr),
    );
}

export type KVHandlerOptions = {
    // "background" never suspends put/delete: the guest issues them through
    // `__zx.call`, so they must complete synchronously.
    writes?: "await" | "background";
};

function background(r: number | Promise<number>): number {
    if (r instanceof Promise) {
        r.catch((err) => console.error("zx.kv write failed:", err));
        return 0;
    }
    return r;
}

/** Host ops for key/value namespace bindings. */
export function createKvHandlers(
    bindings: Record<string, KVNamespace>,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
    options: KVHandlerOptions = {},
): Handlers {
    const write = options.writes === "background" ? background : (r: number | Promise<number>) => r;
    return {
        kv_get: (ns_ptr, ns_len, key_ptr, key_len, out_ptr) => {
            const b = resolve(bindings, readStr(getMemory, ns_ptr, ns_len));
            if (!b) return -1;
            return get(b, readStr(getMemory, key_ptr, key_len), out_ptr, getMemory, allocRef);
        },

        kv_put: (ns_ptr, ns_len, key_ptr, key_len, val_ptr, val_len, ttl_seconds) => {
            const b = resolve(bindings, readStr(getMemory, ns_ptr, ns_len));
            if (!b) return miss;
            return write(put(
                b,
                readStr(getMemory, key_ptr, key_len),
                textOrBytes(readBytes(getMemory, val_ptr, val_len)),
                ttl_seconds,
            ));
        },

        kv_delete: (ns_ptr, ns_len, key_ptr, key_len) => {
            const b = resolve(bindings, readStr(getMemory, ns_ptr, ns_len));
            if (!b) return miss;
            return write(del(b, readStr(getMemory, key_ptr, key_len)));
        },

        kv_list: (ns_ptr, ns_len, pfx_ptr, pfx_len, out_ptr) => {
            const b = resolve(bindings, readStr(getMemory, ns_ptr, ns_len));
            if (!b) {
                new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                return 0;
            }
            return list(b, readStr(getMemory, pfx_ptr, pfx_len), out_ptr, getMemory, allocRef);
        },
    };
}
