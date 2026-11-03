# Ziex Packages

Subpackages that are published separately or consumed by the root Ziex project.

| Package | Platform/Lang | Description |
|---------|---------------|-------------|
| `ziex` | NPM/JavaScript | Ziex JavaScript bindings for browser, Cloudflare, Vercel, WASI, and more |
| `@ziex` | NPM/JavaScript | @ziex org on NPM for CLI-related packages |
| `adapters` | Zig | Adapters for Ziex (zx.db (SQLite), zx.kv (FS)) |
| `create-ziex` | NPM/JavaScript | `npm init ziex` or `bun create ziex` |
| `playground` | Zig | Interactive Zig development environment |
| `plugin-bun` | NPM/JavaScript | Bun plugin for the Zig build system |
| `plugin-system` | Zig | Shared helpers for Zig build plugins |
| `plugin-tailwindcss` | Zig | Tailwind CSS plugin for the Zig build system |
| `plugin-esbuild` | Zig | esbuild plugin for the Zig build system |
| `plugin-typescript` | Zig | TypeScript (`tsc`) plugin for the Zig build system |
| `tree-sitter-zx` | Tree-Sitter (C) | Tree-Sitter parser for .zx files |
| `tree-sitter-mdzx` | Tree-Sitter (C) | Tree-Sitter parser for .mdzx / .md files |

## Zig build plugins

Developed under `pkg/plugin-*` in this monorepo; released to standalone
`ziex-dev/plugin-*` repos on each Ziex release for `zig fetch`.

See **[PLUGINS.md](./PLUGINS.md)** for consumer setup (`build.zig.zon` +
`@import` + `addBuild`).
