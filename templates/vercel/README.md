[![Ziex Vercel template](https://ziex.dev/branding/banner-vercel.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

<p align="center"><a href="https://vercel.com/new/clone?repository-url=https://github.com/ziex-dev/template-vercel"><img src="https://vercel.com/button" alt="Deploy with Vercel" /></a></p>

## Developing

Requirements: [Node.js](https://nodejs.org/)

```bash
npm install
```

Start dev server (http://localhost:3000):

```bash
npx vercel dev
```

Every [Ziex CLI](https://ziex.dev/reference#cli) command is available as `npx zx <command>`.

## Deploying

```bash
npx vercel deploy
```

Runtime: Edge Functions by default (`api/index.ts`). To use the Node.js runtime instead, remove `api/nodejs.ts` from `.vercelignore` and point `vercel.json` at `api/nodejs.ts`.

Pre-rendering: pages that look the same for every visitor can be served from Vercel's CDN. Mark them with `pub const options = zx.PageOptions{ .rendering = .prerendered };` and set `buildCommand` in `vercel.json` to:

```bash
zig build zx -- build --target=wasm32-wasi --release=small --prerender
```

See [Pre-rendering](https://ziex.dev/learn#deployment-prerender).

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
