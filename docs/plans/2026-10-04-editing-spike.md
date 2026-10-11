# Editable TextKit 2 Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that a TextKit 2 text view can fold org subtrees and show org-indent while caret movement, selection, input methods, VoiceOver and copy/paste stay correct, with typing restyled inside a 16 ms frame. Find what doesn't work before phase 2 builds on it.

**Architecture:** `OrgPresentation` is the platform-free layout policy: style runs, org-indent columns and hidden ranges, all computed from the tree. `OrgEditorAppKit` maps that policy onto an `NSTextView` with TextKit 2: folded paragraphs are skipped by `NSTextContentManagerDelegate.shouldEnumerate`, folded headings draw an ellipsis from a custom `NSTextLayoutFragment`, and every character edit flows from the text storage into `DocumentState.apply`. Only the affected region is restyled: the elements around the edit in the innermost section, computed on both the old and the new tree. `OrgstarSpike` is a throwaway app for trying it by hand.

**Tech Stack:** Swift 6.2 tools, Swift Testing, AppKit, TextKit 2.

**Spec:** `docs/design.md`, "iOS considerations" (editor view row) and the phase 1 editing spike gate.

## Global Constraints

- `OrgPresentation` imports only `OrgCore`; it builds for iOS.
- The text storage and `DocumentState` hold the same text after every edit, and the tree equals a full parse.
- Incrementally restyled text equals a fresh editor's full styling after every edit.
- Folded text stays in the storage: copy, accessibility and saving see all of it.

## Findings

Measured in release builds on an M-series Mac (not yet the M1 Air reference machine).

| Check | Result |
| --- | --- |
| Folding by skipping enumeration | Works; layout drops folded paragraphs; ellipsis drawn after folded headings |
| Caret | `moveDown` skips folds; `moveRight`/`moveLeft` would enter hidden text, so the editor moves the caret across the fold |
| Copy across a fold | Includes the hidden text |
| Input methods | Marked text and commit keep the document in sync |
| Undo (`NSTextView`'s undo manager) | Keeps the document in sync |
| Accessibility | `accessibilityValue` is the whole file, folds included; selection and line queries work. A manual VoiceOver pass is still needed (below) |
| Typing, p95 | 5.8 ms on a 1.5 MB file, 3.4 ms on 0.86 MB (gate 16 ms) |
| Blank line in a 1.2 MB top-level section | 256 ms; the reparse covers the whole top-level section (gate 16 ms) |
| Open: parse + load and style | 313 + 124 ms for 1.5 MB; 126 + 101 ms for 0.86 MB (gate 100 ms for 1 MB) |
| Restyle correctness | 10,500 random edits over seven seeds match a fresh full styling |

Two bugs the differential test found and the plan fixes: a line split off by an inserted newline kept the old line's style, and a block or drawer whose delimiters changed left stale styling below the edit (fixed by restyling the union of the old and new trees' affected ranges).

Work for the performance plan: reparse structural edits within the innermost section instead of the top-level section; a faster parser (about 3x for the open gate); style the visible region first on open and the rest after.

Manual VoiceOver checklist (run `swift run OrgstarSpike <file>`, turn on VoiceOver):
- [ ] Line by line through a folded heading skips to the next visible heading. — did not ship: the VoiceOver check is owed (see docs/design.md, phase 1)
- [ ] Reading a heading with tags and a TODO keyword is understandable. — did not ship: the VoiceOver check is owed (see docs/design.md, phase 1)
- [ ] Selection announcements are correct across a fold. — did not ship: the VoiceOver check is owed (see docs/design.md, phase 1)

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgPresentation/Presentation.swift` | Style roles and runs, indent runs, hidden ranges, heading lookup |
| `Sources/OrgEditorAppKit/OrgEditor.swift` | TextKit 2 editor: sync, folding, caret, restyle region, save |
| `Sources/OrgEditorAppKit/Theme.swift` | Attributes per style role |
| `Sources/OrgstarSpike/main.swift` | Runnable spike app |
| `Sources/OrgDocument/ViewState.swift` | `pruned(to:)` descends only through containing sections |

---

### Task 1: Presentation policy

**Files:**
- Modify: `Package.swift` (add `OrgPresentation`)
- Create: `Sources/OrgPresentation/Presentation.swift`
- Test: `Tests/OrgPresentationTests/PresentationTests.swift`

**Interfaces:**
- Produces: `StyleRole`, `StyleRun`, `IndentRun`, `Presentation.styles(_:in:)`, `Presentation.indents(_:in:)`, `Presentation.hiddenRanges(_:folds:)`, `Presentation.heading(containing:in:)`, `Presentation.headings(_:)`.

- [x] **Step 1: Write the failing tests**

```swift
import OrgCore
import Testing
@testable import OrgPresentation

func roles(_ text: String) -> [String] {
    let tree = OrgParser.parse(text)
    let utf16 = Array(text.utf16)
    return Presentation.styles(tree, in: 0..<utf16.count).map { run in
        "\(run.role):\(String(decoding: utf16[run.range], as: UTF16.self))"
    }
}

