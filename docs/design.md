# Orgstar Design Doc

Oct 4, 2026

## Summary

A native macOS app, with iOS to follow, that edits a folder of org files directly and can replace Emacs for someone who only uses org-mode. The buffer is the file: the app is a text editor with an org-aware syntax tree, rendering drawn over the text, and views (agenda, table recalculation, export) that write back minimal edits.

**Goals**

- Cover the org features used daily: cycling, TODO/priority/tags, planning and timestamps, tables with formulas, source blocks with execution, `M-q` fill, agenda, export.
- Byte-for-byte fidelity: text the user did not edit never changes, so Emacs, beorg and Syncthing can work on the same files.
- macOS first. Every core decision keeps an iOS port possible without a rewrite.

**Non-goals for v1**

- Emacs features unrelated to org (an elisp runtime, packages, other major modes).
- Block-based storage, or a database as the source of truth.
- Mac App Store distribution.
- Babel execution on iOS.
- Native Calc symbolic math in table formulas.
- Sync providers other than Syncthing and iCloud Drive.

## Decisions

| Area | Decision | Reason |
| --- | --- | --- |
| Editing model | Text editor; the buffer is the file. Rendering and views sit on top. | Fill, table alignment and fidelity need plain text. Block editors can't round-trip. |
| Platforms | macOS v1. iOS after the Mac app is mature. | One platform at a time; core stays portable. |
| Distribution | Direct download (notarized, Sparkle) and Homebrew cask. No sandbox. | Babel needs to spawn interpreters. |
| Language | Swift throughout. Core in a separate package with no AppKit/UIKit imports. | TextKit uses UTF-16 offsets natively; no FFI layer; direct path to iOS. |
| Parser | New lossless parser (`OrgCore`) with source ranges. Port inline rules from OrgSwift. | OrgSwift and orgo are export parsers: no positions, drop drawers/comments, flat headings. |
| Key bindings | Command registry; keymaps as data. Presets: Emacs (default), Mac, Doom. | One registry serves keys, palette, menus and iOS. Doom needs a modal engine, so it ships last. |
| Babel | Execute `sh`/`bash`/`shell` and `python` with real header args; generic interpreter runner; `emacs-lisp` via `emacs --batch`. Tree-sitter highlighting for ~20 languages. iOS execution: maybe. | Covers the most-used languages; generic runner adds ruby, node, R, sqlite3, awk cheaply. |
| Table formulas | Native evaluator for the common subset; `emacs --batch` fallback for the rest. | Runs on iOS; Calc can't be reproduced exactly. |
| Storage | Plain folders: Syncthing-synced and iCloud Drive. SQLite index is a rebuildable cache. | Files stay the source of truth. |

## Architecture

Three layers: a thin app shell per platform, a platform layer for system services, and `OrgCore`, which holds all org logic and is shared unchanged by both apps.

Diagram (described in text):

- macOS app (v1, AppKit shell, menus) and iOS app (later, UIKit shell, touch input) both sit on the platform layer.
- Platform layer (AppKit or UIKit): Editor view (TextKit 2, rendering over text), Notifications (scheduled from agenda queries), Processes (Babel runs and `emacs --batch`, talks to external interpreters: sh, python, emacs), Files (bookmarks, watching, saving; reads/writes the org folders on Syncthing and iCloud, which are the source of truth).
- The platform layer calls into OrgCore (commands, tree queries).
- OrgCore (Swift package, no UI imports): Parser (lossless tree, UTF-16 ranges), Commands (pure functions, minimal edits), Agenda (index queries, saved views), Compute (TBLFM evaluator, Babel headers). OrgCore writes to OrgIndex (SQLite + FTS5, rebuildable cache).
- Keymaps (TOML; Emacs, Mac, Doom) resolve keys to OrgCore commands.

**Packages**

- `OrgCore`: parser, syntax tree, semantic layer, commands, agenda queries, table formula evaluator, Babel header parsing and results writing. Foundation only.
- `OrgIndex`: GRDB schema, indexing and queries. Foundation only.
- `OrgPlatform`: TextKit 2 editor view, file access and watching, process runner, notifications. Separate macOS and iOS implementations behind shared protocols.
- `OrgSwift` (existing): HTML and SwiftUI rendering. Orgstar doesn't use it: HTML export is `OrgCore`'s own (`HTMLExport`), checked against orgo's conformance cases.
- App target: windows, sidebar, menus, settings, keymap loading.

