# Windows and Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** More than one editor window, and a window split into panes, each pane showing any open buffer with its own caret, folds, narrowing and scroll position, so two files (or two places in one file) sit side by side as `C-x 2` / `C-x 3` give in Emacs.

**Architecture:** `OrgEditor` stays the buffer, as it already is (`DocumentBuffer`, the text storage, undo), and gains views: `addView()` makes another `NSTextView` with its own `NSTextLayoutManager` on the editor's `NSTextContentStorage`, and `textView` is the view with focus, the one commands act on. Folds, narrowing, sparse trees, shrunk columns, inline images and evil state stay the editor's: TextKit hides folded text through the content storage's delegate, which every layout manager shares, and in Emacs these are buffer-local too. `DocumentSession` keeps one `Entry` per open file but no longer has a single "current" buffer: each `EditorPane` (new, `OrgApp`) shows one path, and a `WindowModel` per main window holds a `PaneLayout` tree of panes and the focused one. The session forwards its old `path`, `outline`, `isDirty`, `conflict`, `revealRequest` and `editVersion` to the focused pane so the agenda, capture, menus and palette keep working unchanged.

**Tech Stack:** TextKit 2 (several `NSTextLayoutManager`s on one `NSTextContentStorage`), SwiftUI `WindowGroup`, Swift Testing.

**Spec:** `docs/design.md`, Commands ▸ Document session ("Each window or split has its own selection, fold state and narrowing, mapped through every edit").

## Global constraints

- The buffer is the file: one text storage, one undo stack and one revision per open file, however many views show it.
- Byte fidelity and the save path are untouched; only who owns the storage changes.
- The iOS editor (`MobileEditor`) is not restructured by this plan; iPad multi-window is a later piece.
- Mac preset shortcuts for the new commands are checked against the existing Mac bindings in `Presets.swift` before being chosen, and must not take system shortcuts.

## Decisions

| Question | Decision | Reason |
| --- | --- | --- |
| Pane layout | A binary tree: `.pane(id)` or `.split(axis, first, second, fraction)` | `C-x 2` after `C-x 3` must work; one direction per window would refuse it |
| Buffers per pane | Each pane keeps its own ordered list of buffers it has shown, as its tab bar | Matches editor groups users know; `C-x b` switches in the focused pane as in Emacs |
| Killing a buffer | Removed from every pane; a pane showing it falls back to its previous buffer, else empty | Emacs behaviour |
| Folds, narrowing, sparse trees | Per buffer | Folded text is hidden through the content storage's delegate, shared by every layout manager; Emacs keeps visibility and narrowing buffer-local as well |
| Shrunk table columns, inline-image toggle, markup toggle, evil state, mark | Per buffer | They are buffer-local in Org and evil |
| Caret, selection, scroll position, focus | Per view | What a window owns in Emacs |
| Undo | One `UndoManager` per buffer, returned from every view's `undoManager(for:)` | `C-/` in either view undoes the last edit to the file |
| Quick Open, search field, palette, conflict sheet | Per window (moved from `AppCommands` to `WindowModel`) | Global booleans would present them in every window at once |
| Jump requests (agenda, capture, backlinks) | Go to the key main window's focused pane; open a main window if none | Where the user is looking |
| Sidebar | Per window; its file selection follows the window's focused pane | Nothing shared to keep in step |

## Review focus

- A fold set from one view must hide the same text in the other view, and each view's caret must leave text that a fold from the other view hid.
- Undo from view B of an edit typed in view A: the storage reverts, both views restyle, A's caret lands where the edit was.
- Closing the last main window with dirty buffers: the buffers stay open in the session, and a new window shows them again; the dock-quit path still asks to save.
- Killing a buffer shown in two panes of two windows: both panes fall back, neither crashes on a stale editor.
- A command run from the palette or a menu must act on the focused pane's editor, not whichever editor was created last.

---

### Task 0: Spike: two text views on one content storage

**Files:**
- Create: `Sources/OrgstarSpike/TwoViews.swift` (throwaway, under the existing spike target)