struct StyleTests {
    @Test func headingParts() {
        #expect(roles("** DONE [#A] Ship *it* :work:\n") == [
            "heading(level: 2):** DONE [#A] Ship *it* :work:\n",
            "leadingStars:*", "done:DONE", "priority:[#A]", "tags::work:",
            "bold:*it*", "markup:*", "markup:*",
        ])
    }

    @Test func describedLinksDimTheirTarget() {
        #expect(roles("[[https://a.b][site]]\n") == [
            "link:[[https://a.b][site]]", "linkMarkup:[[", "linkMarkup:https://a.b", "linkMarkup:][", "linkMarkup:]]",
        ])
        #expect(roles("[[https://a.b]]\n") == ["link:[[https://a.b]]", "linkMarkup:[[", "linkMarkup:]]"])
    }

    @Test func blocksAndMetadata() {
        #expect(roles("#+begin_src sh\necho\n#+end_src\n") == [
            "block:#+begin_src sh\necho\n#+end_src\n", "blockDelimiter:#+begin_src sh", "blockDelimiter:#+end_src",
        ])
        #expect(roles("* a\nSCHEDULED: <2026-10-04 Sun>\n").contains("metadata:SCHEDULED: <2026-10-04 Sun>\n"))
    }

    @Test func onlyRunsOverlappingTheRange() {
        let text = "* a\nfirst *b*\n* c\nsecond *d*\n"
        let tree = OrgParser.parse(text)
        let runs = Presentation.styles(tree, in: 17..<28)
        #expect(!runs.contains { $0.range == 10..<13 })
        #expect(runs.contains { $0.range == 25..<28 && $0.role == .bold })
    }
}

struct IndentTests {
    @Test func bodiesIndentPastTheirStars() {
        let text = "pre\n* a\nbody\n** b\nmore\n"
        let runs = Presentation.indents(OrgParser.parse(text), in: 0..<text.utf16.count)
        #expect(runs == [
            IndentRun(range: 4..<8, firstLine: 0, wrapped: 2),
            IndentRun(range: 8..<13, firstLine: 2, wrapped: 2),
            IndentRun(range: 13..<18, firstLine: 0, wrapped: 3),
            IndentRun(range: 18..<23, firstLine: 3, wrapped: 3),
        ])
    }
}

struct FoldTests {
    let text = "* a\nbody\n** b\nmore\n* c\ntext\n"

    @Test func hiddenRanges() {
        let tree = OrgParser.parse(text)
        #expect(Presentation.hiddenRanges(tree, folds: [0]) == [4..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [9]) == [14..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [0, 9]) == [4..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [19]) == [23..<28])
        #expect(Presentation.hiddenRanges(OrgParser.parse("* a"), folds: [0]).isEmpty)
    }

    @Test func headingContaining() {
        let tree = OrgParser.parse(text)
        #expect(Presentation.heading(containing: 2, in: tree) == 0)
        #expect(Presentation.heading(containing: 3, in: tree) == 0)
        #expect(Presentation.heading(containing: 5, in: tree) == nil)
        #expect(Presentation.heading(containing: 10, in: tree) == 9)
        #expect(Presentation.headings(tree) == [0, 9, 19])
    }
}
```

- [x] **Step 2: Implement**

```swift
import OrgCore

/// What a range of text is, for styling. Platform adapters map roles to attributes.
public enum StyleRole: Hashable, Sendable {
    /// A whole heading line.
    case heading(level: Int)
    /// All stars of a heading but the last, hidden as in `org-hide-leading-stars`.
    case leadingStars
    case todo, done, priority, tags
    case bold, italic, underline, strikeThrough, verbatim, code
    /// Emphasis markers.
    case markup
    case link
    /// Brackets and the target of a described link.
    case linkMarkup
    case timestamp, footnote, cookie, target, macro, latex, inlineSource
    case comment, keyword
    /// Planning lines, drawers, property drawers, clock lines.
    case metadata
    case block, blockDelimiter, table, rule
}

public struct StyleRun: Sendable, Equatable {
    public let range: Range<Int>
    public let role: StyleRole
}

/// org-indent: how many columns a run of whole lines starts in.
public struct IndentRun: Sendable, Equatable {
    public let range: Range<Int>
    public let firstLine: Int
    /// Continuation lines of a wrapped paragraph.
    public let wrapped: Int
}

public enum Presentation {
    /// Style runs for nodes and tokens overlapping `range`, outer before inner, so applying
    /// them in order lets inner roles win.
    public static func styles(_ tree: OrgTree, in range: Range<Int>) -> [StyleRun] {
        var runs: [StyleRun] = []
        visit(tree.root, range, tree.settings, &runs)
        return runs
    }

