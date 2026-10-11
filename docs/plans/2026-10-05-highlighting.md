# Src Block Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Code in src blocks is highlighted with tree-sitter grammars and their own highlight queries: shells, Python, Emacs Lisp, C, C++, R, JavaScript, Java, Scheme, Clojure, Haskell, Rust, Go, Ruby, JSON, YAML, Lua.

**Architecture:** `OrgPresentation` defines `SyntaxCategory`, a `.syntax` style role and the `CodeHighlighter` protocol; `Presentation.styles` asks a highlighter for runs inside `#+begin_src LANG` blocks. `OrgHighlight` implements it with swift-tree-sitter 0.25: org language names map to grammars, each grammar and query compiles once, results are cached by code. Queries are embedded as Swift strings (`scripts/update-highlight-queries.sh`), so nothing ships as a resource bundle. The editor takes a highlighter at creation; the theme colors categories.

**Tech Stack:** Swift 6.2 tools, swift-tree-sitter 0.25, tree-sitter grammars pinned in `Package.swift`.

**Spec:** `docs/design.md`, "Babel and table formulas" (highlighting), "Phase 1 scope" (src block highlighting).

## Notes

- Emacs Lisp (no Swift package) and Clojure (no package at its tags) are vendored as C targets.
- The JavaScript, Lua, Python and YAML packages include `scanner.c` only when `fileExists("src/scanner.c")` holds in SwiftPM's working directory, which it doesn't; their scanners are compiled in `TreeSitterScanners`.
- Third-party licenses: `THIRD_PARTY.md`.

## Not highlighted (user may decide)

- SQL: its grammar ships parser.c (41 MB) only on a gh-pages branch.
- LaTeX and Common Lisp (no highlight queries), dot, PlantUML, Mermaid (no usable grammars).

---

### Task 1: Highlighting

- [x] Hook, highlighter, vendored grammars and scanners, embedded queries, theme colors; tests for categories in Python, shell and Emacs Lisp and for runs in a src block; app snapshot.
- [x] Commit "Highlight src blocks with tree-sitter".
