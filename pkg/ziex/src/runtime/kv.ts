export type { WasmAllocRef } from "../wasm/core";
export { createKvHandlers } from "./kv/extern";
export { hasJspi } from "./jspi";

import { hasJspi } from "./jspi";
import {
    get as localStorageGet,
    put as localStoragePut,
    del as localStorageDel,
    list as localStorageList,
} from "./kv/localstorage";
import {
    get as indexedDbGet,
    put as indexedDbPut,
    del as indexedDbDel,
    list as indexedDbList,
    type Options as IndexedDbOptions,
} from "./kv/indexdb";

import type { KVValue, PutOptions } from "./kv/entry";
export type { KVBytes, KVValue, PutOptions } from "./kv/entry";

type MaybePromise<T> = T | Promise<T>;

/**
 * Key/value namespace binding (get/put/del/list), shaped like Cloudflare KV.
 * `put` gets text when the value is valid UTF-8 and bytes otherwise; `get` is
 * called with `"arrayBuffer"` and may return either. Bindings must honor the
 * expiry options.
 */
export interface KVNamespace {
    get(key: string, type?: "arrayBuffer"): MaybePromise<KVValue | null>;
    put(key: string, value: KVValue, options?: PutOptions): MaybePromise<void>;
    del(key: string): MaybePromise<void>;
    list(options?: { prefix?: string }): MaybePromise<{ keys: { name: string }[] }>;
}

/** Synchronous KV used when JSPI is unavailable (e.g. localStorage). Same method names, sync returns. */
export interface SyncKVNamespace {
    get(key: string, type?: "arrayBuffer"): KVValue | null;
    put(key: string, value: KVValue, options?: PutOptions): void;
    del(key: string): void;
    list(options?: { prefix?: string }): { keys: { name: string }[] };
}

export type BrowserKVOptions = IndexedDbOptions & {
    storagePrefix?: string;
    forceLocalStorage?: boolean;
};


/** Prefer IndexedDB when JSPI is available, otherwise localStorage. */
export function createBrowserKVBindings(options: BrowserKVOptions = {}): Record<string, KVNamespace> {
    const namespace = options.namespace ?? "default";
    return {
        [namespace]: hasJspi && !options.forceLocalStorage
            ? { get: indexedDbGet, put: indexedDbPut, del: indexedDbDel, list: indexedDbList }
            : { get: localStorageGet, put: localStoragePut, del: localStorageDel, list: localStorageList },
    };
}
