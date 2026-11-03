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
zig fetch --save "git+https://github.com/ziex-dev/plugin-tailwindcss"
```

Omit the `#tag` to resolve the default branch tip (latest sync). Pin a release
with `#vX.Y.Z` when you want a fixed version.

`build.zig.zon` (filled by `zig fetch --save`):

```zon
.dependencies = .{
    .tailwindcss = .{
        .url = "git+https://github.com/ziex-dev/plugin-tailwindcss",
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

## Publishing

On a GitHub Release of `ziex-dev/ziex`, [`.github/workflows/release.yml`](../.github/workflows/release.yml)
runs `tools/syncplugin`, which:

1. Pushes `plugin-system` and tags it
2. Rewrites dependents' `.plugin_system = .{ .path = ... }` to that tag's url+hash
3. Pushes/tags `plugin-tailwindcss`, `plugin-typescript`, and `plugin-esbuild`

Local dry-run:

```bash
bash tools/syncplugin v0.1.0 --dry-run
```
