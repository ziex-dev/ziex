import { type WasmAllocRef, textDecoder, writeJsonOut } from "../wasm/core";
import type { Handlers } from "./host";

export type { WasmAllocRef };

export type EmailAddress = string | { email: string; name: string };

export type EmailAttachment = {
    /** The file's bytes. */
    content: Uint8Array;
    filename: string;
    /** MIME type. */
    type: string;
    disposition: "attachment" | "inline";
    /** Set when inline: the html references it as `cid:<contentId>`. */
    contentId?: string;
};

/**
 * The message `zx.email` sends; the same shape as Cloudflare Email Service's
 * `send()`, so a `send_email` binding takes it as is. Attachment content is
 * raw bytes: Cloudflare reads a string `content` as the file's literal text.
 */
export type EmailMessage = {
    from: EmailAddress;
    to?: EmailAddress[];
    cc?: EmailAddress[];
    bcc?: EmailAddress[];
    replyTo?: EmailAddress;
    subject: string;
    text?: string;
    html?: string;
    headers?: Record<string, string>;
    attachments?: EmailAttachment[];
};

/**
 * Email binding behind `zx.email` with the wasm provider. A Cloudflare
 * `send_email` binding is one as is; on other runtimes provide an object with
 * this `send`. Throw an `Error` with a `code` (e.g. `E_RATE_LIMIT_EXCEEDED`) to
 * report a typed failure.
 */
export interface EmailBinding {
    send(message: EmailMessage): Promise<{ messageId?: string } | void> | { messageId?: string } | void;
}

/** No such binding. */
const missing = -2;

/**
 * A message as the guest writes it (`Email.Wasm`): JSON, so attachment
 * content is base64. Only this module sees it; bindings get bytes.
 */
type WireMessage = Omit<EmailMessage, "attachments"> & {
    attachments?: (Omit<EmailAttachment, "content"> & { content: string })[];
};

/** Turns the guest's JSON message into the one bindings take, decoding attachments. */
export function decodeMessage(json: string): EmailMessage {
    const wire = JSON.parse(json) as WireMessage;
    if (!wire.attachments) return wire as EmailMessage;
    return { ...wire, attachments: wire.attachments.map((a) => ({ ...a, content: base64ToBytes(a.content) })) };
}

function base64ToBytes(b64: string): Uint8Array {
    const native = (Uint8Array as unknown as { fromBase64?: (s: string) => Uint8Array }).fromBase64;
    if (native) return native(b64);
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
}

/** Host op `email_send`: sends a JSON message through the named binding. */
export function createEmailHandlers(
    bindings: Record<string, EmailBinding> | undefined,
    getMemory: () => WebAssembly.Memory,
    allocRef: WasmAllocRef,
): Handlers {
    const readStr = (ptr: number, len: number): string =>
        len === 0 ? "" : textDecoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0));

    const ok = (out: number, result: { messageId?: string } | void) =>
        writeJsonOut(getMemory, allocRef, out, { messageId: result?.messageId ?? null });
    const fail = (out: number, err: unknown) => {
        const e = err as { code?: unknown; message?: unknown } | null;
        return writeJsonOut(getMemory, allocRef, out, {
            error: {
                code: typeof e?.code === "string" ? e.code : null,
                message: typeof e?.message === "string" ? e.message : String(err),
            },
        });
    };

    return {
        email_send: (name_ptr, name_len, msg_ptr, msg_len, out) => {
            const name = readStr(name_ptr, name_len);
            const binding = bindings?.[name] ?? bindings?.["default"];
            if (typeof binding?.send !== "function") return missing;

            try {
                const result = binding.send(decodeMessage(readStr(msg_ptr, msg_len)));
                if (typeof (result as Promise<unknown> | undefined)?.then !== "function") return ok(out, result as { messageId?: string } | void);
                return Promise.resolve(result).then((r) => ok(out, r), (err) => fail(out, err));
            } catch (err) {
                return fail(out, err);
            }
        },
    };
}
