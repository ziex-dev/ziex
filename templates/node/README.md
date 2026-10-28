[![Ziex Node template](https://ziex.dev/branding/banner-node.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

## Developing

No global Zig or Ziex install needed; works with any Node package manager (npm, pnpm, yarn, bun).

```bash
npm install
```

Start dev server (http://localhost:3000):

```bash
npm run dev
```

Serve a production build:

```bash
npm run serve
```

Bundle for deployment (output in `bundle/`):

```bash
npm run bundle
```

Format code:

```bash
npm run fmt -- .
```

Every [Ziex CLI](https://ziex.dev/reference#cli) command is available as `npx zx <command>`.

Built with

- Ziex: https://ziex.dev
- Zig: https://ziglang.org
