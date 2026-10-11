# File Splits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No hand-written Swift file over 1,000 lines, by moving code between files without changing it, so the next pieces of work (windows and panes first) land in files that fit in one read.

**Architecture:** Each split moves whole `// MARK:` sections or whole types into a new file in the same module as an `extension` of the same type. `private` members that the moved code reaches become internal (no modifier); nothing is renamed, reordered or reworded. One commit per source file, with `swift build` and `swift test` green before and after each.

**Tech Stack:** Swift 6.2, Swift Testing.

**Spec:** this file.

## Global constraints

- Behaviour-preserving: the diff of each commit is moves plus access-level changes only. `git diff --stat` shows a drop in the source file matching the sum of the new files, give or take the `extension` lines.
- Generated files are exempt and untouched: `Sources/OrgCore/Keymap/CharFold.swift` (from `scripts/update-char-fold.sh`) and `Sources/OrgHighlight/Queries.swift` (from `scripts/update-highlight-queries.sh`).
- Order: `ContentView.swift` and `OrgEditor.swift` first, since `2026-10-10-windows-and-panes.md` edits both; the rest in any order.
- Each new file starts with the imports its code needs and nothing else.

## Review focus

- A `private` member made internal must not collide with another internal name in the module: build errors catch it, but check `OrgCore` for duplicate helper names such as `lines`, `trimmed` and `offset` before moving.
- `@MainActor` on the type carries to its extensions; `nonisolated` and `@objc` methods (`textStorage(_:didProcessEditing:…)`, delegate conformances) must stay in an extension that declares the conformance, or `NSObject` dispatch breaks at run time, not build time: run the app after `OrgEditor` and `MobileEditor` move.
- Swift Testing suites that use `@testable import` and reach `private` helpers through `fileprivate` test extensions lose access when the helper moves; build the test targets, not just the products.
- Stored properties cannot live in extensions: every `var` with storage stays in the file that declares the type.

---

### Task 1: `Sources/Orgstar/ContentView.swift` (1,106 lines)

- [ ] Move `Sidebar` and `OutlineColumn` to `Sidebar.swift` (`SidebarFiles.swift` already exists and stays).
- [ ] Move `SearchResults` and `QuickOpenView` to `SearchViews.swift`.
- [ ] Move `BufferTabs` and `PaneDivider` to `BufferTabs.swift`.
- [ ] Move `Panel` and `BlockEditRequest` to `Panels.swift`.
- [ ] `ContentView` itself is about 790 lines and stays. Build, test, run the app, commit "Split ContentView.swift".

### Task 2: `Sources/OrgEditorAppKit/OrgEditor.swift` (1,566 lines)

- [ ] Move `ShadedFragment`, `ImageFragment`, `EntityFragment`, `FoldedHeadingFragment`, `InlineImageBox` and the `NSAttributedString.Key` extension to `Fragments.swift`.
- [ ] Move `HiddenRanges` and `FoldedHeadings` to `HiddenRanges.swift`.
- [ ] Move the `Folding`, `Sparse trees`, `STARTUP display` and `Narrowing` sections to `OrgEditor+Folding.swift`.
- [ ] Move `Inline images` to `OrgEditor+Images.swift`, `Shrunk table columns` to `OrgEditor+Shrink.swift`, `Styling` to `OrgEditor+Styling.swift`.
- [ ] `OrgEditor.swift` keeps the class with its stored properties, `Initial styling`, `Saving`, `Commands`, `Disk`, `Editing` and the delegate extensions (`DocumentBuffer`, `NSTextStorageDelegate`, `NSTextContentStorageDelegate`, `NSTextLayoutManagerDelegate`). Build, test, run the app and type in a folded file, commit "Split OrgEditor.swift".

### Task 3: `Sources/OrgstarMobile/MobileEditor.swift` (1,209 lines)

