import { Ziex } from "../../pkg/ziex/src";
import { stateful } from "../../pkg/ziex/src/platforms/cloudflare";
import module from "../zig-out/bin/ziex_dev.wasm";

const app = new Ziex<Env>({ module, kv: "KV", db: { default: "DB", studio: "DB_STUDIO" } });

export const ChatRoom = stateful(app, { binding: "CHAT_ROOM" });
export default app;
