/** Shared encoder/decoder - avoids allocating new instances on every call. */
export const textDecoder = new TextDecoder();
export const textEncoder = new TextEncoder();

export type MemoryIO = {
    view(): Uint8Array;
    data(): DataView;
    readString(ptr: number, len: number): string;
    writeBytes(ptr: number, data: Uint8Array): void;
};

/** Cached views over a wasm memory; refreshed when the buffer grows. */
export function memoryIO(getMemory: () => WebAssembly.Memory | null | undefined): MemoryIO {
    let buffer: ArrayBufferLike | null = null;
    let u8: Uint8Array = new Uint8Array(0);
    let dv: DataView = new DataView(new ArrayBuffer(0));

    const refresh = () => {
        const buf = getMemory()?.buffer;
        if (!buf) throw new Error("WASM memory is not ready");
        if (buf !== buffer) {
            buffer = buf;
            u8 = new Uint8Array(buf);
            dv = new DataView(buf);
        }
    };

    return {
        view() {
            refresh();
            return u8;
        },
        data() {
            refresh();
            return dv;
        },
        // ptr/len are u32; wasm i32 arrives signed.
        readString(ptr, len) {
            const start = ptr >>> 0;
            const length = len >>> 0;
            if (length === 0) return "";
            refresh();
            if (start + length > u8.byteLength) return "";
            return textDecoder.decode(u8.subarray(start, start + length));
        },
        writeBytes(ptr, data) {
            const start = ptr >>> 0;
            refresh();
            if (start + data.length > u8.byteLength) return;
            u8.set(data, start);
        },
    };
}

export function logMessage(level: number, msg: string): void {
    switch (level) {
        case 0: console.error(msg); break;
        case 1: console.warn(msg); break;
        case 3: console.debug(msg); break;
        default: console.log(msg); break;
    }
}
