import { ZxWasiBridge } from "../wasm/wasi";
import { bindWasmAlloc, type WasmAllocRef } from "../wasm/core";
import { createFetchHandlers } from "./fetch";
import { createIoHandlers } from "./io";
import { createKvHandlers } from "./kv/extern";
import { createDbHandlers } from "./db/extern";
import { createEnvHandlers } from "./env";
import { createEmailHandlers, type EmailBinding } from "./email";
import { createHostImports, type Handlers } from "./host";
import { createWasiImports, ProcExit, type WASI } from "./wasi";
import { createHttpHandlers, type HttpState } from "./http";
import { createWsHandlers, type WsState } from "./ws";
import { Suspending } from "./jspi";
import { get, put, del, list } from "./kv/memory";
import type { KVNamespace } from "./kv";
import type { Database } from "./db";

export type ImportsFactory = (mem: () => WebAssembly.Memory) => WebAssembly.Imports;

export type Bindings = {
    env?: unknown;
    kv: Record<string, KVNamespace>;
    db: Record<string, Database>;
    email?: Record<string, EmailBinding>;
    imports?: ImportsFactory;
    wasi?: WASI;
};

export function defaultKV(): Record<string, KVNamespace> {
    return { default: { get, put, del, list } };
}

// proc_exit is a normal guest exit.
export function isProcExit(e: unknown): boolean {
    return e instanceof ProcExit || (e instanceof Error && e.message.startsWith("proc_exit"));
}

function createSysHandlers(onPark?: () => void): Handlers {
    return {
        // Never resolves: the parked instance serves via `__zx_serve`.
        sys_park: () => {
            if (!Suspending) throw new Error("park requires WebAssembly JSPI");
            onPark?.();
            return new Promise<void>(() => {});
        },
    };
}

export type InstantiateOptions = Bindings & {
    module: WebAssembly.Module;
    request: Request;
    stdinData?: Uint8Array;
    http: HttpState;
    ws: WsState;
    extraArgs?: string[];
    onPark?: () => void;
    // Read per call so a reused instance sees the current request's env.
    getEnv?: () => unknown;
};

export type Instance = {
    instance: WebAssembly.Instance;
    memory: () => WebAssembly.Memory;
    setRequest: (request: Request, stdin?: Uint8Array) => void;
};

export function instantiate(opts: InstantiateOptions): Instance {
    const { wasiImport, setMemory, setRequest } = createWasiImports({
        request: opts.request,
        stdinData: opts.stdinData,
        extraArgs: opts.extraArgs,
        env: opts.env,
    });

    let wasmMemory: WebAssembly.Memory = null!;
    const memory = () => wasmMemory;
    const bridgeRef: [ZxWasiBridge | null] = [null];
    const allocRef: WasmAllocRef = [null];

    const handlers: Handlers = {
        ...createSysHandlers(opts.onPark),
        ...createIoHandlers(memory),
        ...createWsHandlers(memory, opts.ws),
        ...createHttpHandlers(memory, opts.http),
        ...createFetchHandlers(memory),
        ...createEnvHandlers(opts.getEnv ?? (() => opts.env), memory, allocRef),
        ...createEmailHandlers(opts.email, memory, allocRef),
    };
    if (typeof __FEAT_KV_SERVER__ === "undefined" || __FEAT_KV_SERVER__) {
        Object.assign(handlers, createKvHandlers(opts.kv, memory, allocRef));
    }
    if (typeof __FEAT_DB__ === "undefined" || __FEAT_DB__) {
        Object.assign(handlers, createDbHandlers(opts.db, memory, allocRef));
    }

    const bridge = ZxWasiBridge.createImportObject(bridgeRef);
    const importObject: WebAssembly.Imports = {
        wasi_snapshot_preview1: { ...opts.wasi?.wasiImport, ...wasiImport },
        ...opts.imports?.(memory),
        ...bridge,
        __zx: { ...bridge.__zx, ...createHostImports(handlers) },
    };

    const instance = new WebAssembly.Instance(opts.module, importObject);
    wasmMemory = instance.exports.memory as WebAssembly.Memory;
    setMemory(wasmMemory);
    bridgeRef[0] = new ZxWasiBridge(instance.exports);
    bindWasmAlloc(allocRef, instance.exports);
    return { instance, memory, setRequest };
}
