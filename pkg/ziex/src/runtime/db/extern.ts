import { type WasmAllocRef, writeJsonOut } from "../../wasm/core";
import { Suspending } from "../jspi";

export type { WasmAllocRef };

export type DbValue =
    | null
    | string
    | number
    | boolean
    | ArrayBuffer
    | ArrayBufferView;

/** Result of a mutating statement (`INSERT`/`UPDATE`/`DELETE`). */
export interface ExecResult {
    meta?: {
        changes?: number;
        last_row_id?: number;
    };
}

/** Prepared statement - Cloudflare D1–shaped; Postgres/SQLite adapters implement the same. */
export interface PreparedStatement {
    bind(...values: DbValue[]): PreparedStatement;
    first<T = Record<string, unknown>>(): Promise<T | null>;
    all<T = Record<string, unknown>>(): Promise<{ results?: T[] }>;
    raw(options?: { columnNames?: boolean }): Promise<unknown[][]>;
    run(): Promise<ExecResult>;
}

/**
 * SQL database binding for `__zx_db`.
 * Shape matches Cloudflare D1 so Workers bindings work as-is; Postgres and other
 * drivers adapt to this interface.
 */
export interface Database {
    prepare(query: string): PreparedStatement;
}

type JsonBinding =
    | { kind: "none" }
    | { kind: "positional"; values: JsonValue[] }
    | { kind: "named"; values: { name: string; value: JsonValue }[] };

type JsonValue =
    | { kind: "null" }
    | { kind: "integer"; integer: number }
    | { kind: "float"; float: number }
    | { kind: "text"; text: string }
    | { kind: "blob"; blob: string }
    | { kind: "boolean"; boolean: boolean };

type WireValue =
    | { kind: "null" }
    | { kind: "integer"; integer: number }
    | { kind: "float"; float: number }
    | { kind: "text"; text: string }
    | { kind: "blob"; blob: string }
    | { kind: "boolean"; boolean: boolean };

type WireField = { name: string; value: WireValue };
type WireRow = { fields: WireField[] };

