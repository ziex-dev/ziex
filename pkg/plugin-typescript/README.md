[![Ziex TypeScript plugin](https://ziex.dev/branding/banner-typescript.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

# plugin-typescript

TypeScript (`tsc`) plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-typescript`);
this repo is synced on each Ziex release for `zig fetch`.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-typescript#latest"
```

```zig
const typescript = @import("typescript");

const dts = typescript.addBuild(b, .{
    .name = "app.d.ts",
    .config = .{ .project = b.path("tsconfig.json") },
});
```

See [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
