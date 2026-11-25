import { i64, type Handlers } from "./host";

// Guest file ops run sync against an in-memory mirror; a Store persists it in the background.

// Negative results; mapped back in `Io/Web/fs.zig`.
const ENOENT = -2;
const EBADF = -9;
const EEXIST = -17;
const ENOTDIR = -20;
const EISDIR = -21;
const EINVAL = -22;
const ENOTEMPTY = -39;

// Mirrored in `Io/Web/fs.zig`.
const O_READ = 1;
const O_WRITE = 2;
const O_CREATE = 4;
const O_EXCLUSIVE = 8;
const O_TRUNCATE = 16;
const O_DIRECTORY = 32;
const O_ALLOW_DIRECTORY = 64;

export const ROOT_FD = 3;

type FileNode = { kind: "file"; path: string | null; data: Uint8Array; size: number; mtime: number };
type DirNode = { kind: "dir"; path: string | null; mtime: number };
type Node = FileNode | DirNode;

type Handle = {
    node: Node;
    read: boolean;
    write: boolean;
    pos: number;
    entries?: [string, Node["kind"]][];
    cursor?: number;
};

/** Persists the browser file system. Paths are absolute, like `/a/b.txt`. */
export interface Store {
    load(): Promise<{ path: string; data?: Uint8Array }[]>;
    write(path: string, data: Uint8Array): Promise<void>;
    mkdir(path: string): Promise<void>;
    /** Removes a file or directory tree; missing paths are fine. */
    remove(path: string): Promise<void>;
}

type Op = { kind: "write" | "mkdir" | "remove"; path: string };

function parent(path: string): string {
    const i = path.lastIndexOf("/");
    return i <= 0 ? "/" : path.slice(0, i);
}

function basename(path: string): string {
    return path.slice(path.lastIndexOf("/") + 1);
}

function join(dir: string, sub: string): string {
    const parts = sub.startsWith("/") ? [] : dir.split("/").filter(Boolean);
    for (const seg of sub.split("/")) {
        if (seg === "" || seg === ".") continue;
        if (seg === "..") parts.pop();
        else parts.push(seg);
    }
    return `/${parts.join("/")}`;
}

function isUnder(path: string, dir: string): boolean {
    return dir === "/" ? path !== "/" : path.startsWith(`${dir}/`);
}

export class Vfs {
    private nodes = new Map<string, Node>();
    private handles = new Map<number, Handle>();
    private nextFd = ROOT_FD + 1;
    private ops: Op[] = [];
    // Writes queued since the last structural op; later writes to the same file coalesce.
    private queuedWrites = new Set<string>();
    private draining: Promise<void> | null = null;

    constructor(private store: Store | null = null) {
        const root: DirNode = { kind: "dir", path: "/", mtime: Date.now() };
        this.nodes.set("/", root);
        this.handles.set(ROOT_FD, { node: root, read: true, write: false, pos: 0 });
    }

    async load(): Promise<void> {
        if (!this.store) return;
        for (const { path, data } of await this.store.load()) {
            const now = Date.now();
            this.nodes.set(path, data
                ? { kind: "file", path, data, size: data.length, mtime: now }
                : { kind: "dir", path, mtime: now });
        }
    }

    async flush(): Promise<void> {
        this.drain();
        while (this.draining) await this.draining;
    }

    open(dirFd: number, sub: string, flags: number): number {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        let node = this.nodes.get(path);
        if (node && flags & O_CREATE && flags & O_EXCLUSIVE) return EEXIST;
        if (!node) {
            if (!(flags & O_CREATE) || flags & O_DIRECTORY) return ENOENT;
            const dir = this.nodes.get(parent(path));
            if (!dir) return ENOENT;
            if (dir.kind !== "dir") return ENOTDIR;
            node = { kind: "file", path, data: new Uint8Array(0), size: 0, mtime: Date.now() };
            this.nodes.set(path, node);
            this.queue("write", path);
        }
        if (node.kind === "dir") {
            if (flags & O_WRITE) return EISDIR;
            if (!(flags & (O_DIRECTORY | O_ALLOW_DIRECTORY))) return EISDIR;
        } else if (flags & O_DIRECTORY) {
            return ENOTDIR;
        }
        if (node.kind === "file" && flags & O_TRUNCATE && flags & O_WRITE && node.size > 0) {
            node.size = 0;
            node.mtime = Date.now();
            this.queue("write", path);
        }
        const fd = this.nextFd++;
        this.handles.set(fd, { node, read: !!(flags & O_READ), write: !!(flags & O_WRITE), pos: 0 });
        return fd;
    }

