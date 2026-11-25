import {
    type KVValue,
    type PutOptions,
    binaryStringToBytes,
    bytesToBinaryString,
    expiresAt,
    isExpired,
    toBytes,
} from "./entry";

export type Options = {
    namespace?: string;
    storagePrefix?: string;
};

const namespace = "default";
const storagePrefix = "ziex-kv";
const namespacePrefix = `${storagePrefix}:${namespace}:`;

// `\0<s|b><expiresAtMs>:<body>`, `b` being one char per byte; values without `\0` are legacy text.
const mark = "\u0000";

type Entry = { value: string | Uint8Array; at?: number };

export function encodeEntry(value: KVValue, at?: number): string {
    const kind = typeof value === "string" ? "s" : "b";
    const body = typeof value === "string" ? value : bytesToBinaryString(toBytes(value));
    return `${mark}${kind}${at ?? ""}:${body}`;
}

export function decodeEntry(raw: string): Entry {
    if (!raw.startsWith(mark)) return { value: raw };
    const colon = raw.indexOf(":", 2);
    if (colon < 0) return { value: raw };
    const at = colon > 2 ? Number(raw.slice(2, colon)) : undefined;
    const body = raw.slice(colon + 1);
    return { value: raw[1] === "b" ? binaryStringToBytes(body) : body, at };
}

function storage(): Storage {
    if (typeof localStorage === "undefined") {
        throw new Error("localStorage is not available in this environment");
    }
    return localStorage;
}

function read(ls: Storage, id: string): Entry | null {
    const raw = ls.getItem(id);
    if (raw === null) return null;
    const entry = decodeEntry(raw);
    if (isExpired(entry.at)) {
        ls.removeItem(id);
        return null;
    }
    return entry;
}

export function get(key: string): string | Uint8Array | null {
    return read(storage(), namespacePrefix + key)?.value ?? null;
}

export function put(key: string, value: KVValue, options?: PutOptions): void {
    storage().setItem(namespacePrefix + key, encodeEntry(value, expiresAt(options)));
}

export function del(key: string): void {
    storage().removeItem(namespacePrefix + key);
}

export function list(options?: { prefix?: string }): { keys: { name: string }[] } {
    const ls = storage();
    const prefix = namespacePrefix + (options?.prefix ?? "");
    const ids: string[] = [];
    for (let i = 0; i < ls.length; i += 1) {
        const id = ls.key(i);
        if (id && id.startsWith(prefix)) ids.push(id);
    }
    // `read` removes expired items, which shifts `ls.key` indices.
    const keys: { name: string }[] = [];
    for (const id of ids) {
        if (read(ls, id)) keys.push({ name: id.slice(namespacePrefix.length) });
    }
    return { keys };
}
