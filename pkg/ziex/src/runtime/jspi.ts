type SuspendingCtor = new <T extends (...args: any[]) => any>(fn: T) => T;
type Promising = <T extends (...args: any[]) => any>(fn: T) => (...args: Parameters<T>) => Promise<unknown>;

export const Suspending = (WebAssembly as any).Suspending as SuspendingCtor | undefined;
export const promising = (WebAssembly as any).promising as Promising | undefined;

export const hasJspi: boolean = typeof Suspending === "function" && typeof promising === "function";

type Pending = { callId: number; done: boolean; resume: (() => void) | null };

/**
 * Keeps JSPI safe when several calls into one wasm instance are suspended at once.
 *
 * JSPI swaps the wasm call stack but not the shadow stack Zig keeps in linear memory
 * (`__stack_pointer`). Each call that enters while others are suspended sits deeper on
 * that shadow stack, so suspended calls must resume in the reverse order they suspended.
 * The gate lets them all start and wait concurrently and only orders the resumptions.
 *
 * Route every export that may suspend through `promising` and every suspending import
 * through `suspending`.
 */
export class SuspendGate {
    #promising: Promising;
    #Suspending: SuspendingCtor;
    // Suspended calls, oldest (shallowest) first.
    #stack: Pending[] = [];
    // Call whose synchronous part is running right now.
    #current = 0;
    // Call that was resumed and hasn't suspended again or finished yet.
    #resuming = 0;
    // Calls that arrived between a resume and the resumed call running.
    #deferred: (() => void)[] = [];
    #nextId = 1;

    constructor(jspi: { promising: Promising; Suspending: SuspendingCtor }) {
        this.#promising = jspi.promising;
        this.#Suspending = jspi.Suspending;
    }

    promising<F extends (...args: any[]) => any>(fn: F): (...args: Parameters<F>) => Promise<unknown> {
        const run = this.#promising(fn);
        return (...args) => {
            if (this.#resuming === 0) return this.#call(run, args);
            return new Promise((resolve, reject) => {
                this.#deferred.push(() => this.#call(run, args).then(resolve, reject));
            });
        };
    }

    suspending<F extends (...args: any[]) => Promise<any>>(fn: F): F {
        return new this.#Suspending(async (...args: Parameters<F>) => {
            const entry: Pending = { callId: this.#owner(), done: false, resume: null };
            this.#stack.push(entry);
            let value: unknown;
            let error: unknown;
            let failed = false;
            try {
                value = await fn(...args);
            } catch (err) {
                error = err;
                failed = true;
            }
            entry.done = true;
            await new Promise<void>((resolve) => {
                entry.resume = resolve;
                this.#tryResume();
            });
            if (failed) throw error;
            return value;
        }) as unknown as F;
    }

    #call(run: (...args: any[]) => Promise<unknown>, args: any[]): Promise<unknown> {
        const id = this.#nextId++;
        const prev = this.#current;
        this.#current = id;
        let result: Promise<unknown>;
        try {
            result = run(...args);
        } finally {
            this.#current = prev;
        }
        return result.finally(() => {
            if (this.#resuming === id) this.#settle();
            this.#tryResume();
        });
    }

    /** The call making a suspending import: the one just resumed, or the one entering now. */
    #owner(): number {
        if (this.#resuming === 0) return this.#current;
        const id = this.#resuming;
        this.#settle();
        return id;
    }

    #settle(): void {
        this.#resuming = 0;
        // Not inline: this can run inside an import, before the caller has suspended.
        queueMicrotask(() => {
            while (this.#resuming === 0 && this.#deferred.length > 0) this.#deferred.shift()!();
        });
    }

    #tryResume(): void {
        if (this.#resuming !== 0) return;
        const top = this.#stack[this.#stack.length - 1];
        if (!top || !top.done || !top.resume) return;
        this.#stack.pop();
        // Calls made outside `promising` can't be tracked; resume them untracked.
        this.#resuming = top.callId;
        top.resume();
    }
}

/** A gate for one wasm instance, or null without JSPI. */
export function createSuspendGate(): SuspendGate | null {
    return hasJspi ? new SuspendGate({ promising: promising!, Suspending: Suspending! }) : null;
}
