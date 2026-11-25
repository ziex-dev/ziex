import { type WasmAllocRef, textDecoder, textEncoder, writeBytesOut } from "../wasm/core";
import type { Handlers } from "./host";

export type { WasmAllocRef };

/** Object metadata, as Cloudflare R2 reports it. */
export interface BucketObject {
    key: string;
    size: number;
    etag: string;
    uploaded?: Date;
    httpMetadata?: {
        contentType?: string;
        contentDisposition?: string;
        contentEncoding?: string;
        cacheControl?: string;
    } | Headers;
    customMetadata?: Record<string, string>;
}

export interface BucketObjectBody extends BucketObject {
    body: ReadableStream<Uint8Array>;
    arrayBuffer(): Promise<ArrayBuffer>;
}

export type BucketPutOptions = {
    httpMetadata?: {
        contentType?: string;
        contentDisposition?: string;
        contentEncoding?: string;
        cacheControl?: string;
    };
    customMetadata?: Record<string, string>;
};

export type BucketListOptions = {
    prefix?: string;
    delimiter?: string;
    cursor?: string;
    limit?: number;
    include?: ("httpMetadata" | "customMetadata")[];
};

export type BucketListResult = {
    objects: BucketObject[];
    delimitedPrefixes: string[];
    truncated: boolean;
    cursor?: string;
};

export interface BucketMultipartUpload {
    uploadPart(partNumber: number, value: Uint8Array): Promise<{ partNumber: number; etag: string }>;
    complete(parts: { partNumber: number; etag: string }[]): Promise<BucketObject>;
    abort(): Promise<void>;
}

/**
 * Bucket binding behind `zx.bucket` with the wasm provider. A Cloudflare R2
 * binding is one as is; on other runtimes provide an object with these methods.
 * Without `createMultipartUpload`, uploads are buffered and sent with one `put`.
 */
export interface BucketBinding {
    head(key: string): Promise<BucketObject | null>;
    get(key: string, options?: { range?: { offset: number; length?: number } }): Promise<BucketObjectBody | null>;
    put(key: string, value: Uint8Array, options?: BucketPutOptions): Promise<BucketObject | null>;
    delete(key: string): Promise<void>;
    list(options?: BucketListOptions): Promise<BucketListResult>;
    createMultipartUpload?(key: string, options?: BucketPutOptions): Promise<BucketMultipartUpload>;
}

/** Matches `Bucket.Wasm.WireMeta`. */
type WireMeta = {
    key: string;
    size: number;
    etag: string;
    lastModified: number;
    contentType?: string;
    contentDisposition?: string;
    contentEncoding?: string;
    cacheControl?: string;
    metadata: [string, string][];
};

type PutRequest = {
    key: string;
    contentType?: string;
    contentDisposition?: string;
    contentEncoding?: string;
    cacheControl?: string;
    metadata?: [string, string][];
};

type GetRequest = { key: string; range?: { offset: number; length?: number } };

const notFound = -1;
const missing = -2;
const failed = -3;

function httpField(m: BucketObject["httpMetadata"], name: "contentType" | "contentDisposition" | "contentEncoding" | "cacheControl"): string | undefined {
    if (!m) return undefined;
    if (typeof (m as Headers).get === "function") {
        const header = name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
        return (m as Headers).get(header) ?? undefined;
    }
    return (m as Record<string, string | undefined>)[name];
}

export function toWireMeta(o: BucketObject): WireMeta {
    return {
        key: o.key,
        size: o.size,
        etag: o.etag.replace(/^"|"$/g, ""),
        lastModified: o.uploaded ? o.uploaded.getTime() : 0,
        contentType: httpField(o.httpMetadata, "contentType"),
        contentDisposition: httpField(o.httpMetadata, "contentDisposition"),
        contentEncoding: httpField(o.httpMetadata, "contentEncoding"),
        cacheControl: httpField(o.httpMetadata, "cacheControl"),
        metadata: Object.entries(o.customMetadata ?? {}),
    };
}

