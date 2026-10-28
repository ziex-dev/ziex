import { WASI, PreopenDirectory, OpenFile, File, ConsoleStdout, WASIProcExit } from "@bjorn3/browser_wasi_shim";

function asUint8Array(data: unknown): Uint8Array {
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) {
        return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    }
    throw new Error(`expected wasm bytes, got ${Object.prototype.toString.call(data)}`);
}

function readU32LEB(bytes: Uint8Array, offset: { i: number }): number {
    let result = 0;
    let shift = 0;
    while (true) {
        const byte = bytes[offset.i++]!;
        result |= (byte & 0x7f) << shift;
        if ((byte & 0x80) === 0) break;
        shift += 7;
    }
    return result >>> 0;
}

function stripWasmStartSection(bytes: Uint8Array): Uint8Array {
    if (bytes.byteLength < 8) return bytes;
    const out = [bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!, bytes[4]!, bytes[5]!, bytes[6]!, bytes[7]!];
    const pos = { i: 8 };
    let stripped = false;
    while (pos.i < bytes.byteLength) {
        const idStart = pos.i;
        const id = bytes[pos.i++]!;
        const size = readU32LEB(bytes, pos);
        const payloadStart = pos.i;
        const payloadEnd = payloadStart + size;
        if (payloadEnd > bytes.byteLength) {
            return bytes;
        }
        if (id === 8) {
            stripped = true;
        } else {
            for (let i = idStart; i < payloadEnd; i++) out.push(bytes[i]!);
        }
        pos.i = payloadEnd;
    }
    return stripped ? new Uint8Array(out) : bytes;
}

function stubHttpImports(getMemory: () => WebAssembly.Memory | null, sink: {
    html: { value: string };
    meta: { value: ResponseMeta | null };
}) {
    const decoder = new TextDecoder("utf-8", { fatal: false });
    const htmlDec = new TextDecoder("utf-8", { fatal: false });
    return {
        commit: (status: number, meta_ptr: number, meta_len: number) => {
            const mem = getMemory();
            let streaming = false;
            let headers: [string, string][] = [];
            if (mem && meta_len > 0) {
                try {
                    const raw = decoder.decode(new Uint8Array(mem.buffer, meta_ptr >>> 0, meta_len >>> 0));
                    const parsed = JSON.parse(raw) as { streaming?: boolean; headers?: [string, string][] };
                    streaming = parsed.streaming === true;
                    if (Array.isArray(parsed.headers)) headers = parsed.headers;
                } catch {
                    // ignore
                }
            }
            sink.meta.value = { status, streaming, headers };
        },
        write: (ptr: number, len: number) => {
            const mem = getMemory();
            if (!mem || len <= 0) return;
            sink.html.value += htmlDec.decode(new Uint8Array(mem.buffer, ptr >>> 0, len >>> 0), { stream: true });
        },
        end: () => {
            sink.html.value += htmlDec.decode();
        },
    };
}

function noopWsImports() {
    return {
        upgrade: () => {},
        write: () => {},
        close: () => {},
        recv: () => -1,
        subscribe: () => {},
        unsubscribe: () => {},
        publish: () => 0,
        is_subscribed: () => 0,
    };
}

function stubKvImports() {
    return {
        get: () => -1,
        put: () => 0,
        delete: () => 0,
        list: () => 0,
    };
}

function stubDbImports() {
    return {
        open: () => -1,
        run: () => -1,
        get: () => -1,
        all: () => -1,
        values: () => -1,
    };
}

function stubNetImports() {
    return {
        fetch: () => -1,
        take: () => {},
    };
}

function stubSysImports() {
    return {
        sleep_ms: (_ms: number) => {},
        park: () => {
            throw new Error("park is not supported in the playground");
        },
    };
}

type ResponseMeta = {
    status?: number;
    headers?: [string, string][];
    streaming?: boolean;
};

function createZxImports(getMemory: () => WebAssembly.Memory | null) {
    const decoder = new TextDecoder("utf-8", { fatal: false });
    return {
        _log: (_level: number, ptr: number, len: number) => {
            const mem = getMemory();
            if (!mem || len <= 0) return;
            const msg = decoder.decode(new Uint8Array(mem.buffer, ptr >>> 0, len >>> 0));
            if (msg) postMessage({ stderr: msg });
        },
        _fetchAsync: () => {},
        _setTimeout: () => {},
        _setInterval: () => {},
        _clearInterval: () => {},
    };
}

