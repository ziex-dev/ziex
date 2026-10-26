export const MAGIC = 0x3142445a;

export const Kind = {
    records: 1,
    pair: 2,
    rows: 3,
    args: 4,
    strings: 5,
} as const;

export const Tag = {
    null: 0,
    integer: 1,
    float: 2,
    text: 3,
    blob: 4,
    boolean: 5,
} as const;

export type Scalar =
    | null
    | string
    | number
    | boolean
    | ArrayBuffer
    | ArrayBufferView;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export class Writer {
    buf: Uint8Array;
    pos = 0;
    view: DataView;

    constructor(capacity = 256) {
        this.buf = new Uint8Array(capacity);
        this.view = new DataView(this.buf.buffer);
    }

    private ensure(n: number): void {
        const need = this.pos + n;
        if (need <= this.buf.length) return;
        let cap = this.buf.length;
        while (cap < need) cap *= 2;
        const next = new Uint8Array(cap);
        next.set(this.buf.subarray(0, this.pos));
        this.buf = next;
        this.view = new DataView(this.buf.buffer);
    }

    u8(v: number): void {
        this.ensure(1);
        this.buf[this.pos++] = v & 0xff;
    }

    u16(v: number): void {
        this.ensure(2);
        this.view.setUint16(this.pos, v >>> 0, true);
        this.pos += 2;
    }

    u32(v: number): void {
        this.ensure(4);
        this.view.setUint32(this.pos, v >>> 0, true);
        this.pos += 4;
    }

    i64(v: number | bigint): void {
        this.ensure(8);
        this.view.setBigInt64(this.pos, typeof v === "bigint" ? v : BigInt(Math.trunc(v)), true);
        this.pos += 8;
    }

    f64(v: number): void {
        this.ensure(8);
        this.view.setFloat64(this.pos, v, true);
        this.pos += 8;
    }

    raw(src: Uint8Array): void {
        this.ensure(src.length);
        this.buf.set(src, this.pos);
        this.pos += src.length;
    }

    str16(s: string): void {
        const enc = textEncoder.encode(s);
        if (enc.length > 0xffff) throw new Error("wire string too long");
        this.u16(enc.length);
        this.raw(enc);
    }

    str32(s: string): void {
        const enc = textEncoder.encode(s);
        this.u32(enc.length);
        this.raw(enc);
    }

    finish(): Uint8Array {
        return this.buf.subarray(0, this.pos);
    }
}

export class Reader {
    buf: Uint8Array;
    pos = 0;
    view: DataView;

    constructor(buf: Uint8Array) {
        this.buf = buf.slice();
        this.view = new DataView(this.buf.buffer, this.buf.byteOffset, this.buf.byteLength);
    }

    private need(n: number): void {
        if (this.buf.length - this.pos < n) throw new Error("wire truncated");
    }

    u8(): number {
        this.need(1);
        return this.buf[this.pos++]!;
    }

    u16(): number {
        this.need(2);
        const v = this.view.getUint16(this.pos, true);
        this.pos += 2;
        return v;
    }

    u32(): number {
        this.need(4);
        const v = this.view.getUint32(this.pos, true);
        this.pos += 4;
        return v;
    }

    i64(): number {
        this.need(8);
        const v = this.view.getBigInt64(this.pos, true);
        this.pos += 8;
        return Number(v);
    }

    f64(): number {
        this.need(8);
        const v = this.view.getFloat64(this.pos, true);
        this.pos += 8;
        return v;
    }

    bytes(n: number): Uint8Array {
        this.need(n);
        const out = this.buf.subarray(this.pos, this.pos + n);
        this.pos += n;
        return out;
    }

    str16(): string {
        return textDecoder.decode(this.bytes(this.u16()));
    }

    str32(): string {
        return textDecoder.decode(this.bytes(this.u32()));
    }

    expect(kind: number): void {
        if (this.u32() !== MAGIC) throw new Error("wire bad magic");
        if (this.u8() !== kind) throw new Error("wire bad kind");
    }
}

function header(w: Writer, kind: number): void {
    w.u32(MAGIC);
    w.u8(kind);
}