- [ ] Move `LockedRanges`, `FragmentStyle`, `KeyedTextView`, `SelectionHighlightView`, `OrgLineFragment`, `InlineImageBox` and the `NSAttributedString.Key` extension to `MobileFragments.swift`.
- [ ] Move `Styling` to `MobileEditor+Styling.swift`; `Shrunk table columns`, `Inline images`, `Truncation` and `Folding` to `MobileEditor+Display.swift`.
- [ ] Build with `scripts/build-ios-app.sh`, run in the Simulator, fold a heading and shrink a column, commit "Split MobileEditor.swift".

### Task 4: `Sources/OrgCore/Compute/Babel.swift` (2,017 lines)

- [ ] Keep `BabelJob`, `BabelOutput`, `enum Babel` with `Planning`, and `ExecuteSrcBlock` in `Babel.swift`.
- [ ] `BabelNoweb.swift`: `Noweb` (check first whether `BabelExpand.swift` already holds the expansion it calls; if so, move `Noweb` there).
- [ ] `BabelHeaders.swift`: `Header arguments` and `Variables`; `BabelVars.swift`: `Tables in variables`.
- [ ] `BabelCache.swift`: `Cache`. `BabelLanguages.swift`: `Python` and `Emacs Lisp`. `BabelResults.swift`: `Finishing` and `Inserting`.
- [ ] `swift test --filter Babel`, then the whole suite, commit "Split Babel.swift".

### Task 5: `Sources/OrgCore/Keymap/Presets.swift` (1,357 lines)

- [ ] `PresetEmacs.swift`: `emacsBindings`; `PresetMac.swift`: `macBindings`; `PresetDoom.swift`: `doomBindings` and `doomToml`. The enum, `common`, `speedCommands` and `speedBindings(mode:)` stay. Static string constants move as `extension KeymapPreset { static let emacsBindings = """…""" }`.
- [ ] Keymap tests, commit "Split Presets.swift".

### Task 6: `Sources/OrgCore/Keymap/Vim.swift` (1,353 lines)

- [ ] `VimParser.swift`: `Parsing`; `VimMotions.swift`: `Motions` and `Text objects`; `VimApply.swift`: `Applying` and `Text`. `Vim.swift` keeps the struct, its state and `Feeding keys`. `VimExtras.swift` is the precedent for extensions on `Vim`.
- [ ] Vim tests, commit "Split Vim.swift".

### Task 7: `Sources/Orgstar/AgendaView.swift` (1,278 lines)

- [ ] `AgendaRowView.swift`: `AgendaRowView` and `HabitGraph`. `AgendaView+Toolbar.swift`: `Toolbar`, `Span`, `Filters`. `AgendaView+Actions.swift`: `Commands` and `Clock, refile, archive, bulk`. `AgendaView.swift` keeps `AgendaSpan`, `CalendarAccess`, the view, `Lines`, `Days`, `Items`.
- [ ] Build, open the agenda, run a bulk action, commit "Split AgendaView.swift".

### Task 8: `Sources/OrgCore/Compute/TableFormulas.swift` (1,241 lines)

- [ ] `TableFormulaCommands.swift`: `TableRecalculate`, `TableEvalFormula`, `TableEditField`, the two `BlockEdit` extensions and the `EmacsBuffer` extensions after line 977. `TableFormulas.swift` keeps `RemoteTables` and the evaluator extension (lines 15–910).
- [ ] Table formula tests and the oracle, commit "Split TableFormulas.swift".

### Task 9: `Sources/OrgCore/Commands/OrgList.swift` (1,009 lines)

- [ ] `OrgListIndent.swift`: `Indentation changes` and `Repairs`. The rest stays.
- [ ] List tests and the sort-list oracle, commit "Split OrgList.swift".

### Task 10: Keep it that way

- [ ] `scripts/check-file-sizes.sh`: lists hand-written Swift files over 1,000 lines, exempting the two generated files, exit 1 when any. Note it in `docs/design.md` under Testing, beside `swift test`.
- [ ] Commit "check-file-sizes.sh".