async function run(wasmData: unknown, kind: "playground" | "app", opts: {
    pathname?: string;
    search?: string;
    method?: string;
    url?: string;
} = {}) {
    let bytes: Uint8Array;
    try {
        bytes = asUint8Array(wasmData);
    } catch (err) {
        postMessage({ stderr: `${err}` });
        postMessage({ done: true, failed: true });
        return;
    }

    if (bytes.byteLength < 8 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
        postMessage({
            stderr: `invalid wasm magic (len=${bytes.byteLength}, head=${[...bytes.slice(0, 8)].join(",")})`,
        });
        postMessage({ done: true, failed: true });
        return;
    }

    bytes = stripWasmStartSection(bytes);

    const pathname = opts.pathname && opts.pathname.length > 0 ? opts.pathname : "/";
    const search = opts.search ?? "";
    const method = opts.method ?? "GET";
    const url = opts.url ?? `https://playground.local${pathname}${search}`;

    const args = kind === "app"
        ? [
            "ziex_ssr.wasm",
            "--pathname", pathname,
            "--method", method,
            "--search", search,
            "--url", url,
        ]
        : ["main.wasm"];

    let html = { value: "" };
    let responseMeta: { value: ResponseMeta | null } = { value: null };
    let wasmMemory: WebAssembly.Memory | null = null;
    const htmlDec = new TextDecoder("utf-8", { fatal: false });

    const fds = [
        new OpenFile(new File([])),
        new ConsoleStdout((buffer) => {
            // playground (non-app) still prints via stdout
            if (kind !== "app") html.value += htmlDec.decode(buffer, { stream: true });
        }),
        new ConsoleStdout((buffer) => {
            const text = new TextDecoder("utf-8", { fatal: false }).decode(buffer, { stream: true });
            for (const line of text.split("\n")) {
                if (line.length > 0) postMessage({ stderr: line });
            }
        }),
        new PreopenDirectory(".", new Map([])),
    ];
    const wasi = new WASI(args, [], fds);

    try {
        const module = await WebAssembly.compile(bytes);
        const imports: WebAssembly.Imports = {
            wasi_snapshot_preview1: wasi.wasiImport,
        };
        if (kind === "app") {
            Object.assign(imports, {
                __zx: createZxImports(() => wasmMemory),
                __zx_ws: noopWsImports(),
                __zx_sys: stubSysImports(),
                __zx_http: stubHttpImports(() => wasmMemory, { html, meta: responseMeta }),
                __zx_kv: stubKvImports(),
                __zx_db: stubDbImports(),
                __zx_net: stubNetImports(),
            });
        }

        const instance = new WebAssembly.Instance(module, imports);

        wasmMemory = instance.exports.memory as WebAssembly.Memory | null;
        (wasi as { inst?: WebAssembly.Instance }).inst = instance;
        const ctors = instance.exports.__wasm_call_ctors as (() => void) | undefined;
        if (typeof ctors === "function") ctors();

        const startFn = instance.exports._start as (() => void) | undefined;
        if (typeof startFn !== "function") {
            const exportNames = Object.keys(instance.exports).slice(0, 40).join(",");
            throw new Error(`wasm has no _start export (exports: ${exportNames})`);
        }

        try {
            wasi.start(instance);
        } catch (e) {
            if (!(e instanceof WASIProcExit)) throw e;
        }

        if (kind !== "app") html.value += htmlDec.decode();
    } catch (err) {
        const base = err instanceof Error ? `${err.name}: ${err.message}` : `${err}`;
        postMessage({ stderr: base });
        postMessage({ done: true, failed: true });
        return;
    }

    postMessage({
        preview: html.value,
        meta: responseMeta.value,
        done: true,
    });
}

// Runs a plain WASI program (zig run / zig test), streaming its output
async function runProgram(wasm: Uint8Array, args: string[]) {
    const dec = new TextDecoder("utf-8", { fatal: false });
    const sink = () => new ConsoleStdout((buffer) => {
        postMessage({ out: dec.decode(buffer, { stream: true }) });
    });
    const wasi = new WASI(args, [], [
        new OpenFile(new File([])),
        sink(),
        sink(),
        new PreopenDirectory(".", new Map()),
    ]);
    let exitCode = 0;
    try {
        const module = await WebAssembly.compile(wasm);
        const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
        // @ts-ignore
        exitCode = wasi.start(instance) ?? 0;
    } catch (err) {
        if (err instanceof WASIProcExit) exitCode = err.code;
        else {
            postMessage({ out: `${err instanceof Error ? `${err.name}: ${err.message}` : err}\n` });
            exitCode = 1;
        }
    }
    postMessage({ exit: exitCode });
}

onmessage = (event) => {
    if (event.data?.program) {
        void runProgram(event.data.program.wasm, event.data.program.args);
        return;
    }
    try {
        if (event.data?.run == null) return;
        const payload = event.data.run;
        if (payload && typeof payload === "object" && "ssrWasm" in payload) {
            void run(payload.ssrWasm, "app", {
                pathname: typeof payload.pathname === "string" ? payload.pathname : "/",
                search: typeof payload.search === "string" ? payload.search : "",
                method: typeof payload.method === "string" ? payload.method : "GET",
                url: typeof payload.url === "string" ? payload.url : undefined,
            });
        } else {
            void run(payload, "playground");
        }
    } catch (err) {
        postMessage({ stderr: `runner onmessage: ${err}` });
        postMessage({ done: true, failed: true });
    }
};