    close(fd: number): number {
        if (fd === ROOT_FD) return 0;
        return this.handles.delete(fd) ? 0 : EBADF;
    }

    // `offset` -1 uses and advances the handle's position.
    read(fd: number, out: Uint8Array, offset: number): number {
        const h = this.handles.get(fd);
        if (!h || !h.read) return EBADF;
        if (h.node.kind !== "file") return EISDIR;
        const at = offset < 0 ? h.pos : offset;
        const n = Math.max(0, Math.min(out.length, h.node.size - at));
        out.set(h.node.data.subarray(at, at + n));
        if (offset < 0) h.pos += n;
        return n;
    }

    write(fd: number, bytes: Uint8Array, offset: number): number {
        const h = this.handles.get(fd);
        if (!h || !h.write) return EBADF;
        const node = h.node;
        if (node.kind !== "file") return EISDIR;
        const at = offset < 0 ? h.pos : offset;
        this.resize(node, Math.max(node.size, at + bytes.length));
        node.data.set(bytes, at);
        node.mtime = Date.now();
        if (offset < 0) h.pos = at + bytes.length;
        if (node.path) this.queue("write", node.path);
        return bytes.length;
    }

    // Empty `sub` stats the open handle itself.
    stat(dirFd: number, sub: string): { kind: Node["kind"]; size: number; mtime: number } | number {
        let node: Node | undefined;
        if (sub === "") {
            node = this.handles.get(dirFd)?.node;
            if (!node) return EBADF;
        } else {
            const path = this.resolve(dirFd, sub);
            if (typeof path === "number") return path;
            node = this.nodes.get(path);
            if (!node) return ENOENT;
        }
        return { kind: node.kind, size: node.kind === "file" ? node.size : 0, mtime: node.mtime };
    }

    setLength(fd: number, length: number): number {
        const h = this.handles.get(fd);
        if (!h || !h.write) return EBADF;
        if (h.node.kind !== "file") return EISDIR;
        this.resize(h.node, length);
        h.node.mtime = Date.now();
        if (h.node.path) this.queue("write", h.node.path);
        return 0;
    }

    // `whence` 0 from the start, 1 from the current position.
    seek(fd: number, offset: number, whence: number): number {
        const h = this.handles.get(fd);
        if (!h) return EBADF;
        if (h.node.kind !== "file") return EINVAL;
        const pos = whence === 1 ? h.pos + offset : offset;
        if (pos < 0) return EINVAL;
        h.pos = pos;
        return 0;
    }

    // 1 when it already existed (`recursive` only).
    mkdir(dirFd: number, sub: string, recursive: boolean): number {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        const existing = this.nodes.get(path);
        if (existing) {
            if (!recursive) return EEXIST;
            return existing.kind === "dir" ? 1 : ENOTDIR;
        }
        const missing: string[] = [];
        for (let p = path; !this.nodes.has(p); p = parent(p)) missing.push(p);
        const above = this.nodes.get(parent(missing[missing.length - 1]!))!;
        if (above.kind !== "dir") return ENOTDIR;
        if (!recursive && missing.length > 1) return ENOENT;
        for (const p of missing.reverse()) {
            this.nodes.set(p, { kind: "dir", path: p, mtime: Date.now() });
        }
        this.queue("mkdir", path);
        return 0;
    }

    remove(dirFd: number, sub: string, dir: boolean): number {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        const node = this.nodes.get(path);
        if (!node) return ENOENT;
        if (path === "/") return EINVAL;
        if (dir) {
            if (node.kind !== "dir") return ENOTDIR;
            for (const p of this.nodes.keys()) if (isUnder(p, path)) return ENOTEMPTY;
        } else if (node.kind === "dir") {
            return EISDIR;
        }
        this.nodes.delete(path);
        node.path = null;
        this.queue("remove", path);
        return 0;
    }