    private static func visit(_ node: SyntaxNode, _ range: Range<Int>, _ settings: OrgSettings, _ runs: inout [StyleRun]) {
        if let role = role(of: node) { runs.append(StyleRun(range: node.range, role: role)) }
        switch node.kind {
        case .heading:
            for token in node.tokens {
                switch token.kind {
                case .stars where token.range.count > 1:
                    runs.append(StyleRun(range: token.range.lowerBound..<(token.range.upperBound - 1), role: .leadingStars))
                case .todoKeyword:
                    runs.append(StyleRun(range: token.range, role: settings.isDone(token.text) ? .done : .todo))
                case .priority:
                    runs.append(StyleRun(range: token.range, role: .priority))
                case .tags:
                    runs.append(StyleRun(range: token.range, role: .tags))
                default:
                    break
                }
            }
        case .link:
            let described = node.children.contains { $0.kind == .linkDescription }
            for token in node.tokens where token.kind == .marker || (described && token.kind == .linkPath) {
                runs.append(StyleRun(range: token.range, role: .linkMarkup))
            }
        case .bold, .italic, .underline, .strikeThrough, .verbatim, .code:
            for token in node.tokens where token.kind == .marker {
                runs.append(StyleRun(range: token.range, role: .markup))
            }
        case .block, .dynamicBlock:
            let lines = node.tokens.filter { $0.kind == .text }
            for token in [lines.first, lines.count > 1 ? lines.last : nil].compactMap({ $0 }) {
                runs.append(StyleRun(range: token.range, role: .blockDelimiter))
            }
        default:
            break
        }
        for child in node.children where child.range.overlaps(range) {
            visit(child, range, settings, &runs)
        }
    }

    static func role(of node: SyntaxNode) -> StyleRole? {
        switch node.kind {
        case .heading: .heading(level: node.tokens.first { $0.kind == .stars }?.text.count ?? 1)
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikeThrough: .strikeThrough
        case .verbatim: .verbatim
        case .code: .code
        case .link: .link
        case .timestamp: .timestamp
        case .footnoteReference, .footnoteDefinition: .footnote
        case .statisticsCookie: .cookie
        case .target: .target
        case .macro: .macro
        case .latexFragment: .latex
        case .inlineSourceBlock: .inlineSource
        case .comment: .comment
        case .keyword, .affiliatedKeyword: .keyword
        case .planning, .propertyDrawer, .drawer, .clock: .metadata
        case .block, .dynamicBlock, .fixedWidth: .block
        case .table: .table
        case .horizontalRule: .rule
        default: nil
        }
    }

    /// Heading lines start at column 0, with wrapped title lines under the title; a section's
    /// own body starts one column past its stars.
    public static func indents(_ tree: OrgTree, in range: Range<Int>) -> [IndentRun] {
        var runs: [IndentRun] = []
        collectIndents(tree.root, range, &runs)
        return runs
    }

    private static func collectIndents(_ node: SyntaxNode, _ range: Range<Int>, _ runs: inout [IndentRun]) {
        for section in node.children where section.kind == .section && section.range.overlaps(range) {
            let children = section.children
            guard let heading = children.first(where: { $0.kind == .heading }) else { continue }
            let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
            runs.append(IndentRun(range: heading.range, firstLine: 0, wrapped: level + 1))
            let bodyEnd = children.first { $0.kind == .section }?.range.lowerBound ?? section.range.upperBound
            if heading.range.upperBound < bodyEnd {
                runs.append(IndentRun(range: heading.range.upperBound..<bodyEnd, firstLine: level + 1, wrapped: level + 1))
            }
            collectIndents(section, range, &runs)
        }
    }

    /// Ranges to hide for folded headings, given by their start offsets: from the end of the
    /// heading line to the end of its section. Sorted, without nested duplicates.
    public static func hiddenRanges(_ tree: OrgTree, folds: Set<Int>) -> [Range<Int>] {
        guard !folds.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        collectHidden(tree.root, folds, &ranges)
        return ranges
    }

    private static func collectHidden(_ node: SyntaxNode, _ folds: Set<Int>, _ ranges: inout [Range<Int>]) {
        for section in node.children where section.kind == .section {
            guard let heading = section.children.first(where: { $0.kind == .heading }) else { continue }
            if folds.contains(heading.range.lowerBound) {
                if heading.range.upperBound < section.range.upperBound {
                    ranges.append(heading.range.upperBound..<section.range.upperBound)
                }
            } else {
                collectHidden(section, folds, &ranges)
            }
        }
    }

    /// Start offset of the heading whose line contains `offset`.
    public static func heading(containing offset: Int, in tree: OrgTree) -> Int? {
        var node = tree.root
        while let child = node.children.first(where: { $0.range.contains(offset) }) {
            if child.kind == .heading { return child.range.lowerBound }
            guard child.kind == .section || child.kind == .zerothSection else { return nil }
            node = child
        }
        return nil
    }

    /// Start offsets of every heading, for folding everything.
    public static func headings(_ tree: OrgTree) -> [Int] {
        tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound)
    }
}
```

- [x] **Step 3: Run, build for iOS, commit**

Run: `swift test --filter OrgPresentationTests`, then `xcodebuild -scheme OrgPresentation -destination 'generic/platform=iOS' build`.

```bash
git add Package.swift Sources/OrgPresentation Tests/OrgPresentationTests
git commit -m "Add platform-free presentation policy"
```

---

### Task 2: AppKit editor

**Files:**
- Modify: `Package.swift` (add `OrgEditorAppKit`), `Sources/OrgDocument/ViewState.swift`
- Create: `Sources/OrgEditorAppKit/OrgEditor.swift`, `Sources/OrgEditorAppKit/Theme.swift`
- Test: `Tests/OrgEditorAppKitTests/EditorTests.swift`

**Interfaces:**
- Consumes: `DocumentState`, `ViewState`, `Saver`, `lineEdits` (OrgDocument); Task 1.
- Produces: `OrgEditor(document:frame:)` with `textView`, `document`, `view`, `onEditTiming`, `makeScrollView()`, `setFolds(_:)`, `toggleFoldAtCaret()`, `toggleAllFolds()`, `save(using:to:)`.

- [x] **Step 1: Make pruning cheap**

```diff
@@ -22,11 +22,22 @@ public struct ViewState: Sendable, Equatable {
 
     /// Drops folds that no longer sit at the start of a heading.
     public func pruned(to tree: OrgTree) -> ViewState {
-        let headings = Set(tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound))
-        return ViewState(selection: selection, folds: folds.intersection(headings))
+        guard !folds.isEmpty else { return self }
+        return ViewState(selection: selection, folds: folds.filter { isHeadingStart($0, tree.root) })
     }
 }
 
