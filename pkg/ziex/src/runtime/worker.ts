import { writeBytesOut, type WasmAllocRef } from "../wasm/core";
import { ZxBridgeCore, wrapPromisingExport } from "../wasm/core";
import { createWorkerFsHandlers, WorkerFs } from "./fs_worker";
import { hasJspi } from "./jspi";
import { unsupported, type Handlers } from "./host";

// `zx.worker(M)` calls: the page sends encoded arguments to a Worker running M's wasm
// (`zx.Worker.serve`) and suspends until it replies. One Worker per wasm URL, started
// on first call and shared by every page; the Worker runs this same script.

type Request = { id: number; fn: number; args: ArrayBuffer };
type Reply = { id: number; reply?: ArrayBuffer; error?: string };
type Init = { init: string };

class WorkerClient {
    private worker: Worker;
    private pending = new Map<number, (reply: Uint8Array | number) => void>();
    private nextId = 1;

    constructor(scriptUrl: string, wasmUrl: string) {
        // A blob entry lets the bindings come from another origin; they start `runWorker` themselves.
        const source = `importScripts(${JSON.stringify(scriptUrl)});`;
        this.worker = new Worker(URL.createObjectURL(new Blob([source], { type: "text/javascript" })));
        this.worker.onmessage = ({ data }: MessageEvent<Reply>) => {
            const resolve = this.pending.get(data.id);
            if (!resolve) return;
            this.pending.delete(data.id);
            if (data.error) console.error(`zx: worker ${wasmUrl}: ${data.error}`);
            resolve(data.reply ? new Uint8Array(data.reply) : -1);
        };
        this.worker.onerror = (event) => {
            console.error(`zx: worker ${wasmUrl} failed:`, event.message);
            for (const resolve of this.pending.values()) resolve(unsupported);
            this.pending.clear();
        };
        this.worker.postMessage({ init: wasmUrl } satisfies Init);
    }

    call(fn: number, args: Uint8Array): Promise<Uint8Array | number> {
        const id = this.nextId++;
        const copy = args.slice();
        return new Promise((resolve) => {
            this.pending.set(id, resolve);
            this.worker.postMessage({ id, fn, args: copy.buffer } satisfies Request, [copy.buffer]);
        });
    }
}

export function createWorkerHandlers(getMemory: () => WebAssembly.Memory, allocRef: WasmAllocRef, scriptUrl: string | undefined): Handlers {
    const workers = new Map<string, WorkerClient>();
    const decoder = new TextDecoder();
    return {
        worker_call: (urlPtr, urlLen, fn, argsPtr, argsLen, out) => {
            if (!hasJspi || typeof Worker === "undefined") return unsupported;
            if (!scriptUrl) {
                console.error("zx: zx.worker needs the bindings script URL (InitOptions.workerScript)");
                return unsupported;
            }
            const url = new URL(decoder.decode(new Uint8Array(getMemory().buffer, urlPtr >>> 0, urlLen >>> 0)), location.href).href;
            let client = workers.get(url);
            if (!client) {
                client = new WorkerClient(scriptUrl, url);
                workers.set(url, client);
            }
            const args = new Uint8Array(getMemory().buffer, argsPtr >>> 0, argsLen >>> 0);
            return client.call(fn, args).then((reply) =>
                typeof reply === "number" ? reply : writeBytesOut(getMemory, allocRef, out, reply));
        },
    };
}

type WorkerExports = {
    memory: WebAssembly.Memory;
    __zx_alloc(size: number): number;
    __zx_free(ptr: number, size: number): void;
    __zx_worker_init(): number | Promise<number>;
    __zx_worker_call(fn: number, ptr: number, len: number, out: number): number | Promise<number>;
};

// Worker side: instantiate the wasm from the first message, then serve calls in order.
type WorkerScope = {
    onmessage: ((event: MessageEvent<Init | Request>) => void) | null;
    postMessage(message: Reply, transfer?: Transferable[]): void;
};

export function runWorker(scope: WorkerScope): void {
    let ready: Promise<WorkerExports> | null = null;
    let queue: Promise<unknown> = Promise.resolve();

    scope.onmessage = ({ data }: MessageEvent<Init | Request>) => {
        if ("init" in data) {
            ready = start(data.init);
            ready.catch((err) => setTimeout(() => { throw err; }));
            return;
        }
        const request = data;
        queue = queue.then(async () => {
            try {
                const ex = await ready!;
                scope.postMessage(...reply(request.id, await serveCall(ex, request)));
            } catch (err) {
                scope.postMessage({ id: request.id, error: String(err) } satisfies Reply);
            }
        });
    };
}

function reply(id: number, bytes: Uint8Array | null): [Reply, Transferable[]] {
    if (!bytes) return [{ id }, []];
    return [{ id, reply: bytes.buffer as ArrayBuffer }, [bytes.buffer as ArrayBuffer]];
}

async function start(url: string): Promise<WorkerExports> {
    let memory: WebAssembly.Memory;
    const getMemory = () => memory;
    const handlers: Handlers = createWorkerFsHandlers(new WorkerFs(), getMemory);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`zx: worker wasm ${url}: HTTP ${response.status}`);
    const module = response.headers.get("content-type")?.startsWith("application/wasm")
        ? await WebAssembly.compileStreaming(response)
        : await WebAssembly.compile(await response.arrayBuffer());

    const bridgeRef: [ZxBridgeCore | null] = [null];
    const imports = ZxBridgeCore.createImportObject(bridgeRef, handlers) as unknown as WebAssembly.Imports;
    // DOM bindings don't exist in a Worker.
    const web: Record<string, Function> = {};
    for (const imp of WebAssembly.Module.imports(module)) {
        if (imp.module !== "__zx_web") continue;
        web[imp.name] = () => {
            throw new Error(`zx: "${imp.name}" is not available in a worker`);
        };
    }
    imports.__zx_web = web;

    const instance = await WebAssembly.instantiate(module, imports);
    const raw = instance.exports as unknown as WorkerExports;
    memory = raw.memory;
    bridgeRef[0] = new ZxBridgeCore(instance.exports);
    const ex: WorkerExports = {
        ...raw,
        __zx_worker_init: wrapPromisingExport(raw.__zx_worker_init)!,
        __zx_worker_call: wrapPromisingExport(raw.__zx_worker_call)!,
    };
    if ((await ex.__zx_worker_init()) < 0) throw new Error(`zx: worker ${url}: init failed`);
    return ex;
}

async function serveCall(ex: WorkerExports, request: Request): Promise<Uint8Array | null> {
    const len = request.args.byteLength;
    const argsPtr = len > 0 ? ex.__zx_alloc(len) >>> 0 : 0;
    if (len > 0) new Uint8Array(ex.memory.buffer, argsPtr, len).set(new Uint8Array(request.args));
    const outPtr = ex.__zx_alloc(4) >>> 0;
    try {
        const n = await ex.__zx_worker_call(request.fn, argsPtr, len, outPtr);
        if (n < 0) return null;
        const replyPtr = new DataView(ex.memory.buffer).getUint32(outPtr, true);
        const bytes = new Uint8Array(ex.memory.buffer, replyPtr, n).slice();
        ex.__zx_free(replyPtr, n);
        return bytes;
    } finally {
        if (len > 0) ex.__zx_free(argsPtr, len);
        ex.__zx_free(outPtr, 4);
    }
}
