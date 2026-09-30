;;; zx-ts-mode.el --- Major mode for Ziex (ZX) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ziex contributors

;; Author: Ziex contributors
;; URL: https://github.com/ziex-dev/ziex
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, zig, web
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Major mode for ZX, the markup-in-Zig language of the Ziex web framework
;; (https://ziex.dev).  It is backed by the tree-sitter grammar that lives in
;; `pkg/tree-sitter-zx' of the Ziex repository and provides font locking,
;; indentation, imenu and structural navigation for both the Zig and the
;; markup halves of a `.zx' file.
;;
;; Install the grammar once with `M-x zx-ts-mode-install-grammar'.
;;
;; Language server support comes from `zx lsp' via Eglot; the entry is added
;; to `eglot-server-programs' when Eglot is loaded.  See ide/emacs/README.md
;; for the full setup, including the libtree-sitter version ZX needs.

;;; Code:

(require 'treesit)

(declare-function treesit-node-child "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-next-sibling "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-parser-create "treesit.c")

(defgroup zx nil
  "Major mode for editing ZX files."
  :group 'languages
  :prefix "zx-ts-mode-")

(defcustom zx-ts-mode-indent-offset 4
  "Number of spaces for each indentation step in `zx-ts-mode'."
  :type 'integer
  :safe #'integerp)

(defcustom zx-ts-mode-lsp-command '("zx" "lsp")
  "Command that starts the ZX language server for Eglot."
  :type '(repeat string))

;;; Faces

(defface zx-ts-mode-tag-face
  '((t :inherit font-lock-function-name-face))
  "Face for ZX element tag names.")

(defface zx-ts-mode-attribute-face
  '((t :inherit font-lock-variable-name-face))
  "Face for ZX element attribute names.")

(defface zx-ts-mode-builtin-attribute-face
  '((t :inherit font-lock-builtin-face))
  "Face for ZX builtin attribute names such as `@allocator'.")

;;; Grammar

(defvar zx-ts-mode-grammar-source
  '(zx "https://github.com/ziex-dev/ziex" "main" "pkg/tree-sitter-zx/src")
  "Recipe for `treesit-language-source-alist' that builds the ZX grammar.")

;;;###autoload
(defun zx-ts-mode-install-grammar ()
  "Build and install the ZX tree-sitter grammar."
  (interactive)
  (let ((treesit-language-source-alist (list zx-ts-mode-grammar-source)))
    (treesit-install-language-grammar 'zx)))

;;; Font lock

(defvar zx-ts-mode--keywords
  '("asm" "const" "defer" "errdefer" "error" "test" "var")
  "Zig keywords with no more specific `zx-ts-mode' category.")

(defvar zx-ts-mode--type-keywords
  '("enum" "opaque" "struct" "union")
  "Zig keywords that introduce a container type.")

(defvar zx-ts-mode--modifier-keywords
  '("addrspace" "align" "allowzero" "callconv" "comptime" "export" "extern"
    "inline" "linksection" "noalias" "noinline" "packed" "pub" "threadlocal"
    "usingnamespace" "volatile")
  "Zig declaration modifiers.")

(defvar zx-ts-mode--control-keywords
  '("async" "await" "break" "catch" "continue" "else" "for" "if" "nosuspend"
    "resume" "return" "suspend" "switch" "try" "while")
  "Zig control-flow keywords.")

(defvar zx-ts-mode--operator-keywords
  '("and" "or" "orelse")
  "Zig operators spelled as words.")

(defvar zx-ts-mode--operators
  '("=" "*=" "*%=" "*|=" "/=" "%=" "+=" "+%=" "+|=" "-=" "-%=" "-|=" "<<="
    "<<|=" ">>=" "&=" "^=" "|=" "!" "~" "-" "-%" "&" "==" "!=" ">" ">=" "<="
    "<" "^" "|" "<<" ">>" "<<|" "+" "++" "+%" "*" "/" "%" "**" "*%" "*|" "||"
    ".*" ".?" "?" "..")
  "Zig operators.")

(defvar zx-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'zx
   :feature 'comment
   '((comment) @font-lock-comment-face
     ((comment) @font-lock-doc-face
      (:match "\\`//[/!]" @font-lock-doc-face)))

   :language 'zx
   :feature 'definition
   '((function_declaration name: (identifier) @font-lock-function-name-face)
     (parameter name: (identifier) @font-lock-variable-name-face)
     (container_field name: (identifier) @font-lock-property-name-face)
     (payload (identifier) @font-lock-variable-name-face))

   :language 'zx
   :feature 'keyword
   `([,@zx-ts-mode--keywords
      ,@zx-ts-mode--type-keywords
      ,@zx-ts-mode--modifier-keywords
      ,@zx-ts-mode--control-keywords
      ,@zx-ts-mode--operator-keywords
      "fn"]
     @font-lock-keyword-face)

   :language 'zx
   :feature 'string
   '((character) @font-lock-string-face
     (string) @font-lock-string-face
     (multiline_string) @font-lock-string-face)

   :language 'zx
   :feature 'type
   '((builtin_type) @font-lock-type-face
     "anyframe" @font-lock-type-face
     (parameter type: (identifier) @font-lock-type-face)
     ((identifier) @font-lock-type-face
      (:match "\\`[A-Z][A-Za-z0-9_]*\\'" @font-lock-type-face)))

   :language 'zx
   :feature 'tag
   '((zx_tag_name) @zx-ts-mode-tag-face
     ["<" ">" "</" "/>"] @font-lock-bracket-face)

   :language 'zx
   :feature 'attribute
   '((zx_attribute_name) @zx-ts-mode-attribute-face
     (zx_builtin_name) @zx-ts-mode-builtin-attribute-face
     (zx_attribute_value) @font-lock-string-face
     (zx_template_content) @font-lock-string-face
     (zx_shorthand_attribute (identifier) @zx-ts-mode-attribute-face)
     (zx_builtin_shorthand_attribute
      name: (identifier) @zx-ts-mode-builtin-attribute-face))

   :language 'zx
   :feature 'builtin
   '((builtin_identifier) @font-lock-builtin-face
     ((identifier) @font-lock-builtin-face
      (:equal "_" @font-lock-builtin-face)))

   :language 'zx
   :feature 'constant
   '([(boolean) "null" "undefined" "unreachable"] @font-lock-constant-face
     ((identifier) @font-lock-constant-face
      (:match "\\`[A-Z][A-Z0-9_]+\\'" @font-lock-constant-face)))

   :language 'zx
   :feature 'escape-sequence
   :override t
   '((escape_sequence) @font-lock-escape-face)

   :language 'zx
   :feature 'number
   '([(integer) (float)] @font-lock-number-face)

   :language 'zx
   :feature 'property
   '((field_expression member: (identifier) @font-lock-property-use-face))

   :language 'zx
   :feature 'function
   '((call_expression function: (identifier) @font-lock-function-call-face)
     (call_expression
      function: (field_expression member: (identifier) @font-lock-function-call-face)))

   :language 'zx
   :feature 'operator
   `([,@zx-ts-mode--operators] @font-lock-operator-face)

   :language 'zx
   :feature 'bracket
   '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)

   :language 'zx
   :feature 'delimiter
   '([";" "." "," ":" "=>" "->"] @font-lock-delimiter-face)

   :language 'zx
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock settings for `zx-ts-mode'.")

