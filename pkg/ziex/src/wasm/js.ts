// Dynamic JS interop for `src/runtime/client/js.zig` over u32 handles.
import { textEncoder, type MemoryIO } from "./mem";

const FREE = Symbol();

/** Handle table. 0 = undefined, 1 = null, 2 = globalThis. */
export const R: unknown[] = [undefined, null, globalThis];
const freeList: number[] = [];

export function ref(v: unknown): number {
    if (v === undefined) return 0;
    if (v === null) return 1;
    if (v === globalThis) return 2;
    const h = freeList.length > 0 ? freeList.pop()! : R.length;
    R[h] = v;
    return h;
}

export function deref(h: number): unknown {
    const v = R[h >>> 0];
    return v === FREE ? undefined : v;
}

export function unref(h: number): void {
    h >>>= 0;
    if (h <= 2 || h >= R.length || R[h] === FREE) return;
    R[h] = FREE;
    freeList.push(h);
}

export function resetRefs(): void {
    R.length = 3;
    freeList.length = 0;
}

// Raw slot (16 bytes): tag u32, a u32, n f64. Must match `Raw` in js.zig.
const RAW = 16;
const T_UNDEF = 0, T_NULL = 1, T_BOOL = 2, T_NUM = 3, T_STR = 4, T_REF = 5, T_JSON = 6, T_CB = 7, T_BYTES = 8;
// Return modes, must match `Mode` in js.zig.
const M_HANDLE = 2, M_BYTES = 1;

const TYPE_CODE: Record<string, number> = {
    undefined: 0, boolean: 2, number: 3, string: 4, object: 5, function: 6, symbol: 7, bigint: 8,
};

type CallbackExport = (id: number, n: number, a0: number, a1: number, a2: number) => unknown;
let callbackExport: CallbackExport | undefined;
const callbacks = new Map<number, Function>();

/** Set in a callback id when the function returns the Zig result (`Callback.returns_bit`). */
const RETURNS = 0x8000_0000;

/** Binds `__zx_js_cb` for the current instance. */
export function bindCallbacks(fn: CallbackExport | undefined): void {
    callbackExport = fn;
    callbacks.clear();
}

/** Takes ownership of a handle a returning callback handed back. */
function take(h: unknown): unknown {
    if (typeof h !== "number") return undefined;
    const v = deref(h);
    unref(h);
    return v;
}

/**
 * The JS function for a Zig `Callback` id (0 = null). Cached, so identity is stable.
 * Returning callbacks give back the Zig result, as a Promise when the export is JSPI-wrapped.
 */
export function fn(id: number): Function | null {
    id >>>= 0;
    if (id === 0) return null;
    const returns = id >= RETURNS;
    let f = callbacks.get(id);
    if (f) return f;
    f = (...a: unknown[]) => {
        const h0 = ref(a[0]), h1 = ref(a[1]), h2 = ref(a[2]);
        const done = () => { unref(h0); unref(h1); unref(h2); };
        let r: unknown;
        try {
            r = callbackExport?.(id, a.length, h0, h1, h2);
        } catch (e) {
            done();
            throw e;
        }
        if (r && typeof (r as PromiseLike<unknown>).then === "function") {
            const settled = (r as PromiseLike<unknown>).then(
                (v) => { done(); return returns ? take(v) : undefined; },
                (e) => { done(); if (returns) throw e; console.error(e); },
            );
            return returns ? settled : undefined;
        }
        done();
        return returns ? take(r) : undefined;
    };
    callbacks.set(id, f);
    return f;
}

/** Zig wrapper/callback values inside JSON args arrive as `{"$h":id}` / `{"$f":id}`. */
function revive(_key: string, v: any): unknown {
    if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        if ("$h" in v) return deref(v.$h);
        if ("$f" in v) return fn(v.$f);
    }
    return v;
}

/** Reads a `Raw` slot at `p`. */
export function rawReader(mem: MemoryIO) {
    return (p: number): unknown => {
        p >>>= 0;
        const d = mem.data();
        switch (d.getUint32(p, true)) {
            case T_UNDEF: return undefined;
            case T_NULL: return null;
            case T_BOOL: return d.getUint32(p + 4, true) !== 0;
            case T_NUM: return d.getFloat64(p + 8, true);
            case T_STR: return mem.readString(d.getUint32(p + 4, true), d.getFloat64(p + 8, true));
            case T_JSON: return JSON.parse(mem.readString(d.getUint32(p + 4, true), d.getFloat64(p + 8, true)), revive);
            case T_CB: return fn(d.getUint32(p + 4, true));
            case T_BYTES: {
                const start = d.getUint32(p + 4, true);
                return mem.view().slice(start, start + d.getFloat64(p + 8, true));
            }
            default: return deref(d.getUint32(p + 4, true));
        }
    };
}

/** Writes a string result into a `{ptr, len}` slot; null/undefined set len = 0xFFFFFFFF. */
export function stringWriter(mem: MemoryIO, alloc: () => ((size: number) => number) | null) {
    return (v: unknown, out: number): void => {
        out >>>= 0;
        let ptr = 0, len = 0xFFFFFFFF;
        if (v != null) {
            const bytes = textEncoder.encode(String(v));
            len = bytes.length;
            if (len > 0) {
                ptr = alloc()!(len) >>> 0;
                mem.writeBytes(ptr, bytes);
            }
        }
        const d = mem.data();
        d.setUint32(out, ptr, true);
        d.setUint32(out + 4, len, true);
    };
}

