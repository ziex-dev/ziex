import { type KVValue, type PutOptions, expiresAt, isExpired, own } from "./entry";

type MemoryEntry = [string | Uint8Array, number | undefined];
const store = new Map<string, MemoryEntry>();

export async function get(key: string): Promise<string | Uint8Array | null> {
    const entry = store.get(key);
    if (!entry) return null;
    if (isExpired(entry[1])) {
        store.delete(key);
        return null;
    }
    return entry[0];
}

export async function put(key: string, value: KVValue, options?: PutOptions): Promise<void> {
    store.set(key, [own(value), expiresAt(options)]);
}

export async function del(key: string): Promise<void> {
    store.delete(key);
}

export async function list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }> {
    const keys: { name: string }[] = [];
    for (const name of [...store.keys()]) {
        if (options?.prefix && !name.startsWith(options.prefix)) continue;
        if ((await get(name)) !== null) keys.push({ name });
    }
    return { keys };
}
