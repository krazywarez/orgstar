# Incremental Reparse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Given the old tree and one `TextEdit`, produce the new tree without a full parse, always equal to a full parse of the new text.

**Architecture:** Three strategies, tried in order. (1) Full parse when the edit touches a settings keyword line, or moves a block or heading boundary in a file that has settings keywords. (2) Element: when the edit sits inside one leaf element (paragraph, heading, table row, block, keyword, ...) and every line of that element keeps its class and indent, reparse just that element and copy the path from the root. (3) Sections: reparse from the top-level section before the edit until a later top-level heading still ends the reparsed run, and reuse the old top-level sections around it; top-level sections parse independently because blocks and drawers never cross a heading. A randomized differential test compares every result with a full parse.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Foundation only.

**Spec:** `docs/design.md`, "Incremental reparse".

## Global Constraints

- The result always equals a full parse of the new text (green trees compare equal).
- Edits use UTF-16 ranges on unicode scalar boundaries; `TextEdit.apply` works on scalars so an edit between `\r` and `\n` stays exact.
- Gate: 0 mismatches over 100,000 random edits in a release build (`ORGSTAR_FUZZ_EDITS=100000 swift test -c release --filter incrementalEqualsFull`).

## Deviation from the spec

The spec reparses structural edits from the innermost enclosing section. This plan uses top-level sections: simpler, provably independent, and enough for the differential gate. A file that is one large top-level section reparses whole on a structural edit; the performance plan measures that case and narrows the window if the 16 ms gate needs it.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgCore/Parser/Parser.swift` | `Parser(text:settings:)` to parse part of a file with known settings |
| `Sources/OrgCore/Parser/Incremental.swift` | `TextEdit`, `OrgParser.reparse`, strategies, `Parser.reparseElement` |
| `Tests/OrgCoreTests/IncrementalTests.swift` | Strategy tests and the differential fuzz test |

---

### Task 1: Incremental reparse

**Files:**
- Modify: `Sources/OrgCore/Parser/Parser.swift`
- Create: `Sources/OrgCore/Parser/Incremental.swift`
- Test: `Tests/OrgCoreTests/IncrementalTests.swift`

**Interfaces:**
- Consumes: `Parser`, `splitRawLines`, `classifyLine`, `SyntaxNode`, `GreenNode`, `randomDocument`/`fragments`/`SeededGenerator` from `RoundTripTests.swift`.
- Produces: `TextEdit(range:replacement:)` with `apply(to:)`; `OrgParser.reparse(_:oldText:edit:defaults:) -> OrgTree`; internal `OrgParser.reparseWithStrategy` returning `(tree, ReparseStrategy)` with `.element`, `.sections`, `.full`; `Parser(text:settings:)`; `Parser.reparseElement(_:text:settings:) -> GreenNode?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import OrgCore

/// Reparses `text` after an edit, checks the result against a full parse, and returns the
/// strategy used.
@discardableResult
func checkReparse(_ text: String, _ range: Range<Int>, _ replacement: String) -> ReparseStrategy {
    let old = OrgParser.parse(text)
    let edit = TextEdit(range: range, replacement: replacement)
    let result = OrgParser.reparseWithStrategy(old, oldText: text, edit: edit)
    let expected = OrgParser.parse(edit.apply(to: text))
    #expect(result.tree.text == expected.text)
    #expect(result.tree.green == expected.green)
    return result.strategy
}

/// UTF-16 offsets of every unicode scalar boundary.
func scalarOffsets(_ text: String) -> [Int] {
    var offsets = [0]
    var offset = 0
    for scalar in text.unicodeScalars {
        offset += scalar.utf16.count
        offsets.append(offset)
    }
    return offsets
}

struct IncrementalTests {
    @Test func applyKeepsCRLFHalves() {
        #expect(TextEdit(range: 1..<1, replacement: "x").apply(to: "\r\n") == "\rx\n")
        #expect(TextEdit(range: 1..<3, replacement: "").apply(to: "a😀b") == "ab")
    }

