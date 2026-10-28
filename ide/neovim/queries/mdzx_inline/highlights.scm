; MDZX Inline highlights
(emphasis) @markup.italic
(strong_emphasis) @markup.bold
(bold_italic) @markup.italic
(bold_italic) @markup.bold
(strikethrough) @markup.strikethrough
(code_span) @markup.raw.inline
(code_span_delimiter) @punctuation.delimiter

(inline_link
  (link_text) @markup.link.label
  (link_destination)? @markup.link.url)
(full_reference_link
  (link_text) @markup.link.label)
(image
  (link_text) @markup.link.label
  (link_destination)? @markup.link.url)
(autolink (uri) @markup.link.url)
(backslash_escape) @string.escape
