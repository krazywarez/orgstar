# Timestamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Org's date prompt, timestamp insertion (C-c ., C-c !), scheduling and deadlines (C-c C-s, C-c C-d, and removal), timestamp shifting (S-arrows on a timestamp), and repeating entries completed with DONE, all byte- and caret-exact against Emacs with a frozen clock.

**Architecture:** `ReadDate` ports `org-read-date-analyze` with `parse-time-string`'s tokenizer and rules, `org-read-date-get-relative` and `org-small-year-to-year`. `Timestamps.swift` ports `org-at-timestamp-p` (point categories), `org-insert-timestamp`, `org-timestamp-change` with `org-modify-ts-extra`, `org-toggle-timestamp-type`, `org-add-planning-info`. `TimestampCommands.swift` holds `org-timestamp`, `org--deadline-or-schedule` and the shift commands. `Repeat.swift` ports `org-auto-repeat-maybe` and the state note (`org-store-log-note`, `org-log-beginning`); TODO cycling runs it when an entry becomes done. Commands read `now` and `calendar` from `EditContext`. A `timestamp` key context lets S-arrows shift timestamps and fall back to priority and TODO on headings.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Emacs 31.1 / Org 9.8.7 oracle.

**Spec:** `docs/design.md`, "Commands and keymaps" (revisions, time and prompts).

## Global Constraints

- Org defaults: `org-read-date-prefer-future` t, `org-time-stamp-rounding-minutes` (0 5), `org-log-repeat` `time`, `org-log-into-drawer` nil, `org-log-states-order-reversed` t, `org-todo-repeat-to-state` nil, `org-log-reschedule`/`org-log-redeadline` nil.
- The oracle freezes `current-time`, `decode-time`, `format-time-string`, `org-today` and `time-less-p`, runs with `TZ=UTC`, stubs `read-string` with the answer, and stores the deferred log note as the post-command hook would.

## Defaults chosen (user may change)

- Mac preset: ⌃⌘. timestamp, ⌃⌥⌘. inactive, ⌃⌘S schedule, ⌃⌘D deadline, ⌃⌘ arrows shift a timestamp under the caret.
- Not yet: date ranges in the prompt and S-arrows on ranges, the calendar picker, CLOCK line updates, deadline warning edits (C-u C-u).

---

### Task 1: Date prompt

- [x] Port; oracle over 52 inputs (relative, weekdays, ISO weeks, US and European dates, am/pm, `HHhMM`, ranges, durations).
- [x] Commit "Port the date prompt".

### Task 2: Timestamps, planning, repeats

- [x] Port; oracle over 7 texts × every caret × 9 commands × 6 answers, and 10 repeating entries.
- [x] Commit "Port timestamp and planning commands".

### Task 3: Keys

- [x] Bind both presets; `timestamp` context.
