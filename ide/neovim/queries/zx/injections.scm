((comment) @injection.content
  (#set! injection.language "comment"))

; TODO: add when asm is added
; (asm_output_item (string) @injection.content
;   (#set! injection.language "asm"))
; (asm_input_item (string) @injection.content
;   (#set! injection.language "asm"))
; (asm_clobbers (string) @injection.content
;   (#set! injection.language "asm"))

; SQL injections for db.run, db.query, etc.
((call_expression
    function: (field_expression
        object: (identifier) @object (#match? @object "^(db|database)$")
        member: (identifier) @method (#match? @method "^(run|query|exec|prepare)$"))
    arguments: (arguments
        .
        [
            (string
                (string_content) @injection.content)
            (multiline_string) @injection.content
        ]))
 (#set! injection.language "sql"))

; SQL injections for zx.db.run, zx.db.query, etc.
((call_expression
    function: (field_expression
        object: (field_expression
            object: (identifier) @namespace (#eq? @namespace "zx")
            member: (identifier) @object (#match? @object "^(db|database)$"))
        member: (identifier) @method (#match? @method "^(run|query|exec|prepare)$"))
    arguments: (arguments
        .
        [
            (string
                (string_content) @injection.content)
            (multiline_string) @injection.content
        ]))
 (#set! injection.language "sql"))
