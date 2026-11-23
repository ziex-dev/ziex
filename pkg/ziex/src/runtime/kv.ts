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

type MaybePromise<T> = T | Promise<T>;

/** Key/value namespace binding (get/put/del/list). */
export interface KVNamespace {
    get(key: string): MaybePromise<string | null>;
    put(key: string, value: string, options?: { expiration?: number; expirationTtl?: number }): MaybePromise<void>;
    del(key: string): MaybePromise<void>;
    list(options?: { prefix?: string }): MaybePromise<{ keys: { name: string }[] }>;
}

/** Synchronous KV used when JSPI is unavailable (e.g. localStorage). Same method names, sync returns. */
export interface SyncKVNamespace {
    get(key: string): string | null;
    put(key: string, value: string, options?: { expiration?: number; expirationTtl?: number }): void;
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
