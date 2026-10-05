# Heading Structure Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Org's heading structure commands, byte- and caret-exact against Emacs: insert heading (M-RET, C-RET, M-S-RET), move subtree (M-up/down), promote/demote subtree (M-S-left/right), heading motion (C-c C-n/p/f/b/u) and set tags (C-c C-q) through a prompt answered in the echo area.

**Architecture:** Multi-line commands are ported from Org 9.8.7's Lisp onto `EmacsBuffer`, a whole-text buffer with Emacs's point and marker rules (`insert`, `insert-before-markers`, `delete-region`, `replace-match`, `save-excursion`) and org's regexp-based outline primitives. `commitBuffer` turns the result into one minimal edit and the caret. Motion commands skip headings inside `EditContext.hidden` (folded text). Prompts go from `CommandStep.prompt` through `OrgEditor.onPrompt` to a minibuffer field in the echo area; the answer reruns the command.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Emacs 31.1 / Org 9.8.7 oracle.

**Spec:** `docs/design.md`, "Commands and keymaps".

## Global Constraints

- Org defaults: `org-blank-before-new-entry` heading `auto`, `org-M-RET-may-split-line` t, `org-auto-align-tags` t, tags column -77.
- The oracle unfolds the buffer after `org-mode` (`#+STARTUP` may fold it); cases run with everything visible.
- In plain lists, M-RET and M-S-RET insert items in org; list commands come in the next plan.

## Defaults chosen (user may change)

- Mac preset: ⌘↩ insert heading, ⌃⌘↩ after subtree, ⇧⌘↩ TODO heading, ⌃⌥⌘ arrows move/promote/demote subtree, ⌥⌘↑/↓ previous/next heading, ⌃⌘Q tags.
- The tags prompt has no completion yet.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgCore/Commands/EmacsBuffer.swift` | Buffer with point and markers, outline primitives, regexps, `commitBuffer` |
| `Sources/OrgCore/Commands/StructureCommands.swift` | Insert, move, promote/demote subtree, motion |
| `Sources/OrgCore/Commands/TagCommands.swift` | `SetTags` |
| `Sources/OrgCore/Commands/Command.swift` | `EditContext.hidden`, `Prompt.initial` |
| `Sources/OrgEditorAppKit/OrgEditor.swift` | Hidden ranges in the context, `onPrompt` |
| `Sources/Orgstar/*.swift` | Prompt in the echo area |

---

### Task 1: Buffer and structure commands

- [ ] Port `org-insert-heading` (with `org--blank-before-heading-p`, `org-N-empty-lines-before-current`), `org-insert-todo-heading`, `org-move-subtree-down`, `org-promote-subtree`/`org-demote-subtree` (`org-map-tree`, `org-promote`, `org-demote`, `org-fix-position-after-promote`), `org-next-visible-heading`, `org-forward-heading-same-level`, `outline-up-heading`.
- [ ] Oracle: every command at every caret of ten variants (levels, blank lines, tags, text before the first heading, no final newline, non-BMP) and over the corpus (`ORGSTAR_ORACLE_CORPUS`, files up to 20 KB).
- [ ] Commit "Port heading structure commands from org".

### Task 2: Tags and prompts

- [ ] `SetTags`: prompt with the current tags, then `org-set-tags` semantics (realign even when unchanged). Oracle with `completing-read-multiple` stubbed to the answer.
- [ ] Editor `onPrompt`; app minibuffer field (Return answers, Escape cancels); key bindings in both presets.
- [ ] Commit "Set tags through a prompt".
