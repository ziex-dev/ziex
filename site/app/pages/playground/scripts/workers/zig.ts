import { WASI, PreopenDirectory, Fd, File, OpenFile, Directory, Inode, ConsoleStdout, wasi as wasi_defs } from "@bjorn3/browser_wasi_shim";
import { getLatestZigArchive, getZxArchive, stderrOutput, fetchWithCache } from "../utils";
import { nestPaths, flattenDirectory } from "../csr";
import { buildWebGlue } from "../webglue";

declare const ZIG_VERSION: string;

let currentlyRunning = false;
let compiledModule: WebAssembly.Module | null = null;

let cacheContents: Map<string, Inode> | null = null;
let cachesReady: Promise<void> | null = null;

type CompileMode = "playground" | "app";
type CompileKind = "ssr" | "client";

function convertTree(node: Map<string, Map<string, unknown> | Uint8Array>): Directory {
    return new Directory(
        [...node.entries()].map(([key, value]) => {
            if (value instanceof Uint8Array) {
                return [key, new File(value)];
            }
            return [key, convertTree(value as Map<string, Map<string, unknown> | Uint8Array>)];
        }),
    );
}

const IDB_NAME = `ziex-zig-cache-${ZIG_VERSION}`;
const IDB_STORE = "files";

function openCacheDb(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
        const req = indexedDB.open(IDB_NAME, 1);
        req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(IDB_STORE)) {
                db.createObjectStore(IDB_STORE);
            }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error("indexedDB.open failed"));
    });
}

function idbReq<T>(req: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error("indexedDB request failed"));
    });
}

/** Flatten Directory tree to path → bytes (skips tmp/). */
function flattenCache(contents: Map<string, Inode>, prefix = ""): Array<[string, ArrayBuffer]> {
    const out: Array<[string, ArrayBuffer]> = [];
    for (const [name, inode] of contents.entries()) {
        if (name === "tmp") continue;
        const path = prefix ? `${prefix}/${name}` : name;
        if (inode instanceof Directory) {
            out.push(...flattenCache(inode.contents, path));
        } else if (inode instanceof File) {
            const bytes = inode.data;
            const buf = new ArrayBuffer(bytes.byteLength);
            new Uint8Array(buf).set(bytes);
            out.push([path, buf]);
        }
    }
    return out;
}

/** Rebuild Directory map from flat path -> bytes. */
function unflattenCache(entries: Array<[string, ArrayBuffer]>): Map<string, Inode> {
    const root = new Map<string, Inode>();
    for (const [path, buf] of entries) {
        const parts = path.split("/");
        let cur = root;
        for (let i = 0; i < parts.length - 1; i++) {
            const seg = parts[i]!;
            let next = cur.get(seg);
            if (!(next instanceof Directory)) {
                next = new Directory(new Map());
                cur.set(seg, next);
            }
            cur = next.contents;
        }
        cur.set(parts[parts.length - 1]!, new File(new Uint8Array(buf)));
    }
    return root;
}

async function loadCacheMap(): Promise<Map<string, Inode>> {
    try {
        const db = await openCacheDb();
        const tx = db.transaction(IDB_STORE, "readonly");
        const store = tx.objectStore(IDB_STORE);
        // Support both current keys and legacy `global/` / `local/` prefixes.
        const [keys, values] = await Promise.all([
            idbReq(store.getAllKeys()),
            idbReq(store.getAll()),
        ]);
        db.close();

        const entries: Array<[string, ArrayBuffer]> = [];
        for (let i = 0; i < keys.length; i++) {
            const key = keys[i];
            const value = values[i];
            if (typeof key !== "string" || !(value instanceof ArrayBuffer)) continue;
            const path = key.startsWith("global/")
                ? key.slice("global/".length)
                : key.startsWith("local/")
                  ? key.slice("local/".length)
                  : key;
            if (!path) continue;
            entries.push([path, value]);
        }
        return unflattenCache(entries);
    } catch {
        return new Map();
    }
}

async function saveCacheMap(contents: Map<string, Inode>): Promise<void> {
    try {
        const db = await openCacheDb();
        const flat = flattenCache(contents);

        const tx = db.transaction(IDB_STORE, "readwrite");
        const store = tx.objectStore(IDB_STORE);
        store.clear();
        for (const [path, buf] of flat) {
            store.put(buf, path);
        }
        await new Promise<void>((resolve, reject) => {
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error ?? new Error("idb write failed"));
        });
        db.close();
    } catch {
        // Persistence is best-effort; in-memory cache still works for the session.
    }
}

async function ensureZigCache(): Promise<Map<string, Inode>> {
    if (!cachesReady) {
        cachesReady = (async () => {
            cacheContents = await loadCacheMap();
        })();
    }
    await cachesReady;
    return cacheContents!;
}

async function persistZigCache(): Promise<void> {
    if (!cacheContents) return;
    await saveCacheMap(cacheContents);
}

