import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFsHandlers, ROOT_FD, Vfs, type Store } from "./fs";
import { createHostImports } from "./host";
import { createIoHandlers } from "./io";

const enc = (s: string) => new TextEncoder().encode(s);
const dec = (b: Uint8Array | undefined) => (b ? new TextDecoder().decode(b) : undefined);

const O = { read: 1, write: 2, create: 4, exclusive: 8, truncate: 16, directory: 32 };

/** Store that records the persisted tree; `slow` delays every op to a later task. */
function memoryStore(slow = false) {
    const files = new Map<string, Uint8Array>();
    const dirs = new Set<string>();
    const log: string[] = [];
    const tick = () => (slow ? new Promise((r) => setTimeout(r, 1)) : Promise.resolve());
    const mkdirs = (path: string) => {
        const parts = path.split("/").filter(Boolean);
        for (let i = 1; i <= parts.length; i++) dirs.add(`/${parts.slice(0, i).join("/")}`);
    };
    const parentOf = (p: string) => p.slice(0, p.lastIndexOf("/")) || "/";
    const store: Store = {
        async load() {
            return [
                ...[...dirs].map((path) => ({ path })),
                ...[...files].map(([path, data]) => ({ path, data: data.slice() })),
            ];
        },
        async write(path, data) {
            await tick();
            log.push(`write ${path}`);
            mkdirs(parentOf(path));
            files.set(path, data.slice());
        },
        async mkdir(path) {
            await tick();
            log.push(`mkdir ${path}`);
            mkdirs(path);
        },
        async remove(path) {
            await tick();
            log.push(`remove ${path}`);
            for (const p of [...files.keys()]) if (p === path || p.startsWith(`${path}/`)) files.delete(p);
            for (const p of [...dirs]) if (p === path || p.startsWith(`${path}/`)) dirs.delete(p);
        },
    };
    return { store, files, dirs, log };
}

function writeFile(vfs: Vfs, path: string, text: string) {
    const fd = vfs.open(ROOT_FD, path, O.write | O.create | O.truncate);
    expect(fd).toBeGreaterThan(ROOT_FD);
    vfs.write(fd, enc(text), -1);
    vfs.close(fd);
}

function readFile(vfs: Vfs, path: string): string | number {
    const fd = vfs.open(ROOT_FD, path, O.read);
    if (fd < 0) return fd;
    const st = vfs.stat(fd, "") as { size: number };
    const out = new Uint8Array(st.size);
    vfs.read(fd, out, 0);
    vfs.close(fd);
    return new TextDecoder().decode(out);
}