## OrgCore data model

`OrgCore` parses a file into a lossless syntax tree: concatenating its tokens reproduces the file exactly, and every node knows its range in UTF-16 code units, the unit `NSTextStorage` uses.

**Tree structure**

- Two layers, as in rust-analyzer's rowan: immutable *green* nodes store kind and length and can be shared between versions; *red* nodes are created on demand with absolute offsets and parent links.
- Whitespace, blank lines and newlines are tokens in the tree, not discarded.
- Anything the parser doesn't recognize becomes a `Raw` node that keeps its text, so unknown syntax survives every edit.

**Bytes and encoding**

The tree holds text, so byte fidelity needs its own contract.

- Supported: UTF-8, with or without a BOM. Anything else (invalid UTF-8, UTF-16, legacy encodings) opens read-only with a notice; it is never converted on save.
- Each document keeps its original bytes plus metadata: BOM present, line-ending style per line (LF, CRLF, mixed), trailing newline present.
- Line endings stay as tokens in the tree; nothing normalizes CRLF.
- Saving writes untouched byte spans from the original buffer and encodes only edited spans. A UTF-16 edit maps to a byte range through a per-line offset table.
- Fixtures: BOM, CRLF, mixed endings, no trailing newline, non-BMP characters, combining sequences, tabs, invalid UTF-8.

**Node kinds**

- Containers: `Document`, `Section` (heading line, its content, child sections).
- Heading parts: stars, TODO keyword, priority cookie, title objects, tags.
- Heading metadata: `Planning` (SCHEDULED/DEADLINE/CLOSED), `PropertyDrawer`, `Drawer` (incl. LOGBOOK), `Clock`.
- Elements: `Paragraph`, `PlainList`/`Item` (with checkbox and description term), `Table`/`TableRow`/`TableFormula`, blocks (src, example, quote, center, verse, export, special, dynamic), `Keyword`, `AffiliatedKeyword` (`#+NAME`, `#+CAPTION`, `#+RESULTS`), `Comment`, `FixedWidth`, `HorizontalRule`, `FootnoteDefinition`.
- Objects: emphasis, link, timestamp (with repeater and warning cookies), footnote reference, entity, inline src block, macro, statistics cookie, LaTeX fragment, target.

**Parse settings**

Some in-buffer settings change how text parses.

- Syntax-affecting: `#+TODO`/`#+SEQ_TODO`/`#+TYP_TODO`, `#+PRIORITIES`. Semantic only: `#+FILETAGS`, `#+STARTUP`, `#+PROPERTY`.
- The settings pass is element-aware: a `#+TODO` line inside a src, example or export block is not a setting.
- TODO precedence follows org: any file-level TODO line replaces the app default sequences for that file; several lines define several sequences; `|` separates active from done states; fast-select keys and logging suffixes (`TODO(t!)`) are parsed and kept.
- An edit that adds, removes or changes a syntax-affecting line triggers a full reparse. A semantic-only change invalidates the semantic layer and the file's index rows, not the tree.

**Incremental reparse**

1. Compute the damaged range from both the old and the new text: the edited lines plus one line on each side.
2. Classify the damaged lines in both versions (heading, block or drawer delimiter, list item, footnote definition, keyword, table row, plain). If any class differs between old and new, the edit changed structure.
3. No structural change: reparse the enclosing element and reuse everything else.
4. Structural change: reparse forward from the start of the enclosing section until the new tree and the old tree agree on a section boundary at the same shifted offset (a synchronization point), then reuse the old tree from there.
5. Content before the first heading is a zeroth section, so every offset has an enclosing section.
6. When the classifier is unsure, or no synchronization point is found, reparse the whole file.

A differential test asserts that the incremental result always equals a full parse, with edits that create and delete delimiters, join lines, remove indentation, add list tabs and change keyword lines. Latency targets are in Phases.

**Semantic layer**

Typed views over the tree, computed and cached per tree version: `HeadingInfo` (todo, priority, tags with inheritance, properties with inheritance, planning, clocks, ID), `TableModel` (cells, column widths, formulas), `SrcBlockInfo` (language, header args merged from `#+PROPERTY`, property drawers and the block line). Commands and the index read these, never raw text.

Inheritance is not one rule, so the semantic layer stores local values and resolved values separately, and each consumer picks a policy:

