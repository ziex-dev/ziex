# Emacs

`zx-ts-mode` is a tree-sitter major mode for `.zx` files. It provides syntax
highlighting, indentation, imenu and structural navigation for both the Zig and
the markup halves of a ZX file, plus LSP support through `zx lsp`.

`mdzx-ts-mode` covers `.mdzx` files with highlighting and the same LSP support.

## Requirements

- Emacs 29.1 or newer, built with tree-sitter support (`M-: (treesit-available-p)`
  must return `t`).
- A `libtree-sitter` of **0.25 or newer**. The ZX grammar is generated at
  tree-sitter ABI 15, and Emacs only loads grammars up to the ABI of the
  `libtree-sitter` it was linked against. An older build reports:

  ```elisp
  (treesit-language-available-p 'zx t)
  ;; => (nil version-mismatch 15)
  ```

  If you hit this, use an Emacs built against a current `libtree-sitter`.
- A C compiler, for building the grammar.
- The `zx` CLI or `zig` on `PATH` for LSP support.

## Installation

Clone the repository and point Emacs at `ide/emacs`:

```elisp
;; ~/.emacs.d/init.el
(use-package zx-ts-mode
  :load-path "~/src/ziex/ide/emacs"
  :mode "\\.zx\\'")
```

With `straight.el`:

```elisp
(use-package zx-ts-mode
  :straight (zx-ts-mode :type git :host github :repo "ziex-dev/ziex"
                        :files ("ide/emacs/zx-ts-mode.el"))
  :mode "\\.zx\\'")
```

Without a package manager, add the directory to `load-path` and require it:

```elisp
(add-to-list 'load-path "~/src/ziex/ide/emacs")
(require 'zx-ts-mode)
```

## Grammar

Build and install the ZX grammar once:

```
M-x zx-ts-mode-install-grammar
```

For `.mdzx` files, also run `M-x mdzx-ts-mode-install-grammar`.

This clones `ziex-dev/ziex` and compiles `pkg/tree-sitter-zx`. The recipe lives
in `zx-ts-mode-grammar-source` if you would rather build from a local checkout:

```elisp
(setq zx-ts-mode-grammar-source
      '(zx "~/src/ziex" nil "pkg/tree-sitter-zx/src"))
```

## LSP

`zx-ts-mode` and `mdzx-ts-mode` register themselves with Eglot. They run
`zx lsp`, or `zig build zx -Dziex-lsp=true -- lsp` from the nearest `build.zig` when the
`zx` CLI is not installed. Set `zx-ts-mode-lsp-command` to force a command.

```elisp
(add-hook 'zx-ts-mode-hook #'eglot-ensure)
(add-hook 'mdzx-ts-mode-hook #'eglot-ensure)
```

ZLS options go in the `zls` section of `eglot-workspace-configuration` (use
`:json-false` for `false`):

```elisp
(setq-default eglot-workspace-configuration
              '(:zls (:inlay_hints_show_builtin t)))
```

Turn on `eglot-inlay-hints-mode` to see inlay hints. See the
[editor guide](../README.md) for the ZX defaults.

## Customization

| Variable                     | Default        | Description                                |
| ---------------------------- | -------------- | ------------------------------------------ |
| `zx-ts-mode-indent-offset`   | `4`            | Spaces per indentation step.               |
| `zx-ts-mode-lsp-command`     | `nil` (auto)   | Command Eglot uses to start the server.    |
| `zx-ts-mode-grammar-source`  | see above      | Recipe used by `zx-ts-mode-install-grammar`. |

Three faces are defined for the markup so it can be told apart from the Zig
around it: `zx-ts-mode-tag-face`, `zx-ts-mode-attribute-face` and
`zx-ts-mode-builtin-attribute-face`.
