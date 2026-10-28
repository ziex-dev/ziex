; MDZX Text Objects
; Aligned with tree-sitter-markdown naming conventions

; Frontmatter as a block
(frontmatter) @block.around

; ZX elements
(zx_element
  (zx_start_tag)
  (_)* @block.inside
  (zx_end_tag)) @block.around

; Frontmatter body (raw Zig)
(frontmatter
  (frontmatter_body) @function.inside) @function.around

; Markdown block elements
(atx_heading) @block.around
(fenced_code_block) @block.around
(block_quote) @block.around
(list) @block.around
(list_item) @block.around
(paragraph) @block.around

; Comments
(comment)+ @comment.around