    rename(oldFd: number, oldSub: string, newFd: number, newSub: string, replace: boolean): number {
        const from = this.resolve(oldFd, oldSub);
        if (typeof from === "number") return from;
        const to = this.resolve(newFd, newSub);
        if (typeof to === "number") return to;
        const node = this.nodes.get(from);
        if (!node) return ENOENT;
        if (from === to) return 0;
        if (isUnder(to, from)) return EINVAL;
        const dest = this.nodes.get(parent(to));
        if (!dest) return ENOENT;
        if (dest.kind !== "dir") return ENOTDIR;
        const target = this.nodes.get(to);
        if (target) {
            if (!replace) return EEXIST;
            if (target.kind === "dir") {
                if (node.kind !== "dir") return EISDIR;
                for (const p of this.nodes.keys()) if (isUnder(p, to)) return ENOTEMPTY;
            } else if (node.kind === "dir") {
                return ENOTDIR;
            }
            target.path = null;
        }

        const moved: [string, Node][] = [];
        for (const [p, n] of this.nodes) if (p === from || isUnder(p, from)) moved.push([p, n]);
        for (const [p] of moved) this.nodes.delete(p);
        for (const [p, n] of moved) {
            const next = to + p.slice(from.length);
            n.path = next;
            this.nodes.set(next, n);
        }
        this.queue("remove", from);
        this.queue("remove", to);
        for (const [, n] of moved) this.queue(n.kind === "dir" ? "mkdir" : "write", n.path!);
        return 0;
    }

    // Packs `[kind: u8 (1 = dir)][len: u16 le][name]` records; 0 at the end.
    readdir(fd: number, reset: boolean, out: Uint8Array): number {
        const h = this.handles.get(fd);
        if (!h) return EBADF;
        if (h.node.kind !== "dir") return ENOTDIR;
        if (reset || !h.entries) {
            const dir = h.node.path;
            h.entries = [];
            h.cursor = 0;
            if (dir) {
                for (const [p, n] of this.nodes) {
                    if (p !== "/" && parent(p) === dir) h.entries.push([basename(p), n.kind]);
                }
                h.entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
            }
        }
        const encoder = new TextEncoder();
        let off = 0;
        while (h.cursor! < h.entries.length) {
            const [name, kind] = h.entries[h.cursor!]!;
            const bytes = encoder.encode(name);
            if (off + 3 + bytes.length > out.length) {
                if (off === 0) return EINVAL;
                break;
            }
            out[off] = kind === "dir" ? 1 : 0;
            out[off + 1] = bytes.length & 0xff;
            out[off + 2] = bytes.length >> 8;
            out.set(bytes, off + 3);
            off += 3 + bytes.length;
            h.cursor! += 1;
        }
        return off;
    }

    sync(fd: number): number {
        if (!this.handles.has(fd)) return EBADF;
        this.drain();
        return 0;
    }

    private resolve(dirFd: number, sub: string): string | number {
        const h = this.handles.get(dirFd);
        if (!h) return EBADF;
        if (h.node.kind !== "dir") return ENOTDIR;
        if (!h.node.path) return ENOENT;
        return join(h.node.path, sub);
    }

    private resize(node: FileNode, size: number): void {
        if (size > node.data.length) {
            const grown = new Uint8Array(Math.max(size, node.data.length * 2, 64));
            grown.set(node.data.subarray(0, node.size));
            node.data = grown;
        } else if (size > node.size) {
            node.data.fill(0, node.size, size);
        }
        node.size = size;
    }

    private queue(kind: Op["kind"], path: string): void {
        if (!this.store) return;
        if (kind === "write") {
            if (this.queuedWrites.has(path)) return;
            this.queuedWrites.add(path);
        } else {
            this.queuedWrites.clear();
        }
        this.ops.push({ kind, path });
        if (!this.draining) queueMicrotask(() => this.drain());
    }

    private drain(): void {
        if (this.draining || !this.store) return;
        const store = this.store;
        this.draining = (async () => {
            while (this.ops.length > 0) {
                const op = this.ops.shift()!;
                if (op.kind === "write") this.queuedWrites.delete(op.path);
                try {
                    await this.apply(store, op);
                } catch (err) {
                    console.error(`zx: persisting ${op.path} failed:`, err);
                }
            }
        })().finally(() => {
            this.draining = null;
        });
    }

    // Ops read the mirror when they run, so the latest state wins.
    private async apply(store: Store, op: Op): Promise<void> {
        const node = this.nodes.get(op.path);
        switch (op.kind) {
            case "remove":
                return store.remove(op.path);
            case "mkdir":
                if (node?.kind === "dir") return store.mkdir(op.path);
                return;
            case "write":
                if (node?.kind === "file") return store.write(op.path, node.data.slice(0, node.size));
                return;
        }
    }
}

