import { describe, expect, test } from "bun:test";
import { createEmailHandlers, decodeMessage, type EmailBinding, type EmailMessage } from "./email";

const enc = new TextEncoder();
const dec = new TextDecoder();

// Drives `email_send` the way `Email.Wasm` does, against fake guest memory.
function guest(bindings: Record<string, EmailBinding> | undefined) {
    const memory = new WebAssembly.Memory({ initial: 2 });
    let top = 8;
    const alloc = (n: number) => {
        const p = top;
        top += (n + 7) & ~7;
        return p;
    };
    const h = createEmailHandlers(bindings, () => memory, [alloc]);
    const put = (s: string) => {
        const b = enc.encode(s);
        const p = alloc(Math.max(b.length, 1));
        new Uint8Array(memory.buffer, p, b.length).set(b);
        return [p, b.length] as const;
    };
    return {
        send: async (message: unknown) => {
            const out = alloc(4);
            const n = (await h.email_send!(...put("default"), ...put(JSON.stringify(message)), out)) as number;
            if (n < 0) return n;
            const ptr = new DataView(memory.buffer).getUint32(out, true);
            return JSON.parse(dec.decode(new Uint8Array(memory.buffer, ptr, n)));
        },
    };
}

// Every byte value, so any text decoding along the way would show.
const binary = Uint8Array.from({ length: 256 }, (_, i) => i);
const b64 = Buffer.from(binary).toString("base64");

const wireMessage = {
    from: "Acme <hello@acme.test>",
    to: ["a@acme.test"],
    subject: "Your payslip",
    attachments: [
        { content: b64, filename: "payslip.pdf", type: "application/pdf", disposition: "attachment" },
        { content: Buffer.from("logo").toString("base64"), filename: "logo.png", type: "image/png", disposition: "inline", contentId: "logo" },
    ],
};

describe("email host op", () => {
    test("bindings get attachment bytes, not base64 text", async () => {
        let got: EmailMessage | undefined;
        const g = guest({ default: { send: (m) => void (got = m) } });

        expect(await g.send(wireMessage)).toEqual({ messageId: null });
        const [pdf, logo] = got!.attachments!;
        expect(pdf!.content).toBeInstanceOf(Uint8Array);
        expect(Array.from(pdf!.content)).toEqual(Array.from(binary));
        expect(pdf!.filename).toBe("payslip.pdf");
        expect(pdf!.disposition).toBe("attachment");
        expect(dec.decode(logo!.content)).toBe("logo");
        expect(logo!.contentId).toBe("logo");
        expect(got!.subject).toBe("Your payslip");
    });

    test("messages without attachments pass through unchanged", () => {
        const m = { from: "a@acme.test", to: ["b@acme.test"], subject: "Hi", text: "Hello" };
        expect(decodeMessage(JSON.stringify(m))).toEqual(m);
    });

    test("returns the binding's message id and reports its errors", async () => {
        const sent = guest({ default: { send: async () => ({ messageId: "m-1" }) } });
        expect(await sent.send(wireMessage)).toEqual({ messageId: "m-1" });

        const failing = guest({
            default: {
                send: async () => {
                    throw Object.assign(new Error("slow down"), { code: "E_RATE_LIMIT_EXCEEDED" });
                },
            },
        });
        expect(await failing.send(wireMessage)).toEqual({ error: { code: "E_RATE_LIMIT_EXCEEDED", message: "slow down" } });
    });

    test("a missing binding is reported", async () => {
        expect(await guest(undefined).send(wireMessage)).toBe(-2);
    });
});
