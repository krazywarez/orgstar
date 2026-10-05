# Agenda Search and Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The TODO list (`org-todo-list`), tag/property/TODO match views (`org-tags-view`, `m` and `M`), saved views, and agenda commands that change entries (TODO state, priority, schedule, deadline, tags, date shift) from the agenda window.

**Architecture:** `OrgCore/Agenda/AgendaSearch.swift` ports `org-agenda-get-todos`, `org-make-tags-matcher` and `org-scan-tags` over `AgendaSource`, which now carries levels, own properties, planning and first timestamps for the special properties. Emacs regexps in `{...}` terms are translated to ICU. Saved views are read from `views.toml` beside `keymap.toml`. Agenda commands run the existing editor commands at the entry: through the open buffer when the file is open, otherwise on a `DocumentState` read from disk and written back through `Saver`, so a file changed on disk in between is merged or refused.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Emacs 31.1 / Org 9.8.7 oracle.

**Spec:** `docs/design.md`, "Phase 3".

## Global Constraints

- Oracle: `org-todo-list` and `org-tags-view` (with and without TODO-only) over the agenda test files and the corpora, compared line by line as for the agenda.
- `/{regexp}` against a heading without a keyword is an error in Emacs; it is no match here.
- String comparisons in matches use code point order (`string-collate-lessp` in the C locale).

## Defaults chosen (user may change)

- Views: Agenda (`a`), TODO list (`t`), Match (`m`) and TODO match (`M`) are built in; `views.toml` adds named views.
- Agenda keys follow Emacs: `t` TODO cycle, `+`/`-` priority, `,` priority prompt, `:` tags, `C-c C-s`/`C-c C-d` (⌘S-free: `s`/`d` too), `S-→`/`S-←` date shift.

---

### Task 1: TODO list and matcher

- [x] `Agenda.todoList`, `Agenda.tagsMatch`, `TagsMatcher`, `EmacsRegex`.
- [x] Oracle: 4 TODO lists and 34 match strings × TODO-only on three synthetic files; corpora.
- [x] Commit "TODO list and tag matches".

### Task 2: Views in the app

- [ ] `AgendaModel.mode` (agenda, TODO list, match); view picker and match field in the agenda window; `views.toml` loader with errors in the echo area.
- [ ] Commit "Agenda views".

### Task 3: Agenda commands

- [ ] `AgendaEditor`: run a command at a file offset, through the session or through `Saver`.
- [ ] Keys in the agenda window; prompts for dates, tags and priority; the agenda refreshes after each.
- [ ] Commit "Agenda commands".