function decodeBlob(base64: string): Uint8Array {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

function toDbValue(value: JsonValue): DbValue {
    switch (value.kind) {
        case "null": return null;
        case "integer": return value.integer;
        case "float": return value.float;
        case "text": return value.text;
        case "blob": return decodeBlob(value.blob);
        case "boolean": return value.boolean;
    }
}

function toPositionalBindings(json: JsonBinding): DbValue[] {
    switch (json.kind) {
        case "none":
            return [];
        case "positional":
            return json.values.map(toDbValue);
        case "named":
            throw new Error("named SQL bindings are not supported yet");
    }
}

function toWireValue(value: unknown): WireValue {
    if (value === null || value === undefined) return { kind: "null" };
    if (typeof value === "string") return { kind: "text", text: value };
    if (typeof value === "boolean") return { kind: "boolean", boolean: value };
    if (typeof value === "number") {
        return Number.isInteger(value)
            ? { kind: "integer", integer: value }
            : { kind: "float", float: value };
    }
    if (value instanceof ArrayBuffer) {
        const bytes = new Uint8Array(value);
        let binary = "";
        for (const byte of bytes) binary += String.fromCharCode(byte);
        return { kind: "blob", blob: btoa(binary) };
    }
    if (ArrayBuffer.isView(value)) {
        const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        let binary = "";
        for (const byte of bytes) binary += String.fromCharCode(byte);
        return { kind: "blob", blob: btoa(binary) };
    }
    return { kind: "text", text: String(value) };
}

function objectToWireRow(record: Record<string, unknown>): WireRow {
    return {
        fields: Object.entries(record).map(([name, value]) => ({
            name,
            value: toWireValue(value),
        })),
    };
}

function valuesToWireRows(rows: unknown[][]): WireValue[][] {
    return rows.map((row) => row.map((value) => toWireValue(value)));
}

/**
 * Build the `__zx_db` host functions for SQL database bindings.
 *
 * ```ts
 * if (__FEAT_DB__) importObject.__zx_db = createDbImports(bindings, getMemory, allocRef);
 * ```
 */
export function createDbImports(
    bindings: Record<string, Database>,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): WebAssembly.ModuleImports {
    const decoder = new TextDecoder();

    function readStr(ptr: number, len: number): string {
        if (len === 0) return "";
        return decoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
    }

    function binding(ns: string): Database | null {
        return bindings[ns] ?? bindings["default"] ?? null;
    }

    async function statement(
        ns_ptr: number,
        ns_len: number,
        sql_ptr: number,
        sql_len: number,
        bindings_ptr: number,
        bindings_len: number,
    ): Promise<PreparedStatement | null> {
        const database = binding(readStr(ns_ptr, ns_len));
        if (!database) return null;

        const sql = readStr(sql_ptr, sql_len);
        const bindingsJson = JSON.parse(readStr(bindings_ptr, bindings_len)) as JsonBinding;
        return database.prepare(sql).bind(...toPositionalBindings(bindingsJson));
    }

    if (!Suspending) {
        return {
            db_open: (_ns: number, _ns_len: number): number => -1,
            db_run: (_a: number, _b: number, _c: number, _d: number, _e: number, _f: number, _g: number): number => -1,
            db_get: (_a: number, _b: number, _c: number, _d: number, _e: number, _f: number, _g: number): number => -1,
            db_all: (_a: number, _b: number, _c: number, _d: number, _e: number, _f: number, _g: number): number => -1,
            db_values: (_a: number, _b: number, _c: number, _d: number, _e: number, _f: number, _g: number): number => -1,
        };
    }

    return {
        db_open: (ns_ptr: number, ns_len: number): number => binding(readStr(ns_ptr, ns_len)) ? 0 : -1,

        db_run: new Suspending(async (
            ns_ptr: number, ns_len: number,
            sql_ptr: number, sql_len: number,
            bindings_ptr: number, bindings_len: number,
            out_ptr: number,
        ): Promise<number> => {
            const stmt = await statement(ns_ptr, ns_len, sql_ptr, sql_len, bindings_ptr, bindings_len);
            if (!stmt) return -1;
            const result = await stmt.run();
            return writeJsonOut(getMemory, allocRef, out_ptr, {
                last_insert_rowid: result.meta?.last_row_id ?? 0,
                changes: result.meta?.changes ?? 0,
            });
        }),

        db_get: new Suspending(async (
            ns_ptr: number, ns_len: number,
            sql_ptr: number, sql_len: number,
            bindings_ptr: number, bindings_len: number,
            out_ptr: number,
        ): Promise<number> => {
            const stmt = await statement(ns_ptr, ns_len, sql_ptr, sql_len, bindings_ptr, bindings_len);
            if (!stmt) return -1;
            const row = await stmt.first<Record<string, unknown>>();
            if (!row) {
                new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                return 0;
            }
            return writeJsonOut(getMemory, allocRef, out_ptr, [objectToWireRow(row)]);
        }),

        db_all: new Suspending(async (
            ns_ptr: number, ns_len: number,
            sql_ptr: number, sql_len: number,
            bindings_ptr: number, bindings_len: number,
            out_ptr: number,
        ): Promise<number> => {
            const stmt = await statement(ns_ptr, ns_len, sql_ptr, sql_len, bindings_ptr, bindings_len);
            if (!stmt) return -1;
            const result = await stmt.all<Record<string, unknown>>();
            const rows = (result.results ?? []).map(objectToWireRow);
            if (rows.length === 0) {
                new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                return 0;
            }
            return writeJsonOut(getMemory, allocRef, out_ptr, rows);
        }),

        db_values: new Suspending(async (
            ns_ptr: number, ns_len: number,
            sql_ptr: number, sql_len: number,
            bindings_ptr: number, bindings_len: number,
            out_ptr: number,
        ): Promise<number> => {
            const stmt = await statement(ns_ptr, ns_len, sql_ptr, sql_len, bindings_ptr, bindings_len);
            if (!stmt) return -1;
            const rows = await stmt.raw();
            if (rows.length === 0) {
                new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                return 0;
            }
            return writeJsonOut(getMemory, allocRef, out_ptr, valuesToWireRows(rows));
        }),
    };
}
