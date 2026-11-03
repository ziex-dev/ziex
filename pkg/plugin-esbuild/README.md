[![Ziex esbuild plugin](https://ziex.dev/branding/banner-esbuild.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

# plugin-esbuild

esbuild plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-esbuild`);
this repo is synced on each Ziex release for `zig fetch`.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-esbuild"
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
