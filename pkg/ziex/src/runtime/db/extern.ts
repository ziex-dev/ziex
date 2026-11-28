import { type WasmAllocRef, writeBytesOut } from "../../wasm/core";
import { Suspending } from "../jspi";
import type { Handlers } from "../host";
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
 * SQL database binding for the `db_*` host ops.
 * Shape matches Cloudflare D1 so Workers bindings work as-is; Postgres and other
 * drivers adapt to this interface.
 */
export interface Database {
    prepare(query: string): PreparedStatement;
}

/** Host ops for SQL database bindings. */
export function createDbHandlers(
    bindings: Record<string, Database>,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): Handlers {
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
        const fail = () => -1;
        return { db_open: fail, db_run: fail, db_get: fail, db_all: fail, db_values: fail };
    }

    // A thrown query error returns `-2 - len` with its message written to `out_ptr`.
    type Handler = (...args: number[]) => Promise<number>;
    const guarded = (fn: Handler): Handler => async (...args) => {
        try {
            return await fn(...args);
        } catch (e) {
            const message = new TextEncoder().encode(e instanceof Error ? e.message : String(e));
            const n = writeBytesOut(getMemory, allocRef, args[6]!, message);
            return n < 0 ? -1 : -2 - n;
        }
    };

    return {
        db_open: (ns_ptr, ns_len) => binding(readStr(ns_ptr, ns_len)) ? 0 : -1,

        db_run: guarded(async (
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

        db_get: guarded(async (
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

        db_all: guarded(async (
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

        db_values: guarded(async (
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
