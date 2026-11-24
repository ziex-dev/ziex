/**
 * WASI/edge WASM bridge - no browser globals and no `__zx_js` interop.
 * Each instance owns its memory, so several can run side by side.
 */
import { BaseBridge, baseImports, type CallbackHandler } from "./base";
import { memoryIO } from "./mem";

export class ZxWasiBridge extends BaseBridge {
    constructor(exports: WebAssembly.Exports) {
        const memory = exports.memory as WebAssembly.Memory;
        super(
            memoryIO(() => memory),
            exports.__zx_alloc as (size: number) => number,
            exports.__zx_cb as CallbackHandler | undefined,
        );
    }

    /** Only the `__zx` namespace (log, fetch, timers). */
    static createImportObject(bridgeRef: [ZxWasiBridge | null]) {
        return { __zx: baseImports(bridgeRef) };
    }
}
