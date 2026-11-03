[![Ziex Plugin System](https://ziex.dev/branding/banner-plugin-system.svg)](https://ziex.dev)

<p align="center">
	<a href="https://ziex.dev/learn">Docs</a> ·
	<a href="https://ziex.dev/examples">Examples</a> ·
	<a href="https://ziex.dev/reference#cli">CLI</a> ·
	<a href="https://ziex.dev/r/discord">Discord</a> ·
	<a href="https://github.com/ziex-dev/ziex">GitHub</a>
</p>

# plugin-system

Shared helpers for Ziex Zig build plugins (dep-files, npm optional-deps sync).

Developed in [ziex-dev/ziex](https://github.com/ziex-dev/ziex) (`pkg/plugin-system`);
this repo is the consumer-facing package synced on each Ziex release.

Third-party apps normally depend on this only **transitively** through a
plugin package.

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-system"
```

See [Using build plugins](https://github.com/ziex-dev/ziex/blob/main/pkg/PLUGINS.md).
