import { ZxWasiBridge } from "../wasm/wasi";
import { bindWasmAlloc, type WasmAllocRef } from "../wasm/core";
import { createFetchImports } from "./fetch";
import { createKVImports } from "./kv/extern";
import { createDbImports } from "./db/extern";
import { createWasiImports, ProcExit, type WASI } from "./wasi";
import { buildHttpImports, type HttpState } from "./http";
import { buildWsImports, type WsState } from "./ws";
import { Suspending } from "./jspi";
import { get, put, del, list } from "./kv/memory";
import type { KVNamespace } from "./kv";
import type { Database } from "./db";

export type ImportsFactory = (mem: () => WebAssembly.Memory) => WebAssembly.Imports;

export type Bindings = {
    env?: unknown;
    kv: Record<string, KVNamespace>;
    db: Record<string, Database>;
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

function buildSysImports(onPark?: () => void): WebAssembly.ModuleImports {
    if (!Suspending) {
        return {
            sleep_ms: (_ms: number) => {},
            park: () => { throw new Error("park requires WebAssembly JSPI"); },
        };
    }
    return {
        sleep_ms: new Suspending(async (ms: number) => new Promise<void>((r) => setTimeout(r, ms))),
        // Never resolves: the parked instance serves via `__zx_serve`.
        park: new Suspending(() => {
            onPark?.();
            return new Promise<void>(() => {});
        }),
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

    const importObject: WebAssembly.Imports = {
        wasi_snapshot_preview1: { ...opts.wasi?.wasiImport, ...wasiImport },
        __zx_sys: buildSysImports(opts.onPark),
        __zx_ws: buildWsImports(memory, opts.ws),
        __zx_http: buildHttpImports(memory, opts.http),
        __zx_net: createFetchImports(memory),
        ...opts.imports?.(memory),
        ...ZxWasiBridge.createImportObject(bridgeRef),
    };
    if (typeof __FEAT_KV_SERVER__ === "undefined" || __FEAT_KV_SERVER__) {
        importObject.__zx_kv = createKVImports(opts.kv, memory, allocRef);
    }
    if (typeof __FEAT_DB__ === "undefined" || __FEAT_DB__) {
        importObject.__zx_db = createDbImports(opts.db, memory, allocRef);
    }

    const instance = new WebAssembly.Instance(opts.module, importObject);
    wasmMemory = instance.exports.memory as WebAssembly.Memory;
    setMemory(wasmMemory);
    bridgeRef[0] = new ZxWasiBridge(instance.exports);
    bindWasmAlloc(allocRef, instance.exports);
    return { instance, memory, setRequest };
}
