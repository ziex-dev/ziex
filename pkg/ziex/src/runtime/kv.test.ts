import { afterEach, beforeAll, describe, expect, setSystemTime, test } from "bun:test";
import type { KVNamespace } from "./kv";
import { createKvHandlers } from "./kv/extern";
import * as idb from "./kv/indexdb";
import * as ls from "./kv/localstorage";
import * as mem from "./kv/memory";
import { textOrBytes } from "./kv/entry";

// Not valid UTF-8: a lone continuation byte, an invalid lead byte and a NUL.
const binary = new Uint8Array([0x80, 0xff, 0x00, 0xc3, 0x28, 0x7f]);
const bom = new Uint8Array([0xef, 0xbb, 0xbf, 0x41]);
const t0 = new Date("2026-01-01T00:00:00Z");

function bytes(v: unknown): Uint8Array {
    if (typeof v === "string") return new TextEncoder().encode(v);
    expect(v).toBeInstanceOf(Uint8Array);
    return v as Uint8Array;
}

class MemoryStorage {
    private items = new Map<string, string>();
    get length() { return this.items.size; }
    key(i: number) { return [...this.items.keys()][i] ?? null; }
    getItem(k: string) { return this.items.get(k) ?? null; }
    setItem(k: string, v: string) { this.items.set(k, String(v)); }
    removeItem(k: string) { this.items.delete(k); }
    clear() { this.items.clear(); }
}

/** The subset of IndexedDB the backend uses; events fire asynchronously like the real thing. */
function installFakeIndexedDB() {
    type Req = { result?: unknown; error: null; onsuccess?: () => void; onerror?: () => void; onupgradeneeded?: () => void };
    const stores = new Map<string, Map<string, unknown>>();
    const db = {
        objectStoreNames: { contains: (n: string) => stores.has(n) },
        createObjectStore: (n: string) => stores.set(n, new Map()),
        transaction(name: string) {
            const data = stores.get(name)!;
            let pending = 0;
            let done = false;
            const tx: { oncomplete?: () => void; onabort?: () => void; onerror?: () => void; error: null; objectStore: () => unknown } = {
                error: null,
                objectStore: () => store,
            };
            const settle = () => setTimeout(() => {
                if (pending === 0 && !done) {
                    done = true;
                    tx.oncomplete?.();
                }
            }, 0);
            const request = (run: () => unknown): Req => {
                if (done) throw new Error("TransactionInactiveError");
                const req: Req = { error: null };
                const result = run();
                pending += 1;
                setTimeout(() => {
                    req.result = result;
                    req.onsuccess?.();
                    pending -= 1;
                    settle();
                }, 0);
                return req;
            };
            type Range = { includes(k: string): boolean };
            const sorted = (range?: Range) => [...data.keys()].sort().filter((k) => !range || range.includes(k));
            const store = {
                get: (k: string) => request(() => structuredClone(data.get(k))),
                put: (v: unknown, k: string) => request(() => void data.set(k, structuredClone(v))),
                delete: (k: string) => request(() => void data.delete(k)),
                getAllKeys: (r?: Range) => request(() => sorted(r)),
                getAll: (r?: Range) => request(() => sorted(r).map((k) => structuredClone(data.get(k)))),
            };
            return tx;
        },
    };
    let created = false;
    (globalThis as Record<string, unknown>).indexedDB = {
        open() {
            const req: Req = { error: null, result: db };
            setTimeout(() => {
                if (!created) {
                    created = true;
                    req.onupgradeneeded?.();
                }
                req.onsuccess?.();
            }, 0);
            return req;
        },
    };
    (globalThis as Record<string, unknown>).IDBKeyRange = {
        bound: (lo: string, hi: string) => ({ includes: (k: string) => k >= lo && k <= hi }),
    };
    return { raw: (k: string) => stores.get("kv")?.get(k), seed: (k: string, v: unknown) => stores.get("kv")!.set(k, v) };
}

const storage = new MemoryStorage();
let fakeIdb: ReturnType<typeof installFakeIndexedDB>;