- Tags: inherited by default, minus an exclusion list (`org-tags-exclude-from-inheritance`); `#+FILETAGS` apply to the whole file.
- Properties: not inherited for search by default; opt-in per property (`org-use-property-inheritance`). Special properties (`ID`, `CATEGORY`, `ARCHIVE`, `COLUMNS`) have their own rules; `ID` is never inherited.
- Babel header args: resolved from `#+PROPERTY: header-args`, language-specific `header-args:lang`, additive `+` forms, heading properties, `#+HEADER:` lines and the block line, in org's order.
- Every resolved value records where it came from, so the UI can show it and tests can check it.

**From OrgSwift**

Port the inline rules: emphasis border characters (matched to orgo), link forms, timestamp parsing and ranges. OrgSwift itself stays the HTML/SwiftUI renderer; later it can render from the `OrgCore` tree so there is one parser.

## Commands and keymaps

Every feature is a named command, implemented as a pure function in `OrgCore`. Keys, menus, the command palette and (later) iOS touch controls all invoke the same commands.

**Command shape**

```swift
protocol OrgCommand {
    static var id: String { get }          // "org.todo.cycle"
    static var title: String { get }       // shown in the palette
    func applies(in ctx: EditContext) -> Bool
    func run(in ctx: EditContext) throws -> CommandStep
}

struct EditContext {
    let document: DocumentID
    let revision: Int                       // the revision the command read
    let text: String
    let tree: OrgTree
    let selection: [Range<Int>]
    let settings: OrgSettings
    let now: Date                           // injected; commands never read the clock
    let calendar: Calendar                  // includes time zone
    let answers: [String: String]           // replies to earlier prompts
}

enum CommandStep {
    case commit(EditResult)
    case prompt(Prompt)                     // ask, then rerun with the answer in `answers`
}

struct EditResult { var baseRevision: Int; var edits: [TextEdit]; var selection: [Range<Int>]?; var effects: [Effect] }
struct TextEdit   { let range: Range<Int>; let replacement: String }   // UTF-16, against baseRevision, non-overlapping
```

- `edits` are minimal replacements, applied as one undo group.
- `effects` cover anything that isn't a text change: run a src block, open the agenda, show a message, fold a subtree. The platform layer performs them.
- Context dispatch works like org's TAB: one key can bind several commands, and the first whose `applies` returns true runs (cycle on a heading, next cell in a table, indent in a list).

**Revisions, time and prompts**

- Every edit result names the revision it was computed against. The document session applies it only if that is still the current revision; otherwise the command reruns on the new state.
- Prompts (a note when logging a state change, a date for SCHEDULED) use the prepare/prompt/commit loop above. Cancelling at any prompt produces no edit.
- Repeaters, `LOGBOOK` notes and `CLOSED` stamps use the injected `now` and `calendar`, so tests are deterministic.
- Asynchronous effects (a Babel run) carry the revision and the target element's identity. On completion they re-find the target in the current tree (by `#+NAME`, or by the block's position relative to its neighbours) and are rejected with a message if it is gone or ambiguous. Result insertion is its own undo step.

**Document session**

One session per open file owns the text, original bytes, tree, revision counter, merge base and undo history. Each window or split has its own selection and scroll position; folds, narrowing and sparse trees are the buffer's and show the same in every view, as Emacs keeps them buffer-local. Selections are mapped through every edit. On an external reload or merge, view state is mapped through the diff; folds on headings that no longer exist are dropped.

**Keymap format**

Keymaps are TOML files, user-editable, loaded in layers: preset, then user overrides.

```toml
[[bind]]
keys = "C-c C-t"
command = "org.todo.cycle"

[[bind]]
keys = "TAB"
command = "org.cycle"
when = "heading"

[[bind]]
keys = "SPC m t"
command = "org.todo.cycle"
mode = "normal"        # Doom preset only
```

- Key sequences of any length (`C-c C-x C-i`), with an echo area for the pending prefix and a which-key popup after a short delay.
- `when` names a context predicate; `mode` names a modal state. Both exist in the format from day one even though only Doom uses `mode`.
- An "Option as Meta" setting, per side (left/right), like Terminal and iTerm2.
- `⌘` shortcuts (save, undo, find) stay active in every preset.

**Presets**

| Preset | Default | Needs | Ships |
| --- | --- | --- | --- |
| Emacs | Yes | Prefix-key engine | Phase 2 |
| Mac | No | Menu wiring | Phase 2 |
| Doom | No | Modal engine: normal/insert/visual, operators + motions + text objects, counts, `.` repeat, registers; `SPC` leader; evil-org bindings | After phase 3 |

