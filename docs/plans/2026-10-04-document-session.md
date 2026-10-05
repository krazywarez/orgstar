# Document Session and Save Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The state of one open file (text, tree, revision, undo, merge base), view state that follows edits, a line-based three-way merge, and a save sequence that never loses a version another writer produced.

**Architecture:** A new `OrgDocument` target on top of `OrgCore`. `DocumentState` is a value type: edits apply against a revision, go through `OrgParser.reparse`, and record their inverse for undo. External changes reload an unedited buffer or merge into an edited one. `Saver` runs the design's save sequence over a `FileSystem` protocol, so tests can inject another writer at every step; `CoordinatedFileSystem` is the real implementation (`NSFileCoordinator`, temp file and `replaceItemAt` with a kept backup), and `FileRecoveryStore` keeps displaced versions. Views map their own `ViewState` through the edits each change returns.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Foundation, CryptoKit (recovery folder names).

**Spec:** `docs/design.md`, "Document session" and "Saving".

## Global Constraints

- Every version displaced by a save ends up on disk, in the buffer, or in recovery.
- Read-only documents (not valid UTF-8) are never written.
- Undo history is cleared by a reload or merge; it can't be mapped through an external change.
- `OrgDocument` builds for iOS: `xcodebuild -scheme OrgDocument -destination 'generic/platform=iOS' build`.

## Out of scope

Per-window session objects and main-actor wiring (they belong to the app target), file watching (workspace plan), and conflict UI.

## File structure

| File | Responsibility |
| --- | --- |
| `Package.swift` | Adds the `OrgDocument` library and `OrgDocumentTests` |
| `Sources/OrgDocument/Merge.swift` | Line diff (Myers), `threeWayMerge`, `lineEdits` |
| `Sources/OrgDocument/DocumentState.swift` | Edits, undo/redo, external changes, write bookkeeping |
| `Sources/OrgDocument/ViewState.swift` | Selection and folds mapped through edits |
| `Sources/OrgDocument/Saving.swift` | `FileSystem`, `RecoveryStore`, `Saver`, outcomes |
| `Sources/OrgDocument/FileStorage.swift` | `CoordinatedFileSystem`, `FileRecoveryStore` |

---

### Task 1: Three-way merge

**Files:**
- Modify: `Package.swift`
- Create: `Sources/OrgDocument/Merge.swift`
- Test: `Tests/OrgDocumentTests/MergeTests.swift`

**Interfaces:**
- Produces: `MergeConflict(base:ours:theirs:)`, `MergeResult` (`.merged`, `.conflict`), `threeWayMerge(base:ours:theirs:)`, `lineEdits(from:to:) -> [TextEdit]`; internal `textLines`, `matchingLines`.

- [ ] **Step 1: Add the target**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"])
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"])
    ]
)
```

- [ ] **Step 2: Write the failing tests**

```swift
import OrgCore
import Testing
@testable import OrgDocument

struct MergeTests {
    @Test func separateChangesMerge() {
        #expect(threeWayMerge(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n") == .merged("A\nb\nC\n"))
    }

    @Test func sameChangeOnBothSidesMergesOnce() {
        #expect(threeWayMerge(base: "a\nb\n", ours: "a\nX\n", theirs: "a\nX\n") == .merged("a\nX\n"))
    }

