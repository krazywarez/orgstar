# Writable App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Editing on in the Mac app: typing and undo, ⌘S through the merge-safe save path, a save-mode setting (automatic after an idle delay, or explicit), dirty state, external changes merged into edited buffers with a conflict choice, and unsaved text visible to search.

**Architecture:** The editor owns the live `DocumentState`; the session reaches it through a `DocumentBuffer` protocol in `OrgDocument` (`document` plus `update(_:)`, which applies a change made outside typing and refreshes the view). Save, disk change, keep-mine and use-disk are all `update` calls on the buffer, so the editor maps folds and the caret through them the same way. `DocumentSession` keeps a copy of the buffer's state for SwiftUI (dirty flag, outline), runs autosave, and holds conflict state. Before an editor exists, and in tests, a `StateBuffer` holds the state. Search overlays the open file's unsaved text through `WorkspaceModel.overlay`, cached until the text changes.

**Tech Stack:** Swift 6.2 tools, SwiftUI, AppKit, TextKit 2, Swift Testing.

**Spec:** `docs/design.md`, "Saving" and "Index schema" (overlay).

## Global Constraints

- Every write goes through `Saver`; every version a write or a conflict choice displaces goes to the recovery folder (`<data dir>/Recovery`, last 20 per file).
- Files that are not valid UTF-8 stay read-only.
- A conflict never writes; autosave pauses while one is open.
- `OrgApp` imports no AppKit or SwiftUI.

## Defaults chosen (user may change)

- Save mode defaults to automatic, 1 s after the last edit. The delay is fixed.
- Conflicts: an alert with Keep Mine, Use Disk Version, Decide Later. No diff view yet.
- One document per window. Switching files with unsaved edits saves (automatic) or asks Save / Don't Save / Cancel (explicit). Closing the window quits the app, through the same check.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgDocument/Buffer.swift` | `DocumentBuffer`, `StateBuffer` |
| `Sources/OrgDocument/Saving.swift` | `Saver.overwrite(_:to:)` |
| `Sources/OrgEditorAppKit/OrgEditor.swift` | `DocumentBuffer` conformance: `update(_:)` maps folds and caret and clears text-view undo when the text is replaced; `onChange` |
| `Sources/OrgApp/DocumentSession.swift` | Buffer, dirty flag, save, autosave, conflict choices, `SaveMode` |
| `Sources/OrgApp/WorkspaceModel.swift` | `overlay(path:document:)` |
| `Sources/Orgstar/*.swift` | Editable editor, ⌘S, Settings, confirm on switch and quit, conflict alert, edited dot |

---

### Task 1: Buffers

**Files:** `Sources/OrgDocument/Buffer.swift`, `Sources/OrgDocument/Saving.swift`, `Sources/OrgEditorAppKit/OrgEditor.swift`, `Tests/OrgDocumentTests/DocumentStateTests.swift`, `Tests/OrgEditorAppKitTests/EditorTests.swift`

**Produces:**

```swift
@MainActor
public protocol DocumentBuffer: AnyObject {
    var document: DocumentState { get }
    /// Applies a change made outside typing and updates whatever shows the document.
    func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T
}

@MainActor
public final class StateBuffer: DocumentBuffer { public init(_ document: DocumentState) }

extension Saver {
    /// Writes the buffer over whatever is on disk; the replaced version goes to recovery.
    public func overwrite(_ state: inout DocumentState, to url: URL) throws
}

extension OrgEditor: DocumentBuffer   // plus `public var onChange: (() -> Void)?`
```

`OrgEditor.update` records the text and selection, runs the change, and if the text changed: computes `lineEdits(from:to:)`, reloads the storage, maps folds and the selection through the edits, and removes the text view's undo actions (they refer to the old text). `save(using:to:)` and `diskChanged(to:)` become `update` calls; `diskChanged` returns the `ExternalChange`.

- [x] Tests: `overwrite` writes ours and keeps the replaced version; editor `update` replacing text keeps the caret on the same line content, keeps folds, and leaves nothing to undo; typing calls `onChange`.
- [x] Implement; `swift test` green.
- [x] Commit "Add document buffers".

### Task 2: Session saving

**Files:** `Sources/OrgApp/DocumentSession.swift`, `Sources/OrgApp/WorkspaceModel.swift`, `Tests/OrgAppTests/AppTests.swift`

**Produces:**

```swift
public enum SaveMode: String, Sendable, CaseIterable { case automatic, explicit }

extension DocumentSession {
    public init(fileSystem: FileSystem = CoordinatedFileSystem(), recovery: RecoveryStore = FileRecoveryStore(directory: WorkspaceModel.defaultDirectory.appendingPathComponent("Recovery")))
    public var saveMode: SaveMode
    public private(set) var isDirty: Bool
    /// Set while the buffer and the disk conflict; the message says how.
    public private(set) var conflict: String?
    public func attach(_ buffer: DocumentBuffer)
    /// The buffer changed through typing.
    public func bufferChanged()
    /// Saves now. True when nothing is left unsaved.
    @discardableResult public func save() -> Bool
    public func keepMine()
    public func useDiskVersion()
}

extension WorkspaceModel {
    /// Index rows for the open file's unsaved text, keyed by path; empty when it has none.
    public func overlay(path: String?, document: DocumentState?) -> [String: FileRecord]
}
```

`fileChanged` calls `buffer.update { $0.diskChanged(to:) }` and sets `conflict` on a conflict; `diskBytes` goes away. `show(_:)` uses indexed offsets only when the buffer is clean.

- [x] Tests: edit then `save` writes and clears dirty; automatic mode saves after the delay, explicit does not; an external change merges into an edited buffer; a conflicting change sets `conflict`, blocks saving, and `keepMine` writes ours with theirs in recovery while `useDiskVersion` loads theirs with ours in recovery; search with the overlay finds an unsaved heading.
- [x] Implement; `swift test` green.
- [x] Commit "Save from the session".

### Task 3: The app

**Files:** `Sources/Orgstar/*.swift`

- Session moves to app state so the app delegate can check it on quit; closing the last window quits.
- Editor is editable when the file is; it attaches to the session and calls `bufferChanged` on edits; the window shows the edited dot.
- File ▸ Save (⌘S); Settings (⌘,) with the save mode in `@AppStorage("saveMode")`.
- Switching files and quitting with unsaved edits: save in automatic mode, ask in explicit mode; a failed save cancels.
- Conflict alert with the three choices.
- [x] Verify in the built app with a scratch data dir: type, ⌘S, undo, external edit merges, conflicting external edit shows the alert, search finds unsaved text.
- [x] Commit "Edit and save in the app".
