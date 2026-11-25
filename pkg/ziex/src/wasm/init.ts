import { init } from "./index";
import { runWorker } from "../runtime/worker";

// Loaded as a classic script (no `import.meta` or exports). It is also the entry of
// `zx.worker` Workers, which load it with `importScripts`.
if (typeof document !== "undefined") {
    init({ workerScript: (document.currentScript as HTMLScriptElement | null)?.src });
} else if (typeof (globalThis as { importScripts?: unknown }).importScripts === "function") {
    runWorker(globalThis as unknown as Parameters<typeof runWorker>[0]);
}
