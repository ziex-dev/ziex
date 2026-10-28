; MDZX - MDX-like format for Zig
; Self-contained highlights for frontmatter (Zig), ZX components, and markdown

; ==========================================
; Frontmatter
; ==========================================

(frontmatter_delimiter) @punctuation.special

; ==========================================
; ZX Components
; ==========================================

(zx_tag_name) @tag
(zx_attribute_name) @tag.attribute
(zx_string_literal) @string
(zx_builtin_name) @function.builtin
(zx_text) @none

; HTML/JSX-like brackets
[
  "<"
  ">"
  "</"
  "/>"
  "<>"
  "</>"
] @tag.delimiter

; ==========================================
; Zig Syntax (frontmatter)
; ==========================================

; Comments
(comment) @comment

; Variables and identifiers
(identifier) @variable

; Types (PascalCase)
((identifier) @type
  (#match? @type "^[A-Z_][a-zA-Z0-9_]*"))

; Fields in struct initializers
(field_expression
  member: (identifier) @property)

; Builtin functions (@import, etc.)
(builtin_identifier) @function.builtin

; Strings
(string) @string
(string_content) @string

; Numbers
(integer) @number
(float) @number.float

; Keywords
[
  "pub"
  "const"
] @keyword

; Operators
"=" @operator

; Punctuation
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ";"
  ":"
  ","
  "."
] @punctuation.delimiter

; ==========================================
; Markdown Block Elements (aligned with tree-sitter-markdown)
; ==========================================

; ATX Headings
(atx_heading
  (atx_h1_marker) @markup.heading.1.marker
  heading_content: (inline) @markup.heading.1)
(atx_heading
  (atx_h2_marker) @markup.heading.2.marker
  heading_content: (inline) @markup.heading.2)
(atx_heading
  (atx_h3_marker) @markup.heading.3.marker
  heading_content: (inline) @markup.heading.3)
(atx_heading
  (atx_h4_marker) @markup.heading.4.marker
  heading_content: (inline) @markup.heading.4)
(atx_heading
  (atx_h5_marker) @markup.heading.5.marker
  heading_content: (inline) @markup.heading.5)
(atx_heading
  (atx_h6_marker) @markup.heading.6.marker
  heading_content: (inline) @markup.heading.6)

; Fallback for heading markers without field capture
[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
] @markup.heading.marker

; Fenced Code Blocks
(fenced_code_block
  (fenced_code_block_delimiter) @markup.raw.delimiter)
(fenced_code_block
  (info_string
    (language) @label))
(fenced_code_block
  (code_fence_content) @markup.raw.block)

; Block Quotes
(block_quote
  (block_quote_marker) @markup.quote)

; Lists
(list_item
  [
    (list_marker_minus)
    (list_marker_plus)
    (list_marker_star)
    (list_marker_dot)
    (list_marker_parenthesis)
  ] @markup.list.marker)

; Task list markers
(task_list_marker_checked) @markup.list.checked
(task_list_marker_unchecked) @markup.list.unchecked

; Thematic Break
(thematic_break) @punctuation.special

; Link Reference Definition
(link_reference_definition
  (link_label) @markup.link.label
  (link_destination) @markup.link.url
  (link_title) @markup.link.title)

; Paragraph
(paragraph
  (inline) @markup)

; ==========================================
; Markdown Inline Elements
; NOTE: These require a separate inline grammar (like tree-sitter-markdown-inline)
; For now, inline content is captured as a single "inline" node.
; Full inline parsing (emphasis, links, code spans) can be done via:
; 1. Language injection from markdown-inline grammar
; 2. Or extending this grammar to fully parse inline content
; ==========================================

; Backslash Escape (works at block level in link_destination, etc.)
(backslash_escape) @string.escape

; Link components in link_reference_definition
(link_label) @markup.link
(link_destination) @markup.link.url
(link_title) @markup.link.title
