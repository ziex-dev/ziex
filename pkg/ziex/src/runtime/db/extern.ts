import { type WasmAllocRef, writeBytesOut } from "../../wasm/core";
import { Suspending } from "../jspi";
import {
    decodeBindings,
    encodeRun,
    encodeTable,
    encodeTableFromRaw,
    encodeTableFromRecord,
    encodeValues,
} from "./wire";

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

    function readBindings(ptr: number, len: number): DbValue[] {
        if (len === 0) return [];
        return decodeBindings(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));
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
        const values = readBindings(bindings_ptr, bindings_len);
        return database.prepare(sql).bind(...values);
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
            return writeBytesOut(
                getMemory,
                allocRef,
                out_ptr,
                encodeRun(result.meta?.last_row_id ?? 0, result.meta?.changes ?? 0),
            );
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
            return writeBytesOut(getMemory, allocRef, out_ptr, encodeTableFromRecord(row));
        }),

        db_all: new Suspending(async (
            ns_ptr: number, ns_len: number,
            sql_ptr: number, sql_len: number,
            bindings_ptr: number, bindings_len: number,
            out_ptr: number,
        ): Promise<number> => {
            const stmt = await statement(ns_ptr, ns_len, sql_ptr, sql_len, bindings_ptr, bindings_len);
            if (!stmt) return -1;
            try {
                const raw = await stmt.raw({ columnNames: true });
                const encoded = encodeTableFromRaw(raw);
                if (!encoded) {
                    new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                    return 0;
                }
                return writeBytesOut(getMemory, allocRef, out_ptr, encoded);
            } catch {
                const result = await stmt.all<Record<string, unknown>>();
                const records = result.results ?? [];
                if (records.length === 0) {
                    new DataView(getMemory().buffer).setUint32(out_ptr, 0, true);
                    return 0;
                }
                const columns = Object.keys(records[0]!);
                const rows = records.map((record) => columns.map((col) => record[col]));
                return writeBytesOut(getMemory, allocRef, out_ptr, encodeTable(columns, rows));
            }
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
            return writeBytesOut(getMemory, allocRef, out_ptr, encodeValues(rows as unknown[][]));
        }),
    };
}
