export class ProcExit extends Error {
    constructor(public readonly code: number) {
        super(`proc_exit(${code})`);
    }
}

export type WASI = {
    wasiImport: Record<string, (...args: any[]) => unknown>;
    start(instance: {
        exports: { memory: WebAssembly.Memory; _start: () => unknown };
    }): number;
    initialize?(instance: {
        exports: { memory: WebAssembly.Memory; _initialize?: () => unknown };
    }): void;
};

/**
 * WASI imports for request argv/stdin. Response body uses the `http_*` host ops, not stdout.
 * `setRequest` swaps the request so one instance can serve many (see `__zx_serve`).
 */
export function createWasiImports({
    request,
    stdinData,
    extraArgs = [],
    env,
}: {
    request: Request;
    stdinData?: Uint8Array;
    extraArgs?: string[];
    env?: unknown;
}) {
    const encoder = new TextEncoder();
    const environ = environOf(env).map((e) => encoder.encode(e + "\0"));
    const environBufSize = environ.reduce((s, e) => s + e.length, 0);

    let encodedArgs: Uint8Array[] = [];
    let argBufSize = 0;
    let stdinOffset = 0;

    function setRequest(next: Request, nextStdin?: Uint8Array): void {
        // Build args prefixed with a dummy argv[0].
        const url = new URL(next.url);
        const argStrings: string[] = [
            "wasm",
            "--pathname", url.pathname,
            "--method", next.method,
            "--search", url.search,
            "--url", url.href,
            ...extraArgs,
        ];
        next.headers.forEach((value, name) => {
            if (value) argStrings.push("--header", `${name}:${value}`);
        });

        encodedArgs = argStrings.map((a) => encoder.encode(a + "\0"));
        argBufSize = encodedArgs.reduce((s, a) => s + a.length, 0);
        stdinData = nextStdin;
        stdinOffset = 0;
    }
    setRequest(request, stdinData);

    // WASM memory - set after instantiation
    let wasmMemory: WebAssembly.Memory = null!;
    const setMemory = (m: WebAssembly.Memory) => { wasmMemory = m; };

    let stderrPartial = '';
    const stderrDecoder = new TextDecoder('utf-8', { fatal: false, ignoreBOM: true });

    function processStderrChunk(chunk: Uint8Array): void {
        const text = stderrDecoder.decode(chunk, { stream: true });
        const lines = (stderrPartial + text).split('\n');
        stderrPartial = lines.pop() ?? '';
        for (const line of lines) {
            if (line.length > 0) {
                console.error('[ziex]', line);
            }
        }
    }

    function v() { return new DataView(wasmMemory.buffer); }
    function m() { return new Uint8Array(wasmMemory.buffer); }

    const wasiImport = {
        args_sizes_get(argc_ptr: number, argv_buf_size_ptr: number): number {
            v().setUint32(argc_ptr, encodedArgs.length, true);
            v().setUint32(argv_buf_size_ptr, argBufSize, true);
            return 0;
        },
        args_get(argv_ptr: number, argv_buf_ptr: number): number {
            const dv = v(); const mem = m();
            let offset = argv_buf_ptr;
            for (const arg of encodedArgs) {
                dv.setUint32(argv_ptr, offset, true);
                mem.set(arg, offset);
                argv_ptr += 4;
                offset += arg.length;
            }
            return 0;
        },
        environ_sizes_get(count_ptr: number, buf_size_ptr: number): number {
            v().setUint32(count_ptr, environ.length, true);
            v().setUint32(buf_size_ptr, environBufSize, true);
            return 0;
        },
        environ_get(environ_ptr: number, environ_buf_ptr: number): number {
            const dv = v(); const mem = m();
            let offset = environ_buf_ptr;
            for (const entry of environ) {
                dv.setUint32(environ_ptr, offset, true);
                mem.set(entry, offset);
                environ_ptr += 4;
                offset += entry.length;
            }
            return 0;
        },
        fd_write(fd: number, iovs_ptr: number, iovs_len: number, nwritten_ptr: number): number {
            const dv = v(); const mem = m();
            let written = 0;
            for (let i = 0; i < iovs_len; i++) {
                const buf_ptr = dv.getUint32(iovs_ptr + i * 8, true);
                const buf_len = dv.getUint32(iovs_ptr + i * 8 + 4, true);
                const chunk = mem.slice(buf_ptr, buf_ptr + buf_len);
                // fd 2 (stderr) for logs only.
                if (fd === 2) processStderrChunk(chunk);
                written += buf_len;
            }
            dv.setUint32(nwritten_ptr, written, true);
            return 0;
        },
        fd_read(fd: number, iovs_ptr: number, iovs_len: number, nread_ptr: number): number {
            const dv = v(); const mem = m();
            const stdin = stdinData ?? new Uint8Array(0);
            let totalRead = 0;
            for (let i = 0; i < iovs_len; i++) {
                const buf_ptr = dv.getUint32(iovs_ptr + i * 8, true);
                const buf_len = dv.getUint32(iovs_ptr + i * 8 + 4, true);
                if (fd === 0 && stdinOffset < stdin.length) {
                    const toRead = Math.min(buf_len, stdin.length - stdinOffset);
                    mem.set(stdin.subarray(stdinOffset, stdinOffset + toRead), buf_ptr);
                    stdinOffset += toRead;
                    totalRead += toRead;
                }
            }
            dv.setUint32(nread_ptr, totalRead, true);
            return 0;
        },
        fd_fdstat_get(_fd: number, fdstat_ptr: number): number {
            const dv = v();
            dv.setUint8(fdstat_ptr, 2);             // fs_filetype: regular_file
            dv.setUint8(fdstat_ptr + 1, 0);         // padding
            dv.setUint16(fdstat_ptr + 2, 0, true);  // fs_flags
            dv.setUint32(fdstat_ptr + 4, 0, true);  // padding
            dv.setBigUint64(fdstat_ptr + 8, 0n, true);   // fs_rights_base
            dv.setBigUint64(fdstat_ptr + 16, 0n, true);  // fs_rights_inheriting
            return 0;
        },
        fd_prestat_get(_fd: number, _bufptr: number): number {
            return 8; // WASI_EBADF - no preopened directories
        },
        fd_prestat_dir_name(_fd: number, _path: number, _path_len: number): number {
            return 8; // WASI_EBADF
        },
        fd_close(_fd: number): number { return 0; },
        fd_pread(_fd: number, _iovs: number, _iovs_len: number, _offset: bigint, nread_ptr: number): number {
            v().setUint32(nread_ptr, 0, true);
            return 0;
        },
        fd_pwrite(_fd: number, _iovs: number, _iovs_len: number, _offset: bigint, nwritten_ptr: number): number {
            v().setUint32(nwritten_ptr, 0, true);
            return 0;
        },
        fd_filestat_get(_fd: number, filestat_ptr: number): number {
            const dv = v();
            dv.setBigUint64(filestat_ptr, 0n, true);       // dev
            dv.setBigUint64(filestat_ptr + 8, 0n, true);   // ino
            dv.setUint8(filestat_ptr + 16, 2);             // filetype: regular_file
            dv.setBigUint64(filestat_ptr + 24, 1n, true);  // nlink
            dv.setBigUint64(filestat_ptr + 32, 0n, true);  // size
            dv.setBigUint64(filestat_ptr + 40, 0n, true);  // atim
            dv.setBigUint64(filestat_ptr + 48, 0n, true);  // mtim
            dv.setBigUint64(filestat_ptr + 56, 0n, true);  // ctim
            return 0;
        },
        fd_filestat_set_size(_fd: number, _size: bigint): number { return 76; },
        fd_filestat_set_times(_fd: number, _atim: bigint, _mtim: bigint, _fst_flags: number): number { return 76; },
        fd_fdstat_set_flags(_fd: number, _flags: number): number { return 0; },
        fd_fdstat_set_rights(_fd: number, _rights_base: bigint, _rights_inheriting: bigint): number { return 0; },
        fd_sync(_fd: number): number { return 0; },
        fd_datasync(_fd: number): number { return 0; },
        fd_advise(_fd: number, _offset: bigint, _len: bigint, _advice: number): number { return 0; },
        fd_allocate(_fd: number, _offset: bigint, _len: bigint): number { return 76; },
        fd_tell(_fd: number, offset_ptr: number): number {
            v().setBigUint64(offset_ptr, 0n, true);
            return 0;
        },
        fd_renumber(_from: number, _to: number): number { return 0; },
        path_filestat_set_times(_fd: number, _flags: number, _path: number, _path_len: number, _atim: bigint, _mtim: bigint, _fst_flags: number): number { return 76; },
        path_link(_old_fd: number, _old_flags: number, _old_path: number, _old_path_len: number, _new_fd: number, _new_path: number, _new_path_len: number): number { return 76; },
        path_symlink(_old_path: number, _old_path_len: number, _fd: number, _new_path: number, _new_path_len: number): number { return 76; },
        proc_raise(_sig: number): number { return 0; },
        sock_recv(_fd: number, _ri_data: number, _ri_data_len: number, _ri_flags: number, ro_datalen_ptr: number, ro_flags_ptr: number): number {
            v().setUint32(ro_datalen_ptr, 0, true);
            v().setUint32(ro_flags_ptr, 0, true);
            return 76;
        },
        sock_send(_fd: number, _si_data: number, _si_data_len: number, _si_flags: number, so_datalen_ptr: number): number {
            v().setUint32(so_datalen_ptr, 0, true);
            return 76;
        },
        sock_shutdown(_fd: number, _how: number): number { return 76; },
        fd_seek(_fd: number, _offset: bigint, _whence: number, newoffset_ptr: number): number {
            v().setBigInt64(newoffset_ptr, 0n, true);
            return 0;
        },
        proc_exit(code: number): never {
            throw new ProcExit(code);
        },
        sched_yield(): number { return 0; },
        clock_time_get(_id: number, _precision: bigint, time_ptr: number): number {
            v().setBigUint64(time_ptr, BigInt(Date.now()) * 1_000_000n, true);
            return 0;
        },
        clock_res_get(_id: number, res_ptr: number): number {
            v().setBigUint64(res_ptr, 1_000_000n, true);
            return 0;
        },
        random_get(buf_ptr: number, buf_len: number): number {
            crypto.getRandomValues(new Uint8Array(wasmMemory.buffer, buf_ptr, buf_len));
            return 0;
        },
        path_open(_fd: number, _dirflags: number, _path: number, _path_len: number, _oflags: number, _rights_base: bigint, _rights_inheriting: bigint, _fdflags: number, opened_fd_ptr: number): number {
            v().setInt32(opened_fd_ptr, -1, true);
            return 76; // WASI_ENOTCAPABLE
        },
        path_create_directory(_fd: number, _path: number, _path_len: number): number { return 76; },
        path_unlink_file(_fd: number, _path: number, _path_len: number): number { return 76; },
        path_remove_directory(_fd: number, _path: number, _path_len: number): number { return 76; },
        path_rename(_fd: number, _old_path: number, _old_path_len: number, _new_fd: number, _new_path: number, _new_path_len: number): number { return 76; },
        path_filestat_get(_fd: number, _flags: number, _path: number, _path_len: number, filestat_ptr: number): number {
            new Uint8Array(wasmMemory.buffer, filestat_ptr, 64).fill(0);
            return 76;
        },
        path_readlink(_fd: number, _path: number, _path_len: number, _buf: number, _buf_len: number, nread_ptr: number): number {
            v().setUint32(nread_ptr, 0, true);
            return 76;
        },
        fd_readdir(_fd: number, _buf: number, _buf_len: number, _cookie: bigint, bufused_ptr: number): number {
            v().setUint32(bufused_ptr, 0, true);
            return 76;
        },
        poll_oneoff(_in: number, _out: number, _nsubscriptions: number, nevents_ptr: number): number {
            v().setUint32(nevents_ptr, 0, true);
            return 0;
        },
    };

    return { wasiImport, setMemory, setRequest };
}

export function mergeUint8Arrays(arrays: Uint8Array[]): Uint8Array {
    const totalLen = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLen);
    let offset = 0;
    for (const arr of arrays) {
        result.set(arr, offset);
        offset += arr.length;
    }
    return result;
}

// String-valued bindings (vars and secrets) as `KEY=value`; KV, D1 and other objects are skipped.
export function environOf(env: unknown): string[] {
    if (!env || typeof env !== "object") return [];
    return Object.entries(env)
        .filter((entry): entry is [string, string] => typeof entry[1] === "string")
        .map(([key, value]) => `${key}=${value}`);
}
