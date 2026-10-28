import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";
import { Ziex } from "../zig-out/bindings/ziex/index.js";

export default new Ziex({
    module: readFileSync(fileURLToPath(new URL("../zig-out/bin/ziex_app.wasm", import.meta.url).href)),
    wasi: new WASI({ version: "preview1" }),
});