- [ ] One `NSTextContentStorage`, two `NSTextLayoutManager`s each with an `NSTextContainer` and an `NSTextView(frame:textContainer:)`, in one window side by side. A shared `UndoManager` returned by both views' delegate `undoManager(for:)`.
- [ ] Check and write the findings at the top of the file: typing in A shows in B; undo from B reverts A's typing; each layout manager's delegate can return a different `NSTextLayoutFragment` for the same element (fold shown in A only); rendering attributes set on one layout manager do not appear in the other; IME composition in A does not disturb B's selection; selection in B survives an insertion before it in A.
- [ ] If any check fails, stop and amend this plan before Task 1: the fallback is per-view `NSTextStorage`s kept in step by replaying edits, which is a different Task 1.
- [ ] Commit "Spike: two text views on one content storage".

### Task 1: Several text views on one editor (done)

**Files:**
- Modify: `Sources/OrgEditorAppKit/OrgEditor.swift`, `Keys.swift`, `OrgEditor+Folding.swift`, `OrgEditor+Images.swift`, `OrgEditor+Shrink.swift`, `Modal.swift`, `ViewToggles.swift`
- Test: `Tests/OrgEditorAppKitTests/MultiViewTests.swift`, `TwoViewsSpikeTests.swift` (Task 0)

**Interfaces:**
- Produces:

```swift
extension OrgEditor {
    public var textView: NSTextView { get }              // the view with focus, or the last to have had it
    public private(set) var textViews: [NSTextView]      // the first made with the editor
    public let undoManager: UndoManager                  // shared by every view
    public func addView(frame: NSRect = ...) -> NSTextView
    public func removeView(_ view: NSTextView)           // never the first
    public func makeScrollView(for view: NSTextView? = nil) -> NSScrollView
}
```

- [x] Tests: typing in one view shows in the other and in the document; undo is shared; folds are the editor's; commands act on the focused view; a disk change maps every view's caret; removing a view detaches its layout manager.
- [x] `active` follows first responder, key presses and clicks; layout invalidation, theme, line numbers, spell checking and the block cursor apply to every view; a disk change maps every view's selection; `textViewDidChangeSelection` ignores other views' carets.
- [x] Commit "One editor, several text views".

### Task 2: `EditorPane` and the session

**Files:**
- Create: `Sources/OrgApp/EditorPane.swift`, `Sources/OrgApp/PaneLayout.swift`
- Modify: `Sources/OrgApp/DocumentSession.swift`
- Test: `Tests/OrgAppTests/PaneLayoutTests.swift`, `Tests/OrgAppTests/EditorPaneTests.swift`

**Interfaces:**
- Produces:

```swift
public struct PaneID: Hashable, Sendable { }
public indirect enum PaneLayout: Equatable, Sendable {
    case pane(PaneID)
    case split(axis: Axis, first: PaneLayout, second: PaneLayout, fraction: Double)   // Axis: .horizontal (side by side) / .vertical
    public func splitting(_ id: PaneID, axis: Axis, new: PaneID) -> PaneLayout       // new pane after `id`, fraction 0.5
    public func removing(_ id: PaneID) -> PaneLayout?                                  // nil when it was the only pane
    public func only(_ id: PaneID) -> PaneLayout
    public var panes: [PaneID]                                                          // in reading order
    public func next(after id: PaneID) -> PaneID                                        // wraps
}

@MainActor @Observable public final class EditorPane: Identifiable {
    public let id: PaneID
    public private(set) var path: String?
    public private(set) var shown: [String]          // buffers this pane has shown, tab order
    public private(set) var outline: [OutlineEntry]
    public private(set) var editVersion: Int
    public private(set) var revealRequest: (offset: Int, id: Int)?
    public var isDirty: Bool { get }                 // from the session's entry
    public var conflict: String? { get }
    public var document: DocumentState? { get }
}
```

- `DocumentSession` gains `panes: [PaneID: EditorPane]`, `focused: EditorPane?`, `makePane() -> EditorPane`, `closePane(_:)`, `open(_ path: String, in pane: EditorPane)`, `show(_ path:, in:)`, `reveal(_ offset:, in:)`; `kill(path)` updates every pane. The old `path`, `outline`, `isDirty`, `conflict`, `revealRequest`, `editVersion`, `document`, `bufferChanged()` forward to `focused` with a doc comment saying so.