## Workspace, storage and index

A workspace is one or more root folders. The files are the only source of truth; the SQLite index can be deleted and rebuilt at any time.

**Folders and access**

- The user adds folders through an open panel. Store security-scoped bookmarks even though the Mac app is unsandboxed, because iOS will require them.
- Three scopes, configured separately:
    - Discovery: every `.org` and `.org_archive` file under the roots. Indexed for search and link resolution.
    - Agenda: folders or globs, the equivalent of `org-agenda-files`. Archive files and subtrees tagged `ARCHIVE` are excluded by default.
    - Link resolution: all discovered files, including archives, so `id:` links into archived subtrees still resolve. Duplicate IDs are reported. A link to a file outside the roots opens it but doesn't index it.
- Syncthing conflict copies are discovered but excluded from agenda, search and ID resolution; they appear only in the conflict UI.

**Watching for external changes**

- FSEvents (macOS) and `NSFilePresenter` are hints that something changed, not a complete log.
- On launch, and whenever FSEvents reports dropped events, a root change, or must-scan-subdirs, rescan the affected tree and reconcile the index: compare path, size, mtime and hash; detect renames by hash; delete rows for missing files. Reconciliation runs in one transaction per root.
- Roots are identified by bookmark, not path, so a moved root is followed or reported.
- iOS (later): `NSFilePresenter` plus `NSMetadataQuery` for iCloud.
- Ignore Syncthing temp files (`.syncthing.*.tmp`). Show Syncthing conflict files (`*.sync-conflict-*`) with a diff against the original.
- iCloud placeholders: a file not yet downloaded (a dataless file since macOS 14, or `.name.icloud`) is requested with `startDownloadingUbiquitousItem`, shown as downloading, and indexed when it arrives. An evicted file keeps its index rows.

**Saving**

- Save mode is a user setting: autosave after an idle delay, or explicit save only.
- Save sequence, inside a coordinated write:
    1. Read the current disk bytes and hash.
    2. If the hash equals the merge base, write. Otherwise three-way merge (base = merge base, ours = buffer, theirs = disk). On conflict, stop and show the conflict; write nothing.
    3. Write to a temp file in the same folder and replace atomically.
    4. Read back the hash; it becomes the new merge base.
- Emacs and Syncthing don't use `NSFileCoordinator`, so another writer can still replace the file between steps 1 and 3. We can't fully prevent that; we narrow the window and detect it: after the write, if FSEvents reports a change whose hash is neither ours nor the base, treat it as a new external edit and merge again.
- Before any write that replaces a version we didn't produce, keep a copy of both versions in a recovery folder (last 20 per file) so nothing is lost.
- An unedited open file reloads silently on external change, keeping cursor and folds. An edited one merges automatically when the merge is clean, and shows the conflict otherwise.
- Fault-injection tests replace the file at each step of the sequence.

**Index schema (GRDB, SQLite + FTS5)**

| Table | Columns |
| --- | --- |
| `files` | id, root, path, size, mtime, hash, parsed_at |
| `headings` | id, file_id, parent_id, start, end, level, todo, priority, title, outline_path, org_id |
| `tags` | heading_id, tag, inherited |
| `properties` | heading_id, key, value, inherited |
| `timestamps` | heading_id, kind (scheduled, deadline, closed, active, inactive), start, end, repeater, warning |
| `clocks` | heading_id, start, end, minutes |
| `links` | heading_id, type, target |
| `headings_fts` | FTS5 over title and body text |

- A file is reindexed when its disk hash changes, and when an app setting that changes semantics (TODO defaults, inheritance policies) changes. Index rows record the settings version they were built with.
- Open documents with unsaved edits overlay the index: their rows are computed in memory from the session's tree and replace that file's disk rows in every query. Agenda and search therefore reflect unsaved TODO, tag and planning edits in explicit-save mode.
- Index rows store positions with the revision they came from. Jumping to a heading checks the target session's revision and re-finds the heading by ID or outline path if the positions are stale.
- Every query the UI runs (agenda, tag search, TODO list, saved views) is a query over the index plus the overlay.

## Babel and table formulas

Both live in `OrgCore` as parsing and planning logic; only the process launch is platform code. Results are written back as a minimal edit to `#+RESULTS:`.

