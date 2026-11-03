# plugin-typescript

TypeScript (`tsc`) plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-typescript`);
this repo is synced on each Ziex release for `zig fetch`.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-typescript#vX.Y.Z"
```

```zig
const typescript = @import("typescript");

const dts = typescript.addBuild(b, .{
    .name = "app.d.ts",
    .config = .{ .project = b.path("tsconfig.json") },
});
```

See [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