- [ ] Write the failing `PaneLayout` tests: split right then split below the second pane gives three panes in reading order; removing the middle one leaves a two-pane split with the remaining fraction; `only` collapses; `next` wraps; removing the only pane returns nil.
- [ ] Implement `PaneLayout`; run the tests.
- [ ] Write the failing `EditorPane` tests with a `DocumentSession` over an in-memory `FileSystem` (as `DocumentSessionTests` do): opening a path in pane A then showing it in pane B leaves one `Entry`; killing it empties both panes' `path` and `shown`; a pane's `shown` keeps order and drops killed paths; `reveal(_:in:)` bumps only that pane's request; `dirtyPaths` counts a buffer once however many panes show it.
- [ ] Implement `EditorPane` and the session changes: `Entry` keeps its `buffer` (the `OrgEditor`, attached once per path; `attach` becomes `attach(_ buffer:, for path:)`), `current` is replaced by `focused`, `history` moves into each pane. `bufferChanged(path)` refreshes every pane showing that path (outline per pane, since a pane's outline is the buffer's; compute once and assign to each).
- [ ] Run the whole suite. `AppTests` that read `session.path` keep passing through the forwarders.
- [ ] Commit "Editor panes and pane layout in the session".

### Task 3: Panes in the main window

**Files:**
- Create: `Sources/Orgstar/PaneView.swift` (one pane: `BufferTabs` + `EditorView` for that pane), `Sources/Orgstar/PaneLayoutView.swift` (recursive `HSplitView`/`VSplitView` over `PaneLayout`, using `PaneDivider` for the fraction), `Sources/Orgstar/WindowModel.swift`
- Modify: `Sources/Orgstar/EditorView.swift` (takes an `EditorPane`; one `OrgEditor` per path, shared by panes, and one text view per (pane, path) from `addView`), `Sources/Orgstar/ContentView.swift`, `Sources/Orgstar/BufferTabs.swift`, `Sources/Orgstar/OrgstarApp.swift`

**Interfaces:**

```swift
@MainActor @Observable final class WindowModel {
    let id = UUID()
    var layout: PaneLayout
    var focused: PaneID
    var showingQuickOpen = false, focusSearch = false, showingPalette = false, showingConflict = false
}
```

`AppCommands` keeps `editor` (the focused view) and gains `keyWindow: WindowModel?`, set from `NSWindow.didBecomeKeyNotification` by the window's root view; its four presentation booleans move to `WindowModel` and every menu action that set them goes through `keyWindow`.

- [ ] `WindowGroup("orgstar", id: "main")` replaces `Window("orgstar", id: "main")`; the root view creates its `WindowModel` and one pane (`session.makePane()`) in `onAppear`, registers the model with `commands`, and on disappear closes its panes (`session.closePane`) so their text views are removed (`editor.removeView`). Buffers stay in the session.
- [ ] `EditorView` keeps one `OrgEditor` per path and one text view per `(pane.id, path)` from `addView`, removed with `removeView` when the pane closes; a text view becoming first responder sets `commands.editor` and `session.focused = pane` (an `onFocus` callback on `OrgEditor`, from `becomeFirstResponder` on `OrgTextView` in `Sources/OrgEditorAppKit/Keys.swift`).
- [ ] Outline column and sidebar selection follow `session.focused`.
- [ ] Jump requests (`AppCommands.jumpRequest`) are handled by the key window's root view only: `commands.keyWindow === model`. With no main window open, `openWindow(id: "main")` first, then the request is delivered on the new window's first `onAppear`.
- [ ] Commands, as `app.*` ids dispatched where `app.quick-open` is today: `app.split-below`, `app.split-right`, `app.pane-close`, `app.pane-only`, `app.pane-next`, `app.window-new`. Menu: File ▸ New Window; View ▸ Split Below, Split Right, Close Pane, Close Other Panes, Next Pane. Emacs preset: `C-x 2`, `C-x 3`, `C-x 0`, `C-x 1`, `C-x o`, `C-x 5 2`. Doom: `SPC w s`, `SPC w v`, `SPC w d`, `SPC w o`, `SPC w w`, and `C-w s/v/c/o/w` in normal state. Mac: shortcuts chosen after checking `macBindings`; proposal ⌥⌘N, ⌥⌘-, ⌥⌘\, ⌃⌘W, ⌃⌘1, ⌃⌘`.
- [ ] Manual: a "Windows and panes" section in `docs/manual/guide/02-the-editor.org` and the keys in `03-keys.org`'s reference table.
- [ ] Check by hand against the review focus list; the `ORGSTAR_SNAPSHOT` hook in `DevelopmentHooks.swift` gets a two-pane snapshot.
- [ ] Commit "Windows and panes".