beforeAll(() => {
    (globalThis as Record<string, unknown>).localStorage = storage;
    fakeIdb = installFakeIndexedDB();
});

afterEach(() => {
    setSystemTime();
    storage.clear();
});

type Backend = {
    get(k: string): unknown;
    put(k: string, v: string | Uint8Array, o?: { expiration?: number; expirationTtl?: number }): unknown;
    del(k: string): unknown;
    list(o?: { prefix?: string }): unknown;
};

const backends: [string, Backend][] = [
    ["memory", mem],
    ["localStorage", ls],
    ["indexedDB", idb],
];

describe.each(backends)("%s backend", (name, b) => {
    const names = async (prefix?: string) =>
        ((await b.list(prefix === undefined ? undefined : { prefix })) as { keys: { name: string }[] }).keys
            .map((k) => k.name).sort();

    test("expirationTtl hides the entry once it passes", async () => {
        setSystemTime(t0);
        await b.put(`${name}:ttl`, "v", { expirationTtl: 10 });
        await b.put(`${name}:keep`, "v");

        setSystemTime(new Date(t0.getTime() + 9_999));
        expect(await b.get(`${name}:ttl`)).toBe("v");
        expect(await names(`${name}:`)).toEqual([`${name}:keep`, `${name}:ttl`]);

        setSystemTime(new Date(t0.getTime() + 10_000));
        expect(await b.get(`${name}:ttl`)).toBeNull();
        expect(await names(`${name}:`)).toEqual([`${name}:keep`]);
        expect(await b.get(`${name}:keep`)).toBe("v");
    });

    test("absolute expiration", async () => {
        setSystemTime(t0);
        await b.put(`${name}:abs`, "v", { expiration: t0.getTime() / 1000 + 5 });
        expect(await b.get(`${name}:abs`)).toBe("v");
        setSystemTime(new Date(t0.getTime() + 5_000));
        expect(await b.get(`${name}:abs`)).toBeNull();
    });

    test("overwriting without a TTL clears the old expiry", async () => {
        setSystemTime(t0);
        await b.put(`${name}:re`, "a", { expirationTtl: 1 });
        await b.put(`${name}:re`, "b");
        setSystemTime(new Date(t0.getTime() + 60_000));
        expect(await b.get(`${name}:re`)).toBe("b");
    });

    test("binary values round-trip byte for byte", async () => {
        await b.put(`${name}:bin`, binary);
        expect(bytes(await b.get(`${name}:bin`))).toEqual(binary);

        const big = new Uint8Array(100_000).map((_, i) => (i * 31) & 0xff);
        await b.put(`${name}:big`, big);
        expect(bytes(await b.get(`${name}:big`))).toEqual(big);
    });

    test("stored bytes don't alias the caller's buffer", async () => {
        const src = new Uint8Array([1, 2, 3, 4, 5]);
        await b.put(`${name}:alias`, src.subarray(1, 4));
        src.fill(0);
        expect(bytes(await b.get(`${name}:alias`))).toEqual(new Uint8Array([2, 3, 4]));
    });

    test("text stays text", async () => {
        await b.put(`${name}:txt`, "héllo ✓");
        expect(await b.get(`${name}:txt`)).toBe("héllo ✓");
    });
});

describe("legacy entries", () => {
    test("localStorage plain strings read as text that never expires", () => {
        storage.setItem("ziex-kv:default:old", "plain");
        expect(ls.get("old")).toBe("plain");
        expect(ls.list({ prefix: "old" }).keys).toEqual([{ name: "old" }]);
    });

    test("IndexedDB bare string rows read as text", async () => {
        await idb.put("seed", "x"); // opens the db
        fakeIdb.seed("default:old", "plain");
        expect(await idb.get("old")).toBe("plain");
        expect((await idb.list({ prefix: "old" })).keys).toEqual([{ name: "old" }]);
    });

    test("IndexedDB removes expired rows on read", async () => {
        setSystemTime(t0);
        await idb.put("gone", "v", { expirationTtl: 1 });
        setSystemTime(new Date(t0.getTime() + 2_000));
        expect(await idb.get("gone")).toBeNull();
        expect(fakeIdb.raw("default:gone")).toBeUndefined();
    });

    test("localStorage removes expired items on read", () => {
        setSystemTime(t0);
        ls.put("gone", "v", { expirationTtl: 1 });
        setSystemTime(new Date(t0.getTime() + 2_000));
        expect(ls.list().keys).toEqual([]);
        expect(storage.getItem("ziex-kv:default:gone")).toBeNull();
    });
});

