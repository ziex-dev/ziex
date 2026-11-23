import { Suspending } from "./jspi";
import { i64, type Handlers } from "./host";

/** Host ops backing `zx.Io.Web`: clocks, entropy and sleep. */
export function createIoHandlers(getMemory: () => WebAssembly.Memory): Handlers {
    // `getRandomValues` fills at most 64 KiB per call.
    const maxRandomChunk = 65536;
    let warnedSleep = false;

    const sleepSync = (ms: number): void => {
        if (!warnedSleep) {
            warnedSleep = true;
            console.warn("zx.Io.Web: sleep without JSPI blocks the page");
        }
        if (ms < 0) return;
        const end = performance.now() + ms;
        while (performance.now() < end) { /* busy-wait */ }
    };

    const sleepAsync = (ms: number): Promise<void> =>
        new Promise((resolve) => { if (ms >= 0) setTimeout(resolve, ms); });

    const nowNs = (source: number): bigint => {
        const ms = source === 0 ? performance.timeOrigin + performance.now() : performance.now();
        const whole = Math.floor(ms);
        return BigInt(whole) * 1_000_000n + BigInt(Math.round((ms - whole) * 1e6));
    };
    const writeI64 = (ptr: number, value: bigint): void => {
        new DataView(getMemory().buffer).setBigInt64(ptr >>> 0, value, true);
    };

    return {
        io_now: (source, out) => writeI64(out, nowNs(source)),
        io_resolution: (out) => writeI64(out, (globalThis as any).crossOriginIsolated ? 5_000n : 100_000n),
        // Negative waits forever.
        io_sleep: (lo, hi) => {
            const ns = i64(lo, hi);
            const ms = ns < 0 ? -1 : ns / 1e6;
            return Suspending ? sleepAsync(ms) : sleepSync(ms);
        },
        io_random: (ptr, len) => {
            const bytes = new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);
            const crypto = globalThis.crypto;
            if (!crypto?.getRandomValues) {
                for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
                return 0;
            }
            for (let off = 0; off < bytes.length; off += maxRandomChunk) {
                crypto.getRandomValues(bytes.subarray(off, off + maxRandomChunk));
            }
            return 1;
        },
    };
}