describe("Vfs", () => {
    test("positional and streaming reads/writes", () => {
        const vfs = new Vfs();
        const fd = vfs.open(ROOT_FD, "f", O.read | O.write | O.create);
        expect(vfs.write(fd, enc("hello"), -1)).toBe(5);
        expect(vfs.write(fd, enc("J"), 0)).toBe(1);
        expect(vfs.write(fd, enc("!"), 7)).toBe(1); // gap is zero-filled
        const out = new Uint8Array(16);
        expect(vfs.read(fd, out, 0)).toBe(8);
        expect([...out.subarray(0, 8)]).toEqual([...enc("Jello"), 0, 0, 0x21]);
        expect(vfs.seek(fd, 1, 0)).toBe(0);
        expect(vfs.read(fd, out.subarray(0, 2), -1)).toBe(2);
        expect(dec(out.subarray(0, 2))).toBe("el");
        expect(vfs.setLength(fd, 2)).toBe(0);
        expect(vfs.read(fd, out, 0)).toBe(2);
    });

    test("errno results", () => {
        const vfs = new Vfs();
        expect(vfs.open(ROOT_FD, "missing", O.read)).toBe(-2);
        expect(vfs.open(ROOT_FD, "a/b", O.write | O.create)).toBe(-2);
        writeFile(vfs, "file", "x");
        expect(vfs.open(ROOT_FD, "file", O.write | O.create | O.exclusive)).toBe(-17);
        expect(vfs.open(ROOT_FD, "file/x", O.write | O.create)).toBe(-20);
        expect(vfs.open(ROOT_FD, "file", O.read | O.directory)).toBe(-20);
        expect(vfs.mkdir(ROOT_FD, "d/e", false)).toBe(-2);
        expect(vfs.mkdir(ROOT_FD, "d/e", true)).toBe(0);
        expect(vfs.mkdir(ROOT_FD, "d/e", true)).toBe(1);
        expect(vfs.mkdir(ROOT_FD, "d", false)).toBe(-17);
        expect(vfs.mkdir(ROOT_FD, "file", true)).toBe(-20);
        expect(vfs.open(ROOT_FD, "d", O.read)).toBe(-21);
        expect(vfs.remove(ROOT_FD, "d", true)).toBe(-39);
        expect(vfs.remove(ROOT_FD, "d", false)).toBe(-21);
        expect(vfs.remove(ROOT_FD, "file", true)).toBe(-20);
        expect(vfs.read(999, new Uint8Array(1), 0)).toBe(-9);
        const ro = vfs.open(ROOT_FD, "file", O.read);
        expect(vfs.write(ro, enc("x"), 0)).toBe(-9);
    });

    test("paths resolve against the open directory and clamp at the root", () => {
        const vfs = new Vfs();
        vfs.mkdir(ROOT_FD, "a/b", true);
        const b = vfs.open(ROOT_FD, "./a//b/", O.read | O.directory);
        writeFile(vfs, "a/b/f", "in b");
        expect(readFile(vfs, "/a/b/f")).toBe("in b");
        const fd = vfs.open(b, "../../../a/b/f", O.read);
        expect(fd).toBeGreaterThan(0);
        expect(vfs.stat(b, "f")).toMatchObject({ kind: "file", size: 4 });
    });

    test("rename moves trees and keeps open handles working", () => {
        const vfs = new Vfs();
        vfs.mkdir(ROOT_FD, "src/sub", true);
        writeFile(vfs, "src/sub/f", "data");
        const sub = vfs.open(ROOT_FD, "src/sub", O.read | O.directory);
        expect(vfs.rename(ROOT_FD, "src", ROOT_FD, "dst", true)).toBe(0);
        expect(readFile(vfs, "src/sub/f")).toBe(-2);
        expect(readFile(vfs, "dst/sub/f")).toBe("data");
        expect(vfs.stat(sub, "f")).toMatchObject({ size: 4 });

        writeFile(vfs, "x", "x");
        writeFile(vfs, "y", "y");
        expect(vfs.rename(ROOT_FD, "x", ROOT_FD, "y", false)).toBe(-17);
        expect(vfs.rename(ROOT_FD, "x", ROOT_FD, "y", true)).toBe(0);
        expect(readFile(vfs, "y")).toBe("x");
        expect(vfs.rename(ROOT_FD, "dst", ROOT_FD, "dst/sub/inside", true)).toBe(-22);
    });

    test("readdir pages entries through a small buffer", () => {
        const vfs = new Vfs();
        vfs.mkdir(ROOT_FD, "d/zdir", true);
        for (const n of ["b", "a", "ccc"]) writeFile(vfs, `d/${n}`, "");
        const fd = vfs.open(ROOT_FD, "d", O.read | O.directory);
        const seen: string[] = [];
        const buf = new Uint8Array(7);
        for (let reset = true; ; reset = false) {
            const n = vfs.readdir(fd, reset, buf);
            expect(n).toBeGreaterThanOrEqual(0);
            if (n === 0) break;
            for (let i = 0; i < n;) {
                const len = buf[i + 1]! | (buf[i + 2]! << 8);
                seen.push(`${buf[i] ? "d" : "f"}:${dec(buf.subarray(i + 3, i + 3 + len))}`);
                i += 3 + len;
            }
        }
        expect(seen).toEqual(["f:a", "f:b", "f:ccc", "d:zdir"]);
        expect(vfs.readdir(fd, true, new Uint8Array(2))).toBe(-22);
    });
});

describe("persistence", () => {
    test("writes coalesce and the store ends up matching the mirror", async () => {
        const { store, files, log } = memoryStore(true);
        const vfs = new Vfs(store);
        const fd = vfs.open(ROOT_FD, "f", O.write | O.create);
        for (let i = 0; i < 100; i++) vfs.write(fd, enc(String(i % 10)), -1);
        await vfs.flush();
        expect(log.filter((l) => l === "write /f").length).toBeLessThanOrEqual(2);
        expect(dec(files.get("/f"))?.length).toBe(100);
    });

    test("removes are not reordered past later creates", async () => {
        const { store, files, dirs } = memoryStore(true);
        const vfs = new Vfs(store);
        vfs.mkdir(ROOT_FD, "a", false);
        writeFile(vfs, "a/old", "old");
        await vfs.flush();

        // Rename `a` away, then recreate `a` with different contents before anything persists.
        expect(vfs.rename(ROOT_FD, "a", ROOT_FD, "b", true)).toBe(0);
        vfs.mkdir(ROOT_FD, "a", false);
        writeFile(vfs, "a/new", "new");
        writeFile(vfs, "tmp", "t");
        vfs.rename(ROOT_FD, "tmp", ROOT_FD, "a/new", true);
        await vfs.flush();

        expect([...files.keys()].sort()).toEqual(["/a/new", "/b/old"]);
        expect(dec(files.get("/a/new"))).toBe("t");
        expect(dirs.has("/a")).toBe(true);
    });

    test("a fresh mount loads what was persisted", async () => {
        const { store } = memoryStore();
        const first = new Vfs(store);
        first.mkdir(ROOT_FD, "kv/ns", true);
        writeFile(first, "kv/ns/key", "value");
        first.mkdir(ROOT_FD, "empty", false);
        await first.flush();

        const second = new Vfs(store);
        await second.load();
        expect(readFile(second, "kv/ns/key")).toBe("value");
        expect(second.stat(ROOT_FD, "empty")).toMatchObject({ kind: "dir" });
    });
});

