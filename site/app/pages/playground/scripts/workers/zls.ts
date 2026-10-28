import { WASI, PreopenDirectory, Fd, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { getLatestZigArchive, getZxArchive, fetchWithCache } from "../utils";

declare const VERSION: string;

type LspWasmExports = {
    memory: WebAssembly.Memory;
    createServer: () => void;
    allocMessage: (len: number) => number;
    call: () => void;
    outputMessageCount: () => number;
    outputMessagePtr: (index: number) => number;
    outputMessageLen: (index: number) => number;
};

type LspInstance = { exports: LspWasmExports };

class Stdio extends Fd {
    constructor() {
        super();
    }

    fd_write(_slice: Uint8Array): { ret: number; nwritten: number } {
        throw new Error("Cannot write");
    }

    fd_read(_size: number): { ret: number; data: Uint8Array } {
        throw new Error("Cannot read");
    }
}

let lsp: LspInstance | null = null;
let ready = false;
let bufferedMessages: string[] = [];

function callServer(instance: LspInstance, message: string): string[] {
    const inputMessageBuffer = new TextEncoder().encode(message);
    const ptr = instance.exports.allocMessage(inputMessageBuffer.length);
    new Uint8Array(instance.exports.memory.buffer).set(inputMessageBuffer, ptr);
    instance.exports.call();

    const outs: string[] = [];
    const outputMessageCount = instance.exports.outputMessageCount();
    for (let i = 0; i < outputMessageCount; i++) {
        const start = instance.exports.outputMessagePtr(i);
        const end = start + instance.exports.outputMessageLen(i);
        const outputMessageBuffer = new Uint8Array(instance.exports.memory.buffer).slice(start, end);
        outs.push(new TextDecoder().decode(outputMessageBuffer));
    }
    return outs;
}

function sendMessage(message: string) {
    if (!lsp) return;
    for (const raw of callServer(lsp, message)) {
        postMessage(raw);
    }
}

onmessage = (event) => {
    if (ready) {
        sendMessage(event.data);
    } else {
        bufferedMessages.push(event.data);
    }
};

async function instantiateLsp(
    name: string,
    url: string,
    fds: Fd[],
): Promise<LspInstance> {
    const wasii = new WASI([name], ["ZIEX_MODULE_PATH=/zx/src/root.zig"], fds, { debug: false });
    const response = await fetchWithCache(url);
    const { instance } = await WebAssembly.instantiateStreaming(response, {
        wasi_snapshot_preview1: wasii.wasiImport,
    });
    // @ts-ignore
    wasii.inst = instance;
    const lspInstance = instance as unknown as LspInstance;
    lspInstance.exports.createServer();
    return lspInstance;
}

function makeFds(libDirectory: PreopenDirectory, zxDirectory: PreopenDirectory): Fd[] {
    return [
        new Stdio(),
        new Stdio(),
        ConsoleStdout.lineBuffered((line) => postMessage(JSON.stringify({ stderr: line }))),
        new PreopenDirectory(".", new Map([["zx", zxDirectory]])),
        new PreopenDirectory("/zx", zxDirectory.contents),
        new PreopenDirectory("/lib", libDirectory.contents),
        new PreopenDirectory("/cache", new Map()),
    ];
}

(async () => {
    const libDirectory = await getLatestZigArchive();
    const zxDirectory = await getZxArchive();

    try {
        lsp = await instantiateLsp(
            "zx.wasm",
            `/assets/playground/zx-${VERSION}.wasm`,
            makeFds(libDirectory, zxDirectory),
        );
    } catch (reason) {
        console.error("ZX LSP failed to load", reason);
        postMessage(JSON.stringify({ stderr: `ZX LSP failed: ${reason}` }));
        return;
    }

    ready = true;
    for (const bufferedMessage of bufferedMessages) {
        sendMessage(bufferedMessage);
    }
    bufferedMessages = [];
})();