**Babel execution (macOS)**

- Execution plan first: resolve all header args, then check them before launching anything. `:eval never`/`no` blocks execution; `:eval query` always asks. Any header that changes what runs and isn't supported yet (`:session`, `:noweb yes`, `:prologue`, `:epilogue`, `:file`) stops execution with a message naming it, rather than running different code.
- Runner: write the expanded body to a temp file, launch the interpreter with `Process` in `:dir` (default: the file's folder), capture stdout and stderr, support timeout and cancel.
- Each language has an adapter for `:var` serialization (scalars, lists, tables) and for `:results value` (python wraps the body in a function, as org does; shells take the last output). Interpreter invocation alone doesn't provide org semantics.
- Never execute on open or on export without confirmation. Confirm per block, with a per-file trust setting, like `org-confirm-babel-evaluate`. Trust is keyed to the block's content hash, so an external edit that changes the code asks again.

| Language | Runner | Header args in v1 |
| --- | --- | --- |
| `sh`, `bash`, `shell` | Native | `:results`, `:var`, `:dir`, `:cmd`, `:exports` |
| `python` | Native; `:results value` wraps the body in a function, as org does | Same |
| `ruby`, `js`, `R`, `sqlite`, `awk` | Generic: configured command per language (`ruby`, `node`, `Rscript`, `sqlite3`, `awk`) | `:results output`, `:dir`, `:cmd` |
| `emacs-lisp`, `elisp` | `emacs --batch` if Emacs is installed | `:results` |

- `:results` handling in v1: `output`/`value`, `verbatim`/`table`/`list`/`raw`/`drawer`, `replace`/`append`/`silent`.
- Result ownership, matched to org: the results element is the `#+RESULTS:` keyword plus exactly one element after it (fixed-width lines, a table, a list, an example block, or a `:RESULTS:` drawer). `replace` swaps that element; `append` adds after it; `silent` writes nothing. `raw` output has no boundary, so `raw` without `drawer` refuses to replace existing results and asks first. Changing the format replaces the old element by its old format's boundary.
- Results are re-found on completion as described in Commands; affiliated keywords (`#+NAME`, `#+CAPTION`) on the results stay.
- Tests run the same block repeatedly and switch formats between runs.
- Later: `:session`, `:file` with inline images (dot, plantuml, mermaid), `:noweb`, `:tangle`.
- Highlighting: tree-sitter (SwiftTreeSitter) grammars for about 20 languages: shells, emacs-lisp, python, C, R, js, java, lisp, scheme, clojure, haskell, rust, go, sql, ruby, org, latex, dot, plantuml, mermaid.

**Table formula evaluator**

The native evaluator handles a defined numeric domain. A table that uses anything outside it is recalculated through Emacs.

- **Native domain:** integers within ±2^53 and decimals with at most 15 significant digits, using Decimal. Results within the domain must match Calc's output byte for byte; an input or intermediate outside it (overflow, cancellation flagged by precision loss, unsupported mode flags) routes the whole table to Emacs.
- **Emacs fallback:** run `emacs -Q --batch` on a snapshot of the whole file (so `#+CONSTANTS`, properties, named tables for `remote()` and file-local settings are present) in the file's own folder. Put point in the table, select the chosen `#+TBLFM` line, and call `(org-table-recalculate 'all)`; without that argument it recalculates only the current row. Splice back only the table's text.
- **Execution authorization:** Lisp formulas (`'(...)`) and anything that evaluates Lisp run arbitrary code, so they need the same confirmation and content-hash trust as Babel. The fallback disables file-local variable evaluation (`enable-local-variables` set to `:safe`).

| Area | Native | Notes |
| --- | --- | --- |
| Arithmetic, `^`, parentheses | Yes | |
| References: `$N`, `@N`, `@N$M`, `@<`, `@>`, `@I`/`@II`, `$#`, `@#`, relative `@-1` | Yes | |
| Ranges: `$1..$3`, `@2$1..@>$1` | Yes | |
| `vsum`, `vmean`, `vmax`, `vmin`, `vcount`, `vmedian` | Yes | |
| `sqrt`, `exp`, `ln`, `log10`, trig | Yes | |
| Column vs field formulas, field takes precedence | Yes | |
| Several `#+TBLFM:` lines, chosen by cursor line | Yes | |
| Format flags `;%.Nf`, `;N`, `;E` | Yes | |
| Calc display format (e.g. `1.4142136`) | Yes, matched | Must be tested against Emacs output byte for byte. |
| Precision | Bounded | Native within the defined domain only; outside it, Emacs. |
| Dates and durations (`;T`, `;t`, `HH:MM`, timestamp subtraction) | Later | Separate piece of work. |
| `remote(name, ref)` | Later | |
| Calc symbolic math: `taylor`, `deriv`, `integ`, `solve` | No | Emacs fallback. |
| Lisp formulas `'(...)` | No | Emacs fallback. |
| Calc units, vectors/matrices beyond `v*` | No | Emacs fallback. |
| Iterate to convergence (`C-u C-u C-c C-c`) | No | Emacs fallback. |

