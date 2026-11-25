import { i64, type Handlers } from "./host";
import {
    basename, EBADF, EBUSY, EEXIST, EINVAL, EISDIR, ENOENT, ENOSPC, ENOTDIR, ENOTEMPTY, join, parent,
    O_ALLOW_DIRECTORY, O_CREATE, O_DIRECTORY, O_EXCLUSIVE, O_READ, O_TRUNCATE, O_WRITE, ROOT_FD,
} from "./fs";

// `Io.Web`'s file system inside a Worker: OPFS sync access handles, so file data is
// never mirrored in memory and writes are durable once `fs_sync` returns. Path ops
// (open, stat, mkdir, ...) are async and suspend the guest through JSPI.
// A file has one sync access handle at a time, shared by every fd open on it here;
// another tab holding it makes `open` fail with EBUSY.

type Kind = "file" | "dir";

// Worker-only OPFS API, missing from the DOM typings.
interface FileSystemSyncAccessHandle {
    read(buffer: Uint8Array, options?: { at?: number }): number;
    write(buffer: Uint8Array, options?: { at?: number }): number;
    truncate(size: number): void;
    getSize(): number;
    flush(): void;
    close(): void;
}

type SyncFileHandle = FileSystemFileHandle & { createSyncAccessHandle(): Promise<FileSystemSyncAccessHandle> };

type OpenFile = {
    access: FileSystemSyncAccessHandle;
    refs: number;
    // Unlinked while open: removed at the last close, like POSIX.
    unlinked: boolean;
};

type Fd =
    | { kind: "file"; path: string; file: OpenFile; read: boolean; write: boolean; pos: number }
    | { kind: "dir"; path: string; entries?: [string, Kind][]; cursor: number };

function errno(err: unknown, typeMismatch = ENOTDIR): number {
    switch ((err as DOMException)?.name) {
        case "NotFoundError": return ENOENT;
        case "TypeMismatchError": return typeMismatch;
        case "NoModificationAllowedError": return EBUSY;
        case "InvalidModificationError": return ENOTEMPTY;
        case "QuotaExceededError": return ENOSPC;
        default:
            console.error("zx: worker fs:", err);
            return EINVAL;
    }
}

export class WorkerFs {
    private fds = new Map<number, Fd>([[ROOT_FD, { kind: "dir", path: "/", cursor: 0 }]]);
    private open = new Map<string, OpenFile>();
    private nextFd = ROOT_FD + 1;
    private root: Promise<FileSystemDirectoryHandle>;

    // Same OPFS directory as the page's file system.
    constructor(dir = "zx") {
        this.root = navigator.storage.getDirectory().then((r) => r.getDirectoryHandle(dir, { create: true }));
    }

    private resolve(dirFd: number, sub: string): string | number {
        const fd = this.fds.get(dirFd);
        if (!fd) return EBADF;
        if (fd.kind !== "dir") return ENOTDIR;
        return join(fd.path, sub);
    }

    private async dir(path: string, create = false): Promise<FileSystemDirectoryHandle> {
        let handle = await this.root;
        for (const seg of path.split("/").filter(Boolean)) handle = await handle.getDirectoryHandle(seg, { create });
        return handle;
    }

    // The entry at `path`, or null when it doesn't exist.
    private async entry(path: string): Promise<{ kind: Kind; handle: FileSystemHandle } | null> {
        if (path === "/") return { kind: "dir", handle: await this.root };
        let parentDir: FileSystemDirectoryHandle;
        try {
            parentDir = await this.dir(parent(path));
        } catch {
            return null;
        }
        const name = basename(path);
        try {
            return { kind: "file", handle: await parentDir.getFileHandle(name) };
        } catch (err) {
            if ((err as DOMException).name !== "TypeMismatchError") return null;
        }
        return { kind: "dir", handle: await parentDir.getDirectoryHandle(name) };
    }

    private add(fd: Fd): number {
        const n = this.nextFd++;
        this.fds.set(n, fd);
        return n;
    }

    async openAt(dirFd: number, sub: string, flags: number): Promise<number> {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        try {
            const existing = await this.entry(path);
            if (existing && flags & O_CREATE && flags & O_EXCLUSIVE) return EEXIST;
            if (existing?.kind === "dir") {
                if (flags & O_WRITE || !(flags & (O_DIRECTORY | O_ALLOW_DIRECTORY))) return EISDIR;
                return this.add({ kind: "dir", path, cursor: 0 });
            }
            if (flags & O_DIRECTORY) return existing ? ENOTDIR : ENOENT;
            if (!existing && !(flags & O_CREATE)) return ENOENT;

            let file = this.open.get(path);
            if (!file) {
                const handle = (existing
                    ? existing.handle
                    : await (await this.dir(parent(path))).getFileHandle(basename(path), { create: true })) as SyncFileHandle;
                file = { access: await handle.createSyncAccessHandle(), refs: 0, unlinked: false };
                this.open.set(path, file);
            }
            file.refs += 1;
            if (flags & O_TRUNCATE && flags & O_WRITE) file.access.truncate(0);
            return this.add({ kind: "file", path, file, read: !!(flags & O_READ), write: !!(flags & O_WRITE), pos: 0 });
        } catch (err) {
            return errno(err);
        }
    }

