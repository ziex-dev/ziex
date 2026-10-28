; MDZX Outline
; Aligned with tree-sitter-markdown naming conventions

; Markdown headings - primary outline structure
(atx_heading
  (atx_h1_marker) @context
  heading_content: (inline) @name) @item

(atx_heading
  (atx_h2_marker) @context
  heading_content: (inline) @name) @item

(atx_heading
  (atx_h3_marker) @context
  heading_content: (inline) @name) @item

(atx_heading
  (atx_h4_marker) @context
  heading_content: (inline) @name) @item

(atx_heading
  (atx_h5_marker) @context
  heading_content: (inline) @name) @item

(atx_heading
  (atx_h6_marker) @context
  heading_content: (inline) @name) @item

; ZX components (top-level elements)
(mdzx_component
  (zx_element
    (zx_start_tag
      name: (zx_tag_name) @name))) @item

(mdzx_component
  (zx_self_closing_element
    name: (zx_tag_name) @name)) @item
