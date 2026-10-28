; MDZX Injections
; Aligned with tree-sitter-markdown naming conventions

; Inject language for fenced code blocks based on language info string
((fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content))

; Fallback: inject as text if no language specified
((fenced_code_block
  (code_fence_content) @injection.content)
  (#set! injection.language "text"))

; Comments use comment injection
((comment) @injection.content
  (#set! injection.language "comment"))

; Frontmatter is raw Zig
((frontmatter_body) @injection.content
  (#set! injection.language "zig"))