;;; Indentation

(defvar zx-ts-mode--indent-rules
  `((zx
     ((parent-is "source_file") column-0 0)
     ((node-is "}") standalone-parent 0)
     ((node-is ")") standalone-parent 0)
     ((node-is "]") standalone-parent 0)
     ((node-is "else_clause") standalone-parent 0)
     ;; A closing tag lines up with the element it closes.
     ((node-is "zx_end_tag") parent-bol 0)
     ;; Markup children and attributes are indented inside their tag.
     ((parent-is "zx_element") parent-bol zx-ts-mode-indent-offset)
     ((parent-is "zx_fragment") parent-bol zx-ts-mode-indent-offset)
     ((parent-is "zx_start_tag") parent-bol zx-ts-mode-indent-offset)
     ((parent-is "zx_self_closing_element") parent-bol zx-ts-mode-indent-offset)
     ((parent-is "zx_block") parent-bol zx-ts-mode-indent-offset)
     ((parent-is "zx_child") parent-bol 0)
     ;; Zig.
     ((parent-is "block") standalone-parent zx-ts-mode-indent-offset)
     ((parent-is "switch_expression") standalone-parent zx-ts-mode-indent-offset)
     ((parent-is "initializer_list") standalone-parent zx-ts-mode-indent-offset)
     ((parent-is "arguments") standalone-parent zx-ts-mode-indent-offset)
     ((parent-is "parameters") standalone-parent zx-ts-mode-indent-offset)
     ((parent-is "parenthesized_expression") standalone-parent zx-ts-mode-indent-offset)
     (catch-all parent-bol 0)))
  "Tree-sitter indentation rules for `zx-ts-mode'.")

;;; Navigation

(defun zx-ts-mode--defun-name (node)
  "Return the name of NODE for imenu and `which-function-mode'.
`function_declaration' exposes a `name' field.  `test_declaration'
does not; its title is a `string' or `identifier' child."
  (let ((name-node (treesit-node-child-by-field-name node "name")))
    (when (and (null name-node)
               (equal (treesit-node-type node) "test_declaration"))
      (let ((child (treesit-node-child node 0 t)))
        (while (and child
                    (not (member (treesit-node-type child)
                                 '("string" "identifier"))))
          (setq child (treesit-node-next-sibling child t)))
        (setq name-node child)))
    (and name-node (treesit-node-text name-node t))))

;;; Eglot

(defun zx-ts-mode-eglot-contact (&optional _interactive)
  "Return the ZX language server command for Eglot.
Reads `zx-ts-mode-lsp-command' on every connection, so customizing it
takes effect without reloading."
  zx-ts-mode-lsp-command)

(with-eval-after-load 'eglot
  (when (boundp 'eglot-server-programs)
    (add-to-list 'eglot-server-programs
                 '(zx-ts-mode . zx-ts-mode-eglot-contact))))

;;; Mode

(defvar zx-ts-mode--syntax-table
  (let ((table (make-syntax-table)))
    ;; Zig comments: `//' to end of line.
    (modify-syntax-entry ?/ ". 12" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?@ "'" table)
    (dolist (char '(?+ ?- ?* ?% ?& ?| ?^ ?! ?= ?< ?> ?~ ??))
      (modify-syntax-entry char "." table))
    table)
  "Syntax table for `zx-ts-mode'.")

;;;###autoload
(define-derived-mode zx-ts-mode prog-mode "ZX"
  "Major mode for editing ZX files, powered by tree-sitter.

\\{zx-ts-mode-map}"
  :syntax-table zx-ts-mode--syntax-table

  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "//+[ \t]*")

  (if (not (treesit-ready-p 'zx))
      (message "ZX tree-sitter grammar is missing; run M-x zx-ts-mode-install-grammar")

    (treesit-parser-create 'zx)

    (setq-local treesit-font-lock-settings zx-ts-mode--font-lock-settings)
    (setq-local treesit-font-lock-feature-list
                '((comment definition)
                  (keyword string type tag)
                  (attribute builtin constant escape-sequence number property)
                  (bracket delimiter function operator error)))

    (setq-local treesit-simple-indent-rules zx-ts-mode--indent-rules)
    (setq-local indent-tabs-mode nil)

    (setq-local treesit-defun-type-regexp
                "\\`\\(?:function_declaration\\|test_declaration\\)\\'")
    (setq-local treesit-defun-name-function #'zx-ts-mode--defun-name)
    (setq-local treesit-simple-imenu-settings
                '(("Function" "\\`function_declaration\\'" nil nil)
                  ("Test" "\\`test_declaration\\'" nil nil)))

    (treesit-major-mode-setup)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.zx\\'" . zx-ts-mode))

(provide 'zx-ts-mode)

;;; zx-ts-mode.el ends here
