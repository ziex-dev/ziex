import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createFsHandlers, Vfs, type Store } from "./fs";
import { createHostImports } from "./host";
import { createIoHandlers } from "./io";

const repo = realpathSync(new URL("../../../../", import.meta.url).pathname);

// Builds test/db.zig with the real pkg/db-sqlite, against a copy of the runtime laid out as in src/runtime.
function buildFixture(): Uint8Array | null {
    try {
        execFileSync("zig", ["version"], { stdio: "pipe" });
    } catch {
        return null;
    }
    // Real path: zig resolves the build root through symlinks like macOS's /var.
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "zx-db-")));
    const rt = join(dir, "src/runtime");
    for (const f of ["core/Db.zig", "core/Db", "core/Wire.zig", "core/Io/Web.zig", "core/Io/Web/fs.zig", "wasm/imports.zig"]) {
        mkdirSync(join(rt, f, ".."), { recursive: true });
        cpSync(join(repo, "src/runtime", f), join(rt, f), { recursive: true });
    }
    cpSync(join(repo, "pkg/ziex/test/db.zig"), join(rt, "fixture.zig"));
    writeFileSync(join(dir, "libc.txt"), ["include_dir", "sys_include_dir", "crt_dir"].map((k) => `${k}=/zx-no-libc`)
        .concat(["msvc_lib_dir=", "kernel32_lib_dir=", "gcc_dir=", "darwin_sdk_dir=", "haiku_dir="]).join("\n"));
    writeFileSync(join(dir, "build.zig.zon"), `.{
    .name = .zx_db_fixture,
    .version = "0.0.0",
    .fingerprint = 0xf8c9f11a00a96f48,
    .dependencies = .{ .db_sqlite = .{ .path = "${relative(dir, join(repo, "pkg/db-sqlite"))}" } },
    .paths = .{""},
}`);
    writeFileSync(join(dir, "build.zig"), `const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sqlite = b.dependency("db_sqlite", .{ .target = target, .optimize = .ReleaseSmall }).module("sqlite");
    const exe = b.addExecutable(.{ .name = "db", .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/fixture.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "sqlite", .module = sqlite }},
    }) });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.root_module.link_libc = true;
    exe.setLibCFile(b.path("libc.txt"));
    b.installArtifact(exe);
}
`);
    // A stable cache keeps reruns from recompiling sqlite3.c.
    const cache = join(tmpdir(), "zx-db-fixture-cache");
    try {
        execFileSync("zig", ["build", "--cache-dir", cache], { cwd: dir, stdio: "pipe" });
    } catch (err) {
        throw new Error((err as { stderr?: Buffer }).stderr?.toString() ?? String(err));
    }
    const out = join(dir, "zig-out/bin/db.wasm");
    return existsSync(out) ? readFileSync(out) : null;
}

function mapStore() {
    const files = new Map<string, Uint8Array>();
    const store: Store = {
        async load() {
            return [...files].map(([path, data]) => ({ path, data: data.slice() }));
        },
        async write(path, data) {
            files.set(path, data.slice());
        },
        async mkdir() {},
        async remove(path) {
            for (const p of [...files.keys()]) if (p === path || p.startsWith(`${path}/`)) files.delete(p);
        },
    };
    return { store, files };
}

async function instantiate(wasm: Uint8Array, vfs: Vfs) {
    let memory: WebAssembly.Memory;
    const getMemory = () => memory;
    const host = createHostImports({ ...createIoHandlers(getMemory), ...createFsHandlers(vfs, getMemory) });
    const { instance } = await WebAssembly.instantiate(wasm, { __zx: host });
    const ex = instance.exports as Record<string, () => number> & { memory: WebAssembly.Memory };
    memory = ex.memory;
    return (name: string) => {
        const rc = ex[name]!();
        return rc === 0 ? "" : new TextDecoder().decode(new Uint8Array(memory.buffer, ex.errPtr!() >>> 0, ex.errLen!()));
    };
}

const wasm = buildFixture();

describe.skipIf(!wasm)("zx.Db.Sqlite on the browser file system (needs zig on PATH)", () => {
    test("writes persist and a fresh mount reads them back", async () => {
        const { store, files } = mapStore();
        const first = new Vfs(store);
        expect(await (await instantiate(wasm!, first))("write")).toBe("");
        await first.flush();
        expect(files.get("/db/default.db")?.length).toBeGreaterThan(0);
        // The rollback journal is gone once its transaction ends.
        expect([...files.keys()].filter((p) => p.includes("journal"))).toEqual([]);

        const second = new Vfs(store);
        await second.load();
        expect(await (await instantiate(wasm!, second))("read")).toBe("");
    }, 120_000);
});
