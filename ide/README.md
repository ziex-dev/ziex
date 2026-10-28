# Editor support

Setup guides: [VS Code](vscode/README.md), [Neovim](neovim/README.md),
[Helix](helix/README.md), [Zed](zed/README.md), [Emacs](emacs/README.md).

## Language server

Every editor runs the same server, `zx lsp`. It handles ZX markup itself
(completion, hover, formatting, diagnostics) and forwards Zig features to an
embedded [ZLS](https://github.com/zigtools/zls).

When the `zx` CLI is not on `PATH`, the editors build and run the server from
your project instead:

```sh
zig build zx -Dziex-lsp=true --release=fast -- lsp
```

## Settings

The embedded ZLS takes the standard
[ZLS options](https://github.com/zigtools/zls/blob/master/src/Config.zig),
read from your editor's `zls` settings section (Helix sends them as
`initializationOptions`). Changes apply without a restart. Each editor guide
shows where to put them.

Ziex changes a few ZLS defaults to cut inlay hint noise in page code:

| Option | Ziex default | ZLS default |
| --- | --- | --- |
| `inlay_hints_show_builtin` | `false` | `true` |
| `inlay_hints_show_struct_literal_field_type` | `false` | `true` |
| `inlay_hints_hide_redundant_param_names` | `true` | `false` |
| `inlay_hints_hide_redundant_param_names_last_token` | `true` | `false` |

Notes:

- Inlay hints are never shown inside markup, and must also be enabled in the
  editor.
- `modules` and `import_extensions` come from your `build.zig`. Do not set them.
- Diagnostics in `.zx` files come from `zx lsp` (ZX syntax plus Zig
  `ast-check`), so ZLS diagnostic options such as `warn_style` have no effect.
