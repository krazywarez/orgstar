# Table Formulas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `#+TBLFM` recalculation (`C-c *`, `C-u C-c *`, `C-c C-c` on a `#+TBLFM` line) computed natively where Calc's results can be reproduced exactly, and in Emacs otherwise.

**Architecture:** `OrgCore/Compute/Calc.swift` implements the Calc subset table formulas use with Calc's number model: exact integers, decimal floats rounded half-up to 12 digits after each operation (`math-make-float`, `math-div-float`, `math-ipow`), `*` binding tighter than `/`, exact results for special trig and log values, and `math-format-number` for `float`, `fix`, `sci` and `eng` formats. `TableFormulas.swift` ports `org-table-recalculate`, `org-table-eval-formula`, `org-table-get-range`, row descriptors (`@I`, `@-1`, `@<`, `@>`), lhs ranges and `org-table-justify-field-maybe`, then aligns with the existing `org-table-align` port. Anything outside the domain (text in a referenced field, division by zero, names, constants, `remote()`, Lisp, durations, unsupported functions or flags) returns `.external(.emacsTable)`: the app runs `emacs --batch` on a snapshot of the buffer in the file's folder and splices back the table text if the table is unchanged. Lisp formulas ask first, with "always" stored by content hash in `trusted.json`.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Emacs 31.1 / Org 9.8.7 / Calc oracle.

**Spec:** `docs/design.md`, "Table formula evaluator".

## Global Constraints

- Calc oracle: 475 expressions (fixed and random) against `calc-eval` with `org-calc-default-modes`, every display format.
- Table oracle: 20 tables × every row and `#+TBLFM` line × `org-table-recalculate t`/`nil` and `org-ctrl-c-ctrl-c`, text and point; corpus `#+TBLFM` lines.
- On an error partway through, Emacs keeps the fields already written; here nothing changes.
- New command step `.external(ExternalRequest)` for work done outside the text.

## Defaults chosen (user may change)

- Keys: `C-c *` recalculates the row, `C-c C-c` on `#+TBLFM` the table; "Recalculate Table" in the palette for `C-u C-c *`.
- Emacs is found at `ORGSTAR_EMACS`, Homebrew, `/usr/local/bin` or Emacs.app.

---

### Task 1: Calc

- [x] Numbers, operators, functions, formats; oracle.

### Task 2: Recalculation

- [x] `tableRecalculate`, `TableRecalculate`, `tblfm` key context, bindings; oracle; corpus.

### Task 3: Emacs fallback

- [x] `.external`, `EmacsRunner.recalculateTable`, `DocumentSession.recalculateInEmacs`, `TrustStore`, editor wiring; test with a text field.
- [x] Commit "Table formulas".
