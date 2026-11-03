# plugin-system

Shared helpers for Ziex Zig build plugins (dep-files, npm optional-deps sync).

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-system`);
this repo is the consumer-facing package synced on each Ziex release.

Third-party apps normally depend on this only **transitively** via
`plugin-tailwindcss`, `plugin-esbuild`, or `plugin-typescript`.

See [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
