[![Ziex Railway template](https://ziex.dev/branding/banner-railway.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

<p align="center"><a href="https://railway.com/new/template?template=https://github.com/ziex-dev/template-railway"><img src="https://railway.com/button.svg" alt="Deploy on Railway" /></a></p>

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

Push this repo to GitHub and create a Railway project from it. Railway builds with the included `Dockerfile` (configured in `railway.json`).

The app listens on `PORT` (default `3000`). Set the service's internal port to match.

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
