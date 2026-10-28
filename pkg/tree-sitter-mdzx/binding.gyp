{
  "targets": [
    {
      "target_name": "tree_sitter_mdzx_binding",
      "dependencies": [
        "<!(node -p \"require('node-addon-api').targets\"):node_addon_api_except",
      ],
      "include_dirs": [
        "src",
      ],
      "sources": [
        "bindings/node/binding.cc",
        "src/parser.c",
        "tree-sitter-mdzx-inline/src/parser.c",
      ],
      "variables": {
        "has_scanner": "<!(node -p \"fs.existsSync('src/scanner.c')\")",
        "has_inline_scanner": "<!(node -p \"fs.existsSync('tree-sitter-mdzx-inline/src/scanner.c')\")"
      },
      "conditions": [
        ["has_scanner=='true'", {
          "sources+": ["src/scanner.c"],
        }],
        ["has_inline_scanner=='true'", {
          "sources+": ["tree-sitter-mdzx-inline/src/scanner.c"],
        }],
        ["OS!='win'", {
          "cflags_c": [
            "-std=c11",
          ],
        }, { # OS == "win"
          "cflags_c": [
            "/std:c11",
            "/utf-8",
          ],
        }],
      ],
    }
  ]
}
