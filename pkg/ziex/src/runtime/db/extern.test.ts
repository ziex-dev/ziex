import { describe, expect, test } from "bun:test";
import { queryError } from "./extern";

describe("queryError", () => {
    test("unwraps D1 errors and their offset", () => {
        expect(queryError(new Error("D1_ERROR: no such column: age at offset 7: SQLITE_ERROR")))
            .toEqual({ message: "no such column: age", offset: 7 });
        expect(queryError(new Error('D1_ERROR: near "SELEC": syntax error at offset 0: SQLITE_ERROR')))
            .toEqual({ message: 'near "SELEC": syntax error', offset: 0 });
        expect(queryError(new Error("D1_ERROR: no such table: nope: SQLITE_ERROR")))
            .toEqual({ message: "no such table: nope", offset: -1 });
    });

    test("keeps other errors and a driver-provided offset", () => {
        expect(queryError(new Error("boom"))).toEqual({ message: "boom", offset: -1 });
        expect(queryError("boom")).toEqual({ message: "boom", offset: -1 });
        expect(queryError(Object.assign(new Error("bad"), { offset: 3 }))).toEqual({ message: "bad", offset: 3 });
    });
});
