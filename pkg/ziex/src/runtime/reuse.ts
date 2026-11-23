import { newHttpState, toResponse, type HttpState } from "./http";
import { newWsState } from "./ws";
import { instantiate, isProcExit, type Bindings } from "./instance";
import { promising } from "./jspi";

const MAX_IDLE_INSTANCES = 4;
const MAX_REQUESTS_PER_INSTANCE = 1000;
const MAX_INSTANCE_MEMORY = 64 * 1024 * 1024;

type ReusableInstance = {
    serve: () => Promise<unknown>;
    setRequest: (request: Request, stdin?: Uint8Array) => void;
    memory: () => WebAssembly.Memory;
    http: HttpState;
    // Read live by the imports; swapped per request.
    bindings: Pick<Bindings, "kv" | "db" | "env">;
    served: number;
};

export type ServeOptions = Bindings & {
    module: WebAssembly.Module;
    request: Request;
    stdinData?: Uint8Array;
};

const reuseSupport = new WeakMap<WebAssembly.Module, boolean>();
const idleInstances = new WeakMap<WebAssembly.Module, ReusableInstance[]>();

export function supportsReuse(module: WebAssembly.Module): boolean {
    let supported = reuseSupport.get(module);
    if (supported === undefined) {
        supported = WebAssembly.Module.exports(module).some((e) => e.name === "__zx_serve");
        reuseSupport.set(module, supported);
    }
    return supported;
}

export async function serveReused(opts: ServeOptions): Promise<Response> {
    let idle = idleInstances.get(opts.module);
    if (!idle) idleInstances.set(opts.module, (idle = []));

    const reused = idle.pop();
    const inst = reused ?? await createReusable(opts);
    if (reused) inst.setRequest(opts.request, opts.stdinData);
    Object.assign(inst.http, newHttpState());
    replaceEntries(inst.bindings.kv, opts.kv);
    replaceEntries(inst.bindings.db, opts.db);
    inst.bindings.env = opts.env;

    const done = inst.serve().then(
        () => {
            inst.served++;
            if (isHealthy(inst) && idle.length < MAX_IDLE_INSTANCES) idle.push(inst);
        },
        (e: unknown) => {
            // Never pool a trapped instance.
            if (!isProcExit(e)) throw e;
        },
    );
    return toResponse(inst.http, done);
}

function isHealthy(inst: ReusableInstance): boolean {
    return inst.served < MAX_REQUESTS_PER_INSTANCE &&
        inst.memory().buffer.byteLength <= MAX_INSTANCE_MEMORY;
}

async function createReusable(opts: ServeOptions): Promise<ReusableInstance> {
    const http = newHttpState();
    const bindings: ReusableInstance["bindings"] = { kv: { ...opts.kv }, db: { ...opts.db }, env: opts.env };

    let onPark!: () => void;
    const parked = new Promise<void>((resolve) => { onPark = resolve; });
    const { instance, setRequest, memory } = instantiate({
        ...opts,
        ...bindings,
        http,
        ws: newWsState(),
        extraArgs: ["--zx-reuse"],
        onPark,
        getEnv: () => bindings.env,
    });

    const exited = promising!(instance.exports._start as () => void)().then(() => {
        throw new Error("ziex: wasm exited before parking for reuse");
    });
    await Promise.race([parked, exited]);

    return {
        serve: promising!(instance.exports.__zx_serve as () => void),
        setRequest,
        memory,
        http,
        bindings,
        served: 0,
    };
}

function replaceEntries<T>(target: Record<string, T>, source: Record<string, T>): void {
    for (const key of Object.keys(target)) delete target[key];
    Object.assign(target, source);
}
