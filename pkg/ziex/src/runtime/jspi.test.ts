// Run with JSPI: node --experimental-wasm-jspi --test src/runtime/jspi.test.ts
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createSuspendGate, hasJspi } from "./jspi.ts";

const fixture = fileURLToPath(new URL("../../test/suspend.zig", import.meta.url));

function buildFixture(): Uint8Array | null {
    try {
        const out = join(mkdtempSync(join(tmpdir(), "zx-jspi-")), "suspend.wasm");
        execFileSync("zig", ["build-exe", fixture, "-target", "wasm32-freestanding", "-fno-entry", "-rdynamic", "-ODebug", `-femit-bin=${out}`]);
        return readFileSync(out);
    } catch {
        return null;
    }
}

const wasm = hasJspi ? buildFixture() : null;
const skip = !hasJspi ? "needs JSPI (--experimental-wasm-jspi)" : !wasm ? "needs zig on PATH" : false;

async function setup() {
    const gate = createSuspendGate()!;
    const waits = new Map<number, () => void>();
    const wait = gate.suspending((id: number) => new Promise<void>((resolve) => waits.set(id, resolve)));
    const fail = gate.suspending(async (id: number): Promise<number> => {
        await null;
        throw new Error(`fail ${id}`);
    });
    const { instance } = await WebAssembly.instantiate(wasm as BufferSource, { env: { wait, fail } });
    const ex = instance.exports as Record<string, any>;
    const settle = () => new Promise((r) => setTimeout(r, 5));
    const release = async (id: number) => {
        await settle();
        waits.get(id)!();
        await settle();
    };
    return {
        run: gate.promising(ex.run) as (id: number) => Promise<number>,
        runTwice: gate.promising(ex.runTwice) as (id: number) => Promise<number>,
        runFailing: gate.promising(ex.runFailing) as (id: number) => Promise<number>,
        scribble: ex.scribble as () => void,
        release,
    };
}

test("gate > out-of-order completion keeps suspended stacks intact", { skip }, async () => {
    const w = await setup();
    const a = w.run(1);
    const b = w.run(2);
    await w.release(1); // the shallower call finishes first
    w.scribble();
    await w.release(2);
    assert.deepEqual(await Promise.all([a, b]), [0, 0]);
});

test("gate > every release order of three calls", { skip }, async () => {
    for (const order of [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]) {
        const w = await setup();
        const calls = [w.run(1), w.run(2), w.run(3)];
        for (const id of order) {
            await w.release(id);
            w.scribble();
        }
        assert.deepEqual(await Promise.all(calls), [0, 0, 0], `order ${order}`);
    }
});

test("gate > a resumed call that suspends again", { skip }, async () => {
    const w = await setup();
    const a = w.runTwice(1);
    const b = w.run(2);
    await w.release(1);
    w.scribble();
    await w.release(2); // b finishes, then a resumes and waits on 101
    w.scribble();
    await w.release(101);
    assert.deepEqual(await Promise.all([a, b]), [0, 0]);
});

test("gate > calls made while another waits for its turn still run", { skip }, async () => {
    const w = await setup();
    const a = w.run(1);
    const b = w.run(2);
    await w.release(1); // a is done but must wait for b
    const c = w.run(3); // a new call can still start and suspend
    await w.release(3);
    await w.release(2);
    assert.deepEqual(await Promise.all([a, b, c]), [0, 0, 0]);
});

test("gate > a failing import rejects the call and the gate keeps working", { skip }, async () => {
    const w = await setup();
    await assert.rejects(w.runFailing(1), /fail 1/);
    const b = w.run(2);
    await w.release(2);
    assert.equal(await b, 0);
});