    @Test func differentChangesConflict() {
        let result = threeWayMerge(base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nY\nc\n")
        #expect(result == .conflict([MergeConflict(base: "b\n", ours: "X\n", theirs: "Y\n")]))
    }

    @Test func insertionsAndDeletions() {
        #expect(threeWayMerge(base: "a\nb\n", ours: "a\nb\nc\n", theirs: "b\n") == .merged("b\nc\n"))
        #expect(threeWayMerge(base: "", ours: "x\n", theirs: "") == .merged("x\n"))
    }

    @Test func lineEndingsSurvive() {
        #expect(threeWayMerge(base: "a\r\nb\r\n", ours: "A\r\nb\r\n", theirs: "a\r\nb\r\nc") == .merged("A\r\nb\r\nc"))
    }

    @Test func lineEditsRebuildTheNewText() {
        let pairs = [("a\nb\nc\n", "a\nx\nc\nd\n"), ("", "x"), ("x", ""), ("a\r\nb", "b\r\na"), ("same\n", "same\n")]
        for (old, new) in pairs {
            var text = old
            for edit in lineEdits(from: old, to: new).reversed() { text = edit.apply(to: text) }
            #expect(text == new)
        }
    }

    @Test func largeFilesWithSmallChanges() {
        let base = (0..<20_000).map { "line \($0)\n" }.joined()
        let ours = base.replacingOccurrences(of: "line 100\n", with: "ours\n")
        let theirs = base.replacingOccurrences(of: "line 19000\n", with: "theirs\n")
        guard case .merged(let merged) = threeWayMerge(base: base, ours: ours, theirs: theirs) else {
            Issue.record("expected a clean merge")
            return
        }
        #expect(merged.contains("ours\n") && merged.contains("theirs\n"))
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter MergeTests`
Expected: build failure, `cannot find 'threeWayMerge' in scope`.

- [ ] **Step 4: Implement**

```swift
import OrgCore

public struct MergeConflict: Sendable, Equatable {
    public let base: String
    public let ours: String
    public let theirs: String
}

public enum MergeResult: Sendable, Equatable {
    case merged(String)
    case conflict([MergeConflict])
}

/// Line-based three-way merge. Lines keep their endings, so CRLF and a missing final newline
/// survive. A region changed on one side takes that side; changed the same way on both, takes
/// it once; changed differently, is a conflict.
public func threeWayMerge(base: String, ours: String, theirs: String) -> MergeResult {
    let baseLines = textLines(base)
    let ourLines = textLines(ours)
    let theirLines = textLines(theirs)
    var ids = LineIDs()
    let baseIDs = ids.encode(baseLines)
    let ourIDs = ids.encode(ourLines)
    let theirIDs = ids.encode(theirLines)

    var toOurs = [Int?](repeating: nil, count: baseLines.count)
    for (b, o) in matchingLines(baseIDs, ourIDs) { toOurs[b] = o }
    var toTheirs = [Int?](repeating: nil, count: baseLines.count)
    for (b, t) in matchingLines(baseIDs, theirIDs) { toTheirs[b] = t }

    var merged: [String] = []
    var conflicts: [MergeConflict] = []
    var nextBase = 0, nextOurs = 0, nextTheirs = 0

    func resolve(_ baseEnd: Int, _ oursEnd: Int, _ theirsEnd: Int) {
        let b = baseLines[nextBase..<baseEnd]
        let o = ourLines[nextOurs..<oursEnd]
        let t = theirLines[nextTheirs..<theirsEnd]
        if o.elementsEqual(b) {
            merged += t
        } else if t.elementsEqual(b) || o.elementsEqual(t) {
            merged += o
        } else {
            conflicts.append(MergeConflict(base: b.joined(), ours: o.joined(), theirs: t.joined()))
        }
    }

    // A base line kept by both sides is a fixed point; everything between fixed points is
    // resolved as one region.
    for k in baseLines.indices {
        guard let o = toOurs[k], let t = toTheirs[k], o >= nextOurs, t >= nextTheirs else { continue }
        resolve(k, o, t)
        merged.append(baseLines[k])
        nextBase = k + 1
        nextOurs = o + 1
        nextTheirs = t + 1
    }
    resolve(baseLines.count, ourLines.count, theirLines.count)
    return conflicts.isEmpty ? .merged(merged.joined()) : .conflict(conflicts)
}

/// Edits, in `old` coordinates and ascending order, that turn `old` into `new` line by line.
public func lineEdits(from old: String, to new: String) -> [TextEdit] {
    let oldLines = textLines(old)
    let newLines = textLines(new)
    var ids = LineIDs()
    let pairs = matchingLines(ids.encode(oldLines), ids.encode(newLines))
    var offsets = [0]
    for line in oldLines { offsets.append(offsets.last! + line.utf16.count) }
    var edits: [TextEdit] = []
    var i = 0, j = 0
    for (pi, pj) in pairs + [(oldLines.count, newLines.count)] {
        if i < pi || j < pj {
            edits.append(TextEdit(range: offsets[i]..<offsets[pi], replacement: newLines[j..<pj].joined()))
        }
        i = pi + 1
        j = pj + 1
    }
    return edits
}

/// Lines with their endings.
func textLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
        current.unicodeScalars.append(scalar)
        if scalar == "\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

struct LineIDs {
    private var ids: [String: Int] = [:]

    mutating func encode(_ lines: [String]) -> [Int] {
        lines.map { line in
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }
    }
}

/// Matched index pairs of a longest common subsequence, ascending. Common prefix and suffix
/// are matched directly; Myers' algorithm handles the middle. When the middle differs by more
/// than the memory budget allows, it is treated as having no matches.
func matchingLines(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }
    var pairs = (0..<prefix).map { ($0, $0) }
    let middleA = Array(a[prefix..<(a.count - suffix)])
    let middleB = Array(b[prefix..<(b.count - suffix)])
    pairs += myers(middleA, middleB).map { ($0.0 + prefix, $0.1 + prefix) }
    pairs += (0..<suffix).map { (a.count - suffix + $0, b.count - suffix + $0) }
    return pairs
}

private func myers(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    let n = a.count, m = b.count
    guard n > 0, m > 0 else { return [] }
    let maxD = n + m
    let offset = maxD + 1
    // Each step keeps a copy of the frontier for backtracking; cap that at ~20M entries.
    let budget = max(1, 20_000_000 / (2 * maxD + 3))
    var v = [Int](repeating: 0, count: 2 * maxD + 3)
    var trace: [[Int]] = []
    var found = false
    search: for d in 0...min(maxD, budget) {
        trace.append(v)
        for k in stride(from: -d, through: d, by: 2) {
            var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
            var y = x - k
            while x < n, y < m, a[x] == b[y] {
                x += 1
                y += 1
            }
            v[offset + k] = x
            if x >= n, y >= m {
                found = true
                break search
            }
        }
    }
    guard found else { return [] }

    var pairs: [(Int, Int)] = []
    var x = n, y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
        let v = trace[d]
        let k = x - y
        let previousK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
        let previousX = v[offset + previousK]
        let previousY = previousX - previousK
        while x > previousX, y > previousY {
            pairs.append((x - 1, y - 1))
            x -= 1
            y -= 1
        }
        if d > 0 {
            x = previousX
            y = previousY
        }
    }
    return pairs.reversed()
}
```

- [ ] **Step 5: Run to verify pass, then commit**

Run: `swift test --filter MergeTests`

```bash
git add Package.swift Sources/OrgDocument/Merge.swift Tests/OrgDocumentTests/MergeTests.swift
git commit -m "Add OrgDocument target with three-way merge"
```

---

### Task 2: Document state and view state

**Files:**
- Create: `Sources/OrgDocument/DocumentState.swift`, `Sources/OrgDocument/ViewState.swift`
- Test: `Tests/OrgDocumentTests/DocumentStateTests.swift`

**Interfaces:**
- Consumes: `threeWayMerge`, `lineEdits` (Task 1); `OrgParser.reparse`, `SourceText`, `TextEdit`.
- Produces: `DocumentState(bytes:defaults:)` with `source`, `text`, `tree`, `revision`, `mergeBase`, `isDirty`, `isEditable`, `canUndo`, `canRedo`, `encodedText()`, `apply(_:baseRevision:)`, `undo()`, `redo()`, `diskChanged(to:) -> ExternalChange`, `mergeOverwritten(_:base:)`, `didWrite(_:)`; `ViewState` with `mapped(through:)`, `pruned(to:)`; internal `mapOffset`, `utf16Slice`.

- [ ] **Step 1: Write the failing tests**

```swift
import OrgCore
import Testing
@testable import OrgDocument

func state(_ text: String) -> DocumentState {
    DocumentState(bytes: Array(text.utf8))
}

struct DocumentStateTests {
    @Test func applyUndoRedo() throws {
        var doc = state("* a\nbody\n")
        try doc.apply([TextEdit(range: 2..<3, replacement: "TODO b")], baseRevision: 0)
        #expect(doc.text == "* TODO b\nbody\n")
        #expect(doc.revision == 1)
        #expect(doc.isDirty)
        #expect(doc.tree.green == OrgParser.parse(doc.text).green)

        #expect(doc.undo() != nil)
        #expect(doc.text == "* a\nbody\n")
        #expect(!doc.isDirty)
        #expect(doc.tree.green == OrgParser.parse(doc.text).green)

        #expect(doc.redo() != nil)
        #expect(doc.text == "* TODO b\nbody\n")
    }

