## Installation

### Zed Marketplace
The extension has not yet been published in the marketplace. See PR [here](https://github.com/zed-industries/extensions/pull/6307).

### Manual Installation
- Clone this repository
    ```bash
    git clone git@github.com:ziex-dev/ziex.git
    ```

- Open the Extensions panel in Zed (CTRL/CMD + SHIFT + P)
- Select `Install Dev Extension`
- Navigate to the `ide/zed` directory in the cloned repository

## Language server settings

Without the `zx` CLI, the server is built with
`zig build zx -Dziex-lsp=true -- lsp`, which only works when the opened
folder is the Ziex project itself. For a Ziex app inside a Zig monorepo,
install the `zx` CLI or open the app's folder in Zed.

Put ZLS options under `lsp.zxls.settings`:

```jsonc
{
  "lsp": {
    "zxls": { "settings": { "inlay_hints_show_builtin": true } }
  },
  "inlay_hints": { "enabled": true }
}
```

See the [editor guide](../README.md) for the Ziex defaults.