+/// Descends only through the sections containing `offset`.
+func isHeadingStart(_ offset: Int, _ root: SyntaxNode) -> Bool {
+    var node = root
+    while let child = node.children.first(where: { $0.range.contains(offset) }) {
+        if child.kind == .heading { return child.range.lowerBound == offset }
+        guard child.kind == .section || child.kind == .zerothSection else { return false }
+        node = child
+    }
+    return false
+}
+
 /// An offset before an edit stays put; one at the start of a replaced range stays at its start;
 /// one inside it, at its end, or at an insertion point moves past the replacement.
 func mapOffset(_ offset: Int, _ sortedEdits: [TextEdit]) -> Int {
```

- [x] **Step 2: Write the failing tests**

The tests drive a real `NSTextView` in an offscreen window. `RestyleFuzzTests` compares the incrementally styled storage with a fresh editor after every random edit.

```swift
import AppKit
import OrgCore
import OrgDocument
import Testing
@testable import OrgEditorAppKit

/// An editor in an offscreen window, laid out.
@MainActor
final class Harness {
    let editor: OrgEditor
    let window: NSWindow

    init(_ text: String) {
        _ = NSApplication.shared
        editor = OrgEditor(document: DocumentState(bytes: Array(text.utf8)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.makeScrollView()
        window.makeFirstResponder(editor.textView)
        layout()
    }

    var textView: NSTextView { editor.textView }
    var string: String { textView.string }

    func layout() {
        let manager = editor.textLayoutManager
        manager.ensureLayout(for: manager.documentRange)
    }

    /// Text of each laid-out paragraph.
    var visibleLines: [String] {
        layout()
        let manager = editor.textLayoutManager
        var lines: [String] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let content = manager.textContentManager!
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            lines.append((self.string as NSString).substring(with: NSRange(location: start, length: end - start)))
            return true
        }
        return lines.filter { !$0.isEmpty }
    }

    func caret(at offset: Int) {
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }

    var caret: Int { textView.selectedRange().location }

    func offset(of line: String) -> Int {
        (string as NSString).range(of: line).location
    }

    func checkInSync() {
        #expect(editor.document.text == string)
        #expect(editor.document.tree.green == OrgParser.parse(string).green)
    }
}

let outline = "* a\nbody\n** b\nmore\n* c\ntext\n"

@MainActor
struct FoldingTests {
    @Test func foldingHidesTheSubtree() {
        let h = Harness(outline)
        #expect(h.visibleLines == ["* a\n", "body\n", "** b\n", "more\n", "* c\n", "text\n"])
        h.caret(at: 1)
        #expect(h.editor.toggleFoldAtCaret())
        #expect(h.visibleLines == ["* a\n", "* c\n", "text\n"])
        h.editor.toggleFoldAtCaret()
        #expect(h.visibleLines.count == 6)
    }

    @Test func tabFoldsOnlyOnHeadings() {
        let h = Harness(outline)
        h.caret(at: 5)
        #expect(!h.editor.toggleFoldAtCaret())
        h.textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(h.visibleLines == ["* a\n", "* c\n"])
    }

    @Test func caretMovesOverFoldedText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.toggleFoldAtCaret()
        h.caret(at: 0)
        h.textView.moveDown(nil)
        #expect(h.caret >= h.offset(of: "* c") && h.caret < h.offset(of: "text"))
        h.caret(at: 3)
        h.textView.moveRight(nil)
        #expect(h.caret == h.offset(of: "* c"))
        h.textView.moveLeft(nil)
        #expect(h.caret == 3)
    }

    @Test func copyingAcrossAFoldIncludesHiddenText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.toggleFoldAtCaret()
        h.textView.setSelectedRange(NSRange(location: 0, length: h.offset(of: "text")))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orgstar-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(h.textView.writeSelection(to: pasteboard, types: h.textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "* a\nbody\n** b\nmore\n* c\n")
    }

    @Test func foldsFollowEdits() {
        let h = Harness(outline)
        h.caret(at: h.offset(of: "* c") + 1)
        h.editor.toggleFoldAtCaret()
        h.caret(at: 0)
        h.textView.insertText("new ", replacementRange: NSRange(location: 2, length: 0))
        #expect(h.visibleLines == ["* new a\n", "body\n", "** b\n", "more\n", "* c\n"])
        h.checkInSync()
    }
}

@MainActor
struct EditingTests {
    @Test func typingKeepsTheDocumentInSync() {
        let h = Harness(outline)
        h.caret(at: h.offset(of: "body") + 4)
        h.textView.insertText(" *bold*", replacementRange: h.textView.selectedRange())
        h.textView.insertNewline(nil)
        h.textView.insertText("* new heading", replacementRange: h.textView.selectedRange())
        h.textView.deleteBackward(nil)
        h.checkInSync()
        #expect(h.editor.document.isDirty)
    }

    @Test func inputMethodComposition() {
        let h = Harness("* a\n")
        h.caret(at: 3)
        h.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.textView.hasMarkedText())
        h.textView.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!h.textView.hasMarkedText())
        #expect(h.string == "* a漢\n")
        h.checkInSync()
    }

    @Test func undoKeepsTheDocumentInSync() {
        let h = Harness(outline)
        h.caret(at: 3)
        h.textView.insertText("xyz", replacementRange: h.textView.selectedRange())
        h.textView.breakUndoCoalescing()
        h.textView.undoManager?.undo()
        #expect(h.string == outline)
        h.checkInSync()
    }

    @Test func styling() throws {
        let h = Harness("** b\nbody\n")
        let storage = try #require(h.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .clear)
        let style = try #require(storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == 3 * h.editor.theme.column)
        h.caret(at: 0)
        h.textView.insertText("*", replacementRange: NSRange(location: 0, length: 0))
        let deeper = try #require(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(deeper.firstLineHeadIndent == 4 * h.editor.theme.column)
    }

    @Test func accessibilityReadsTheWholeText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.toggleFoldAtCaret()
        #expect(h.textView.accessibilityValue() as? String == outline)
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(h.textView.accessibilitySelectedText() == "* a")
        #expect(h.textView.accessibilityLine(for: h.offset(of: "* c")) >= 1)
    }

    @Test func saveWritesAndClearsDirty() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        try Data(outline.utf8).write(to: file)
        let h = Harness(outline)
        h.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        let saver = Saver(fileSystem: CoordinatedFileSystem(), recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        #expect(try h.editor.save(using: saver, to: file) == .saved)
        #expect(!h.editor.document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x" + outline)
    }
}