    @Test func groupedEditsAreOneUndoStep() throws {
        var doc = state("ab cd ef\n")
        try doc.apply([TextEdit(range: 0..<2, replacement: "X"), TextEdit(range: 6..<8, replacement: "YYY")], baseRevision: 0)
        #expect(doc.text == "X cd YYY\n")
        _ = doc.undo()
        #expect(doc.text == "ab cd ef\n")
    }

    @Test func rejectsStaleOverlappingAndReadOnly() throws {
        var doc = state("abc\n")
        #expect(throws: DocumentState.EditError.staleRevision) { try doc.apply([], baseRevision: 5) }
        #expect(throws: DocumentState.EditError.overlappingEdits) {
            try doc.apply([TextEdit(range: 0..<2, replacement: ""), TextEdit(range: 1..<3, replacement: "")], baseRevision: 0)
        }
        var invalid = DocumentState(bytes: [0x61, 0xFF])
        #expect(throws: DocumentState.EditError.readOnly) { try invalid.apply([], baseRevision: 0) }
        #expect(throws: DocumentState.EditError.readOnly) { try invalid.encodedText() }
    }

    @Test func newEditClearsRedo() throws {
        var doc = state("a\n")
        try doc.apply([TextEdit(range: 0..<0, replacement: "x")], baseRevision: 0)
        _ = doc.undo()
        try doc.apply([TextEdit(range: 0..<0, replacement: "y")], baseRevision: doc.revision)
        #expect(!doc.canRedo)
    }

