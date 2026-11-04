# Using build plugins

Ziex ships Zig build plugins for Tailwind CSS, esbuild, and TypeScript. They are
developed in this monorepo (`pkg/plugin-*`) and published on each Ziex release
to standalone repos so apps outside the monorepo can `zig fetch` them.

| Package dir | Published repo | `@import` name |
|-------------|----------------|----------------|
| `pkg/plugin-system` | [ziex-dev/plugin-system](https://github.com/ziex-dev/plugin-system) | (transitive) |
| `pkg/plugin-tailwindcss` | [ziex-dev/plugin-tailwindcss](https://github.com/ziex-dev/plugin-tailwindcss) | `tailwindcss` |
| `pkg/plugin-esbuild` | [ziex-dev/plugin-esbuild](https://github.com/ziex-dev/plugin-esbuild) | `esbuild` |
| `pkg/plugin-typescript` | [ziex-dev/plugin-typescript](https://github.com/ziex-dev/plugin-typescript) | `typescript` |

Inside this repo, keep using path dependencies (as `site/` and the plugin
examples do). For a third-party app, depend on the published package.

## Consumer setup

```bash
zig fetch --save "git+https://github.com/ziex-dev/plugin-tailwindcss#latest"
```

`#latest` is a moving tag updated on each plugin sync (stable docs URL). Pin a
release with `#vX.Y.Z` when you want an immutable version. `zig fetch --save`
still records a content `hash`, so builds stay reproducible until you re-fetch.

`build.zig.zon` (filled by `zig fetch --save`):

```zon
.dependencies = .{
    .tailwindcss = .{
        .url = "git+https://github.com/ziex-dev/plugin-tailwindcss#latest",
        .hash = "...",
    },
},
```

`build.zig`:

```zig
const std = @import("std");
const tailwindcss = @import("tailwindcss");

pub fn build(b: *std.Build) !void {
    const css = tailwindcss.addBuild(b, .{
        .config = .{
            .input = b.path("app/styles/tailwind.css"),
        },
    });
    const install = b.addInstallFile(css.file, "static/assets/tailwind.css");
    b.default_step.dependOn(&install.step);
}
```

The same pattern applies to `esbuild` and `typescript` (`addBuild` /
`addBuilds`). See each package's `example/` directory and the snippets in
[`site/app/assets/snippets/plugin_examples.zig`](../site/app/assets/snippets/plugin_examples.zig).

CI builds those examples on plugin changes (`.github/workflows/plugin.yml`) and
again before plugin sync on release.

## Publishing

On a GitHub Release of `ziex-dev/ziex`, [`.github/workflows/release.yml`](../.github/workflows/release.yml)
runs `tools/syncplugin`, which:

1. Pushes `plugin-system` and tags it (`vX.Y.Z` + moving `latest`)
2. Rewrites dependents' `.plugin_system = .{ .path = ... }` to that version tag's url+hash
3. Pushes/tags `plugin-tailwindcss`, `plugin-typescript`, and `plugin-esbuild` the same way

Patch one dependent without bumping `plugin-system` (reuses its latest release,
or pass `--plugin-system-tag vX.Y.Z`):

```bash
bash tools/syncplugin v0.1.1 --dry-run plugin-tailwindcss
bash tools/syncplugin v0.1.1 plugin-tailwindcss
```

Full sync dry-run:

```bash
bash tools/syncplugin v0.1.0 --dry-run
```
