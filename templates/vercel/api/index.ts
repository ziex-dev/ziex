import module from "../zig-out/bin/ziex_app.wasm?module";
import { Ziex } from "../zig-out/bindings/ziex/index.js";
import { handle } from "../zig-out/bindings/ziex/platforms/vercel/index.js";

export const config = { runtime: "edge" };

export default handle(new Ziex({ module }));
