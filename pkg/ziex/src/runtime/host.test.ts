import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createHostImports, i64, ops, unsupported } from "./host";

test("ops match `Op` in imports.zig", () => {
    const zig = readFileSync(new URL("../../../../src/runtime/wasm/imports.zig", import.meta.url), "utf8");
    const body = zig.match(/pub const Op = enum\(u32\) \{([^}]*)\}/)![1]!;
    const names = body.split(",").map((s) => s.trim()).filter(Boolean);
    expect(names).toEqual([...ops]);

    const code = Number(zig.match(/pub const unsupported: i32 = (-?\d+);/)![1]);
    expect(code).toBe(unsupported);
});

test("call dispatches by op index", () => {
    const { call } = createHostImports({ ws_publish: (a, b, c, d) => a + b + c + d });
    expect(call(ops.indexOf("ws_publish"), 1, 2, 3, 4, 0, 0, 0)).toBe(10);
    expect(call(ops.indexOf("kv_get"), 0, 0, 0, 0, 0, 0, 0)).toBe(unsupported);
});

test("call rejects handlers that suspend", () => {
    const { call } = createHostImports({ kv_get: async () => 1 });
    expect(() => call(ops.indexOf("kv_get"), 0, 0, 0, 0, 0, 0, 0)).toThrow("must not suspend");
});

test("i64 joins lo and hi", () => {
    expect(i64(0xffff_ffff, -1)).toBe(-1);
    expect(i64(5, 0)).toBe(5);
    expect(i64(0, 1)).toBe(0x1_0000_0000);
});