    close(n: number): number {
        if (n === ROOT_FD) return 0;
        const fd = this.fds.get(n);
        if (!fd) return EBADF;
        this.fds.delete(n);
        if (fd.kind === "file") this.release(fd.path, fd.file);
        return 0;
    }

    private release(path: string, file: OpenFile): void {
        file.refs -= 1;
        if (file.refs > 0) return;
        file.access.close();
        if (this.open.get(path) === file) this.open.delete(path);
        if (file.unlinked) void this.removeEntry(path).catch((err) => console.error("zx: worker fs unlink:", err));
    }

    private file(n: number): Extract<Fd, { kind: "file" }> | number {
        const fd = this.fds.get(n);
        if (!fd) return EBADF;
        return fd.kind === "file" ? fd : EISDIR;
    }

    read(n: number, out: Uint8Array, offset: number): number {
        const fd = this.file(n);
        if (typeof fd === "number") return fd;
        if (!fd.read) return EBADF;
        const at = offset < 0 ? fd.pos : offset;
        const got = fd.file.access.read(out, { at });
        if (offset < 0) fd.pos += got;
        return got;
    }

    write(n: number, bytes: Uint8Array, offset: number): number {
        const fd = this.file(n);
        if (typeof fd === "number") return fd;
        if (!fd.write) return EBADF;
        const at = offset < 0 ? fd.pos : offset;
        const wrote = fd.file.access.write(bytes, { at });
        if (offset < 0) fd.pos = at + wrote;
        return wrote;
    }

    setLength(n: number, length: number): number {
        const fd = this.file(n);
        if (typeof fd === "number") return fd;
        if (!fd.write) return EBADF;
        fd.file.access.truncate(length);
        return 0;
    }

    seek(n: number, offset: number, whence: number): number {
        const fd = this.file(n);
        if (typeof fd === "number") return fd === EISDIR ? EINVAL : fd;
        const pos = whence === 1 ? fd.pos + offset : offset;
        if (pos < 0) return EINVAL;
        fd.pos = pos;
        return 0;
    }

    sync(n: number): number {
        const fd = this.fds.get(n);
        if (!fd) return EBADF;
        if (fd.kind === "file") fd.file.access.flush();
        return 0;
    }

    // Empty `sub` stats the open fd itself.
    async stat(dirFd: number, sub: string): Promise<{ kind: Kind; size: number; mtime: number } | number> {
        let path: string;
        if (sub === "") {
            const fd = this.fds.get(dirFd);
            if (!fd) return EBADF;
            if (fd.kind === "file") return { kind: "file", size: fd.file.access.getSize(), mtime: 0 };
            path = fd.path;
        } else {
            const resolved = this.resolve(dirFd, sub);
            if (typeof resolved === "number") return resolved;
            path = resolved;
        }
        const open = this.open.get(path);
        if (open) return { kind: "file", size: open.access.getSize(), mtime: 0 };
        try {
            const entry = await this.entry(path);
            if (!entry) return ENOENT;
            if (entry.kind === "dir") return { kind: "dir", size: 0, mtime: 0 };
            const f = await (entry.handle as FileSystemFileHandle).getFile();
            return { kind: "file", size: f.size, mtime: f.lastModified };
        } catch (err) {
            return errno(err);
        }
    }

    // 1 when it already existed (`recursive` only).
    async mkdir(dirFd: number, sub: string, recursive: boolean): Promise<number> {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        try {
            const existing = await this.entry(path);
            if (existing) return !recursive ? EEXIST : existing.kind === "dir" ? 1 : ENOTDIR;
            if (recursive) {
                await this.dir(path, true);
            } else {
                await (await this.dir(parent(path))).getDirectoryHandle(basename(path), { create: true });
            }
            return 0;
        } catch (err) {
            return errno(err);
        }
    }

    private async removeEntry(path: string): Promise<void> {
        await (await this.dir(parent(path))).removeEntry(basename(path));
    }

    async remove(dirFd: number, sub: string, isDir: boolean): Promise<number> {
        const path = this.resolve(dirFd, sub);
        if (typeof path === "number") return path;
        if (path === "/") return EINVAL;
        const open = this.open.get(path);
        if (open) {
            if (isDir) return ENOTDIR;
            open.unlinked = true;
            this.open.delete(path);
            return 0;
        }
        try {
            const entry = await this.entry(path);
            if (!entry) return ENOENT;
            if (isDir && entry.kind !== "dir") return ENOTDIR;
            if (!isDir && entry.kind === "dir") return EISDIR;
            await this.removeEntry(path);
            return 0;
        } catch (err) {
            return errno(err);
        }
    }

