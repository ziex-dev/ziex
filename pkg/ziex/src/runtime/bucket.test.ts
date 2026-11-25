import { describe, expect, test } from "bun:test";
import { type BucketBinding, createBucketHandlers, createMemoryBucket } from "./bucket";

const enc = new TextEncoder();
const dec = new TextDecoder();

// Drives the `bucket_*` ops the way `Bucket.Wasm` does, against fake guest memory.
function guest(bindings: Record<string, BucketBinding> | undefined) {
    const memory = new WebAssembly.Memory({ initial: 4 });
    let top = 8;
    const alloc = (n: number) => {
        const p = top;
        top += (n + 7) & ~7;
        return p;
    };
    const h = createBucketHandlers(bindings, () => memory, [alloc]);
    const put = (s: string | Uint8Array) => {
        const b = typeof s === "string" ? enc.encode(s) : s;
        const p = alloc(Math.max(b.length, 1));
        new Uint8Array(memory.buffer, p, b.length).set(b);
        return [p, b.length] as const;
    };
    const json = (v: unknown) => put(JSON.stringify(v));
    const name = put("default");
    const out = () => alloc(4);
    const take = (outPtr: number, n: number) => {
        const ptr = new DataView(memory.buffer).getUint32(outPtr, true);
        return new Uint8Array(memory.buffer, ptr, n).slice();
    };
    const u32 = (ptr: number) => new DataView(memory.buffer).getUint32(ptr, true);

    return {
        put: async (req: object, body: string) => h.bucket_put!(...name, ...json(req), ...put(body), 0),
        head: async (key: string) => {
            const o = out();
            const n = (await h.bucket_head!(...name, ...put(key), o, 0, 0)) as number;
            return n < 0 ? n : JSON.parse(dec.decode(take(o, n)));
        },
        get: async (req: object) => {
            const o = out();
            const n = (await h.bucket_get!(...name, ...json(req), o, 0, 0)) as number;
            if (n < 0) return n;
            const raw = take(o, n);
            const metaLen = new DataView(raw.buffer).getUint32(0, true);
            return { meta: JSON.parse(dec.decode(raw.subarray(4, 4 + metaLen))), body: dec.decode(raw.subarray(4 + metaLen)) };
        },
        list: async (req: object) => {
            const o = out();
            const n = (await h.bucket_list!(...name, ...json(req), o, 0, 0)) as number;
            return JSON.parse(dec.decode(take(o, n)));
        },
        del: async (key: string) => h.bucket_delete!(...name, ...put(key), 0, 0, 0),
        open: async (req: object) => {
            const o = out();
            const handle = alloc(4);
            const n = (await h.bucket_open!(...name, ...json(req), o, handle, 0)) as number;
            return n < 0 ? null : { meta: JSON.parse(dec.decode(take(o, n))), handle: u32(handle) };
        },
        read: async (handle: number) => {
            const buf = alloc(3);
            const n = (await h.bucket_read!(handle, buf, 3, 0, 0, 0, 0)) as number;
            return dec.decode(new Uint8Array(memory.buffer, buf, Math.max(n, 0)));
        },
        upload: async (req: object, parts: string[], rest: string) => {
            const handle = alloc(4);
            expect(await h.bucket_upload!(...name, ...json(req), handle, 0, 0)).toBe(0);
            for (const p of parts) expect(await h.bucket_upload_part!(u32(handle), ...put(p), 0, 0, 0, 0)).toBe(0);
            return h.bucket_upload_finish!(u32(handle), ...put(rest), 0, 0, 0, 0);
        },
    };
}

describe("bucket host ops", () => {
    test("put/head/get/delete roundtrip with metadata", async () => {
        const g = guest({ default: createMemoryBucket() });
        expect(await g.put({ key: "a/b.txt", contentType: "text/plain", metadata: [["owner", "ana"]] }, "hello")).toBe(0);

        const head = await g.head("a/b.txt");
        expect(head.key).toBe("a/b.txt");
        expect(head.size).toBe(5);
        expect(head.contentType).toBe("text/plain");
        expect(head.metadata).toEqual([["owner", "ana"]]);
        expect(head.lastModified).toBeGreaterThan(0);

        const got = await g.get({ key: "a/b.txt", range: { offset: 1, length: 3 } });
        expect(got.body).toBe("ell");
        expect(got.meta.size).toBe(5);

        expect(await g.del("a/b.txt")).toBe(0);
        expect(await g.head("a/b.txt")).toBe(-1);
        expect(await g.get({ key: "a/b.txt" })).toBe(-1);
    });

    test("list rolls up prefixes and pages", async () => {
        const g = guest({ default: createMemoryBucket() });
        for (const k of ["p/1", "p/2", "p/q/3", "x"]) await g.put({ key: k }, "v");

        const level = await g.list({ prefix: "p/", delimiter: "/", limit: 1000 });
        expect(level.objects.map((o: { key: string }) => o.key)).toEqual(["p/1", "p/2"]);
        expect(level.prefixes).toEqual(["p/q/"]);
        expect(level.cursor).toBeNull();

        const first = await g.list({ prefix: "", limit: 2 });
        expect(first.objects.length).toBe(2);
        const second = await g.list({ prefix: "", limit: 2, cursor: first.cursor });
        expect(second.objects.map((o: { key: string }) => o.key)).toEqual(["p/q/3", "x"]);
        expect(second.cursor).toBeNull();
    });

    test("open streams the body", async () => {
        const g = guest({ default: createMemoryBucket() });
        await g.put({ key: "s" }, "abcdefg");
        const r = (await g.open({ key: "s", range: { offset: 1 } }))!;
        expect(r.meta.size).toBe(7);
        let text = "";
        for (let chunk = await g.read(r.handle); chunk.length > 0; chunk = await g.read(r.handle)) text += chunk;
        expect(text).toBe("bcdefg");
        expect(await g.open({ key: "missing" })).toBeNull();
    });

    test("uploads go multipart, or one put without it", async () => {
        const mem = createMemoryBucket();
        const g = guest({ default: mem });
        expect(await g.upload({ key: "m", contentType: "x/y" }, ["ab", "cd"], "e")).toBe(0);
        const got = await g.get({ key: "m" });
        expect(got.body).toBe("abcde");
        expect(got.meta.contentType).toBe("x/y");

        const { createMultipartUpload: _, ...plain } = mem;
        const g2 = guest({ default: plain as BucketBinding });
        expect(await g2.upload({ key: "n" }, ["12", "34"], "5")).toBe(0);
        expect((await g2.get({ key: "n" })).body).toBe("12345");
    });

    test("missing bindings and failures are reported", async () => {
        expect(await guest(undefined).head("a")).toBe(-2);
        const broken = { ...createMemoryBucket(), get: async () => { throw new Error("boom"); } };
        const orig = console.error;
        console.error = () => {};
        try {
            expect(await guest({ default: broken }).get({ key: "a" })).toBe(-3);
        } finally {
            console.error = orig;
        }
    });

    test("R2-style Headers metadata and quoted etags are normalized", async () => {
        const r2: BucketBinding = {
            ...createMemoryBucket(),
            head: async (key) => ({
                key,
                size: 1,
                etag: "\"abc\"",
                uploaded: new Date(1000),
                httpMetadata: new Headers({ "content-type": "a/b", "cache-control": "no-store" }),
            }),
        };
        const head = await guest({ default: r2 }).head("k");
        expect(head.etag).toBe("abc");
        expect(head.lastModified).toBe(1000);
        expect(head.contentType).toBe("a/b");
        expect(head.cacheControl).toBe("no-store");
    });
});