@MainActor
struct RestyleTests {
    func indent(_ h: Harness, at line: String) -> CGFloat? {
        let style = h.textView.textStorage?.attribute(.paragraphStyle, at: h.offset(of: line), effectiveRange: nil) as? NSParagraphStyle
        return style.map { $0.firstLineHeadIndent / h.editor.theme.column }
    }

    @Test func newHeadingReindentsTheLinesItTakesOver() {
        let h = Harness("* a\none\ntwo\nthree\n")
        h.textView.insertText("** b\n", replacementRange: NSRange(location: h.offset(of: "two"), length: 0))
        #expect(indent(h, at: "one") == 2)
        #expect(indent(h, at: "three") == 3)
        h.checkInSync()
    }

    @Test func joiningAwayAHeadingReindentsItsBody() {
        let h = Harness("* a\none\n** b\ntwo\nthree\n")
        h.textView.insertText("", replacementRange: NSRange(location: h.offset(of: "** b") - 1, length: 1))
        #expect(indent(h, at: "three") == 2)
        h.checkInSync()
    }

    @Test func typingASpaceAfterAStarMakesAHeading() {
        let h = Harness("* a\n*x\nbody\nmore\n")
        h.textView.insertText(" ", replacementRange: NSRange(location: h.offset(of: "*x") + 1, length: 0))
        #expect(indent(h, at: "more") == 2)
        h.checkInSync()
    }
}

@MainActor
struct RestyleFuzzTests {
    /// After each random edit, the restyled text must equal a fresh editor's full styling. Set
    /// `ORGSTAR_RESTYLE_EDITS` and `ORGSTAR_FUZZ_SEED` for longer runs.
    @Test func incrementalRestyleEqualsFullRestyle() throws {
        let environment = ProcessInfo.processInfo.environment
        var state = UInt64(environment["ORGSTAR_FUZZ_SEED"] ?? "") ?? 20261006
        let count = Int(environment["ORGSTAR_RESTYLE_EDITS"] ?? "") ?? 300
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["* ", "** ", "*", " ", "\n", "x", "*b*", "TODO ", "- ", "| a |", "#+begin_src\n", "#+end_src\n", ":PROPERTIES:\n", ":END:\n", "[[l][d]]", "<2026-10-04 Sun>"]
        let h = Harness("* a\nbody *b*\n** b\n- item\nmore\n* c\ntext\n")
        for n in 0..<count {
            let length = (h.string as NSString).length
            let start = next(length + 1)
            let end = min(length, start + next(4))
            let replacement = next(3) == 0 ? "" : pieces[next(pieces.count)]
            h.textView.insertText(replacement, replacementRange: NSRange(location: start, length: end - start))
            let fresh = Harness(h.string)
            let same = h.textView.textStorage!.isEqual(to: fresh.textView.textStorage!)
            #expect(same, "edit \(n): \(start)..<\(end) \(replacement.debugDescription) -> \(h.string.debugDescription)")
            if !same { break }
        }
        h.checkInSync()
    }
}
```

- [x] **Step 3: Implement `Theme.swift`**

```swift
#if os(macOS)
import AppKit
import OrgPresentation