export function writeValue(w: Writer, value: unknown): void {
    if (value === null || value === undefined) {
        w.u8(Tag.null);
        return;
    }
    if (typeof value === "boolean") {
        w.u8(Tag.boolean);
        w.u8(value ? 1 : 0);
        return;
    }
    if (typeof value === "number") {
        if (Number.isInteger(value) && value >= Number.MIN_SAFE_INTEGER && value <= Number.MAX_SAFE_INTEGER) {
            w.u8(Tag.integer);
            w.i64(value);
        } else {
            w.u8(Tag.float);
            w.f64(value);
        }
        return;
    }
    if (typeof value === "bigint") {
        w.u8(Tag.integer);
        w.i64(value);
        return;
    }
    if (typeof value === "string") {
        w.u8(Tag.text);
        w.str32(value);
        return;
    }
    if (value instanceof ArrayBuffer) {
        const bytes = new Uint8Array(value);
        w.u8(Tag.blob);
        w.u32(bytes.length);
        w.raw(bytes);
        return;
    }
    if (ArrayBuffer.isView(value)) {
        const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        w.u8(Tag.blob);
        w.u32(bytes.length);
        w.raw(bytes);
        return;
    }
    w.u8(Tag.text);
    w.str32(String(value));
}

export function readValue(r: Reader): Scalar {
    switch (r.u8()) {
        case Tag.null:
            return null;
        case Tag.integer:
            return r.i64();
        case Tag.float:
            return r.f64();
        case Tag.text:
            return r.str32();
        case Tag.blob:
            return r.bytes(r.u32()).slice();
        case Tag.boolean:
            return r.u8() !== 0;
        default:
            throw new Error("wire bad tag");
    }
}

export function encodePair(a: number, b: number): Uint8Array {
    const w = new Writer(24);
    header(w, Kind.pair);
    w.i64(a);
    w.i64(b);
    return w.finish();
}

export function decodePair(bytes: Uint8Array): { a: number; b: number } {
    const r = new Reader(bytes);
    r.expect(Kind.pair);
    return { a: r.i64(), b: r.i64() };
}

export function encodeStrings(items: string[]): Uint8Array {
    const w = new Writer(32 + items.length * 16);
    header(w, Kind.strings);
    w.u32(items.length);
    for (const s of items) w.str32(s);
    return w.finish();
}

export function decodeStrings(bytes: Uint8Array): string[] {
    const r = new Reader(bytes);
    r.expect(Kind.strings);
    const n = r.u32();
    const out = new Array<string>(n);
    for (let i = 0; i < n; i++) out[i] = r.str32();
    return out;
}

export function encodeRecords(columns: string[], rows: unknown[][]): Uint8Array {
    const w = new Writer(64 + columns.length * 16 + rows.length * columns.length * 8);
    header(w, Kind.records);
    w.u32(columns.length);
    w.u32(rows.length);
    for (const col of columns) w.str16(col);
    for (const row of rows) {
        for (let i = 0; i < columns.length; i++) writeValue(w, row[i]);
    }
    return w.finish();
}

export function encodeRows(rows: unknown[][]): Uint8Array {
    const w = new Writer(64 + rows.length * 32);
    header(w, Kind.rows);
    w.u32(rows.length);
    for (const row of rows) {
        w.u32(row.length);
        for (const cell of row) writeValue(w, cell);
    }
    return w.finish();
}

export function encodeArgsList(values: unknown[]): Uint8Array {
    const w = new Writer(32 + values.length * 16);
    header(w, Kind.args);
    w.u8(1);
    w.u32(values.length);
    for (const v of values) writeValue(w, v);
    return w.finish();
}

export function decodeArgs(bytes: Uint8Array): Scalar[] {
    const r = new Reader(bytes);
    r.expect(Kind.args);
    const mode = r.u8();
    if (mode === 0) return [];
    if (mode !== 1) throw new Error("wire unsupported args mode");
    const n = r.u32();
    const out = new Array<Scalar>(n);
    for (let i = 0; i < n; i++) out[i] = readValue(r);
    return out;
}