/** Builds test/fs.zig against a copy of the runtime sources it needs, laid out as in src/runtime. */
function buildFixture(): Uint8Array | null {
    const repo = new URL("../../../../", import.meta.url).pathname;
    const dir = mkdtempSync(join(tmpdir(), "zx-fs-"));
    const rt = join(dir, "src/runtime");
    for (const f of ["core/Io/Web.zig", "core/Io/Web/fs.zig", "wasm/imports.zig"]) {
        mkdirSync(join(rt, f, ".."), { recursive: true });
        cpSync(join(repo, "src/runtime", f), join(rt, f));
    }
    cpSync(join(repo, "pkg/ziex/test/fs.zig"), join(rt, "fixture.zig"));
    // Same empty libc the client build uses, for a real `File.Handle` (see `withFdHandles`).
    const libc = join(dir, "libc.txt");
    writeFileSync(libc, ["include_dir", "sys_include_dir", "crt_dir"].map((k) => `${k}=/zx-no-libc`)
        .concat(["msvc_lib_dir=", "kernel32_lib_dir=", "gcc_dir=", "darwin_sdk_dir=", "haiku_dir="]).join("\n"));
    const out = join(dir, "fs.wasm");
    try {
        execFileSync("zig", [
            "build-exe", join(rt, "fixture.zig"), "-target", "wasm32-freestanding", "-fno-entry", "-rdynamic",
            "-ODebug", "-lc", "--libc", libc, `-femit-bin=${out}`, `--cache-dir`, join(dir, "cache"),
        ], { stdio: "pipe" });
        return readFileSync(out);
    } catch (err) {
        const stderr = (err as { stderr?: Buffer }).stderr?.toString() ?? "";
        if (stderr.includes("error:")) throw new Error(stderr);
        return null;
    }
}

const wasm = buildFixture();

describe.skipIf(!wasm)("std.Io through zx.Io.Web (needs zig on PATH)", async () => {
    const { store, files } = memoryStore();
    const vfs = new Vfs(store);
    let memory: WebAssembly.Memory;
    const getMemory = () => memory;
    const host = createHostImports({ ...createIoHandlers(getMemory), ...createFsHandlers(vfs, getMemory) });
    const { instance } = await WebAssembly.instantiate(wasm!, { __zx: host });
    const ex = instance.exports as Record<string, (() => number)> & { memory: WebAssembly.Memory };
    memory = ex.memory;

    const run = (name: string) => {
        const rc = ex[name]!();
        const err = rc === 0 ? "" : new TextDecoder().decode(
            new Uint8Array(memory.buffer, ex.errPtr!() >>> 0, ex.errLen!()),
        );
        expect(err).toBe("");
    };

    test("exports the marker the browser host mounts on", () => {
        expect(ex.__zx_fs).toBeInstanceOf(WebAssembly.Global);
    });

    test("createFileAtomic + replace, read back, delete (what Kv.Fs does)", async () => {
        run("atomicRoundtrip");
        await vfs.flush();
        // Temp files were renamed away; only the directories remain.
        expect([...files.keys()].filter((p) => p.startsWith("/kv"))).toEqual([]);
        expect(vfs.stat(ROOT_FD, "kv/ns")).toMatchObject({ kind: "dir" });
    });

    test("Dir.iterate", () => run("iterate"));
    test("errors map to std error names", () => run("errors"));
    test("buffered File.Writer/Reader and seek", () => run("streaming"));

    test("relative dirs, stat and cross-dir rename persist", async () => {
        run("relative");
        await vfs.flush();
        expect(dec(files.get("/rel/moved"))).toBe("abc");
        expect(files.has("/rel/deep/f")).toBe(false);
    });
});
