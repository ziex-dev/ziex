# Ziex

[Ziex](https://ziex.dev) is a full-stack web framework for Zig.

## Zig toolchain

Zig does not need to be on your `PATH`. The extension uses the first of:

1. The `zig.path` setting of the [Zig extension](https://marketplace.visualstudio.com/items?itemName=ziglang.vscode-zig)
2. A Zig installed by the Zig extension matching the project's `minimum_zig_version`
3. `zig` on `PATH`
4. The newest Zig installed by the Zig extension

## Language server

The server starts when you open a `.zx` file, from the nearest project whose
`build.zig` has a `zx` step. It runs `zx lsp`, or
`zig build zx -Dziex-lsp=true -- lsp` when the `zx` CLI is not installed.

Configure it under **Settings › Extensions › Ziex**:

```jsonc
{
  "ziex.lsp.inlayHintsShowBuiltin": true,
  // Other ZLS options, by their ZLS name
  "ziex.lsp.additionalOptions": { "skip_std_references": true },
  "editor.inlayHints.enabled": "on"
}
```

Unset `ziex.lsp.*` options fall back to your Zig extension settings
(`zig.zls.*`, `zig.libPath`). See the [editor guide](https://github.com/ziex-dev/ziex/blob/main/ide/README.md) for the Ziex
defaults.