/// Attributes for each style role. A fixed theme for now; the app's theme settings replace it.
@MainActor
struct Theme {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    /// Width of one column of the monospaced font.
    var column: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    func paragraphStyle(firstLine: Int, wrapped: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(firstLine) * column
        style.headIndent = CGFloat(wrapped) * column
        return style
    }

    func apply(_ role: StyleRole, to storage: NSTextStorage, range: NSRange) {
        switch role {
        case .heading(let level):
            let size = font.pointSize + CGFloat(max(0, 4 - level))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold), range: range)
        case .leadingStars:
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        case .todo:
            storage.addAttributes([.foregroundColor: NSColor.systemRed, .font: bold(storage, range)], range: range)
        case .done:
            storage.addAttributes([.foregroundColor: NSColor.systemGreen, .font: bold(storage, range)], range: range)
        case .priority:
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
        case .tags, .comment, .keyword, .metadata:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .bold:
            storage.addAttribute(.font, value: bold(storage, range), range: range)
        case .italic:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .italicFontMask), range: range)
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .strikeThrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .verbatim, .code, .inlineSource:
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
        case .markup, .linkMarkup, .blockDelimiter:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .link:
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .timestamp:
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
        case .footnote, .cookie, .target, .macro, .latex:
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
        case .block:
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
        case .table, .rule:
            break
        }
    }

    private func currentFont(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? font
    }

    private func bold(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .boldFontMask)
    }
}
#endif
```

- [x] **Step 4: Implement `OrgEditor.swift`**

```swift
#if os(macOS)
import AppKit
import OrgCore
import OrgDocument
import OrgPresentation

/// Hidden ranges, read by TextKit's enumeration callbacks, which may run off the main thread.
final class HiddenRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>] = []

    func set(_ new: [Range<Int>]) {
        lock.withLock { ranges = new }
    }

    var all: [Range<Int>] {
        lock.withLock { ranges }
    }

    func covers(_ start: Int, _ end: Int) -> Bool {
        lock.withLock { ranges.contains { $0.lowerBound <= start && end <= $0.upperBound } }
    }

    func containing(_ offset: Int) -> Range<Int>? {
        lock.withLock { ranges.first { $0.lowerBound <= offset && offset < $0.upperBound } }
    }
}

/// Folded heading starts, read by the layout-fragment callback.
final class FoldedHeadings: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: Set<Int> = []

    func set(_ new: Set<Int>) {
        lock.withLock { starts = new }
    }

    func contains(_ offset: Int) -> Bool {
        lock.withLock { starts.contains(offset) }
    }
}

/// A TextKit 2 text view over a `DocumentState`. The text storage mirrors the document; every
/// character edit goes through `DocumentState.apply`, and only the affected region is restyled.
@MainActor
public final class OrgEditor: NSObject {
    public let textView: NSTextView
    public private(set) var document: DocumentState
    public private(set) var view = ViewState()
    /// Called with the time from a character edit to restyled text.
    public var onEditTiming: ((Duration) -> Void)?

    let hidden = HiddenRanges()
    let folded = FoldedHeadings()
    let theme = Theme()
    private var isLoading = false
    private var previousSelection = 0