function putOptions(req: PutRequest): BucketPutOptions {
    const httpMetadata: NonNullable<BucketPutOptions["httpMetadata"]> = {};
    if (req.contentType !== undefined) httpMetadata.contentType = req.contentType;
    if (req.contentDisposition !== undefined) httpMetadata.contentDisposition = req.contentDisposition;
    if (req.contentEncoding !== undefined) httpMetadata.contentEncoding = req.contentEncoding;
    if (req.cacheControl !== undefined) httpMetadata.cacheControl = req.cacheControl;
    return { httpMetadata, customMetadata: Object.fromEntries(req.metadata ?? []) };
}

function concat(chunks: Uint8Array[]): Uint8Array {
    const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
    let offset = 0;
    for (const c of chunks) {
        out.set(c, offset);
        offset += c.length;
    }
    return out;
}

/** An upload in progress; the multipart upload starts with the first part. */
type Upload = {
    binding: BucketBinding;
    req: PutRequest;
    multipart?: BucketMultipartUpload;
    parts: { partNumber: number; etag: string }[];
    // Parts held back when the binding can't do multipart.
    buffered: Uint8Array[];
};

type Stream = { reader: ReadableStreamDefaultReader<Uint8Array>; pending: Uint8Array };

/** Host ops for bucket bindings (`bucket_*`). */
export function createBucketHandlers(
    bindings: Record<string, BucketBinding> | undefined,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): Handlers {
    const streams = new Map<number, Stream>();
    const uploads = new Map<number, Upload>();
    let nextHandle = 1;

    const readStr = (ptr: number, len: number): string =>
        len === 0 ? "" : textDecoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
    // Copied: the guest may reuse its memory once it resumes.
    const readBytes = (ptr: number, len: number): Uint8Array =>
        len === 0 ? new Uint8Array(0) : new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0).slice();
    const readJson = <T>(ptr: number, len: number): T => JSON.parse(readStr(ptr, len)) as T;
    const setU32 = (ptr: number, value: number) => new DataView(getMemory().buffer).setUint32(ptr >>> 0, value, true);
    const writeJson = (out: number, value: unknown) => writeBytesOut(getMemory, allocRef, out, textEncoder.encode(JSON.stringify(value)));

    const resolve = (ptr: number, len: number): BucketBinding | undefined => {
        const name = readStr(ptr, len);
        const b = bindings?.[name] ?? bindings?.["default"];
        return typeof b?.head === "function" ? b : undefined;
    };

    // Runs `f` against the binding; failures are logged and reported as `failed`.
    const run = (namePtr: number, nameLen: number, op: string, f: (b: BucketBinding) => Promise<number>): number | Promise<number> => {
        const b = resolve(namePtr, nameLen);
        if (!b) return missing;
        try {
            return f(b).catch((err) => report(op, err));
        } catch (err) {
            return report(op, err);
        }
    };

    function report(op: string, err: unknown): number {
        console.error(`zx.bucket ${op} failed:`, err);
        return failed;
    }

    async function sendPart(u: Upload, bytes: Uint8Array): Promise<void> {
        if (!u.binding.createMultipartUpload) {
            u.buffered.push(bytes);
            return;
        }
        u.multipart ??= await u.binding.createMultipartUpload(u.req.key, putOptions(u.req));
        u.parts.push(await u.multipart.uploadPart(u.parts.length + 1, bytes));
    }

    return {
        bucket_head: (np, nl, kp, kl, out) =>
            run(np, nl, "head", async (b) => {
                const o = await b.head(readStr(kp, kl));
                return o ? writeJson(out, toWireMeta(o)) : notFound;
            }),

        bucket_get: (np, nl, rp, rl, out) => {
            const req = readJson<GetRequest>(rp, rl);
            return run(np, nl, "get", async (b) => {
                const o = await b.get(req.key, req.range ? { range: req.range } : undefined);
                if (!o) return notFound;
                const meta = textEncoder.encode(JSON.stringify(toWireMeta(o)));
                const body = new Uint8Array(await o.arrayBuffer());
                const bytes = new Uint8Array(4 + meta.length + body.length);
                new DataView(bytes.buffer).setUint32(0, meta.length, true);
                bytes.set(meta, 4);
                bytes.set(body, 4 + meta.length);
                return writeBytesOut(getMemory, allocRef, out, bytes);
            });
        },

        bucket_put: (np, nl, rp, rl, bp, bl) => {
            const req = readJson<PutRequest>(rp, rl);
            const body = readBytes(bp, bl);
            return run(np, nl, "put", async (b) => {
                await b.put(req.key, body, putOptions(req));
                return 0;
            });
        },

        bucket_delete: (np, nl, kp, kl) => {
            const key = readStr(kp, kl);
            return run(np, nl, "delete", async (b) => {
                await b.delete(key);
                return 0;
            });
        },

        bucket_list: (np, nl, rp, rl, out) => {
            const req = readJson<{ prefix: string; delimiter?: string; cursor?: string; limit: number }>(rp, rl);
            return run(np, nl, "list", async (b) => {
                const res = await b.list({
                    prefix: req.prefix || undefined,
                    delimiter: req.delimiter,
                    cursor: req.cursor,
                    limit: req.limit,
                    include: ["httpMetadata", "customMetadata"],
                });
                return writeJson(out, {
                    objects: res.objects.map(toWireMeta),
                    prefixes: res.delimitedPrefixes ?? [],
                    cursor: res.truncated ? res.cursor ?? null : null,
                });
            });
        },

        bucket_open: (np, nl, rp, rl, out, handleOut) => {
            const req = readJson<GetRequest>(rp, rl);
            return run(np, nl, "open", async (b) => {
                const o = await b.get(req.key, req.range ? { range: req.range } : undefined);
                if (!o) return notFound;
                const handle = nextHandle++;
                streams.set(handle, { reader: o.body.getReader(), pending: new Uint8Array(0) });
                setU32(handleOut, handle);
                return writeJson(out, toWireMeta(o));
            });
        },

        // Copies up to `len` body bytes; 0 at the end.
        bucket_read: (handle, ptr, len) => {
            const s = streams.get(handle);
            if (!s) return failed;
            return (async () => {
                try {
                    while (s.pending.length === 0) {
                        const { done, value } = await s.reader.read();
                        if (done) return 0;
                        s.pending = value;
                    }
                } catch (err) {
                    return report("read", err);
                }
                const n = Math.min(len >>> 0, s.pending.length);
                new Uint8Array(getMemory().buffer, ptr >>> 0, n).set(s.pending.subarray(0, n));
                s.pending = s.pending.subarray(n);
                return n;
            })();
        },

        bucket_close: (handle) => {
            const s = streams.get(handle);
            if (!s) return;
            streams.delete(handle);
            s.reader.cancel().catch(() => {});
        },

        bucket_upload: (np, nl, rp, rl, handleOut) => {
            const b = resolve(np, nl);
            if (!b) return missing;
            const handle = nextHandle++;
            uploads.set(handle, { binding: b, req: readJson<PutRequest>(rp, rl), parts: [], buffered: [] });
            setU32(handleOut, handle);
            return 0;
        },

        bucket_upload_part: (handle, bp, bl) => {
            const u = uploads.get(handle);
            if (!u) return failed;
            const bytes = readBytes(bp, bl);
            return sendPart(u, bytes).then(() => 0, (err) => report("upload part", err));
        },

        bucket_upload_finish: (handle, bp, bl) => {
            const u = uploads.get(handle);
            if (!u) return failed;
            uploads.delete(handle);
            const rest = readBytes(bp, bl);
            return (async () => {
                if (!u.multipart) {
                    await u.binding.put(u.req.key, concat([...u.buffered, rest]), putOptions(u.req));
                    return 0;
                }
                if (rest.length > 0) u.parts.push(await u.multipart.uploadPart(u.parts.length + 1, rest));
                await u.multipart.complete(u.parts);
                return 0;
            })().catch(async (err) => {
                await u.multipart?.abort().catch(() => {});
                return report("upload", err);
            });
        },

        bucket_upload_abort: (handle) => {
            const u = uploads.get(handle);
            if (!u) return 0;
            uploads.delete(handle);
            return (u.multipart?.abort() ?? Promise.resolve()).then(() => 0, () => 0);
        },
    };
}

