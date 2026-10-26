import assert from "node:assert/strict";
import { test } from "node:test";
import {
    Kind,
    MAGIC,
    Writer,
    decodeArgs,
    decodePair,
    decodeStrings,
    encodePair,
    encodeRecords,
    encodeRows,
    encodeStrings,
    writeValue,
} from "./wire.ts";

function hex(bytes: Uint8Array): string {
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

test("encodePair golden", () => {
    const encoded = encodePair(42, 3);
    assert.equal(hex(encoded), "5a444231" + "02" + "2a00000000000000" + "0300000000000000");
    assert.equal(encoded[4], Kind.pair);
    assert.deepEqual(decodePair(encoded), { a: 42, b: 3 });
    assert.equal(new DataView(encoded.buffer, encoded.byteOffset, 4).getUint32(0, true), MAGIC);
});

test("encodeStrings roundtrip", () => {
    const names = ["alpha", "beta/γ", ""];
    assert.deepEqual(decodeStrings(encodeStrings(names)), names);
    assert.deepEqual(decodeStrings(encodeStrings([])), []);
});

test("encodeRecords and encodeRows kinds", () => {
    assert.equal(encodeRecords(["id", "name"], [[1, "a"]])[4], Kind.records);
    assert.equal(encodeRows([[1, 2], ["a"]])[4], Kind.rows);
});

test("decodeArgs list", () => {
    const w = new Writer(64);
    w.u32(MAGIC);
    w.u8(Kind.args);
    w.u8(1);
    w.u32(3);
    writeValue(w, 9);
    writeValue(w, "x");
    writeValue(w, null);
    assert.deepEqual(decodeArgs(w.finish()), [9, "x", null]);
});
