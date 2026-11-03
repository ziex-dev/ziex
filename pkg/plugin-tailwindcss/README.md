# plugin-tailwindcss

Tailwind CSS plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-tailwindcss`);
this repo is synced on each Ziex release for `zig fetch`.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-tailwindcss#vX.Y.Z"
```

```zig
const tailwindcss = @import("tailwindcss");

const css = tailwindcss.addBuild(b, .{
    .config = .{ .input = b.path("app/styles/tailwind.css") },
});
```

See `example/` and [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
