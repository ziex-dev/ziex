export type PlaygroundBuildArtifacts = {
  ssrWasm: Uint8Array;
  clientWasm: Uint8Array;
  /** `__zx_web` shims the client wasm imports (see webglue.ts). */
  webGlue?: string;
};

export const PLAYGROUND_APP_FILES = [
  "app/main.zig",
  "app/pages/layout.zx",
  "app/pages/page.zx",
] as const;

export const CLIENT_WASM_PLACEHOLDER = "__PLAYGROUND_CLIENT_WASM__";

export function isGeneratedPlaygroundPath(name: string): boolean {
  return (
    name === "app/app.zig" ||
    (name.endsWith(".zig") && name.startsWith("app/pages/")) ||
    name.endsWith(".zon")
  );
}

export function nestPaths(
  files: Record<string, Uint8Array | string>,
): Map<string, Map<string, unknown> | Uint8Array> {
  const root = new Map<string, Map<string, unknown> | Uint8Array>();
  const enc = new TextEncoder();

  for (const [filename, content] of Object.entries(files)) {
    const parts = filename.split("/").filter(Boolean);
    if (parts.length === 0) continue;
    let cur: Map<string, Map<string, unknown> | Uint8Array> = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const seg = parts[i]!;
      let next = cur.get(seg);
      if (!(next instanceof Map)) {
        next = new Map();
        cur.set(seg, next);
      }
      cur = next as Map<string, Map<string, unknown> | Uint8Array>;
    }
    const data = typeof content === "string" ? enc.encode(content) : content;
    cur.set(parts[parts.length - 1]!, data);
  }
  return root;
}

export function flattenDirectory(
  dir: { contents: Map<string, unknown> },
  prefix = "",
): Record<string, Uint8Array> {
  const out: Record<string, Uint8Array> = {};
  for (const [name, node] of dir.contents.entries()) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (node && typeof node === "object" && "data" in (node as object)) {
      out[path] = (node as { data: Uint8Array }).data;
    } else if (node && typeof node === "object" && "contents" in (node as object)) {
      Object.assign(out, flattenDirectory(node as { contents: Map<string, unknown> }, path));
    }
  }
  return out;
}