On iOS, tables that need Emacs keep their last computed values and show a "recalculate on Mac" marker.

## Testing

Fidelity is checked against Emacs itself, using the same oracle pattern as orgo's `tests/oracle.rs`.

| Layer | Test | Corpus |
| --- | --- | --- |
| Parser | Round trip: tree text equals file bytes | Your org files, org-conformance cases, org manual examples |
| Parser | Incremental equals full: random edits, then compare incremental tree with a fresh parse | Same, plus fuzzed edits |
| Parser | Conformance: HTML skeleton from an `OrgCore`-based renderer matches the goldens | org-conformance |
| Commands | Oracle: same file, cursor and command in `emacs --batch`; diff resulting bytes | Generated cases per command |
| Table formulas | Oracle: `org-table-recalculate` output vs native, byte for byte | Tables from your files plus a generated set |
| Babel | Results block text vs Emacs for the same block and header args | sh and python cases |
| Performance | Parse, reparse and restyle times on the largest real files | Your largest files, plus synthetic 10x copies |

- Command oracle mapping examples: `org.todo.cycle` → `org-todo`, `org.heading.demote` → `org-metaright`, `org.fill` → `org-fill-paragraph`, `org.table.align` → `org-table-align`.
- The command oracle is stateful. Each case fixes: file, point and mark (converted from UTF-16 offsets to Emacs character positions), prefix argument, active region, the org settings that matter (`org-todo-keywords`, `org-log-done`, `fill-column`, `tab-width`, `indent-tabs-mode`), frozen time via a stubbed `current-time`, locale and time zone, and scripted answers to prompts. Emacs runs with `-Q` plus that explicit configuration.
- Oracle comparisons cover resulting bytes, resulting point and mark, and the text after one undo.
- Pin Emacs 31.1 and Org 9.8.7, recorded in the repo. CI requires the pinned Emacs; a missing oracle fails the job instead of skipping.
- Encoding fixtures (BOM, CRLF, mixed endings, invalid UTF-8, non-BMP, combining characters) are public, in the repo.
- Save fault-injection tests replace the file on disk at each step of the save sequence.
- Personal org files are a second, private corpus run locally; phase gates use the public corpus.
- `scripts/check-file-sizes.sh` fails when a hand-written Swift file is over 1,000 lines; run it beside `swift test`. The generated `CharFold.swift` and `Queries.swift` are exempt.

## Phases

Seven phases, each usable on its own. Phase 1 is read-only, so it can run next to Emacs from the first build.

Status, 2026-10-10: phases 1–7 are built. The Mac app is released as v0.2.0 (universal, notarized DMG, Homebrew cask). The iOS app is complete for Simulator builds; device signing and TestFlight are not set up. Owed: the phase-1 gate run on the M1 Air, and the VoiceOver check on both platforms. The gates pass on an M-series Mac except peak memory for small real files (about 20x for a 161 kB file, from fixed overhead).

1. **Core and viewer:** `OrgCore` parser, workspace, index, read-only rendering, folding, search.
2. **Editor:** text editing, structure and heading commands, timestamps, `M-q`, table alignment, command palette, Emacs and Mac keymaps, remaining tree-sitter grammars.
3. **Agenda:** day/week views, tag and TODO search, saved custom views, notifications from SCHEDULED/DEADLINE.
4. **Computation:** native table formulas with Emacs fallback, Babel execution and results.
5. **Export and capture:** native HTML and Markdown export, pandoc or Emacs for the rest, capture templates, global capture hotkey.
6. **Beyond Emacs:** clock reports, habit charts, table and kanban views over properties, Doom keymap.
7. **iOS:** same core; touch input, capture and agenda first.