/** Helpers the generated `__zx_web` shims close over. */
export function webHelpers(mem: MemoryIO, alloc: () => ((size: number) => number) | null) {
    const V = rawReader(mem);
    return {
        R,
        S: mem.readString,
        N: (p: number, l: number) => (l >>> 0 === 0xFFFFFFFF ? null : mem.readString(p, l)),
        H: ref,
        W: stringWriter(mem, alloc),
        F: fn,
        V,
        // Zero-copy typed-array view of wasm memory; len 0xFFFFFFFF means absent.
        T: (C: any, p: number, l: number) => {
            l >>>= 0;
            if (l === 0xFFFFFFFF) return undefined;
            p >>>= 0;
            const buffer = mem.view().buffer;
            if (C === ArrayBuffer) return buffer.slice(p, p + l);
            if (C === DataView) return new DataView(buffer, p, l);
            return new C(buffer, p, l / C.BYTES_PER_ELEMENT);
        },
        A: (p: number, n: number) => {
            p >>>= 0;
            const out = new Array(n >>> 0);
            for (let i = 0; i < out.length; i++) out[i] = V(p + i * RAW);
            return out;
        },
    };
}

export type WebHelpers = ReturnType<typeof webHelpers>;

export function createJsImports(
    mem: MemoryIO,
    alloc: () => ((size: number) => number) | null,
    exports: () => WebAssembly.Exports | null = () => null,
) {
    const readRaw = rawReader(mem);

    const readArgs = (p: number, n: number): unknown[] => {
        p >>>= 0;
        const out = new Array(n >>> 0);
        for (let i = 0; i < out.length; i++) out[i] = readRaw(p + i * RAW);
        return out;
    };

    const writeRaw = (p: number, v: unknown, mode: number): void => {
        let tag = T_REF, a = 0, n = 0;
        const t = typeof v;
        if (v === undefined) tag = T_UNDEF;
        else if (v === null) tag = T_NULL;
        else if (mode !== M_HANDLE && t === "boolean") { tag = T_BOOL; a = v ? 1 : 0; }
        else if (mode !== M_HANDLE && t === "number") { tag = T_NUM; n = v as number; }
        else if (mode !== M_HANDLE && t === "bigint") { tag = T_NUM; n = Number(v); }
        else if (mode === M_BYTES && t === "string") {
            const bytes = textEncoder.encode(v as string);
            tag = T_STR;
            n = bytes.length;
            if (n > 0) {
                a = alloc()!(n) >>> 0;
                mem.writeBytes(a, bytes);
            }
        } else {
            a = ref(v);
            n = TYPE_CODE[t] ?? 5;
        }
        // After alloc: memory may have grown.
        const d = mem.data();
        p >>>= 0;
        d.setUint32(p, tag, true);
        d.setUint32(p + 4, a, true);
        d.setFloat64(p + 8, n, true);
    };

    return {
        get(h: number, np: number, nl: number, out: number, mode: number): void {
            const o = deref(h) as any;
            writeRaw(out, o == null ? undefined : o[mem.readString(np, nl)], mode);
        },
        set(h: number, np: number, nl: number, v: number): void {
            const o = deref(h) as any;
            if (o != null) o[mem.readString(np, nl)] = readRaw(v >>> 0);
        },
        call(h: number, np: number, nl: number, args: number, n: number, out: number, mode: number): number {
            try {
                const o = deref(h) as any;
                writeRaw(out, o[mem.readString(np, nl)](...readArgs(args, n)), mode);
                return 1;
            } catch {
                writeRaw(out, undefined, mode);
                return 0;
            }
        },
        apply(f: number, self: number, args: number, n: number, out: number, mode: number): number {
            try {
                writeRaw(out, Reflect.apply(deref(f) as Function, deref(self), readArgs(args, n)), mode);
                return 1;
            } catch {
                writeRaw(out, undefined, mode);
                return 0;
            }
        },
        construct(f: number, args: number, n: number, out: number): number {
            try {
                writeRaw(out, Reflect.construct(deref(f) as Function, readArgs(args, n)), M_HANDLE);
                return 1;
            } catch {
                writeRaw(out, undefined, M_HANDLE);
                return 0;
            }
        },
        read(h: number, out: number, mode: number): void {
            writeRaw(out, deref(h), mode);
        },
        toRef(v: number): number {
            return ref(readRaw(v >>> 0));
        },
        release: unref,
        /**
         * `js.awaitValue`: settles a promise into `out` (1 = fulfilled, 0 = rejected). Returns a
         * Promise for pending ones, so the import must be JSPI-suspending (see `ZxBridgeCore`).
         */
        awaitValue(h: number, out: number): number | Promise<number> {
            const v = deref(h) as PromiseLike<unknown> | undefined;
            if (!v || typeof v.then !== "function") {
                writeRaw(out, v, M_HANDLE);
                return 1;
            }
            return Promise.resolve(v).then(
                (value) => { writeRaw(out, value, M_HANDLE); return 1; },
                (reason) => { writeRaw(out, reason, M_HANDLE); return 0; },
            );
        },
        /** This instance's exports, e.g. to hand `export fn`s to another module as imports. */
        exports(): number {
            return ref(exports() ?? undefined);
        },
        bytes(h: number, ptr: number, len: number): number {
            const v = deref(h);
            const src = v instanceof ArrayBuffer
                ? new Uint8Array(v)
                : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : null;
            if (!src) return 0;
            const n = Math.min(src.length, len >>> 0);
            if (n > 0) mem.view().set(src.subarray(0, n), ptr >>> 0);
            return src.length;
        },
    };
}