    @Test func keepsBOMWhenEncoding() throws {
        var doc = DocumentState(bytes: [0xEF, 0xBB, 0xBF] + Array("a\n".utf8))
        try doc.apply([TextEdit(range: 0..<1, replacement: "b")], baseRevision: 0)
        #expect(try doc.encodedText() == [0xEF, 0xBB, 0xBF] + Array("b\n".utf8))
    }

    @Test func externalChangeReloadsCleanBuffer() {
        var doc = state("a\nb\n")
        #expect(doc.diskChanged(to: Array("a\nb\n".utf8)) == .unchanged)
        guard case .reloaded = doc.diskChanged(to: Array("a\nc\n".utf8)) else {
            Issue.record("expected a reload")
            return
        }
        #expect(doc.text == "a\nc\n")
        #expect(!doc.isDirty)
    }

    @Test func externalChangeMergesIntoEditedBuffer() throws {
        var doc = state("a\nb\nc\n")
        try doc.apply([TextEdit(range: 0..<1, replacement: "A")], baseRevision: 0)
        guard case .merged = doc.diskChanged(to: Array("a\nb\nC\n".utf8)) else {
            Issue.record("expected a merge")
            return
        }
        #expect(doc.text == "A\nb\nC\n")
        #expect(doc.mergeBase == Array("a\nb\nC\n".utf8))
        #expect(doc.isDirty)
        #expect(!doc.canUndo)
    }

    @Test func conflictingExternalChangeLeavesBufferAlone() throws {
        var doc = state("a\n")
        try doc.apply([TextEdit(range: 0..<1, replacement: "X")], baseRevision: 0)
        guard case .conflict = doc.diskChanged(to: Array("Y\n".utf8)) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(doc.text == "X\n")
        #expect(doc.mergeBase == Array("a\n".utf8))
    }
}

struct ViewStateTests {
    @Test func mapsSelectionAndFolds() {
        let view = ViewState(selection: [2..<6], folds: [0, 10])
        let mapped = view.mapped(through: [TextEdit(range: 1..<1, replacement: "xx"), TextEdit(range: 8..<9, replacement: "")])
        #expect(mapped.selection == [4..<8])
        #expect(mapped.folds == [0, 11])
    }

    @Test func offsetsInsideAReplacementMoveToItsEnd() {
        let edits = [TextEdit(range: 2..<5, replacement: "ab")]
        #expect(mapOffset(2, edits) == 2)
        #expect(mapOffset(3, edits) == 4)
        #expect(mapOffset(5, edits) == 4)
        #expect(mapOffset(6, edits) == 5)
        #expect(mapOffset(2, [TextEdit(range: 2..<2, replacement: "ab")]) == 4)
    }

