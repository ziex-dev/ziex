import type { DbValue } from "./extern";
import {
    decodeArgs,
    encodePair,
    encodeRecords,
    encodeRows,
    type Scalar,
} from "../wire";

export function encodeTable(columns: string[], rows: unknown[][]): Uint8Array {
    return encodeRecords(columns, rows);
}

export function encodeTableFromRecord(record: Record<string, unknown>): Uint8Array {
    const entries = Object.entries(record);
    return encodeRecords(
        entries.map(([name]) => name),
        [entries.map(([, value]) => value)],
    );
}

export function encodeTableFromRaw(raw: unknown[][]): Uint8Array | null {
    if (raw.length === 0) return null;
    const headerRow = raw[0];
    if (!Array.isArray(headerRow) || headerRow.length === 0) return null;
    if (typeof headerRow[0] !== "string") return null;
    const columns = headerRow as string[];
    const rows = raw.slice(1) as unknown[][];
    if (rows.length === 0) return null;
    return encodeRecords(columns, rows);
}

export function encodeValues(rows: unknown[][]): Uint8Array {
    return encodeRows(rows);
}

export function encodeRun(lastInsertRowid: number, changes: number): Uint8Array {
    return encodePair(lastInsertRowid, changes);
}

export function decodeBindings(bytes: Uint8Array): DbValue[] {
    return decodeArgs(bytes) as DbValue[];
}

export type { Scalar };