    // Files only; `move()` where the browser has it, copying otherwise.
    async rename(oldFd: number, oldSub: string, newFd: number, newSub: string, replace: boolean): Promise<number> {
        const from = this.resolve(oldFd, oldSub);
        if (typeof from === "number") return from;
        const to = this.resolve(newFd, newSub);
        if (typeof to === "number") return to;
        if (from === to) return 0;
        if (this.open.has(from) || this.open.has(to)) return EBUSY;
        try {
            const src = await this.entry(from);
            if (!src) return ENOENT;
            if (src.kind === "dir") return EINVAL;
            const dest = await this.entry(to);
            if (dest) {
                if (!replace) return EEXIST;
                if (dest.kind === "dir") return EISDIR;
                await this.removeEntry(to);
            }
            const destDir = await this.dir(parent(to));
            const handle = src.handle as FileSystemFileHandle & { move?: (dir: FileSystemDirectoryHandle, name: string) => Promise<void> };
            if (handle.move) {
                await handle.move(destDir, basename(to));
                return 0;
            }
            const data = new Uint8Array(await (await handle.getFile()).arrayBuffer());
            const target = await ((await destDir.getFileHandle(basename(to), { create: true })) as SyncFileHandle).createSyncAccessHandle();
            try {
                target.truncate(0);
                target.write(data, { at: 0 });
                target.flush();
            } finally {
                target.close();
            }
            await this.removeEntry(from);
            return 0;
        } catch (err) {
            return errno(err);
        }
    }

    // Packs `[kind: u8 (1 = dir)][len: u16 le][name]` records; 0 at the end. Async only on reset.
    readdir(n: number, reset: boolean, out: () => Uint8Array): number | Promise<number> {
        const fd = this.fds.get(n);
        if (!fd) return EBADF;
        if (fd.kind !== "dir") return ENOTDIR;
        if (!reset && fd.entries) return pack(fd, out());
        return (async () => {
            try {
                const entries: [string, Kind][] = [];
                const dir = await this.dir(fd.path);
                for await (const [name, handle] of (dir as unknown as AsyncIterable<[string, FileSystemHandle]>)) {
                    entries.push([name, handle.kind === "directory" ? "dir" : "file"]);
                }
                entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
                fd.entries = entries;
                fd.cursor = 0;
                return pack(fd, out());
            } catch (err) {
                return errno(err);
            }
        })();
    }
}

function pack(fd: Extract<Fd, { kind: "dir" }>, out: Uint8Array): number {
    const encoder = new TextEncoder();
    let off = 0;
    while (fd.cursor < fd.entries!.length) {
        const [name, kind] = fd.entries![fd.cursor]!;
        const bytes = encoder.encode(name);
        if (off + 3 + bytes.length > out.length) return off === 0 ? EINVAL : off;
        out[off] = kind === "dir" ? 1 : 0;
        out[off + 1] = bytes.length & 0xff;
        out[off + 2] = bytes.length >> 8;
        out.set(bytes, off + 3);
        off += 3 + bytes.length;
        fd.cursor += 1;
    }
    return off;
}

// Host ops backing `Io/Web/fs.zig` in a Worker. Views are taken after any await,
// since wasm memory can grow while the guest is suspended.
export function createWorkerFsHandlers(fs: WorkerFs, getMemory: () => WebAssembly.Memory): Handlers {
    const bytes = (ptr: number, len: number) => new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);
    const decoder = new TextDecoder();
    const str = (ptr: number, len: number) => (len === 0 ? "" : decoder.decode(bytes(ptr, len)));

    return {
        fs_open: (dir, p, l, flags) => fs.openAt(dir, str(p, l), flags),
        fs_close: (fd) => fs.close(fd),
        fs_read: (fd, p, l, lo, hi) => fs.read(fd, bytes(p, l), i64(lo, hi)),
        fs_write: (fd, p, l, lo, hi) => fs.write(fd, bytes(p, l), i64(lo, hi)),
        fs_stat: (dir, p, l, out) => fs.stat(dir, str(p, l)).then((st) => {
            if (typeof st === "number") return st;
            const view = new DataView(getMemory().buffer, out >>> 0, 24);
            view.setUint32(0, st.kind === "dir" ? 1 : 0, true);
            view.setBigUint64(8, BigInt(st.size), true);
            view.setBigInt64(16, BigInt(st.mtime) * 1_000_000n, true);
            return 0;
        }),
        fs_set_len: (fd, lo, hi) => fs.setLength(fd, i64(lo, hi)),
        fs_seek: (fd, lo, hi, whence) => fs.seek(fd, i64(lo, hi), whence),
        fs_mkdir: (dir, p, l, recursive) => fs.mkdir(dir, str(p, l), recursive !== 0),
        fs_remove: (dir, p, l, isDir) => fs.remove(dir, str(p, l), isDir !== 0),
        fs_rename: (od, op, ol, nd, np, nl, replace) => fs.rename(od, str(op, ol), nd, str(np, nl), replace !== 0),
        fs_readdir: (fd, reset, p, l) => fs.readdir(fd, reset !== 0, () => bytes(p, l)),
        fs_sync: (fd) => fs.sync(fd),
    };
}
