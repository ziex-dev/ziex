/**
 * Cloudflare KV can be used as a {@link KVNamespace} binding
 * (`delete` is accepted as `del` by the host imports).
 */
export { createKvHandlers } from "../../runtime/kv";
export type { KVNamespace } from "../../runtime/kv";
export { get, put, del, list } from "../../runtime/kv/memory";