export function createFsHandlers(vfs: Vfs, getMemory: () => WebAssembly.Memory): Handlers {
    const bytes = (ptr: number, len: number) => new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);
    const decoder = new TextDecoder();
    const str = (ptr: number, len: number) => (len === 0 ? "" : decoder.decode(bytes(ptr, len)));

    return {
        fs_open: (dir, p, l, flags) => vfs.open(dir, str(p, l), flags),
        fs_close: (fd) => vfs.close(fd),
        fs_read: (fd, p, l, lo, hi) => vfs.read(fd, bytes(p, l), i64(lo, hi)),
        // Copied: the mirror keeps the bytes.
        fs_write: (fd, p, l, lo, hi) => vfs.write(fd, bytes(p, l).slice(), i64(lo, hi)),
        fs_stat: (dir, p, l, out) => {
            const st = vfs.stat(dir, str(p, l));
            if (typeof st === "number") return st;
            const view = new DataView(getMemory().buffer, out >>> 0, 24);
            view.setUint32(0, st.kind === "dir" ? 1 : 0, true);
            view.setBigUint64(8, BigInt(st.size), true);
            view.setBigInt64(16, BigInt(st.mtime) * 1_000_000n, true);
            return 0;
        },
        fs_set_len: (fd, lo, hi) => vfs.setLength(fd, i64(lo, hi)),
        fs_seek: (fd, lo, hi, whence) => vfs.seek(fd, i64(lo, hi), whence),
        fs_mkdir: (dir, p, l, recursive) => vfs.mkdir(dir, str(p, l), recursive !== 0),
        fs_remove: (dir, p, l, isDir) => vfs.remove(dir, str(p, l), isDir !== 0),
        fs_rename: (od, op, ol, nd, np, nl, replace) => vfs.rename(od, str(op, ol), nd, str(np, nl), replace !== 0),
        fs_readdir: (fd, reset, p, l) => vfs.readdir(fd, reset !== 0, bytes(p, l)),
        fs_sync: (fd) => vfs.sync(fd),
    };
}

/** Persists under the OPFS subdirectory `dir`. */
export function opfsStore(dir = "zx"): Store | null {
    const storage = (globalThis as { navigator?: Navigator }).navigator?.storage;
    if (!storage?.getDirectory) return null;
    const notFound = (err: unknown) => (err as DOMException).name === "NotFoundError";

    // Created on first write, so apps that never use files leave nothing behind.
    const walk = async (path: string, create: boolean): Promise<FileSystemDirectoryHandle | null> => {
        let handle = await storage.getDirectory();
        for (const seg of [dir, ...path.split("/").filter(Boolean)]) {
            try {
                handle = await handle.getDirectoryHandle(seg, { create });
            } catch (err) {
                if (!create && notFound(err)) return null;
                throw err;
            }
        }
        return handle;
    };

    return {
        async load() {
            const out: { path: string; data?: Uint8Array }[] = [];
            const visit = async (handle: FileSystemDirectoryHandle, path: string): Promise<void> => {
                for await (const [name, child] of (handle as unknown as AsyncIterable<[string, FileSystemHandle]>)) {
                    const p = `${path}/${name}`;
                    if (child.kind === "directory") {
                        out.push({ path: p });
                        await visit(child as FileSystemDirectoryHandle, p);
                    } else {
                        const file = await (child as FileSystemFileHandle).getFile();
                        out.push({ path: p, data: new Uint8Array(await file.arrayBuffer()) });
                    }
                }
            };
            const root = await walk("/", false);
            if (root) await visit(root, "");
            return out.sort((a, b) => a.path.split("/").length - b.path.split("/").length);
        },
        async write(path, data) {
            const dirHandle = (await walk(parent(path), true))!;
            const file = await dirHandle.getFileHandle(basename(path), { create: true });
            const w = await file.createWritable();
            await w.write(data as Uint8Array<ArrayBuffer>);
            await w.close();
        },
        async mkdir(path) {
            await walk(path, true);
        },
        async remove(path) {
            const dirHandle = await walk(parent(path), false);
            try {
                await dirHandle?.removeEntry(basename(path), { recursive: true });
            } catch (err) {
                if (!notFound(err)) throw err;
            }
        },
    };
}

/** Mounts the browser file system: OPFS when available, memory only otherwise. */
export async function mountBrowserFs(store: Store | null = opfsStore()): Promise<Vfs> {
    const vfs = new Vfs(store);
    try {
        await vfs.load();
    } catch (err) {
        console.warn("zx: OPFS unavailable, files will not persist:", err);
        return new Vfs(null);
    }
    return vfs;
}