    public init(document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800)) {
        self.document = document
        textView = NSTextView(usingTextLayoutManager: true)
        super.init()
        textView.frame = frame
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = theme.font
        textView.typingAttributes = theme.base
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        textLayoutManager.delegate = self
        textContentStorage.delegate = self

        isLoading = true
        textView.string = document.text
        isLoading = false
        restyleOutsideEditing(0..<utf16Length)
    }

    public var textLayoutManager: NSTextLayoutManager { textView.textLayoutManager! }
    var textContentStorage: NSTextContentStorage { textLayoutManager.textContentManager as! NSTextContentStorage }
    var utf16Length: Int { (textView.string as NSString).length }

    /// A scroll view holding the text view, ready for a window.
    public func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    // MARK: - Saving

    /// Saves through `saver`. When a merge changes the buffer, the text view is reloaded and
    /// folds are mapped through the change.
    @discardableResult
    public func save(using saver: Saver, to url: URL) throws -> SaveOutcome {
        let before = document.text
        let outcome = try saver.save(&document, to: url)
        if document.text != before {
            let edits = lineEdits(from: before, to: document.text)
            isLoading = true
            textView.string = document.text
            isLoading = false
            restyleOutsideEditing(0..<utf16Length)
            setFolds(view.mapped(through: edits).folds)
        }
        return outcome
    }

    // MARK: - Folding

    public func setFolds(_ folds: Set<Int>) {
        view.folds = folds
        view = view.pruned(to: document.tree)
        folded.set(view.folds)
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds))
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(range.lowerBound - 1) }
    }

    /// Folds or unfolds the heading whose line holds the caret. Returns false off a heading.
    @discardableResult
    public func toggleFoldAtCaret() -> Bool {
        guard let heading = Presentation.heading(containing: textView.selectedRange().location, in: document.tree) else { return false }
        var folds = view.folds
        if folds.contains(heading) { folds.remove(heading) } else { folds.insert(heading) }
        setFolds(folds)
        return true
    }

    /// Folds every heading, or unfolds everything if anything is folded.
    public func toggleAllFolds() {
        setFolds(view.folds.isEmpty ? Set(Presentation.headings(document.tree)) : [])
    }

    private func setCaret(_ offset: Int) {
        let clamped = max(0, min(offset, utf16Length))
        previousSelection = clamped
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    // MARK: - Styling

    private func restyleOutsideEditing(_ range: Range<Int>) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        restyle(range, in: storage)
        storage.endEditing()
    }

    /// Sets attributes for whole lines in `range`. Safe inside `didProcessEditing`, where
    /// attribute changes are allowed and characters must not change.
    private func restyle(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !range.isEmpty else { return }
        let whole = NSRange(range)
        storage.setAttributes(theme.base, range: whole)
        for run in Presentation.indents(document.tree, in: range) {
            guard let clipped = clip(run.range, to: range) else { continue }
            storage.addAttribute(.paragraphStyle, value: theme.paragraphStyle(firstLine: run.firstLine, wrapped: run.wrapped), range: clipped)
        }
        for run in Presentation.styles(document.tree, in: range) {
            guard let clipped = clip(run.range, to: range) else { continue }
            theme.apply(run.role, to: storage, range: clipped)
        }
    }

    private func clip(_ run: Range<Int>, to range: Range<Int>) -> NSRange? {
        let clipped = run.clamped(to: range)
        return clipped.isEmpty ? nil : NSRange(clipped)
    }

    /// The region an edit affects in one version of the tree: inside the innermost section
    /// holding the edited lines (plus the line after), every element that overlaps them or the
    /// line on either side. A changed heading line, or an added or removed heading, widens it
    /// to that section's whole own body. Run on the old and the new tree, the union covers
    /// elements that grew and elements that shrank.
    static func affectedRange(_ tree: OrgTree, _ text: NSString, _ start: Int, _ end: Int, touchedHeadings: Bool) -> Range<Int> {
        let lines = text.lineRange(for: NSRange(location: start, length: min(end + 1, text.length) - start))
        let lineRange = lines.location..<(lines.location + lines.length)
        let around = max(0, lineRange.lowerBound - 1)..<min(text.length, lineRange.upperBound + 1)
        var container = tree.root
        while let child = container.children.first(where: {
            ($0.kind == .section || $0.kind == .zerothSection)
                && $0.range.lowerBound <= lineRange.lowerBound && lineRange.upperBound <= $0.range.upperBound
        }) {
            container = child
        }
        var lower = lineRange.lowerBound
        var upper = lineRange.upperBound
        let children = container.children
        for child in children where child.range.overlaps(around) {
            lower = min(lower, child.range.lowerBound)
            upper = max(upper, child.range.upperBound)
        }
        let heading = children.first { $0.kind == .heading }
        if touchedHeadings || heading.map({ $0.range.overlaps(lineRange) }) == true {
            lower = min(lower, container.range.lowerBound)
            upper = max(upper, children.first { $0.kind == .section }?.range.lowerBound ?? container.range.upperBound)
        }
        return lower..<min(upper, text.length)
    }

    // MARK: - Editing

    fileprivate func storageEdited(range: NSRange, delta: Int) {
        guard !isLoading, let storage = textView.textStorage else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let replacement = (storage.string as NSString).substring(with: range)
        let edit = TextEdit(range: range.location..<(range.location + range.length - delta), replacement: replacement)
        let oldText = document.text as NSString
        let newText = storage.string as NSString
        let newEnd = edit.range.lowerBound + replacement.utf16.count
        let touchedHeadings = Self.headingLineNear(edit.range.lowerBound, edit.range.upperBound, in: oldText)
            || Self.headingLineNear(edit.range.lowerBound, newEnd, in: newText)
        let oldAffected = Self.affectedRange(document.tree, oldText, edit.range.lowerBound, edit.range.upperBound, touchedHeadings: touchedHeadings)
        do {
            try document.apply([edit], baseRevision: document.revision)
        } catch {
            assertionFailure("text view and document disagree: \(error)")
            return
        }
        let oldHidden = hidden.all
        view = view.mapped(through: [edit]).pruned(to: document.tree)
        folded.set(view.folds)
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds))
        let newAffected = Self.affectedRange(document.tree, newText, edit.range.lowerBound, newEnd, touchedHeadings: touchedHeadings)
        let delta = edit.replacement.utf16.count - edit.range.count
        let oldMapped = oldAffected.lowerBound..<(oldAffected.upperBound >= edit.range.upperBound ? oldAffected.upperBound + delta : newEnd)
        restyle(min(oldMapped.lowerBound, newAffected.lowerBound)..<min(max(oldMapped.upperBound, newAffected.upperBound), newText.length), in: storage)
        if hidden.all != oldHidden.map({ mapRange($0, through: edit) }) {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
        onEditTiming?(clock.now - start)
    }

    /// Whether a heading line touches `start..<end` or starts right after it, where joining
    /// lines could take it away.
    static func headingLineNear(_ start: Int, _ end: Int, in text: NSString) -> Bool {
        let length = min(end + 1, text.length) - start
        guard length >= 0 else { return false }
        let lines = text.substring(with: text.lineRange(for: NSRange(location: start, length: length)))
        return lines.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let stars = line.prefix { $0 == "*" }
            let after = line.dropFirst(stars.count)
            return !stars.isEmpty && (after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r")
        }
    }

    private func mapRange(_ range: Range<Int>, through edit: TextEdit) -> Range<Int> {
        let mapped = ViewState(selection: [range]).mapped(through: [edit]).selection[0]
        return mapped
    }

    /// Keeps the caret out of folded text: moving forward into a fold jumps past it, moving
    /// back jumps to the end of the heading line.
    fileprivate func selectionChanged() {
        let selection = textView.selectedRange()
        defer { previousSelection = selection.location }
        guard selection.length == 0, let range = hidden.containing(selection.location) else { return }
        setCaret(selection.location >= previousSelection ? range.upperBound : range.lowerBound - 1)
    }
}

