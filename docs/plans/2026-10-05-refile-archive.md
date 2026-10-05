# Refile and Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refile (C-c C-w) to any heading down to level 3 in the workspace or to the end of a file, archive (C-c C-x C-s, C-c $) where `org-archive-subtree` would, and the TODO statistics updates org makes after TODO changes, all byte- and caret-exact against Emacs.

**Architecture:** `OrgCore` ports `org-copy-subtree`, `org-paste-subtree`, `org-map-region` and the insert/delete steps of `org-refile` (`Refile.swift`); `org-archive-subtree` with `org-archive--compute-location`, context properties through `org-entry-put` (property drawer creation, `org-property-format` alignment), and `org-update-statistics-cookies` (`Archive.swift`); `org-update-parent-todo-statistics` (`Statistics.swift`), now run after TODO cycling and TODO-heading insertion through `followUp`. `DocumentSession.refile(to:)` and `archive()` handle a second file: it is read and written through the save path first, and the subtree leaves the buffer (`PrecomputedEdit`, one undo step) only once that write succeeds. Refile targets come from the index (`IndexStore.outline(maxLevel:)`) and, for the open file, from its buffer. Prompts gain choices, filtered as you type in the echo area.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Emacs 31.1 / Org 9.8.7 oracle.

**Spec:** `docs/design.md`, "Commands and keymaps", "Saving".

## Global Constraints

- Org defaults: `org-log-refile` nil, `org-reverse-note-order` nil, `org-refile-keep` nil, archive location `%s_archive::`, context info time/file/olpath/category/todo/itags, inherited tags added only in-file, no DONE marking, `org-provide-todo-statistics` t, hierarchical statistics.
- The oracle visits real temporary files, freezes `format-time-string` and runs with `TZ=UTC`; `.org_archive` files open in Org mode.

## Defaults chosen (user may change)

- Refile targets: every org file itself plus its headings to level 3 (org's default is level-1 headings of the current file).
- Mac preset: ⌃⌘W refile, ⌃⌘A archive.

---

### Task 1: Core

- [ ] Port refile, archive and statistics; oracles: refile within a file and to another file (4 sources × every caret × every target, 5 target files), archive (7 sources × 4 archive files), TODO cycle and TODO-heading insert with parent cookies.
- [ ] Commit "Port refile, archive and TODO statistics from org".

### Task 2: Session and app

- [ ] `DocumentBuffer.selection` and `perform`; `PrecomputedEdit`; `DocumentSession.refile(to:)`, `archive()`; `WorkspaceModel.refileTargets`; prompt choices; keys and palette entries.
- [ ] Commit "Refile and archive in the app".
