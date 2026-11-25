/** Raw bytes accepted and returned by KV bindings (Cloudflare KV takes the same). */
export type KVBytes = ArrayBuffer | ArrayBufferView;

/** Text when the value is valid UTF-8, raw bytes otherwise. */
export type KVValue = string | KVBytes;

export type PutOptions = {
    /** Absolute expiry, Unix seconds. */
    expiration?: number;
    /** Relative expiry, seconds from now. */
    expirationTtl?: number;
};

export function expiresAt(options?: PutOptions): number | undefined {
    if (options?.expiration !== undefined) return options.expiration * 1000;
    if (options?.expirationTtl !== undefined) return Date.now() + options.expirationTtl * 1000;
    return undefined;
}

export function isExpired(at: number | undefined): boolean {
    return at !== undefined && Date.now() >= at;
}

// Always a copy, so it never aliases wasm memory.
export function toBytes(value: KVValue): Uint8Array {
    if (typeof value === "string") return new TextEncoder().encode(value);
    if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
    return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
}

export function own(value: KVValue): string | Uint8Array {
    return typeof value === "string" ? value : toBytes(value);
}

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

// Text only when it round-trips exactly (fatal decode, BOM kept).
export function textOrBytes(bytes: Uint8Array): string | Uint8Array {
    try {
        return utf8.decode(bytes);
    } catch {
        return bytes;
    }
}

export function bytesToBinaryString(bytes: Uint8Array): string {
    let out = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
        out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000) as unknown as number[]);
    }
    return out;
}

export function binaryStringToBytes(s: string): Uint8Array {
    const bytes = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i += 1) bytes[i] = s.charCodeAt(i);
    return bytes;
}
