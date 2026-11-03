[![Ziex Tailwind CSS plugin](https://ziex.dev/branding/banner-tailwind-css.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

# plugin-tailwindcss

Tailwind CSS plugin for the Zig build system.

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-tailwindcss`);
this repo is synced on each Ziex release for `zig fetch`.

## Requirements

- [Node.js](https://nodejs.org/) on `PATH` (or pass a path via `tailwindcss.setNodePath`)
- Tailwind packages in the app's `node_modules` (the plugin runs `@tailwindcss/node`):

```bash
npm i -D tailwindcss @tailwindcss/node
```

## Usage

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-tailwindcss#latest"
```

```zig
const tailwindcss = @import("tailwindcss");

const css = tailwindcss.addBuild(b, .{
    .config = .{ .input = b.path("app/styles/tailwind.css") },
});
```

See `example/` and [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
