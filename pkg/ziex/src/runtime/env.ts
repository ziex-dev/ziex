import { type WasmAllocRef, textDecoder, writeJsonOut } from "../wasm/core";
import type { Handlers } from "./host";

/** No such binding or method on `env`. */
const missing = -2;

/**
 * Host op `env_call`: calls `env[binding][method](...args)` with JSON-encoded
 * arguments, awaits it and writes the result as JSON. Lets the guest use any
 * Worker binding (Flagship, Queues, ...) without a dedicated import.
 */
export function createEnvHandlers(
    getEnv: () => unknown,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): Handlers {
    const readStr = (ptr: number, len: number): string =>
        len === 0 ? "" : textDecoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));

    const write = (out: number, value: unknown): number => writeJsonOut(getMemory, allocRef, out, value ?? null);
    const fail = (name: string, method: string, err: unknown): number => {
        console.error(`zx: env.${name}.${method} failed:`, err);
        return -1;
    };

    return {
        env_call: (name_ptr, name_len, method_ptr, method_len, args_ptr, args_len, out) => {
            const name = readStr(name_ptr, name_len);
            const method = readStr(method_ptr, method_len);
            const target = (getEnv() as Record<string, any> | undefined)?.[name];
            const fn = target?.[method];
            if (typeof fn !== "function") return missing;

            try {
                const args = args_len > 0 ? JSON.parse(readStr(args_ptr, args_len)) : [];
                // Call through `target`: on RPC stubs `fn.apply` is itself a remote method.
                const result = target[method](...(Array.isArray(args) ? args : [args]));
                // RPC bindings return thenables, not native promises.
                if (typeof result?.then !== "function") return write(out, result);
                return Promise.resolve(result).then((value) => write(out, value), (err) => fail(name, method, err));
            } catch (err) {
                return fail(name, method, err);
            }
        },
    };
}