function buildPlaygroundArgs(): string[] {
    return [
        "zig.wasm",
        "build-exe",
        "--dep",
        "zx",
        "-Mroot=main.zig",
        "-Mzx=zx/src/root.zig",
        "--name",
        "main",
        "libcompiler_rt.a",
        "-fno-compiler-rt",
        "-fno-entry",
    ];
}

function buildAppArgs(kind: CompileKind): string[] {
    const name = kind === "ssr" ? "ziex_ssr" : "ziex_client";
    const target = kind === "ssr" ? "wasm32-wasi" : "wasm32-freestanding";

    const args = [
        "zig.wasm",
        "build-exe",
        "-target",
        target,
        "-O",
        "ReleaseSmall",
        "--dep",
        "zx",
        "-Mroot=app/main.zig",
        "--dep",
        "zx_info",
        "--dep",
        "app",
        "--dep",
        "app_opts",
        "--dep",
        "manifest",
    ];

    args.push(
        "-Mzx=zx/src/root.zig",
        "-Mzx_info=stubs/zx_info.zig",
        "--dep",
        "zx",
        "-Mapp=app/app.zig",
        "-Mapp_opts=stubs/app_opts.zig",
        "-Mmanifest=stubs/manifest.zon",
    );

    args.push(
        "--name",
        name,
        "libcompiler_rt.a",
        "-fno-compiler-rt",
        "--export-memory",
        "-rdynamic",
    );

    if (kind === "client") {
        args.push("-fno-entry", "--stack", "524288", "--max-memory=16777216");
    }

    return args;
}

async function ensureZigModule(): Promise<WebAssembly.Module> {
    if (!compiledModule) {
        const response = await fetchWithCache(`/assets/playground/zig-${ZIG_VERSION}.wasm`);
        compiledModule = await WebAssembly.compileStreaming(response);
    }
    return compiledModule;
}

function zigFds(
    cwdContents: Map<string, Inode>,
    libDirectory: Directory,
    cache: Map<string, Inode>,
): Fd[] {
    return [
        new OpenFile(new File([])),
        stderrOutput(),
        stderrOutput(),
        new PreopenDirectory(".", cwdContents),
        new PreopenDirectory("/lib", libDirectory.contents),
        new PreopenDirectory("/cache", cache),
    ];
}

async function compilePlayground(
    files: { [filename: string]: string },
    zxDirectory: Directory,
    libDirectory: Directory,
    libCompilerRt: ArrayBuffer,
    cache: Map<string, Inode>,
): Promise<Uint8Array> {
    const args = buildPlaygroundArgs();
    const fileContents = new Map<string, Inode>();
    const enc = new TextEncoder();
    for (const [filename, content] of Object.entries(files)) {
        fileContents.set(filename, new File(enc.encode(content)));
    }
    fileContents.set("libcompiler_rt.a", new File(new Uint8Array(libCompilerRt)));
    fileContents.set("zx", zxDirectory);

    const wasi = new WASI(args, [], zigFds(fileContents, libDirectory, cache), { debug: false });

    const instance = await WebAssembly.instantiate(await ensureZigModule(), {
        wasi_snapshot_preview1: wasi.wasiImport,
    });
    // @ts-ignore
    const exitCode = wasi.start(instance);
    if (exitCode !== 0) throw new Error(`playground compile failed (exit ${exitCode})`);

    const cwd = wasi.fds[3] as PreopenDirectory;
    const wasmFile = cwd.dir.contents.get("main.wasm") as File | undefined;
    if (!wasmFile) throw new Error("playground compile produced no main.wasm");
    return wasmFile.data.slice();
}

async function compileAppOne(
    kind: CompileKind,
    files: { [filename: string]: string },
    zxDirectory: Directory,
    libDirectory: Directory,
    libCompilerRt: ArrayBuffer,
    cache: Map<string, Inode>,
): Promise<Uint8Array> {
    const args = buildAppArgs(kind);
    const tree = nestPaths(files);
    tree.set("libcompiler_rt.a", new Uint8Array(libCompilerRt));
    const cwdContents = convertTree(tree).contents;
    cwdContents.set("zx", zxDirectory);

    const wasi = new WASI(args, [], zigFds(cwdContents, libDirectory, cache), { debug: false });

    const instance = await WebAssembly.instantiate(await ensureZigModule(), {
        wasi_snapshot_preview1: wasi.wasiImport,
    });
    // @ts-ignore
    const exitCode = wasi.start(instance);
    if (exitCode !== 0) throw new Error(`${kind} compile failed (exit ${exitCode})`);

    const cwd = wasi.fds[3] as PreopenDirectory;
    const outName = kind === "ssr" ? "ziex_ssr.wasm" : "ziex_client.wasm";
    const wasmFile = cwd.dir.contents.get(outName) as File | undefined;
    if (!wasmFile) throw new Error(`${kind} compile produced no ${outName}`);
    return wasmFile.data.slice();
}

