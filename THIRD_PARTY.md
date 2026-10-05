# Third-party code

Orgstar is 0BSD. It builds on these projects, under their own licenses.

| Project | Use | License |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Index database | MIT |
| [tree-sitter](https://github.com/tree-sitter/tree-sitter), [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter) | Src block parsing | MIT |
| tree-sitter grammars: [bash](https://github.com/tree-sitter/tree-sitter-bash), [c](https://github.com/tree-sitter/tree-sitter-c), [cpp](https://github.com/tree-sitter/tree-sitter-cpp), [go](https://github.com/tree-sitter/tree-sitter-go), [haskell](https://github.com/tree-sitter/tree-sitter-haskell), [java](https://github.com/tree-sitter/tree-sitter-java), [javascript](https://github.com/tree-sitter/tree-sitter-javascript), [json](https://github.com/tree-sitter/tree-sitter-json), [python](https://github.com/tree-sitter/tree-sitter-python), [ruby](https://github.com/tree-sitter/tree-sitter-ruby), [rust](https://github.com/tree-sitter/tree-sitter-rust) | Highlighting; parsers, scanners and queries | MIT |
| [tree-sitter-lua](https://github.com/tree-sitter-grammars/tree-sitter-lua), [tree-sitter-yaml](https://github.com/tree-sitter-grammars/tree-sitter-yaml) | Highlighting | MIT |
| [tree-sitter-r](https://github.com/r-lib/tree-sitter-r) | Highlighting | MIT |
| [tree-sitter-scheme](https://github.com/6cdh/tree-sitter-scheme) | Highlighting | MIT |
| [tree-sitter-elisp](https://github.com/Wilfred/tree-sitter-elisp) | Highlighting (vendored in `Sources/TreeSitterElisp`) | MIT |
| [tree-sitter-clojure](https://github.com/sogaiu/tree-sitter-clojure) | Highlighting (vendored in `Sources/TreeSitterClojure`) | CC0-1.0 |

The JavaScript, Lua, Python and YAML scanners are copied into `Sources/TreeSitterScanners` with their licenses. Highlight queries are embedded in `Sources/OrgHighlight/Queries.swift` by `scripts/update-highlight-queries.sh`.
