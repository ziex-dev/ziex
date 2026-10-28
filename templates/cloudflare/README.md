[![Ziex Cloudflare template](https://ziex.dev/branding/banner-cloudflare.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

<p align="center"><a href="https://deploy.workers.cloudflare.com/?url=https://github.com/ziex-dev/template-cloudflare"><img src="https://deploy.workers.cloudflare.com/button" alt="Deploy to Cloudflare Workers" /></a></p>

## Developing

Requirements: [Node.js](https://nodejs.org/)

```bash
npm install
```

Start dev server (http://localhost:8787):

```bash
npm run dev
```

Every [Ziex CLI](https://ziex.dev/reference#cli) command is available as `npx zig build zx -- <command>`.

## Deploying

```bash
npm run deploy
```

The worker entrypoint is `app/main.ts`, and a `KV` namespace binding is declared in `wrangler.jsonc`.

Pre-rendering: pages that look the same for every visitor can be served from Cloudflare's CDN. Mark them with `pub const options = zx.PageOptions{ .rendering = .prerendered };` and set `build.command` in `wrangler.jsonc` to:

```bash
zig build zx -- build --target=wasm32-wasi --release=small --prerender
```

See [Pre-rendering](https://ziex.dev/learn#deployment-prerender).

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