    @Test func typingInAParagraphReparsesOneElement() {
        #expect(checkReparse("* a\nhello world\n* b\n", 10..<10, "big ") == .element)
        #expect(checkReparse("- item *one*\n  - two\n", 8..<8, "x") == .element)
    }

    @Test func typingAtTheStartOfAnItemParagraph() {
        #expect(checkReparse(" >\n1. one", 6..<6, " ") != .element)
    }

    @Test func changingATodoKeywordReparsesOneElement() {
        #expect(checkReparse("* TODO a\nbody\n", 2..<6, "DONE") == .element)
    }

    @Test func newHeadingReparsesSections() {
        #expect(checkReparse("* a\nx\ny\n* b\n", 6..<6, "* c\n") == .sections)
    }

    @Test func joiningParagraphsReparsesSections() {
        #expect(checkReparse("a\n\nb\n", 1..<2, "") == .sections)
    }

    @Test func runGrowsUntilAHeadingEndsIt() {
        #expect(checkReparse("** a\n** b\n* c\n", 0..<0, "* x\n") == .sections)
    }

    @Test func settingsLineForcesFullParse() {
        #expect(checkReparse("#+TODO: A | B\n* A x\n", 8..<9, "C") == .full)
    }

    @Test func exposingAKeywordInsideABlockForcesFullParse() {
        let text = "#+begin_example\n#+TODO: X\n#+end_example\n* X a\n"
        #expect(checkReparse(text, 26..<40, "") == .full)
    }

    @Test func editsAtTheEdges() {
        checkReparse("", 0..<0, "* a\n")
        checkReparse("* a\n", 0..<4, "")
        checkReparse("* a", 3..<3, "\n")
        checkReparse("a\r\nb\r\n", 1..<1, "x")
    }

