# plugin-esbuild

esbuild plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-esbuild`);
this repo is synced on each Ziex release for `zig fetch`.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-esbuild#vX.Y.Z"
```

```zig
const esbuild = @import("esbuild");

const out = esbuild.addBuild(b, .{
    .config = .{
        .entrypoints = &.{b.path("app/main.ts")},
        .platform = .browser,
    },
});
```

See `example/` and [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
