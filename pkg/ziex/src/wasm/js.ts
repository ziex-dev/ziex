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
const T_UNDEF = 0, T_NULL = 1, T_BOOL = 2, T_NUM = 3, T_STR = 4, T_REF = 5;
// Return modes, must match `Mode` in js.zig.
const M_HANDLE = 2, M_BYTES = 1;

const TYPE_CODE: Record<string, number> = {
    undefined: 0, boolean: 2, number: 3, string: 4, object: 5, function: 6, symbol: 7, bigint: 8,
};

export function createJsImports(mem: MemoryIO, alloc: () => ((size: number) => number) | null) {
    const readRaw = (p: number): unknown => {
        const d = mem.data();
        switch (d.getUint32(p, true)) {
            case T_UNDEF: return undefined;
            case T_NULL: return null;
            case T_BOOL: return d.getUint32(p + 4, true) !== 0;
            case T_NUM: return d.getFloat64(p + 8, true);
            case T_STR: return mem.readString(d.getUint32(p + 4, true), d.getFloat64(p + 8, true));
            default: return deref(d.getUint32(p + 4, true));
        }
    };

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
    };
}