    @Test func pruneDropsFoldsThatAreNoLongerHeadings() {
        let tree = OrgParser.parse("* a\ntext\n* b\n")
        #expect(ViewState(folds: [0, 4, 9]).pruned(to: tree).folds == [0, 9])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DocumentStateTests`
Expected: build failure, `cannot find 'DocumentState' in scope`.

- [ ] **Step 3: Implement `DocumentState.swift`**

```swift
import OrgCore

/// One open file: its text, tree, revision, undo history, and the bytes last read from or
/// written to disk, which are the base for merging external changes.
public struct DocumentState: Sendable {
    public enum EditError: Error, Equatable {
        case readOnly
        case staleRevision
        case overlappingEdits
    }

    public enum ExternalChange: Sendable, Equatable {
        case unchanged
        /// The buffer had no edits and now holds the disk version. Edits are in the old text's
        /// coordinates, for mapping view state.
        case reloaded([TextEdit])
        /// The disk version was merged into the edited buffer.
        case merged([TextEdit])
        /// Nothing changed in the buffer.
        case conflict([MergeConflict])
    }

    /// The bytes on disk as of the last read or write.
    public private(set) var source: SourceText
    public private(set) var text: String
    public private(set) var tree: OrgTree
    /// Increases on every change to `text`.
    public private(set) var revision = 0
    public let defaults: OrgSettings
    private var undoStack: [[TextEdit]] = []
    private var redoStack: [[TextEdit]] = []

    public init(bytes: [UInt8], defaults: OrgSettings = .default) {
        source = SourceText(bytes: bytes)
        text = source.text
        tree = OrgParser.parse(text, defaults: defaults)
        self.defaults = defaults
    }

    public var mergeBase: [UInt8] { source.originalBytes }
    public var isDirty: Bool { text != source.text }
    public var isEditable: Bool { source.isEditable }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Bytes to write for the current text, keeping the file's BOM.
    public func encodedText() throws -> [UInt8] {
        guard isEditable else { throw EditError.readOnly }
        return source.encode(text)
    }

    // MARK: - Editing

    /// Applies non-overlapping edits, computed against `baseRevision`, as one undo step.
    public mutating func apply(_ edits: [TextEdit], baseRevision: Int) throws {
        guard isEditable else { throw EditError.readOnly }
        guard baseRevision == revision else { throw EditError.staleRevision }
        let inverse = try applyGroup(edits)
        undoStack.append(inverse)
        redoStack = []
    }

    /// Reverts the last edit group. Returns the edits applied, for mapping view state.
    public mutating func undo() -> [TextEdit]? {
        guard let group = undoStack.popLast() else { return nil }
        redoStack.append(try! applyGroup(group))
        return group
    }

    public mutating func redo() -> [TextEdit]? {
        guard let group = redoStack.popLast() else { return nil }
        undoStack.append(try! applyGroup(group))
        return group
    }

    /// Applies `edits` (old coordinates) and returns their inverse (new coordinates).
    private mutating func applyGroup(_ edits: [TextEdit]) throws -> [TextEdit] {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (first, second) in zip(sorted, sorted.dropFirst()) where first.range.upperBound > second.range.lowerBound {
            throw EditError.overlappingEdits
        }
        var inverse: [TextEdit] = []
        var shift = 0
        for edit in sorted {
            let start = edit.range.lowerBound + shift
            inverse.append(TextEdit(range: start..<(start + edit.replacement.utf16.count), replacement: utf16Slice(text, edit.range)))
            shift += edit.replacement.utf16.count - edit.range.count
        }
        // Back to front, so earlier offsets stay valid.
        for edit in sorted.reversed() {
            tree = OrgParser.reparse(tree, oldText: text, edit: edit, defaults: defaults)
            text = edit.apply(to: text)
        }
        revision += 1
        return inverse
    }

    // MARK: - Disk

    /// The file on disk now holds `bytes`. Reloads an unedited buffer, merges into an edited
    /// one, and makes `bytes` the new merge base unless the merge conflicts.
    public mutating func diskChanged(to bytes: [UInt8]) -> ExternalChange {
        guard bytes != mergeBase else { return .unchanged }
        let disk = SourceText(bytes: bytes)
        if !isDirty {
            let edits = lineEdits(from: text, to: disk.text)
            replaceText(with: disk.text, source: disk)
            return .reloaded(edits)
        }
        return mergeIn(disk, base: source.text, newSource: disk)
    }

    /// Our bytes are on disk, but they replaced `theirs`, which was based on `base`. Merges
    /// their changes into the buffer and leaves the merge base at our bytes.
    public mutating func mergeOverwritten(_ theirs: [UInt8], base: [UInt8]) -> ExternalChange {
        mergeIn(SourceText(bytes: theirs), base: SourceText(bytes: base).text, newSource: source)
    }

    private mutating func mergeIn(_ theirs: SourceText, base: String, newSource: SourceText) -> ExternalChange {
        guard theirs.isValidUTF8 else {
            return .conflict([MergeConflict(base: base, ours: text, theirs: theirs.text)])
        }
        switch threeWayMerge(base: base, ours: text, theirs: theirs.text) {
        case .merged(let merged):
            let edits = lineEdits(from: text, to: merged)
            replaceText(with: merged, source: newSource)
            return .merged(edits)
        case .conflict(let conflicts):
            return .conflict(conflicts)
        }
    }

    /// Records that `bytes` were written. The text stays as is; edits made since the write keep
    /// the buffer dirty.
    public mutating func didWrite(_ bytes: [UInt8]) {
        source = SourceText(bytes: bytes)
    }

    /// Undo history can't be mapped through an external change, so it is cleared.
    private mutating func replaceText(with newText: String, source newSource: SourceText) {
        source = newSource
        if newText != text {
            text = newText
            tree = OrgParser.parse(newText, defaults: defaults)
            revision += 1
        }
        undoStack = []
        redoStack = []
    }
}

func utf16Slice(_ text: String, _ range: Range<Int>) -> String {
    let start = String.Index(utf16Offset: range.lowerBound, in: text)
    let end = String.Index(utf16Offset: range.upperBound, in: text)
    return String(text.unicodeScalars[start..<end])
}
```

- [ ] **Step 4: Implement `ViewState.swift`**

```swift
import OrgCore

/// Per-window state for one document: selection and folds, in UTF-16 offsets.
public struct ViewState: Sendable, Equatable {
    public var selection: [Range<Int>]
    /// Start offsets of folded headings.
    public var folds: Set<Int>

    public init(selection: [Range<Int>] = [0..<0], folds: Set<Int> = []) {
        self.selection = selection
        self.folds = folds
    }

    /// Maps through non-overlapping edits given in old coordinates.
    public func mapped(through edits: [TextEdit]) -> ViewState {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        return ViewState(
            selection: selection.map { mapOffset($0.lowerBound, sorted)..<mapOffset($0.upperBound, sorted) },
            folds: Set(folds.map { mapOffset($0, sorted) })
        )
    }

    /// Drops folds that no longer sit at the start of a heading.
    public func pruned(to tree: OrgTree) -> ViewState {
        let headings = Set(tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound))
        return ViewState(selection: selection, folds: folds.intersection(headings))
    }
}

/// An offset before an edit stays put; one at the start of a replaced range stays at its start;
/// one inside it, at its end, or at an insertion point moves past the replacement.
func mapOffset(_ offset: Int, _ sortedEdits: [TextEdit]) -> Int {
    var shift = 0
    for edit in sortedEdits {
        let lower = edit.range.lowerBound, upper = edit.range.upperBound
        if offset < lower || (offset == lower && upper > lower) { return offset + shift }
        if offset <= upper { return lower + shift + edit.replacement.utf16.count }
        shift += edit.replacement.utf16.count - edit.range.count
    }
    return offset + shift
}
```

- [ ] **Step 5: Run to verify pass, then commit**

Run: `swift test --filter "DocumentStateTests|ViewStateTests"`

```bash
git add Sources/OrgDocument/DocumentState.swift Sources/OrgDocument/ViewState.swift Tests/OrgDocumentTests/DocumentStateTests.swift
git commit -m "Add document state and view state"
```

---

### Task 3: Save path

**Files:**
- Create: `Sources/OrgDocument/Saving.swift`, `Sources/OrgDocument/FileStorage.swift`
- Test: `Tests/OrgDocumentTests/SaveTests.swift`

**Interfaces:**
- Consumes: `DocumentState` (Task 2).
- Produces: `FileSystem`, `RecoveryStore`, `SaveOutcome`, `SaveError`, `Saver(fileSystem:recovery:)` with `save(_:to:)`, `CoordinatedFileSystem`, `FileRecoveryStore(directory:limit:)` with `versions(for:)`.

- [ ] **Step 1: Write the failing tests**

The fault-injection cases put another writer's change in place before each read and before the replace, and check that both versions survive.

```swift
import Foundation
import OrgCore
import Testing
@testable import OrgDocument

/// An in-memory file with hooks that let another writer change it at each step of a save.
final class FaultyFileSystem: FileSystem, @unchecked Sendable {
    var file: [UInt8]?
    var reads = 0
    /// Content another writer puts in place just before the n-th read (1-based).
    var beforeRead: [Int: [UInt8]] = [:]
    /// Content another writer puts in place just before our replace.
    var beforeReplace: [UInt8]?

    init(_ text: String?) {
        file = text.map { Array($0.utf8) }
    }

    func read(_ url: URL) throws -> [UInt8]? {
        reads += 1
        if let injected = beforeRead[reads] { file = injected }
        return file
    }

    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        if let injected = beforeReplace { file = injected }
        let replaced = file
        file = bytes
        return replaced
    }

    var text: String? { file.map { String(decoding: $0, as: UTF8.self) } }
}

final class MemoryRecovery: RecoveryStore, @unchecked Sendable {
    var kept: [(label: String, text: String)] = []

    func keep(_ bytes: [UInt8], for url: URL, label: String) throws {
        kept.append((label, String(decoding: bytes, as: UTF8.self)))
    }

    func contains(_ text: String) -> Bool { kept.contains { $0.text == text } }
}

let url = URL(fileURLWithPath: "/notes/a.org")

/// A buffer loaded from "a\nb\nc\n" with its first line changed to "A".
func editedState() throws -> DocumentState {
    var doc = state("a\nb\nc\n")
    try doc.apply([TextEdit(range: 0..<1, replacement: "A")], baseRevision: 0)
    return doc
}

struct SaveTests {
    @Test func plainSave() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        let recovery = MemoryRecovery()
        var doc = try editedState()
        #expect(try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) == .saved)
        #expect(files.text == "A\nb\nc\n")
        #expect(!doc.isDirty)
        #expect(recovery.kept.isEmpty)
    }

    @Test func missingFileIsCreated() throws {
        let files = FaultyFileSystem(nil)
        var doc = try editedState()
        #expect(try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) == .saved)
        #expect(files.text == "A\nb\nc\n")
    }

    @Test func readOnlyDocumentsAreNotSaved() {
        var doc = DocumentState(bytes: [0x61, 0xFF])
        #expect(throws: DocumentState.EditError.readOnly) {
            try Saver(fileSystem: FaultyFileSystem("x"), recovery: MemoryRecovery()).save(&doc, to: url)
        }
    }

    // MARK: - Another writer at each step

    @Test func changedBeforeSaveMerges() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[1] = Array("a\nb\nC\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .mergedAndSaved = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected a merge")
            return
        }
        #expect(files.text == "A\nb\nC\n")
        #expect(recovery.contains("a\nb\nC\n") && recovery.contains("A\nb\nc\n"))
    }

    @Test func conflictingChangeWritesNothing() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[1] = Array("Z\nb\nc\n".utf8)
        var doc = try editedState()
        guard case .conflict = try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(files.text == "Z\nb\nc\n")
        #expect(doc.text == "A\nb\nc\n")
    }

    @Test func changedBetweenReadAndCheckRetries() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[2] = Array("a\nb\nC\n".utf8)
        var doc = try editedState()
        guard case .mergedAndSaved = try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) else {
            Issue.record("expected a merge on the second attempt")
            return
        }
        #expect(files.text == "A\nb\nC\n")
    }

    @Test func changedJustBeforeReplaceIsRecovered() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeReplace = Array("a\nb\nC\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .overwroteExternalChange(.merged) = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected their change merged into the buffer")
            return
        }
        #expect(files.text == "A\nb\nc\n")
        #expect(recovery.contains("a\nb\nC\n"))
        #expect(doc.text == "A\nb\nC\n")
        #expect(doc.isDirty)
    }

    @Test func changedRightAfterWriteKeepsOursInRecovery() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[3] = Array("A\nb\nc\nD\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .changedAfterWrite(.reloaded) = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected a reload of their version")
            return
        }
        #expect(recovery.contains("A\nb\nc\n"))
        #expect(doc.text == "A\nb\nc\nD\n")
    }

    @Test func keepsChangingGivesUp() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        for n in stride(from: 2, through: 6, by: 2) { files.beforeRead[n] = Array("a\nb\nc\n\(n)\n".utf8) }
        var doc = try editedState()
        #expect(throws: SaveError.fileKeepsChanging) {
            try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url)
        }
    }
}

struct FileStorageTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func readAndReplace() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        let files = CoordinatedFileSystem()
        #expect(try files.read(file) == nil)
        #expect(try files.replace(file, with: Array("one\n".utf8)) == nil)
        #expect(try files.replace(file, with: Array("two\n".utf8)) == Array("one\n".utf8))
        #expect(try files.read(file) == Array("two\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.org"])
    }

    @Test func savesThroughTheRealFileSystem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        try Data("a\nb\nc\n".utf8).write(to: file)
        let recovery = FileRecoveryStore(directory: folder.appendingPathComponent("recovery"))
        var doc = try editedState()
        #expect(try Saver(fileSystem: CoordinatedFileSystem(), recovery: recovery).save(&doc, to: file) == .saved)
        #expect(try String(contentsOf: file, encoding: .utf8) == "A\nb\nc\n")
    }

    @Test func recoveryKeepsTheNewestVersions() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileRecoveryStore(directory: folder, limit: 3)
        for n in 0..<5 { try store.keep(Array("v\(n)".utf8), for: url, label: "local") }
        let versions = try store.versions(for: url)
        #expect(versions.count == 3)
        #expect(try versions.map { try String(contentsOf: $0, encoding: .utf8) } == ["v2", "v3", "v4"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SaveTests`
Expected: build failure, `cannot find type 'FileSystem' in scope`.

- [ ] **Step 3: Implement `Saving.swift`**

```swift
import Foundation
import OrgCore

public protocol FileSystem: Sendable {
    /// The file's bytes, or nil if it doesn't exist.
    func read(_ url: URL) throws -> [UInt8]?
    /// Replaces the file through a temporary file in the same folder. Returns the bytes that
    /// were replaced, read from the replaced file itself, or nil if there was none.
    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]?
}

public protocol RecoveryStore: Sendable {
    func keep(_ bytes: [UInt8], for url: URL, label: String) throws
}

public enum SaveOutcome: Sendable, Equatable {
    case saved
    /// The file had changed since it was read; the change merged cleanly into the buffer and
    /// the merge was written.
    case mergedAndSaved([TextEdit])
    /// The file had changed and the change conflicts. Nothing was written; the buffer is
    /// unchanged.
    case conflict([MergeConflict])
    /// Another writer replaced the file between our last check and our write. Ours is on disk;
    /// theirs is in recovery and was merged into the buffer where possible.
    case overwroteExternalChange(DocumentState.ExternalChange)
    /// Another writer changed the file right after our write. Theirs is on disk; ours is in
    /// recovery.
    case changedAfterWrite(DocumentState.ExternalChange)
}

public enum SaveError: Error, Equatable {
    case fileKeepsChanging
}

/// The save sequence from the design: read, merge if the file moved, check again, replace,
/// read back. Emacs and Syncthing don't coordinate, so the sequence can't lock them out; it
/// narrows the window and makes sure every version it displaces lands in recovery.
public struct Saver: Sendable {
    public let fileSystem: FileSystem
    public let recovery: RecoveryStore
    public var maxAttempts = 3

    public init(fileSystem: FileSystem, recovery: RecoveryStore) {
        self.fileSystem = fileSystem
        self.recovery = recovery
    }

    public func save(_ state: inout DocumentState, to url: URL) throws -> SaveOutcome {
        guard state.isEditable else { throw DocumentState.EditError.readOnly }
        for _ in 0..<maxAttempts {
            let disk = try fileSystem.read(url)
            var merged: [TextEdit]?
            if let disk, disk != state.mergeBase {
                try recovery.keep(disk, for: url, label: "external")
                try recovery.keep(state.encodedText(), for: url, label: "local")
                switch state.diskChanged(to: disk) {
                case .conflict(let conflicts): return .conflict(conflicts)
                case .merged(let edits), .reloaded(let edits): merged = edits
                case .unchanged: break
                }
            }
            let bytes = try state.encodedText()
            guard try fileSystem.read(url) == disk else { continue }

            let replaced = try fileSystem.replace(url, with: bytes)
            state.didWrite(bytes)
            if replaced != disk, let replaced {
                try recovery.keep(replaced, for: url, label: "external")
                return .overwroteExternalChange(state.mergeOverwritten(replaced, base: disk ?? []))
            }

            if let after = try fileSystem.read(url), after != bytes {
                try recovery.keep(bytes, for: url, label: "local")
                return .changedAfterWrite(state.diskChanged(to: after))
            }
            return merged.map { .mergedAndSaved($0) } ?? .saved
        }
        throw SaveError.fileKeepsChanging
    }
}
```

- [ ] **Step 4: Implement `FileStorage.swift`**

```swift
import CryptoKit
import Foundation

/// Reads and replaces files under `NSFileCoordinator`, so iCloud and other coordinating
/// writers see a consistent file.
public struct CoordinatedFileSystem: FileSystem {
    public init() {}

    public func read(_ url: URL) throws -> [UInt8]? {
        try coordinate(reading: url) { url in
            FileManager.default.fileExists(atPath: url.path) ? [UInt8](try Data(contentsOf: url)) : nil
        }
    }

    public func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        try coordinate(writing: url) { url in
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).orgstar-\(UUID().uuidString)")
            try Data(bytes).write(to: temporary)
            guard manager.fileExists(atPath: url.path) else {
                try manager.moveItem(at: temporary, to: url)
                return nil
            }
            // The backup is the file as it was at the moment of replacement, including any
            // write that landed after our last check.
            let backupName = ".\(url.lastPathComponent).orgstar-backup-\(UUID().uuidString)"
            _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: backupName, options: .withoutDeletingBackupItem)
            let backup = folder.appendingPathComponent(backupName)
            defer { try? manager.removeItem(at: backup) }
            return [UInt8](try Data(contentsOf: backup))
        }
    }

    private func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func coordinate<T>(writing url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
}

/// Keeps the last `limit` displaced versions per file in `directory/<hash of path>/`.
public struct FileRecoveryStore: RecoveryStore {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 20) {
        self.directory = directory
        self.limit = limit
    }

    public func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    public func keep(_ bytes: [UInt8], for url: URL, label: String) throws {
        let folder = folder(for: url)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Zero-padded wall-clock nanoseconds sort by time; the UUID keeps same-instant names apart.
        let stamp = String(format: "%020llu", UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
        let name = "\(stamp)-\(label)-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        try Data(bytes).write(to: folder.appendingPathComponent(name))
        let kept = try manager.contentsOfDirectory(atPath: folder.path).sorted()
        for old in kept.dropLast(limit) {
            try manager.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    /// Kept versions, oldest first.
    public func versions(for url: URL) throws -> [URL] {
        let folder = folder(for: url)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().map { folder.appendingPathComponent($0) }
    }
}
```

- [ ] **Step 5: Run everything, including the iOS build**

Run: `swift test`, then `xcodebuild -scheme OrgDocument -destination 'generic/platform=iOS' build`
Expected: all pass; `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrgDocument/Saving.swift Sources/OrgDocument/FileStorage.swift Tests/OrgDocumentTests/SaveTests.swift
git commit -m "Add save path with recovery and fault-injection tests"
```