Plans in `docs/plans/` are ticked when their commits land, and a step that did not ship is marked in the plan. Open work is in the repository's issues.

**Phase 1 scope**

- [x] `OrgCore` package: lossless parser with UTF-16 ranges and the bytes-and-encoding contract; element-aware settings pass; inline rules ported from OrgSwift
- [x] Incremental reparse with old/new classification and synchronization points; differential tests
- [x] Document session: original bytes, revisions, merge base, per-view state
- [x] Save path with merge, recovery copies and fault-injection tests (used by the editing spike, not exposed in the viewer)
- [ ] Editable TextKit 2 spike: folding and org-indent display with correct caret movement, selection, IME composition, VoiceOver and copy/paste across folded text (done but the VoiceOver check)
- [x] Workspace: folders, bookmarks, discovery/agenda/link scopes, FSEvents with reconciliation scans, Syncthing temp/conflict handling, iCloud placeholders
- [x] Index: schema, settings version, dirty-buffer overlay, FTS5 search
- [x] Mac app (read-only): sidebar of folders and files, outline of the current file, quick open (`⌘P`), full-text search
- [x] Rendering over the text: heading styles, TODO/priority/tag styling, links, emphasis, tables, src blocks highlighted for org, emacs-lisp, sh and python only (the rest move to phase 2)
- [x] Folding: local and global cycling, `#+STARTUP` visibility
- [ ] Benchmarks recorded for the files listed in the exit gates (recorded on an M-series Mac; the M1 Air run is owed)

**Phase 1 exit gates** (measured on an M1 MacBook Air, 8 GB, the slowest supported reference machine):

| Gate | Target |
| --- | --- |
| Round trip | 100% byte-identical on the public corpus and the private corpus |
| Incremental equals full | 0 mismatches over 100,000 fuzzed edits |
| Open to first render | p95 under 100 ms for a 1 MB file; under 500 ms for a 10 MB file |
| Keystroke to restyled frame (spike) | p95 under 16 ms for a 1 MB file, including one file whose content is a single top-level section and one with a 5,000-row table |
| Peak memory | Under 10x file size for an open typical document (prose, lists, tables); under 45x for worst-case dense markup (the synthetic gate files: a 1 MB single section measures 30x, a 5,000-row table 43x) |
| Index | Full rebuild of 10,000 files under 30 s; reconciliation after restart under 2 s with no changes |
| Save safety | All fault-injection cases end with both versions recoverable |
| Editing spike | Caret, selection, IME, VoiceOver and copy/paste checks pass on folded and indented text |

Phase 2 (writable editor) does not start until every gate passes.

## iOS considerations

| Area | Mac v1 | iOS impact |
| --- | --- | --- |
| Core | `OrgCore`, `OrgIndex` with no AppKit imports | Reused unchanged. CI builds them for iOS from phase 1 to catch accidental AppKit use. |
| Editor view | TextKit 2 in an `NSTextView` wrapper | Shared layout policy (what folds, what is indented, how org markup is styled) in a platform-free module; separate AppKit and UIKit adapters for caret movement, selection, input methods and accessibility across hidden text. The phase 1 editing spike keeps that adapter boundary explicit. |
| Input | Keymaps call commands | Same commands from a keyboard accessory bar, palette and gestures; iPad hardware keyboards use the keymaps. |
| Storage | Bookmarks, FSEvents, `NSFilePresenter` | Bookmarks and `NSFilePresenter` carry over; Syncthing through Möbius Sync's File Provider. |
| Babel | `Process` | Maybe. Results blocks display either way. |
| Table formulas | Native plus Emacs fallback | Native only; Emacs-only tables show a marker. |
| Notifications | Local notifications from the index | iOS caps pending local notifications at 64 and doesn't guarantee background time to refill them. Schedule the next 64 events, reconcile on every launch, foreground and sync, and show in the agenda how far ahead reminders are scheduled. If the app isn't opened, reminders stop after the last scheduled one, and the UI says so. Repeating requests are used only where they match org repeater semantics. |

## Open questions

- [x] App name: orgstar, spelt in lowercase.
- [x] Save model: a user setting (see Saving).
- [x] Minimum OS: macOS 26 and iOS 26. One release behind current (macOS 27).
- [x] License: 0BSD.
- [x] Oracle pins: Emacs 31.1 and Org 9.8.7.
- [x] OrgSwift moves onto `OrgCore`'s tree later, tracked in krz/org-swift#2. Out of scope for now.