    /// Set `ORGSTAR_FUZZ_EDITS` to run more (the phase 1 gate is 100,000 in a release build) and
    /// `ORGSTAR_FUZZ_SEED` to try another sequence.
    @Test func incrementalEqualsFull() {
        let environment = ProcessInfo.processInfo.environment
        var rng = SeededGenerator(state: UInt64(environment["ORGSTAR_FUZZ_SEED"] ?? "") ?? 20261005)
        let count = Int(environment["ORGSTAR_FUZZ_EDITS"] ?? "") ?? 3_000
        let small = ["a", " ", "*", "/", "=", "[", "]", "<", ">", "-", ":", "|", "#", "+", "\n", "\r\n", "😀", "é"]
        for n in 0..<count {
            let text = randomDocument(&rng)
            let offsets = scalarOffsets(text)
            let a = offsets.randomElement(using: &rng)!
            let later = offsets.filter { $0 >= a && $0 <= a + 12 }
            let b = Bool.random(using: &rng) ? a : later.randomElement(using: &rng)!
            let replacement: String
            if Int.random(in: 0..<10, using: &rng) < 7 {
                replacement = (0..<Int.random(in: 0...2, using: &rng)).map { _ in small.randomElement(using: &rng)! }.joined()
            } else {
                replacement = fragments.randomElement(using: &rng)! + (Bool.random(using: &rng) ? "\n" : "")
            }
            let old = OrgParser.parse(text)
            let edit = TextEdit(range: a..<b, replacement: replacement)
            let tree = OrgParser.reparse(old, oldText: text, edit: edit)
            let expected = OrgParser.parse(edit.apply(to: text))
            #expect(tree.green == expected.green, "edit \(n): \(a)..<\(b) \(replacement.debugDescription) in \(text.debugDescription)")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter IncrementalTests`
Expected: build failure, `cannot find 'TextEdit' in scope`.

- [ ] **Step 3: Let the parser take known settings**

```diff
@@ -16,10 +16,25 @@ struct Parser {
     var i = 0
 
     init(text: String, defaults: OrgSettings) {
-        lines = splitRawLines(text)
-        info = lines.map { classifyLine($0.content) }
-        blockEnds = Parser.matchEnds(info)
-        settings = SettingsScanner.scan(lines: lines, info: info, blockEnds: blockEnds, defaults: defaults)
+        let lines = splitRawLines(text)
+        let info = lines.map { classifyLine($0.content) }
+        let ends = Parser.matchEnds(info)
+        let settings = SettingsScanner.scan(lines: lines, info: info, blockEnds: ends, defaults: defaults)
+        self.init(lines: lines, info: info, blockEnds: ends, settings: settings)
+    }
+
+    /// Parses part of a document with the settings already read from the whole file.
+    init(text: String, settings: OrgSettings) {
+        let lines = splitRawLines(text)
+        let info = lines.map { classifyLine($0.content) }
+        self.init(lines: lines, info: info, blockEnds: Parser.matchEnds(info), settings: settings)
+    }
+
+    private init(lines: [RawLine], info: [ClassifiedLine], blockEnds: [Int: Int], settings: OrgSettings) {
+        self.lines = lines
+        self.info = info
+        self.blockEnds = blockEnds
+        self.settings = settings
     }
 
     static func matchEnds(_ info: [ClassifiedLine]) -> [Int: Int] {
```

- [ ] **Step 4: Implement `Incremental.swift`**

```swift
import Foundation

public struct TextEdit: Sendable, Equatable {
    /// UTF-16 range in the old text, on unicode scalar boundaries.
    public let range: Range<Int>
    public let replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// Works on unicode scalars, so an edit between "\r" and "\n" stays exact.
    public func apply(to text: String) -> String {
        let scalars = text.unicodeScalars
        let start = String.Index(utf16Offset: range.lowerBound, in: text)
        let end = String.Index(utf16Offset: range.upperBound, in: text)
        return String(scalars[..<start]) + replacement + String(scalars[end...])
    }
}

enum ReparseStrategy: Equatable {
    /// One element reparsed in place; everything else reused.
    case element
    /// A run of top-level sections reparsed; the sections before and after reused.
    case sections
    case full
}

extension OrgParser {
    /// The tree for `edit.apply(to: oldText)`, reusing as much of `old` as stays valid. Always
    /// equal to a full parse of the new text.
    public static func reparse(_ old: OrgTree, oldText: String, edit: TextEdit, defaults: OrgSettings = .default) -> OrgTree {
        reparseWithStrategy(old, oldText: oldText, edit: edit, defaults: defaults).tree
    }

    static func reparseWithStrategy(
        _ old: OrgTree, oldText: String, edit: TextEdit, defaults: OrgSettings = .default
    ) -> (tree: OrgTree, strategy: ReparseStrategy) {
        let newText = edit.apply(to: oldText)
        let context = EditContext(oldText: oldText, newText: newText, edit: edit)
        if context.touchesSettings() { return (parse(newText, defaults: defaults), .full) }
        if let tree = context.reparseElement(old) { return (tree, .element) }
        if let tree = context.reparseSections(old) { return (tree, .sections) }
        return (parse(newText, defaults: defaults), .full)
    }
}

private struct EditContext {
    let oldText: String
    let newText: String
    let edit: TextEdit
    /// Change in UTF-16 length.
    var delta: Int { edit.replacement.utf16.count - edit.range.count }

    static let settingsKeys: Set<String> = ["TODO", "SEQ_TODO", "TYP_TODO", "PRIORITIES"]

    /// Elements that parse the same in isolation as in place, as long as their lines keep
    /// their classes.
    static let leafKinds: Set<SyntaxKind> = [
        .paragraph, .heading, .tableRow, .planning, .clock, .keyword, .affiliatedKeyword, .horizontalRule,
        .nodeProperty, .block, .comment, .fixedWidth, .footnoteDefinition,
    ]

    /// File settings must be read again when an edited line is a settings keyword, or when it
    /// moves a block or heading boundary in a file that has settings keywords: that can hide or
    /// expose a keyword inside a block.
    func touchesSettings() -> Bool {
        let start = lineStart(oldText, edit.range.lowerBound)
        let oldLines = classes(slice(oldText, start, lineEnd(oldText, edit.range.upperBound)))
        let newLines = classes(slice(newText, start, lineEnd(newText, edit.range.lowerBound + edit.replacement.utf16.count)))
        var movesBoundary = false
        for line in oldLines + newLines {
            switch line.cls {
            case .keyword(let key) where Self.settingsKeys.contains(key):
                return true
            case .blockBegin, .blockEnd, .dynamicBegin, .dynamicEnd, .heading:
                movesBoundary = true
            default:
                break
            }
        }
        return movesBoundary && Self.settingsKeys.contains { newText.range(of: "#+\($0):", options: .caseInsensitive) != nil }
    }

    // MARK: - Element

    func reparseElement(_ old: OrgTree) -> OrgTree? {
        guard let leaf = leaf(in: old.root) else { return nil }
        let start = lineStart(oldText, leaf.range.lowerBound)
        // An element that starts mid-line (an item's paragraph) follows tokens that would absorb
        // whitespace typed at its start.
        guard start == leaf.range.lowerBound || edit.range.lowerBound > leaf.range.lowerBound else { return nil }
        let oldEnd = leaf.range.upperBound
        let newEnd = oldEnd + delta
        let newLength = newText.utf16.count
        guard newEnd > leaf.range.lowerBound, newEnd <= newLength else { return nil }
        // The element must still end at a line end.
        if newEnd < newLength {
            let utf16 = newText.utf16
            guard utf16[utf16.index(utf16.startIndex, offsetBy: newEnd - 1)] == 0x0A else { return nil }
        }
        let oldClasses = classes(slice(oldText, start, oldEnd))
        let newClasses = classes(slice(newText, start, newEnd))
        guard oldClasses.count == newClasses.count,
              zip(oldClasses, newClasses).allSatisfy({ $0.cls == $1.cls && $0.indent == $1.indent }) else { return nil }
        let text = String(slice(newText, leaf.range.lowerBound, newEnd))
        guard let green = Parser.reparseElement(leaf.kind, text: text, settings: old.settings) else { return nil }
        return OrgTree(green: replacing(leaf, with: green), settings: old.settings)
    }

    /// The outermost leaf element containing the edit.
    func leaf(in root: SyntaxNode) -> SyntaxNode? {
        let range = edit.range
        var current = root
        while let child = current.children.first(where: {
            $0.range.lowerBound <= range.lowerBound && range.lowerBound < $0.range.upperBound
                && range.upperBound <= $0.range.upperBound
        }) {
            if Self.leafKinds.contains(child.kind) { return child }
            current = child
        }
        return nil
    }

    /// Copies the path from the root down to `target`, swapping in `green`.
    func replacing(_ target: SyntaxNode, with green: GreenNode) -> GreenNode {
        var node = target
        var replacement = green
        while let parent = node.parent {
            var children = parent.green.children
            let index = children.firstIndex {
                if case .node(let child) = $0 { return child === node.green }
                return false
            }!
            children[index] = .node(replacement)
            replacement = GreenNode(kind: parent.kind, children: children)
            node = parent
        }
        return replacement
    }

    // MARK: - Sections

    /// Reparses from the top-level section before the edit up to the first later top-level
    /// heading that still ends the reparsed run, then reuses the old sections from there.
    /// Top-level sections parse independently: blocks and drawers never cross a heading.
    func reparseSections(_ old: OrgTree) -> OrgTree? {
        let units = old.root.children
        guard !units.isEmpty else { return nil }
        let anchor = max(0, lineStart(oldText, edit.range.lowerBound) - 1)
        guard let startIndex = units.firstIndex(where: { $0.range.contains(anchor) }) else { return nil }
        let start = units[startIndex].range.lowerBound
        var endIndex = units.firstIndex { $0.range.lowerBound > edit.range.upperBound } ?? units.count
        let newLength = newText.utf16.count
        while true {
            let newEnd = endIndex < units.count ? units[endIndex].range.lowerBound + delta : newLength
            var parser = Parser(text: String(slice(newText, start, newEnd)), settings: old.settings)
            let window = parser.run().green
            if endIndex == units.count || endsRun(window, next: units[endIndex].green) {
                let children = units[..<startIndex].map { GreenElement.node($0.green) }
                    + window.children
                    + units[endIndex...].map { GreenElement.node($0.green) }
                return OrgTree(green: GreenNode(kind: .document, children: children), settings: old.settings)
            }
            endIndex += 1
        }
    }

    /// Whether the heading of `next` ends the last section of the reparsed window.
    func endsRun(_ window: GreenNode, next: GreenNode) -> Bool {
        guard case .node(let last)? = window.children.last, last.kind == .section else { return true }
        return headingLevel(next) <= headingLevel(last)
    }

    func headingLevel(_ section: GreenNode) -> Int {
        for case .node(let heading) in section.children where heading.kind == .heading {
            for case .token(let token) in heading.children where token.kind == .stars {
                return token.text.count
            }
        }
        return 0
    }

    // MARK: - Text helpers

    func classes(_ text: Substring) -> [ClassifiedLine] {
        splitRawLines(String(text)).map { classifyLine($0.content) }
    }

    func slice(_ text: String, _ from: Int, _ to: Int) -> Substring {
        text[String.Index(utf16Offset: from, in: text)..<String.Index(utf16Offset: to, in: text)]
    }

    /// UTF-16 offset of the start of the line containing `offset`.
    func lineStart(_ text: String, _ offset: Int) -> Int {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        while index > utf16.startIndex {
            let before = utf16.index(before: index)
            if utf16[before] == 0x0A { break }
            index = before
        }
        return utf16.distance(from: utf16.startIndex, to: index)
    }

    /// UTF-16 offset just past the newline ending the line containing `offset`.
    func lineEnd(_ text: String, _ offset: Int) -> Int {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        while index < utf16.endIndex {
            let current = utf16[index]
            index = utf16.index(after: index)
            if current == 0x0A { break }
        }
        return utf16.distance(from: utf16.startIndex, to: index)
    }
}

extension Parser {
    /// One element of `kind` parsed from exactly `text`, or nil if `text` doesn't parse as a
    /// single element of that kind.
    static func reparseElement(_ kind: SyntaxKind, text: String, settings: OrgSettings) -> GreenNode? {
        var parser = Parser(text: text, settings: settings)
        let count = parser.lines.count
        guard count > 0 else { return nil }
        switch kind {
        case .paragraph:
            parser.paragraph(limit: count, floor: nil)
        case .heading:
            guard count == 1 else { return nil }
            parser.headingLine(parser.lines[0])
            parser.i = 1
        case .tableRow:
            guard count == 1 else { return nil }
            parser.tableRow()
        case .planning, .clock, .keyword, .affiliatedKeyword, .horizontalRule, .nodeProperty:
            guard count == 1 else { return nil }
            parser.single(kind)
        case .block, .comment, .fixedWidth, .footnoteDefinition:
            parser.element(limit: count, floor: nil)
        default:
            return nil
        }
        guard parser.i == count else { return nil }
        let green = parser.builder.build()
        return green.kind == kind ? green : nil
    }
}
```

- [ ] **Step 5: Run all tests, then the gate**

Run: `swift test`
Expected: all pass.

Run: `ORGSTAR_FUZZ_EDITS=100000 swift test -c release --filter incrementalEqualsFull`, and again with `ORGSTAR_FUZZ_SEED=1`, `2`, `3`.
Expected: pass. A failure prints the edit and the document; reduce it to a unit test before fixing.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "Add incremental reparse"
```
