// In-browser version of src/build/webglue.zig: the `__zx_web` shims a client
// wasm imports, read from the zx sources' generated shims.zig.
import type { Directory, File } from "@bjorn3/browser_wasi_shim";

type Table = { shims: Map<string, string>; enums: Map<string, string> };

let cached: Table | null = null;

export async function buildWebGlue(clientWasm: Uint8Array, zx: Directory): Promise<string> {
    const module = await WebAssembly.compile(clientWasm);
    const names = WebAssembly.Module.imports(module)
        .filter((imp) => imp.module === "__zx_web")
        .map((imp) => imp.name)
        .sort();
    if (names.length === 0) return "globalThis.__zx_web=false;\n";

    const table = (cached ??= parseShims(readFile(zx, ["src", "runtime", "client", "web", "shims.zig"])));
    const enums = new Set<string>();
    for (const name of names) {
        for (const m of (table.shims.get(name) ?? "").matchAll(/E_(\w+)/g)) enums.add(m[1]!);
    }
    let out = "globalThis.__zx_web=({R,S,N,H,W,F,V,A,T})=>{";
    for (const e of enums) {
        const arr = table.enums.get(e);
        if (arr) out += `const E_${e}=${arr};`;
    }
    const entries = names.flatMap((n) => {
        const src = table.shims.get(n);
        return src ? [`${JSON.stringify(n)}:${src}`] : [];
    });
    return `${out}return{${entries.join(",")}}};\n`;
}

function readFile(dir: Directory, path: string[]): string {
    let cur: Directory | File = dir;
    for (const seg of path) {
        const next = (cur as Directory).contents.get(seg) as Directory | File | undefined;
        if (!next) throw new Error(`zx sources missing ${path.join("/")}`);
        cur = next;
    }
    return new TextDecoder().decode((cur as File).data);
}

// Lines look like `    .{ "Node.appendChild", "(h,p0)=>H(R[h].appendChild(R[p0]))" },`.
function parseShims(src: string): Table {
    const shims = new Map<string, string>();
    const enums = new Map<string, string>();
    const split = src.indexOf("pub const enums");
    const entry = /^\s*\.\{ "((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)" \},$/gm;
    for (const m of src.matchAll(entry)) {
        (m.index! < split ? shims : enums).set(unescapeZig(m[1]!), unescapeZig(m[2]!));
    }
    return { shims, enums };
}

function unescapeZig(s: string): string {
    return s.replace(/\\(x[0-9a-fA-F]{2}|.)/g, (_, c: string) => {
        if (c[0] === "x") return String.fromCharCode(parseInt(c.slice(1), 16));
        return c === "n" ? "\n" : c === "t" ? "\t" : c === "r" ? "\r" : c;
    });
}
