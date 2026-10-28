
# Helix

## 1. Language & Grammar Setup

Add the following entries to your Helix `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "zx"
scope = "source.zx"
roots = ["build.zig", ".git"]
file-types = ["zx"]
grammar = "zx"
language-servers = ["zxls"]

[[language]]
name = "mdzx"
scope = "text.mdzx"
roots = ["build.zig", ".git"]
file-types = ["mdzx"]
grammar = "mdzx"
language-servers = ["zxls"]

[[language]]
name = "mdzx_inline"
scope = "text.mdzx_inline"
file-types = []
grammar = "mdzx_inline"

[language-server.zxls]
command = "zx"
args = ["lsp"]

[[grammar]]
name = "zx"
source = { git = "https://github.com/ziex-dev/ziex", rev = "main", subpath = "pkg/tree-sitter-zx" }

[[grammar]]
name = "mdzx"
source = { git = "https://github.com/ziex-dev/ziex", rev = "main", subpath = "pkg/tree-sitter-mdzx" }

[[grammar]]
name = "mdzx_inline"
source = { git = "https://github.com/ziex-dev/ziex", rev = "main", subpath = "pkg/tree-sitter-mdzx/tree-sitter-mdzx-inline" }
```

---

## 2. Build Grammar

Fetch and build the grammar:

```sh
hx --grammar fetch
hx --grammar build
```

---

## 3. Copy Queries

Clone this repo, then copy the queries:

```sh
mkdir -p ~/.config/helix/runtime/queries
cp -r ide/helix/queries/zx ide/helix/queries/mdzx ide/helix/queries/mdzx_inline ~/.config/helix/runtime/queries/
```

---

## 4. Configure the Language Server

Set ZLS options in the server's `config` table and enable inlay hints:

```toml
# languages.toml
[language-server.zxls]
command = "zx"
args = ["lsp"]
config = { inlay_hints_show_builtin = true }
```

```toml
# config.toml
[editor.lsp]
display-inlay-hints = true
```

Without the `zx` CLI, build the server from the project. Helix starts it in
the workspace root, which must contain the project's `build.zig`:

```toml
[language-server.zxls]
command = "zig"
args = ["build", "zx", "-Dziex-lsp=true", "--release=fast", "--", "lsp"]
```

See the [editor guide](../README.md) for the Ziex defaults.
