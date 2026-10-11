# Planning Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `docs/plans`, `docs/design.md` and `docs/review-2026-10-05.md` say what is done and what is not, and every open piece of work has exactly one home.

**Architecture:** Plans are historical once their commits land: their boxes get ticked against `git log`, and any step that did not ship is marked so in place. The design doc's status paragraph and phase-1 boxes are brought to today. The review is kept as a record with a note at the top that its tiers shipped and that the manual's "Known differences from Emacs Org" is now the living list. Open work goes to gitbay issues on `krz/orgstar`, one per piece, so the backlog is the issue list and nothing else.

**Tech Stack:** `git log`, `gitbay issue create`.

**Spec:** this file.

## Global constraints

- Plans are not rewritten or trimmed; only checkboxes and short "did not ship:" lines change.
- A box is ticked only when the commit it names, or one that plainly covers the step, is found; a box for a verification step (a gate run, a VoiceOver pass) is ticked only when the result is recorded somewhere.
- No new planning documents beyond this one.

## Review focus

- The two owed items in `docs/design.md` (the VoiceOver check at line 353, the M1 Air gate run at line 359) must remain unticked and get an issue each; ticking them by momentum is the failure to avoid.
- Plan steps that say "Commit "X"" should be matched by subject, not by topic: `git log --oneline --fixed-strings --grep="X"`.
- The review's defects table was fixed by named commits (`Fix duplicate bindings`, `Keep body folds through edits`, `Watch folders added during a session`, `Report each buffer's changes as its own`, `Refile and archive into open buffers`, `Babel: show errors, cancel runs`, `Line index, and cheaper block bands while typing`, `Open .org files from Finder, app icon, current docs`); the clock report reading from disk (`ClockViews.swift`) is the one row to check by reading the code before calling the table closed.

---

### Task 1: Tick the 20 plans

Files: the plans with open boxes, found with `for f in docs/plans/*.md; do grep -q '^\s*- \[ \]' "$f" && echo "$f"; done` (20 files dated 2026-10-04 and 2026-10-05).

- [ ] For each file, for each `- [ ]` line: find its commit (`git log --oneline --fixed-strings --grep="<subject>"` for "Commit …" steps; `git log --oneline -- <path>` for implementation steps naming a file; the step's tests by name in `Tests/`). Tick it.
- [ ] A step with no evidence stays `- [ ]` and gets ` — did not ship: <one line>` appended. Expected: `2026-10-04-editing-spike.md`'s VoiceOver step, `2026-10-04-viewer.md`'s and `2026-10-04-performance.md`'s "run the gates" steps (recorded on an M-series Mac only, per `design.md`); anything else found is reported in the commit message.
- [ ] Commit "Tick the shipped plan steps" with the did-not-ship list in the body.

### Task 2: `docs/design.md`

- [ ] Replace the status paragraph (line 337) with one dated 2026-10-10: phases 1–7 built; the Mac released as v0.2.0 (notarized DMG, cask); iOS complete for Simulator builds, device signing and TestFlight not set up; owed: the M1 Air gate run, the VoiceOver check on both platforms.
- [ ] Phase-1 boxes: leave lines 353 and 359 unticked; tick nothing else (all others are already `[x]`).
- [ ] Open questions: tick "App name: Orgstar (chosen)" (line 390); add the lowercase spelling, per commit `Name the app orgstar, in lowercase`.
- [ ] Under "Phases", after the list, one sentence: plans in `docs/plans/` are ticked when their commits land, and what did not ship is marked in the plan; open work is in the repository's issues.
- [ ] Commit "Design doc status for 2026-10-10".

### Task 3: The review

- [ ] At the top of `docs/review-2026-10-05.md`, under the title, a two-line note: every tier shipped between a831086 and 2d3da68 (`git log --oneline a831086..2d3da68 | wc -l` commits); the current list of refusals and gaps is `docs/manual/guide/15-alongside-emacs.org`, "Known differences from Emacs Org".
- [ ] Check `Sources/Orgstar/ClockViews.swift` for the defects-table row "Clock report reads files from disk and ignores unsaved buffers"; if still true, it becomes an issue in Task 4.
- [ ] Commit "Mark the October 5 review as historical".

### Task 4: Issues for the open work

- [ ] `gitbay issue create --title … --file -` for each, body: what, where, done-when, pointer to the plan when one exists:
  - Run the phase-1 gates on the M1 Air (`ORGSTAR_GATES=1 swift test -c release --filter GateTests`); record the numbers in `design.md`.
  - VoiceOver pass, Mac: the editing-spike checklist in `docs/plans/2026-10-04-editing-spike.md`.
  - VoiceOver pass, iOS: reader, editor, agenda rows, capture form.
  - Sparkle updates (`docs/plans/2026-10-10-sparkle-updates.md`).
  - Windows and panes (`docs/plans/2026-10-10-windows-and-panes.md`).
  - File splits (`docs/plans/2026-10-10-file-splits.md`).
  - iOS device signing and a TestFlight release script.
  - Clock report over unsaved buffers, if Task 3 found it still reads disk.
- [ ] Issue 1 ("iOS: refile under a heading") stays as it is.
- [ ] No commit; list the issue numbers in the merge request description.
