# Neovim

Syntax highlighting, LSP and file icons for `.zx` and `.mdzx` files. Requires
Neovim 0.11 or newer and the [tree-sitter CLI](https://github.com/tree-sitter/tree-sitter/tree/master/cli)
for building the parsers.

## Installation

```lua
-- ~/.config/nvim/lua/plugins/zx.lua
return {
    "ziex-dev/ziex",
    dependencies = { "nvim-tree/nvim-web-devicons" }, -- optional, for file icons
    lazy = false,
    config = function(plugin)
        vim.opt.runtimepath:prepend(plugin.dir .. "/ide/neovim")
        vim.cmd("runtime! plugin/zx.lua")
        require("zx").setup({
            zls_settings = { inlay_hints_show_builtin = true },
        })
    end,
}
```

Parsers for `zx`, `mdzx` and `mdzx_inline` are built on first use. Rebuild
them with `:ZxInstallParser`.

## Options

```lua
require("zx").setup({
    cmd = nil,          -- server command; default `zx lsp`, then `zig build zx -- lsp`
    zls_settings = {},  -- ZLS options, sent as the `zls` settings section
    inlay_hints = true,
    auto_install = true, -- build missing parsers on first use
    keymaps = true,      -- <leader>zh (Inspect) and <leader>zt (InspectTree)
})
```

`setup` is optional; the defaults apply when it is not called. The server is
registered as `zxls`, so `vim.lsp.config("zxls", { ... })` also works.

## Commands

| Command | Description |
| --- | --- |
| `:ZxInstallParser` | Build the tree-sitter parsers |
| `:ZxLspRestart` | Restart the language server |

## Language server

The plugin runs `zx lsp`, or `zig build zx -Dziex-lsp=true -- lsp` from the
nearest `build.zig` when the `zx` CLI is not installed.

Without the plugin:

```lua
vim.lsp.config("zxls", {
    cmd = { "zx", "lsp" },
    filetypes = { "zx", "mdzx" },
    root_markers = { "build.zig", ".git" },
    settings = { zls = { inlay_hints_show_builtin = true } },
})
vim.lsp.enable("zxls")
```

See the [editor guide](../README.md) for the ZX defaults.
