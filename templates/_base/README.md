[![Ziex Starter template](https://ziex.dev/branding/banner-starter.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

## Developing

Requirements: `zig` ([version](build.zig.zon#L5))

Start dev server (http://localhost:3000):

```bash
zig build dev
```

Serve a production build:

```bash
zig build serve --release=fast
```

Bundle for deployment (output in `bundle/`):

```bash
zig build zx -- bundle
```

Format code:

```bash
zig build zx -- fmt .
```

Every [Ziex CLI](https://ziex.dev/reference#cli) command is available as `zig build zx -- <command>`.

## Deploying

Copy `bundle/` to any server and run the binary inside it. The app listens on port `3000` by default; set `PORT` to change it.

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