async function run(files: { [filename: string]: string }, mode: CompileMode) {
    if (currentlyRunning) return;
    currentlyRunning = true;

    try {
        const [cache, zxDirectory, libDirectory, libCompilerRtRes] = await Promise.all([
            ensureZigCache(),
            getZxArchive(),
            getLatestZigArchive(),
            fetchWithCache(`/assets/playground/libcompiler_rt-${ZIG_VERSION}.a`),
        ]);
        const libCompilerRt = await libCompilerRtRes.arrayBuffer();

        if (mode === "playground") {
            const wasm = await compilePlayground(files, zxDirectory, libDirectory, libCompilerRt, cache);
            postMessage({ compiled: wasm });
        } else {
            const ssrWasm = await compileAppOne("ssr", files, zxDirectory, libDirectory, libCompilerRt, cache);
            const clientWasm = await compileAppOne("client", files, zxDirectory, libDirectory, libCompilerRt, cache);
            const webGlue = await buildWebGlue(clientWasm, zxDirectory);
            postMessage({ compiled: { ssrWasm, clientWasm, webGlue } });
        }

        await persistZigCache().catch(() => {});
    } catch (err) {
        await persistZigCache().catch(() => {});
        postMessage({ stderr: `${err}` });
        postMessage({ failed: true });
    }

    currentlyRunning = false;
}

// Commands that link an executable get the prebuilt compiler_rt instead of compiling it in-browser
const LINKING_COMMANDS = new Set(["build-exe", "test"]);

function usesPrebuiltCompilerRt(args: string[]): boolean {
    if (!LINKING_COMMANDS.has(args[0])) return false;
    const i = args.indexOf("-target");
    return i === -1 || (args[i + 1] ?? "").startsWith("wasm32");
}

// zig.wasm only resolves absolute paths for /lib and /cache, so scratch files live under cwd
const SCRATCH_DIR = ".zig-cache/playground";

// Runs the zig CLI as-is against a file tree; `emit` names a SCRATCH_DIR output to hand back
async function runExec(args: string[], files: Record<string, Uint8Array>, emit?: string) {
    if (currentlyRunning) {
        postMessage({ exec: { output: "zig worker is busy\n", exitCode: 1, files } });
        return;
    }
    currentlyRunning = true;

    let output = "";
    let exitCode = 1;
    let emitted: Uint8Array | null = null;
    const cwd = new PreopenDirectory(".", convertTree(nestPaths(files)).contents);
    try {
        const [cache, libDirectory, libCompilerRtRes] = await Promise.all([
            ensureZigCache(),
            getLatestZigArchive(),
            fetchWithCache(`/assets/playground/libcompiler_rt-${ZIG_VERSION}.a`),
        ]);
        const scratch = new Directory(new Map([
            ["libcompiler_rt.a", new File(new Uint8Array(await libCompilerRtRes.arrayBuffer()))],
        ]));
        let zigCache = cwd.dir.contents.get(".zig-cache");
        if (!(zigCache instanceof Directory)) {
            zigCache = new Directory(new Map());
            cwd.dir.contents.set(".zig-cache", zigCache);
        }
        (zigCache as Directory).contents.set("playground", scratch);

        const argv = usesPrebuiltCompilerRt(args)
            ? ["zig", ...args, `${SCRATCH_DIR}/libcompiler_rt.a`, "-fno-compiler-rt"]
            : ["zig", ...args];

        const dec = new TextDecoder("utf-8", { fatal: false });
        const sink = () => {
            const out = new ConsoleStdout((buffer) => {
                output += dec.decode(buffer, { stream: true });
            });
            out.fd_pwrite = () => ({ ret: wasi_defs.ERRNO_SPIPE, nwritten: 0 });
            return out;
        };
        const fds: Fd[] = [
            new OpenFile(new File([])),
            sink(),
            sink(),
            cwd,
            new PreopenDirectory("/lib", libDirectory.contents),
            new PreopenDirectory("/cache", cache),
        ];
        const wasi = new WASI(argv, [], fds, { debug: false });
        const instance = await WebAssembly.instantiate(await ensureZigModule(), {
            wasi_snapshot_preview1: wasi.wasiImport,
        });
        // @ts-ignore
        exitCode = wasi.start(instance);
        output += dec.decode();
        if (emit) {
            const file = scratch.contents.get(emit);
            if (file instanceof File) emitted = file.data.slice();
        }
        (zigCache as Directory).contents.delete("playground");
    } catch (err) {
        output += `${err}\n`;
    }
    await persistZigCache().catch(() => {});
    currentlyRunning = false;
    postMessage({ exec: { output, exitCode, files: flattenDirectory(cwd.dir), emitted } });
}

onmessage = (event) => {
    if (event.data?.exec) {
        const { args, files, emit } = event.data.exec;
        runExec(args, files, emit);
        return;
    }
    if (event.data?.clearCache) {
        cacheContents = new Map();
        cachesReady = Promise.resolve();
        void saveCacheMap(cacheContents).then(() => postMessage({ cacheCleared: true }));
        return;
    }
    if (event.data.files) {
        const mode: CompileMode = event.data.mode === "app" ? "app" : "playground";
        run(event.data.files, mode);
    }
};