test("textOrBytes keeps a leading BOM and rejects invalid UTF-8", () => {
    expect(bytes(textOrBytes(bom))).toEqual(bom);
    expect(textOrBytes(binary)).toBeInstanceOf(Uint8Array);
    expect(textOrBytes(new TextEncoder().encode("ok"))).toBe("ok");
});

/** Drives the host ops the way `Kv.Wasm` does, against a real wasm memory. */
function guest(bindings: Record<string, KVNamespace>) {
    const memory = new WebAssembly.Memory({ initial: 4 });
    let top = 1024;
    const alloc = (n: number) => {
        const p = top;
        top += (n + 7) & ~7;
        return p;
    };
    const h = createKvHandlers(bindings, () => memory, [alloc]);
    const put = (s: string | Uint8Array) => {
        const b = typeof s === "string" ? new TextEncoder().encode(s) : s;
        const p = alloc(b.length);
        new Uint8Array(memory.buffer, p, b.length).set(b);
        return [p, b.length] as const;
    };
    const ns = put("default");
    return {
        put: (key: string, value: Uint8Array, ttl = 0) =>
            h.kv_put!(...ns, ...put(key), ...put(value), ttl),
        get: (key: string): Uint8Array | null => {
            const out = alloc(4);
            const n = h.kv_get!(...ns, ...put(key), out, 0, 0) as number;
            if (n < 0) return null;
            const ptr = new DataView(memory.buffer).getUint32(out, true);
            return new Uint8Array(memory.buffer, ptr, n).slice();
        },
    };
}

describe("host ops", () => {
    test("binary and BOM values survive put/get through localStorage", () => {
        const g = guest({ default: ls });
        g.put("bin", binary);
        g.put("bom", bom);
        g.put("empty", new Uint8Array(0));
        expect(g.get("bin")).toEqual(binary);
        expect(g.get("bom")).toEqual(bom);
        expect(g.get("empty")).toEqual(new Uint8Array(0));
        expect(g.get("missing")).toBeNull();
    });

    test("ttl from the guest expires the entry", () => {
        setSystemTime(t0);
        const g = guest({ default: ls });
        g.put("t", new TextEncoder().encode("v"), 3);
        expect(g.get("t")).toEqual(new TextEncoder().encode("v"));
        setSystemTime(new Date(t0.getTime() + 3_000));
        expect(g.get("t")).toBeNull();
    });

    test("Cloudflare-style bindings get text or bytes and are read as arrayBuffer", () => {
        const seen: unknown[] = [];
        const types: unknown[] = [];
        const data = new Map<string, Uint8Array>();
        const cf = {
            get(key: string, type?: string) {
                types.push(type);
                const v = data.get(key);
                if (!v) return null;
                return type === "arrayBuffer" ? v.slice().buffer : new TextDecoder().decode(v);
            },
            put(key: string, value: string | Uint8Array) {
                seen.push(value);
                data.set(key, typeof value === "string" ? new TextEncoder().encode(value) : value.slice());
            },
            del(key: string) { data.delete(key); },
            list() { return { keys: [...data.keys()].map((name) => ({ name })) }; },
        };
        const g = guest({ default: cf });
        g.put("txt", new TextEncoder().encode("hi"));
        g.put("bin", binary);
        expect(seen[0]).toBe("hi");
        expect(seen[1]).toBeInstanceOf(Uint8Array);
        expect(g.get("bin")).toEqual(binary);
        expect(types).toEqual(["arrayBuffer"]);
    });
});