/** An in-memory bucket with the binding's shape, for development and tests. */
export function createMemoryBucket(): BucketBinding {
    type Entry = { bytes: Uint8Array; meta: BucketObject };
    const objects = new Map<string, Entry>();

    const etagOf = (bytes: Uint8Array) => {
        let h = 2166136261;
        for (const b of bytes) h = Math.imul(h ^ b, 16777619) >>> 0;
        return h.toString(16).padStart(8, "0");
    };
    const store = (key: string, bytes: Uint8Array, options?: BucketPutOptions): BucketObject => {
        const meta: BucketObject = {
            key,
            size: bytes.length,
            etag: etagOf(bytes),
            uploaded: new Date(),
            httpMetadata: { ...options?.httpMetadata },
            customMetadata: { ...options?.customMetadata },
        };
        objects.set(key, { bytes: bytes.slice(), meta });
        return meta;
    };
    const withBody = (meta: BucketObject, bytes: Uint8Array): BucketObjectBody => ({
        ...meta,
        body: new Blob([bytes as BlobPart]).stream(),
        arrayBuffer: async () => bytes.slice().buffer,
    });

    return {
        async head(key) {
            return objects.get(key)?.meta ?? null;
        },
        async get(key, options) {
            const e = objects.get(key);
            if (!e) return null;
            const r = options?.range;
            const bytes = r ? e.bytes.subarray(r.offset, r.length === undefined ? undefined : r.offset + r.length) : e.bytes;
            return withBody(e.meta, bytes);
        },
        async put(key, value, options) {
            return store(key, value, options);
        },
        async delete(key) {
            objects.delete(key);
        },
        async list(options = {}) {
            const prefix = options.prefix ?? "";
            const limit = options.limit ?? 1000;
            const keys = [...objects.keys()].filter((k) => k.startsWith(prefix) && (!options.cursor || k > options.cursor)).sort();
            const result: BucketListResult = { objects: [], delimitedPrefixes: [], truncated: false };
            let i = 0;
            let last: string | undefined;
            while (i < keys.length) {
                if (result.objects.length + result.delimitedPrefixes.length >= limit) break;
                const key = keys[i]!;
                const at = options.delimiter ? key.indexOf(options.delimiter, prefix.length) : -1;
                if (at >= 0) {
                    const rolled = key.slice(0, at + options.delimiter!.length);
                    result.delimitedPrefixes.push(rolled);
                    while (i < keys.length && keys[i]!.startsWith(rolled)) last = keys[i++];
                    continue;
                }
                result.objects.push(objects.get(key)!.meta);
                last = key;
                i++;
            }
            if (i < keys.length) {
                result.truncated = true;
                result.cursor = last;
            }
            return result;
        },
        async createMultipartUpload(key, options) {
            const parts = new Map<number, Uint8Array>();
            return {
                async uploadPart(partNumber, value) {
                    parts.set(partNumber, value.slice());
                    return { partNumber, etag: etagOf(value) };
                },
                async complete(uploaded) {
                    return store(key, concat(uploaded.map((p) => parts.get(p.partNumber)!)), options);
                },
                async abort() {
                    parts.clear();
                },
            };
        },
    };
}
