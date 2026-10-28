[![Ziex Render template](https://ziex.dev/branding/banner-render.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

<p align="center"><a href="https://render.com/deploy?repo=https://github.com/ziex-dev/template-render"><img src="https://render.com/images/deploy-to-render-button.svg" alt="Deploy to Render" /></a></p>

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

Push this repo to GitHub and create a [Blueprint](https://dashboard.render.com/select-repo?type=blueprint) from it. Render reads `render.yaml` and builds with the included `Dockerfile`.

The app reads Render's `PORT` and binds to `0.0.0.0`, so no port setup is needed.

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
