import { type KVValue, type PutOptions, expiresAt, isExpired, own } from "./entry";

export type Options = {
    databaseName?: string;
    storeName?: string;
    namespace?: string;
};

const databaseName = "ziex-kv";
const storeName = "kv";
const namespace = "default";

// Bare string rows are legacy and never expire.
type Row = { v: string | Uint8Array; e?: number };

let dbPromise: Promise<IDBDatabase> | undefined;

function openDb(): Promise<IDBDatabase> {
    if (!dbPromise) {
        if (typeof indexedDB === "undefined") {
            return Promise.reject(new Error("IndexedDB is not available in this environment"));
        }
        dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
            const request = indexedDB.open(databaseName, 1);

            request.onupgradeneeded = () => {
                const db = request.result;
                if (!db.objectStoreNames.contains(storeName)) {
                    db.createObjectStore(storeName);
                }
            };

            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error ?? new Error("Failed to open IndexedDB"));
        });
    }
    return dbPromise;
}

function requestToPromise<T>(request: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
    });
}

function transactionToPromise(transaction: IDBTransaction): Promise<void> {
    return new Promise((resolve, reject) => {
        transaction.oncomplete = () => resolve();
        transaction.onabort = () => reject(transaction.error ?? new Error("IndexedDB transaction aborted"));
        transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB transaction failed"));
    });
}

function unwrap(row: unknown): Row | null {
    if (typeof row === "string") return { v: row };
    if (row && typeof row === "object" && "v" in row) return row as Row;
    return null;
}

function id(key: string): string {
    return `${namespace}:${key}`;
}

// Rechecked in a write transaction so a newer put survives.
async function evict(db: IDBDatabase, key: string): Promise<void> {
    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    const row = unwrap(await requestToPromise(store.get(id(key))));
    if (row && isExpired(row.e)) store.delete(id(key));
    await transactionToPromise(tx);
}

export async function get(key: string): Promise<string | Uint8Array | null> {
    const db = await openDb();
    const tx = db.transaction(storeName, "readonly");
    const row = unwrap(await requestToPromise(tx.objectStore(storeName).get(id(key))));
    await transactionToPromise(tx);
    if (!row) return null;
    if (isExpired(row.e)) {
        await evict(db, key);
        return null;
    }
    return row.v;
}

export async function put(key: string, value: KVValue, options?: PutOptions): Promise<void> {
    const db = await openDb();
    const tx = db.transaction(storeName, "readwrite");
    const row: Row = { v: own(value) };
    const e = expiresAt(options);
    if (e !== undefined) row.e = e;
    tx.objectStore(storeName).put(row, id(key));
    await transactionToPromise(tx);
}

export async function del(key: string): Promise<void> {
    const db = await openDb();
    const tx = db.transaction(storeName, "readwrite");
    tx.objectStore(storeName).delete(id(key));
    await transactionToPromise(tx);
}

export async function list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }> {
    const db = await openDb();
    const prefix = id(options?.prefix ?? "");
    const range = IDBKeyRange.bound(prefix, `${prefix}￿`);
    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);
    const [ids, rows] = await Promise.all([
        requestToPromise(store.getAllKeys(range)),
        requestToPromise(store.getAll(range)),
    ]);
    await transactionToPromise(tx);

    const keys: { name: string }[] = [];
    ids.forEach((k, i) => {
        if (typeof k !== "string" || !k.startsWith(prefix)) return;
        const row = unwrap(rows[i]);
        if (row && !isExpired(row.e)) keys.push({ name: k.slice(namespace.length + 1) });
    });
    return { keys };
}
