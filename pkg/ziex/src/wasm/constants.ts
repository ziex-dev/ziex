/**
 * Numeric wire constants for the WASM↔JS ABI.
 *
 * Kept in a path-import-free module so esbuild's const-inlining heuristic can
 * fold these into call sites across the bundle (#1317 / #1981):
 * only `null` / `undefined` / `true` / `false` / integers / short reals, at the
 * top of a scope with no `import`/`export … from "…"`.
 *
 * Must stay in sync with Zig (`dom_cmd.zig`, `host.zig` / `__zx_cb` types).
 */

// --- DomCmd record layout ---
export const DOM_CMD_HEADER_SIZE = 8;
export const DOM_CMD_RECORD_SIZE = 24;

// --- DomCmd opcodes (`DomOp` in dom_cmd.zig) ---
export const DomOp_CreateElement = 1;
export const DomOp_CreateText = 2;
export const DomOp_HydrateInsert = 3;
export const DomOp_SetAttr = 4;
export const DomOp_SetProp = 5;
export const DomOp_RemoveAttr = 6;
export const DomOp_SetNodeValue = 7;
export const DomOp_SetInnerHtml = 8;
export const DomOp_AppendChild = 9;
export const DomOp_InsertBefore = 10;
export const DomOp_RemoveChild = 11;
export const DomOp_ReplaceChild = 12;

// --- Host→guest `__zx_cb` type ids (must match `HostMsg` in src/runtime/wasm/host.zig) ---
export const CallbackType_Event = 0;
export const CallbackType_FetchSuccess = 1;
export const CallbackType_FetchError = 2;
export const CallbackType_Timeout = 3;
export const CallbackType_Interval = 4;
export const CallbackType_WebSocketOpen = 5;
export const CallbackType_WebSocketMessage = 6;
export const CallbackType_WebSocketError = 7;
export const CallbackType_WebSocketClose = 8;