extension OrgEditor: NSTextViewDelegate {
    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): return toggleFoldAtCaret()
        case #selector(NSResponder.insertBacktab(_:)):
            toggleAllFolds()
            return true
        default: return false
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }
}

extension OrgEditor: NSTextStorageDelegate {
    public nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { storageEdited(range: editedRange, delta: delta) }
    }
}

extension OrgEditor: NSTextContentStorageDelegate {
    /// Folded text isn't enumerated, so it isn't laid out or drawn.
    public nonisolated func textContentManager(
        _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let documentStart = textContentManager.documentRange.location
        let start = textContentManager.offset(from: documentStart, to: range.location)
        let end = textContentManager.offset(from: documentStart, to: range.endLocation)
        return !hidden.covers(start, end)
    }
}

extension OrgEditor: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let range, let manager = textLayoutManager.textContentManager {
            let offset = manager.offset(from: manager.documentRange.location, to: range.location)
            if folded.contains(offset) { return FoldedHeadingFragment(textElement: textElement, range: range) }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A heading line drawn with an ellipsis after it, like org's folded headings.
final class FoldedHeadingFragment: NSTextLayoutFragment, @unchecked Sendable {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let ellipsis = NSAttributedString(string: " …", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        NSGraphicsContext.restoreGraphicsState()
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0)
    }
}
#endif
```

- [x] **Step 5: Run, including longer fuzz runs, then commit**

Run: `swift test`, then `ORGSTAR_RESTYLE_EDITS=1500 ORGSTAR_FUZZ_SEED=<n> swift test --filter RestyleFuzzTests` for several seeds.

```bash
git add Package.swift Sources/OrgDocument/ViewState.swift Sources/OrgEditorAppKit Tests/OrgEditorAppKitTests
git commit -m "Add TextKit 2 editor with folding and incremental restyle"
```

---

### Task 3: Spike app

**Files:**
- Modify: `Package.swift` (add the `OrgstarSpike` executable)
- Create: `Sources/OrgstarSpike/main.swift`

- [x] **Step 1: Implement**

```swift
#if os(macOS)
import AppKit
import OrgDocument
import OrgEditorAppKit

/// A throwaway app for trying the editor by hand: `swift run OrgstarSpike path/to/file.org`.
/// TAB on a heading folds it, Shift-TAB folds everything, ⌘S saves. Edit timings are printed
/// every 50 edits.
@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    let url: URL
    var editor: OrgEditor?
    var window: NSWindow?
    var timings: [Duration] = []

    init(url: URL) {
        self.url = url
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bytes = (try? [UInt8](Data(contentsOf: url))) ?? []
        let editor = OrgEditor(document: DocumentState(bytes: bytes), frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        editor.onEditTiming = { [weak self] in self?.record($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 1000),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.contentView = editor.makeScrollView()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        self.editor = editor
        self.window = window
        buildMenu()
        NSApp.activate()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        fileItem.submenu = NSMenu(title: "File")
        fileItem.submenu?.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s").target = self
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editItem.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editItem.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editItem.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        [appItem, fileItem, editItem].forEach(main.addItem)
        NSApp.mainMenu = main
    }

    @objc func save() {
        guard let editor else { return }
        let recovery = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orgstar/Recovery")
        let saver = Saver(fileSystem: CoordinatedFileSystem(), recovery: FileRecoveryStore(directory: recovery))
        do {
            print("save:", try editor.save(using: saver, to: url))
        } catch {
            print("save failed:", error)
        }
    }

    func record(_ duration: Duration) {
        timings.append(duration)
        guard timings.count % 50 == 0 else { return }
        let sorted = timings.sorted()
        print("edits: \(timings.count)  p50 \(sorted[sorted.count / 2])  p95 \(sorted[sorted.count * 95 / 100])")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: OrgstarSpike path/to/file.org")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = SpikeDelegate(url: URL(fileURLWithPath: CommandLine.arguments[1]))
app.delegate = delegate
app.run()
#endif
```

- [x] **Step 2: Run by hand, measure, commit** (measured; the VoiceOver checklist did not run)

Run: `swift run -c release OrgstarSpike <large file>`; type, fold with TAB and Shift-TAB, save with ⌘S, watch the printed p50/p95; then the VoiceOver checklist above.

```bash
git add Package.swift Sources/OrgstarSpike
git commit -m "Add spike app"
```
