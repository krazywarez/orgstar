# OrgCore Parser Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package, `OrgCore`, that turns org file bytes into a lossless syntax tree of block-level elements, with the byte and encoding contract from the design.

**Architecture:** Bytes decode into `SourceText` (UTF-8 only, BOM kept, invalid input read-only). The parser splits lines without normalizing endings, classifies each line once, matches block and drawer ends, scans in-buffer TODO settings outside blocks, then builds an immutable green tree through `GreenBuilder`. `SyntaxNode` gives offset-aware red views. Every input byte ends up in exactly one token, so the tree text always equals the source.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Foundation only. No third-party dependencies.

**Spec:** `docs/design.md` (sections "OrgCore data model", "Testing", "Phases").

## Global Constraints

- Platforms: macOS 26, iOS 26.
- `OrgCore` imports Foundation only; never AppKit, UIKit or SwiftUI.
- Ranges and offsets exposed by the tree are UTF-16 code units.
- Supported encoding: UTF-8 with or without BOM. Anything else is read-only and never converted.
- Round trip: tree text equals source text for every input, and encoding unchanged text returns the original bytes.
- License 0BSD. No attribution lines in code, commits or docs.

## Out of scope for this plan

Inline objects (emphasis, links, timestamps), the semantic layer, incremental reparse, conformance rendering, and the private-corpus benchmarks. Each gets its own plan.

## File structure

| File | Responsibility |
| --- | --- |
| `Package.swift` | Package with `OrgCore` library and `OrgCoreTests` |
| `Sources/OrgCore/SourceText.swift` | Byte decoding, BOM, validity, encoding back to bytes |
| `Sources/OrgCore/Syntax/SyntaxKind.swift` | Token and node kinds |
| `Sources/OrgCore/Syntax/GreenTree.swift` | `GreenToken`, `GreenNode`, `GreenElement`, `GreenBuilder` |
| `Sources/OrgCore/Syntax/SyntaxNode.swift` | Red nodes, tokens, `OrgTree` |
| `Sources/OrgCore/Parser/Lines.swift` | Line splitting and classification |
| `Sources/OrgCore/Parser/Settings.swift` | TODO sequences, priorities, settings scan |
| `Sources/OrgCore/Parser/Parser.swift` | Tree construction |
| `Tests/OrgCoreTests/*.swift` | One test file per source file, plus round-trip fuzz and corpus tests |

---

### Task 1: Package and SourceText

**Files:**
- Create: `Package.swift`
- Create: `Sources/OrgCore/SourceText.swift`
- Test: `Tests/OrgCoreTests/SourceTextTests.swift`

**Interfaces:**
- Produces: `SourceText(bytes: [UInt8])`, `SourceText(_ text: String)`, properties `originalBytes`, `hasBOM`, `isValidUTF8`, `isEditable`, `text`; `encode(_ newText: String) -> [UInt8]`.

- [ ] **Step 1: Create the package**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"])
    ],
    targets: [
        .target(name: "OrgCore"),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"])
    ]
)
```

- [ ] **Step 2: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct SourceTextTests {
    @Test func plainUTF8() {
        let source = SourceText(bytes: Array("* a\n".utf8))
        #expect(source.text == "* a\n")
        #expect(!source.hasBOM)
        #expect(source.isEditable)
    }

    @Test func bomIsStrippedAndRestored() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("x\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.hasBOM)
        #expect(source.text == "x\n")
        #expect(source.encode(source.text) == bytes)
        #expect(source.encode("y\n") == [0xEF, 0xBB, 0xBF] + Array("y\n".utf8))
    }

    @Test func crlfAndMixedEndingsSurvive() {
        let bytes = Array("a\r\nb\nc\r\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.encode(source.text) == bytes)
    }

    @Test func invalidUTF8IsReadOnlyAndUnchanged() {
        let bytes: [UInt8] = [0x61, 0xFF, 0x0A]
        let source = SourceText(bytes: bytes)
        #expect(!source.isValidUTF8)
        #expect(!source.isEditable)
        #expect(source.encode(source.text) == bytes)
    }

    @Test func nonBMPAndCombiningSurvive() {
        let bytes = Array("😀 e\u{301}\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.encode(source.text) == bytes)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SourceTextTests`
Expected: build failure, `cannot find 'SourceText' in scope`.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// A file's bytes and their decoded text. Only UTF-8 (with or without a BOM) is editable;
/// anything else decodes with replacement characters for display and is never written back.
public struct SourceText: Sendable {
    public let originalBytes: [UInt8]
    public let hasBOM: Bool
    public let isValidUTF8: Bool
    /// Decoded text without the BOM.
    public let text: String

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    public init(bytes: [UInt8]) {
        originalBytes = bytes
        hasBOM = bytes.starts(with: Self.bom)
        let body = hasBOM ? Array(bytes.dropFirst(3)) : bytes
        if let decoded = String(validating: body, as: UTF8.self) {
            text = decoded
            isValidUTF8 = true
        } else {
            text = String(decoding: body, as: UTF8.self)
            isValidUTF8 = false
        }
    }

    public init(_ text: String) {
        self.init(bytes: Array(text.utf8))
    }

    public var isEditable: Bool { isValidUTF8 }

    /// Bytes to write for `newText`. Unchanged text returns the original bytes. Valid UTF-8
    /// round-trips through `String` unchanged, so untouched spans keep their exact bytes.
    public func encode(_ newText: String) -> [UInt8] {
        if newText == text { return originalBytes }
        precondition(isEditable, "a read-only document cannot be re-encoded")
        return (hasBOM ? Self.bom : []) + Array(newText.utf8)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SourceTextTests`
Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Add OrgCore package and SourceText byte contract"
```

---

### Task 2: Green and red syntax tree

**Files:**
- Create: `Sources/OrgCore/Syntax/SyntaxKind.swift`
- Create: `Sources/OrgCore/Syntax/GreenTree.swift`
- Create: `Sources/OrgCore/Syntax/SyntaxNode.swift`
- Test: `Tests/OrgCoreTests/SyntaxTreeTests.swift`

**Interfaces:**
- Produces: `SyntaxKind` (enum, `String` raw values), `GreenToken(kind:text:)`, `GreenNode(kind:children:)` with `.length`, `.text`; `GreenElement` (`.node`, `.token`); internal `GreenBuilder` with `start(_:)`, `token(_:_:)`, `finish()`, `build()`; `SyntaxNode` with `kind`, `range`, `text`, `children`, `tokens`, `descendants()`; `SyntaxToken`. `OrgTree` depends on `OrgSettings` (Task 4), so it is added in Task 5.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct SyntaxTreeTests {
    func sample() -> GreenNode {
        var b = GreenBuilder()
        b.start(.document)
        b.start(.paragraph)
        b.token(.text, "hé😀")
        b.token(.newline, "\n")
        b.finish()
        b.token(.newline, "\r\n")
        b.finish()
        return b.build()
    }

    @Test func lengthsAreUTF16() {
        let green = sample()
        #expect(green.length == 4 + 1 + 2)
        #expect(green.text == "hé😀\n\r\n")
    }

    @Test func redNodesCarryOffsets() {
        let root = SyntaxNode(green: sample(), offset: 0, parent: nil)
        let paragraph = root.children[0]
        #expect(paragraph.kind == .paragraph)
        #expect(paragraph.range == 0..<5)
        #expect(paragraph.parent === root)
        #expect(root.tokens.map(\.range) == [5..<7])
        #expect(paragraph.tokens.map(\.kind) == [.text, .newline])
    }

    @Test func builderSkipsEmptyTokens() {
        var b = GreenBuilder()
        b.start(.document)
        b.token(.whitespace, "")
        b.finish()
        #expect(b.build().children.isEmpty)
    }

    @Test func descendantsArePreorder() {
        let root = SyntaxNode(green: sample(), offset: 0, parent: nil)
        #expect(root.descendants().map(\.kind) == [.document, .paragraph])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SyntaxTreeTests`
Expected: build failure, `cannot find 'GreenBuilder' in scope`.

- [ ] **Step 3: Implement `SyntaxKind.swift`**

```swift
public enum SyntaxKind: String, Sendable {
    // Tokens
    case text, newline, whitespace
    case stars, todoKeyword, priority, title, tags

    // Nodes
    case document, zerothSection, section, heading
    case planning, propertyDrawer, nodeProperty, drawer, clock
    case paragraph, plainList, item, table, tableRow, tableFormula
    case block, dynamicBlock, keyword, affiliatedKeyword
    case comment, fixedWidth, horizontalRule, footnoteDefinition
}
```

- [ ] **Step 4: Implement `GreenTree.swift`**

```swift
public struct GreenToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
    /// Length in UTF-16 code units.
    public let length: Int

    public init(kind: SyntaxKind, text: String) {
        self.kind = kind
        self.text = text
        self.length = text.utf16.count
    }
}

/// An immutable node. Stores only kind, children and length, so unchanged subtrees can be
/// shared between versions of a document.
public final class GreenNode: Sendable, Equatable {
    public let kind: SyntaxKind
    public let children: [GreenElement]
    /// Length in UTF-16 code units.
    public let length: Int

    public init(kind: SyntaxKind, children: [GreenElement]) {
        self.kind = kind
        self.children = children
        self.length = children.reduce(0) { $0 + $1.length }
    }

    public static func == (lhs: GreenNode, rhs: GreenNode) -> Bool {
        lhs === rhs || (lhs.kind == rhs.kind && lhs.children == rhs.children)
    }

    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        for child in children {
            switch child {
            case .node(let node): node.write(to: &out)
            case .token(let token): out += token.text
            }
        }
    }
}

public enum GreenElement: Sendable, Equatable {
    case node(GreenNode)
    case token(GreenToken)

    public var length: Int {
        switch self {
        case .node(let node): node.length
        case .token(let token): token.length
        }
    }
}

struct GreenBuilder {
    private var stack: [(kind: SyntaxKind, children: [GreenElement])] = []
    private var root: GreenNode?

    mutating func start(_ kind: SyntaxKind) {
        stack.append((kind, []))
    }

    mutating func token(_ kind: SyntaxKind, _ text: some StringProtocol) {
        guard !text.isEmpty else { return }
        stack[stack.count - 1].children.append(.token(GreenToken(kind: kind, text: String(text))))
    }

    mutating func finish() {
        let (kind, children) = stack.removeLast()
        let node = GreenNode(kind: kind, children: children)
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(.node(node))
        }
    }

    func build() -> GreenNode {
        precondition(stack.isEmpty, "unfinished nodes")
        return root!
    }
}
```

- [ ] **Step 5: Implement `SyntaxNode.swift`**

```swift
/// A view of a green node at an absolute offset, with a parent link. Created on demand.
public final class SyntaxNode: Sendable {
    public let green: GreenNode
    public let offset: Int
    public let parent: SyntaxNode?

    init(green: GreenNode, offset: Int, parent: SyntaxNode?) {
        self.green = green
        self.offset = offset
        self.parent = parent
    }

    public var kind: SyntaxKind { green.kind }
    public var range: Range<Int> { offset..<(offset + green.length) }
    public var text: String { green.text }

    public var children: [SyntaxNode] {
        var result: [SyntaxNode] = []
        var at = offset
        for child in green.children {
            if case .node(let node) = child {
                result.append(SyntaxNode(green: node, offset: at, parent: self))
            }
            at += child.length
        }
        return result
    }

    public var tokens: [SyntaxToken] {
        var result: [SyntaxToken] = []
        var at = offset
        for child in green.children {
            if case .token(let token) = child {
                result.append(SyntaxToken(kind: token.kind, text: token.text, range: at..<(at + token.length)))
            }
            at += child.length
        }
        return result
    }

    /// This node and every node below it, in document order.
    public func descendants() -> [SyntaxNode] {
        [self] + children.flatMap { $0.descendants() }
    }
}

public struct SyntaxToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
    public let range: Range<Int>
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SyntaxTreeTests`
Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "Add green and red syntax tree"
```

---

### Task 3: Line splitting and classification

**Files:**
- Create: `Sources/OrgCore/Parser/Lines.swift`
- Test: `Tests/OrgCoreTests/LinesTests.swift`

**Interfaces:**
- Produces (internal): `RawLine(content: Substring, ending: Substring)`, `splitRawLines(_ text: String) -> [RawLine]`, `LineClass` enum, `ClassifiedLine(cls:indent:)`, `classifyLine(_ line: Substring) -> ClassifiedLine`, `Substring.trimmingTrailingWhitespace`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct LinesTests {
    @Test func splitKeepsEveryEnding() {
        let lines = splitRawLines("a\r\nb\n\nc")
        #expect(lines.map { String($0.content) } == ["a", "b", "", "c"])
        #expect(lines.map { String($0.ending) } == ["\r\n", "\n", "\n", ""])
        #expect(splitRawLines("").isEmpty)
        #expect(splitRawLines("x\n").count == 1)
    }

    @Test func splitIsLossless() {
        let text = "\r\n\n a\r b\r\n😀\n"
        #expect(splitRawLines(text).map { String($0.content) + String($0.ending) }.joined() == text)
    }

    @Test(arguments: [
        ("", LineClass.blank),
        ("   \t", .blank),
        ("* a", .heading(level: 1)),
        ("*** ", .heading(level: 3)),
        ("*", .heading(level: 1)),
        ("*bold* text", .plain),
        (" * a", .listItem),
        ("#+BEGIN_SRC sh :results output", .blockBegin(name: "src")),
        ("#+end_src", .blockEnd(name: "src")),
        ("#+BEGIN: clocktable :scope file", .dynamicBegin),
        ("#+END:", .dynamicEnd),
        ("#+TITLE: x", .keyword(key: "TITLE")),
        ("#+tblfm: $2=$1", .keyword(key: "TBLFM")),
        ("# comment", .comment),
        ("#", .comment),
        ("#hashtag", .plain),
        (": fixed", .fixedWidth),
        (":", .fixedWidth),
        (":PROPERTIES:", .drawerBegin(name: "PROPERTIES")),
        ("  :LOGBOOK:", .drawerBegin(name: "LOGBOOK")),
        (":END:", .drawerEnd),
        ("| a | b |", .tableRow),
        ("-----", .horizontalRule),
        ("----", .plain),
        ("[fn:1] note", .footnoteDefinition),
        ("CLOCK: [2026-10-04 Sun 10:00]", .clock),
        ("SCHEDULED: <2026-10-04 Sun>", .planning),
        ("- item", .listItem),
        ("+ item", .listItem),
        ("1. item", .listItem),
        ("2) item", .listItem),
        ("-", .listItem),
        ("-x", .plain),
        ("1.5 apples", .plain),
        ("plain text", .plain),
    ])
    func classify(line: String, expected: LineClass) {
        #expect(classifyLine(line[...]).cls == expected)
    }

    @Test func indentCountsTabsToEight() {
        #expect(classifyLine("\t- a").indent == 8)
        #expect(classifyLine("  \t- a").indent == 8)
        #expect(classifyLine("   - a").indent == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LinesTests`
Expected: build failure, `cannot find 'splitRawLines' in scope`.

- [ ] **Step 3: Implement**

```swift
/// One line of source: its content and its terminator ("", "\n" or "\r\n"), both as slices of
/// the original text.
struct RawLine {
    let content: Substring
    let ending: Substring
}

/// Splits on "\n" without normalizing anything. Works on unicode scalars, because String
/// treats "\r\n" as a single Character.
func splitRawLines(_ text: String) -> [RawLine] {
    var lines: [RawLine] = []
    let scalars = text.unicodeScalars
    var lineStart = scalars.startIndex
    var i = lineStart
    while i != scalars.endIndex {
        if scalars[i] == "\n" {
            var contentEnd = i
            if contentEnd > lineStart, scalars[scalars.index(before: i)] == "\r" {
                contentEnd = scalars.index(before: i)
            }
            let next = scalars.index(after: i)
            lines.append(RawLine(content: text[lineStart..<contentEnd], ending: text[contentEnd..<next]))
            lineStart = next
            i = next
        } else {
            i = scalars.index(after: i)
        }
    }
    if lineStart != scalars.endIndex {
        lines.append(RawLine(content: text[lineStart...], ending: ""))
    }
    return lines
}

enum LineClass: Equatable {
    case blank
    case heading(level: Int)
    case blockBegin(name: String)
    case blockEnd(name: String)
    case dynamicBegin
    case dynamicEnd
    case drawerBegin(name: String)
    case drawerEnd
    case keyword(key: String)
    case comment
    case fixedWidth
    case horizontalRule
    case tableRow
    case footnoteDefinition
    case clock
    case planning
    case listItem
    case plain
}

struct ClassifiedLine {
    let cls: LineClass
    /// Column of the first non-blank character, with tabs advancing to the next multiple of 8.
    let indent: Int
}

func classifyLine(_ line: Substring) -> ClassifiedLine {
    var column = 0
    var rest = line
    while let c = rest.first, c == " " || c == "\t" {
        column = c == "\t" ? (column / 8 + 1) * 8 : column + 1
        rest = rest.dropFirst()
    }
    if rest.isEmpty { return ClassifiedLine(cls: .blank, indent: column) }
    return ClassifiedLine(cls: lineClass(rest, columnZero: column == 0), indent: column)
}

private func lineClass(_ rest: Substring, columnZero: Bool) -> LineClass {
    let trimmed = rest.trimmingTrailingWhitespace

    if columnZero, rest.first == "*" {
        let stars = rest.prefix { $0 == "*" }
        let after = rest.dropFirst(stars.count)
        if after.isEmpty || after.first == " " || after.first == "\t" {
            return .heading(level: stars.count)
        }
    }

    if rest.hasPrefix("#+") {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("#+begin_") {
            let name = lower.dropFirst(8).prefix { !$0.isWhitespace }
            if !name.isEmpty { return .blockBegin(name: String(name)) }
        }
        if lower.hasPrefix("#+end_") {
            let name = lower.dropFirst(6)
            if !name.isEmpty, !name.contains(where: \.isWhitespace) { return .blockEnd(name: String(name)) }
        }
        if lower.hasPrefix("#+begin:") { return .dynamicBegin }
        if lower == "#+end:" { return .dynamicEnd }
        if let colon = rest.firstIndex(of: ":") {
            let key = rest[rest.index(rest.startIndex, offsetBy: 2)..<colon]
            if !key.isEmpty, !key.contains(where: \.isWhitespace) { return .keyword(key: key.uppercased()) }
        }
    }

    if trimmed == "#" || rest.hasPrefix("# ") || rest.hasPrefix("#\t") { return .comment }

    if rest.first == ":" {
        if trimmed == ":" || rest.hasPrefix(": ") || rest.hasPrefix(":\t") { return .fixedWidth }
        if trimmed.uppercased() == ":END:" { return .drawerEnd }
        if trimmed.count >= 3, trimmed.last == ":" {
            let name = trimmed.dropFirst().dropLast()
            if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                return .drawerBegin(name: String(name))
            }
        }
    }

    if rest.first == "|" { return .tableRow }
    if trimmed.count >= 5, trimmed.allSatisfy({ $0 == "-" }) { return .horizontalRule }

    if columnZero, rest.hasPrefix("[fn:"), let close = rest.firstIndex(of: "]"),
       close > rest.index(rest.startIndex, offsetBy: 4) {
        return .footnoteDefinition
    }

    if rest.hasPrefix("CLOCK:") { return .clock }
    if rest.hasPrefix("SCHEDULED:") || rest.hasPrefix("DEADLINE:") || rest.hasPrefix("CLOSED:") { return .planning }
    if isListBullet(rest, indented: !columnZero) { return .listItem }
    return .plain
}

/// `-`, `+`, `*` (indented only), `1.` or `1)`, followed by whitespace or end of line.
/// Alphabetical bullets are off, as in org's default.
private func isListBullet(_ rest: Substring, indented: Bool) -> Bool {
    guard let first = rest.first else { return false }
    let afterBullet: Substring
    if first == "-" || first == "+" || (first == "*" && indented) {
        afterBullet = rest.dropFirst()
    } else if first.isASCII, first.isNumber {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let tail = rest.dropFirst(digits.count)
        guard let separator = tail.first, separator == "." || separator == ")" else { return false }
        afterBullet = tail.dropFirst()
    } else {
        return false
    }
    return afterBullet.isEmpty || afterBullet.first == " " || afterBullet.first == "\t"
}

extension Substring {
    var trimmingTrailingWhitespace: Substring {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return s
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LinesTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add line splitting and classification"
```

---

### Task 4: In-buffer settings

**Files:**
- Create: `Sources/OrgCore/Parser/Settings.swift`
- Test: `Tests/OrgCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `RawLine`, `ClassifiedLine`, `LineClass` (Task 3).
- Produces: `TodoKeyword`, `TodoSequence`, `Priorities`, `OrgSettings` with `.default`, `todoKeywordNames: Set<String>`, `isDone(_:)`; internal `SettingsScanner.scan(lines:info:blockEnds:defaults:) -> OrgSettings`, where `blockEnds: [Int: Int]` maps a block's begin line index to its end line index.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct SettingsTests {
    func scan(_ text: String, blockEnds: [Int: Int] = [:]) -> OrgSettings {
        let lines = splitRawLines(text)
        let info = lines.map { classifyLine($0.content) }
        return SettingsScanner.scan(lines: lines, info: info, blockEnds: blockEnds, defaults: .default)
    }

    @Test func defaultsWithoutKeywords() {
        let settings = scan("* TODO a\n")
        #expect(settings.todoKeywordNames == ["TODO", "DONE"])
        #expect(settings.isDone("DONE"))
    }

    @Test func fileKeywordsReplaceDefaults() {
        let settings = scan("#+TODO: NEXT(n) WAIT(w@/!) | DONE(d!) CANCELED(c@)\n")
        #expect(settings.todoKeywordNames == ["NEXT", "WAIT", "DONE", "CANCELED"])
        let sequence = settings.todoSequences[0]
        #expect(sequence.active.map(\.name) == ["NEXT", "WAIT"])
        #expect(sequence.done.map(\.name) == ["DONE", "CANCELED"])
        #expect(sequence.active[1] == TodoKeyword(name: "WAIT", fastKey: "w", logOnEnter: "@", logOnLeave: "!"))
        #expect(sequence.done[0] == TodoKeyword(name: "DONE", fastKey: "d", logOnEnter: "!", logOnLeave: nil))
    }

    @Test func lastWordIsDoneWithoutSeparator() {
        let settings = scan("#+SEQ_TODO: A B C\n")
        #expect(settings.todoSequences[0].active.map(\.name) == ["A", "B"])
        #expect(settings.todoSequences[0].done.map(\.name) == ["C"])
    }

    @Test func severalLinesMakeSeveralSequences() {
        let settings = scan("#+TODO: A | B\n#+TYP_TODO: X | Y\n")
        #expect(settings.todoSequences.count == 2)
        #expect(settings.todoSequences[1].kind == .type)
    }

    @Test func keywordsInsideBlocksAreIgnored() {
        let text = "#+begin_example\n#+TODO: X | Y\n#+end_example\n"
        #expect(scan(text, blockEnds: [0: 2]).todoKeywordNames == ["TODO", "DONE"])
    }

    @Test func priorities() {
        #expect(scan("#+PRIORITIES: 1 10 5\n").priorities == Priorities(highest: "1", lowest: "10", default: "5"))
        #expect(scan("").priorities == Priorities(highest: "A", lowest: "C", default: "B"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsTests`
Expected: build failure, `cannot find 'SettingsScanner' in scope`.

- [ ] **Step 3: Implement**

```swift
public struct TodoKeyword: Sendable, Hashable {
    public var name: String
    public var fastKey: Character?
    /// Logging flag when entering the state (`!` or `@`), from `NAME(k!/@)`.
    public var logOnEnter: String?
    /// Logging flag when leaving the state.
    public var logOnLeave: String?

    public init(name: String, fastKey: Character? = nil, logOnEnter: String? = nil, logOnLeave: String? = nil) {
        self.name = name
        self.fastKey = fastKey
        self.logOnEnter = logOnEnter
        self.logOnLeave = logOnLeave
    }
}

public struct TodoSequence: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case sequence, type }

    public var kind: Kind
    public var active: [TodoKeyword]
    public var done: [TodoKeyword]

    public init(kind: Kind, active: [TodoKeyword], done: [TodoKeyword]) {
        self.kind = kind
        self.active = active
        self.done = done
    }
}

public struct Priorities: Sendable, Equatable {
    public var highest: String
    public var lowest: String
    public var `default`: String

    public init(highest: String, lowest: String, default: String) {
        self.highest = highest
        self.lowest = lowest
        self.default = `default`
    }
}

public struct OrgSettings: Sendable, Equatable {
    public var todoSequences: [TodoSequence]
    public var priorities: Priorities

    public init(todoSequences: [TodoSequence], priorities: Priorities) {
        self.todoSequences = todoSequences
        self.priorities = priorities
    }

    public static let `default` = OrgSettings(
        todoSequences: [TodoSequence(kind: .sequence, active: [TodoKeyword(name: "TODO")], done: [TodoKeyword(name: "DONE")])],
        priorities: Priorities(highest: "A", lowest: "C", default: "B")
    )

    public var todoKeywordNames: Set<String> {
        Set(todoSequences.flatMap { ($0.active + $0.done).map(\.name) })
    }

    public func isDone(_ name: String) -> Bool {
        todoSequences.contains { $0.done.contains { $0.name == name } }
    }
}

enum SettingsScanner {
    /// Reads `#+TODO`, `#+SEQ_TODO`, `#+TYP_TODO` and `#+PRIORITIES` outside blocks. Any TODO
    /// line replaces the default sequences, as in org.
    static func scan(lines: [RawLine], info: [ClassifiedLine], blockEnds: [Int: Int], defaults: OrgSettings) -> OrgSettings {
        var sequences: [TodoSequence] = []
        var priorities = defaults.priorities
        var k = 0
        while k < lines.count {
            switch info[k].cls {
            case .blockBegin, .dynamicBegin:
                if let end = blockEnds[k] { k = end }
            case .keyword(let key):
                let value = keywordValue(lines[k].content)
                switch key {
                case "TODO", "SEQ_TODO":
                    if let s = todoSequence(value, kind: .sequence) { sequences.append(s) }
                case "TYP_TODO":
                    if let s = todoSequence(value, kind: .type) { sequences.append(s) }
                case "PRIORITIES":
                    let words = value.split(whereSeparator: \.isWhitespace)
                    if words.count == 3 {
                        priorities = Priorities(highest: String(words[0]), lowest: String(words[1]), default: String(words[2]))
                    }
                default:
                    break
                }
            default:
                break
            }
            k += 1
        }
        return OrgSettings(todoSequences: sequences.isEmpty ? defaults.todoSequences : sequences, priorities: priorities)
    }

    static func keywordValue(_ line: Substring) -> Substring {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...]
    }

    static func todoSequence(_ value: Substring, kind: TodoSequence.Kind) -> TodoSequence? {
        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        if let bar = words.firstIndex(of: "|") {
            return TodoSequence(kind: kind, active: words[..<bar].map(todoKeyword), done: words[(bar + 1)...].map(todoKeyword))
        }
        return TodoSequence(kind: kind, active: words.dropLast().map(todoKeyword), done: [todoKeyword(words.last!)])
    }

    /// `NAME`, or `NAME(spec)` where spec is an optional fast key followed by `enter/leave`
    /// logging flags.
    static func todoKeyword(_ word: Substring) -> TodoKeyword {
        guard let open = word.firstIndex(of: "("), word.last == ")" else { return TodoKeyword(name: String(word)) }
        var spec = word[word.index(after: open)..<word.index(before: word.endIndex)]
        var fastKey: Character?
        if let first = spec.first, first != "!", first != "@", first != "/" {
            fastKey = first
            spec = spec.dropFirst()
        }
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        let enter = parts.first.flatMap { $0.isEmpty ? nil : String($0) }
        let leave = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return TodoKeyword(name: String(word[..<open]), fastKey: fastKey, logOnEnter: enter, logOnLeave: leave)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add in-buffer TODO and priority settings"
```

---

### Task 5: Parser — document, sections and headings

**Files:**
- Create: `Sources/OrgCore/Parser/Parser.swift`
- Modify: `Sources/OrgCore/Syntax/SyntaxNode.swift` (append `OrgTree`)
- Test: `Tests/OrgCoreTests/ParserSectionTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces: `public enum OrgParser { static func parse(_ text: String, defaults: OrgSettings = .default) -> OrgTree }`; `public struct OrgTree { green: GreenNode; settings: OrgSettings; root: SyntaxNode; text: String }`; internal `struct Parser` with `element(limit:floor:)` that Task 6 fills in. In this task `element` handles every class as a paragraph or a blank line.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

func nodeKinds(_ text: String) -> [SyntaxKind] {
    OrgParser.parse(text).root.descendants().map(\.kind)
}

func tokens(of kind: SyntaxKind, in text: String) -> [SyntaxToken] {
    OrgParser.parse(text).root.descendants().filter { $0.kind == kind }.flatMap(\.tokens)
}

struct ParserSectionTests {
    @Test func emptyDocument() {
        let tree = OrgParser.parse("")
        #expect(tree.text == "")
        #expect(nodeKinds("") == [.document])
    }

    @Test func zerothSectionHoldsPreamble() {
        #expect(nodeKinds("text\n* a\n") == [.document, .zerothSection, .paragraph, .section, .heading])
    }

    @Test func sectionsNestByLevel() {
        let text = "* a\n** b\n*** c\n** d\n* e\n"
        let root = OrgParser.parse(text).root
        let top = root.children
        #expect(top.map(\.kind) == [.section, .section])
        #expect(top[0].children.map(\.kind) == [.heading, .section, .section])
        #expect(top[0].children[1].children.map(\.kind) == [.heading, .section])
    }

    @Test func headingTokens() {
        let parts = tokens(of: .heading, in: "** TODO [#A] Write the plan  :work:urgent:  \n")
        #expect(parts.map(\.kind) == [.stars, .whitespace, .todoKeyword, .whitespace, .priority, .whitespace, .title, .whitespace, .tags, .whitespace, .newline])
        #expect(parts.first { $0.kind == .tags }?.text == ":work:urgent:")
        #expect(parts.first { $0.kind == .title }?.text == "Write the plan")
    }

    @Test func todoKeywordsComeFromSettings() {
        let text = "#+TODO: NEXT | DONE\n* NEXT a\n* TODO b\n"
        let todo = tokens(of: .heading, in: text).filter { $0.kind == .todoKeyword }.map(\.text)
        #expect(todo == ["NEXT"])
    }

    @Test func priorityNeedsValidValueAndSpace() {
        #expect(tokens(of: .heading, in: "* [#B] x\n").contains { $0.kind == .priority })
        #expect(tokens(of: .heading, in: "* [#10] x\n").contains { $0.kind == .priority })
        #expect(!tokens(of: .heading, in: "* [#AB] x\n").contains { $0.kind == .priority })
        #expect(!tokens(of: .heading, in: "* [#A]x\n").contains { $0.kind == .priority })
    }

    @Test func tagsNeedValidCharacters() {
        #expect(tokens(of: .heading, in: "* a :b@c_1:\n").contains { $0.kind == .tags })
        #expect(!tokens(of: .heading, in: "* a :b c:\n").contains { $0.kind == .tags })
        #expect(!tokens(of: .heading, in: "* a :b:c\n").contains { $0.kind == .tags })
    }

    @Test func headingWithoutNewlineAtEnd() {
        #expect(OrgParser.parse("* a").text == "* a")
    }

    @Test(arguments: ["* a\n", "*\n", "* TODO\n", "text\r\n* a\r\n** b\r\n", "\n\n* a\n\n"])
    func roundTrip(text: String) {
        #expect(OrgParser.parse(text).text == text)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParserSectionTests`
Expected: build failure, `cannot find 'OrgParser' in scope`.

- [ ] **Step 3: Append `OrgTree` to `SyntaxNode.swift`**

```swift
public struct OrgTree: Sendable {
    public let green: GreenNode
    public let settings: OrgSettings

    public var root: SyntaxNode { SyntaxNode(green: green, offset: 0, parent: nil) }
    public var text: String { green.text }
}
```

- [ ] **Step 4: Implement `Parser.swift`**

```swift
public enum OrgParser {
    public static func parse(_ text: String, defaults: OrgSettings = .default) -> OrgTree {
        var parser = Parser(text: text, defaults: defaults)
        return parser.run()
    }
}

struct Parser {
    let lines: [RawLine]
    let info: [ClassifiedLine]
    /// Begin line → end line, for blocks, dynamic blocks and drawers that are closed before the
    /// next heading.
    let blockEnds: [Int: Int]
    let settings: OrgSettings
    var builder = GreenBuilder()
    var i = 0

    init(text: String, defaults: OrgSettings) {
        lines = splitRawLines(text)
        info = lines.map { classifyLine($0.content) }
        blockEnds = Parser.matchEnds(info)
        settings = SettingsScanner.scan(lines: lines, info: info, blockEnds: blockEnds, defaults: defaults)
    }

    static func matchEnds(_ info: [ClassifiedLine]) -> [Int: Int] {
        var ends: [Int: Int] = [:]
        var k = 0
        while k < info.count {
            let isEnd: ((LineClass) -> Bool)?
            switch info[k].cls {
            case .blockBegin(let name): isEnd = { $0 == .blockEnd(name: name) }
            case .dynamicBegin: isEnd = { $0 == .dynamicEnd }
            case .drawerBegin: isEnd = { $0 == .drawerEnd }
            default: isEnd = nil
            }
            if let isEnd {
                var j = k + 1
                while j < info.count {
                    if case .heading = info[j].cls { break }
                    if isEnd(info[j].cls) { ends[k] = j; break }
                    j += 1
                }
                // Block contents are verbatim, so nothing inside starts another element.
                if let end = ends[k], !isDrawer(info[k].cls) { k = end }
            }
            k += 1
        }
        return ends
    }

    static func isDrawer(_ cls: LineClass) -> Bool {
        if case .drawerBegin = cls { return true }
        return false
    }

    mutating func run() -> OrgTree {
        builder.start(.document)
        if !lines.isEmpty, !isHeading(0) {
            builder.start(.zerothSection)
            parseContent(limit: lines.count)
            builder.finish()
        }
        while i < lines.count, case .heading(let level) = info[i].cls {
            parseSection(level: level)
        }
        builder.finish()
        return OrgTree(green: builder.build(), settings: settings)
    }

    func isHeading(_ k: Int) -> Bool {
        if case .heading = info[k].cls { return true }
        return false
    }

    mutating func parseSection(level: Int) {
        builder.start(.section)
        headingLine(lines[i])
        i += 1
        if i < lines.count, info[i].cls == .planning {
            builder.start(.planning)
            line(i)
            i += 1
            builder.finish()
        }
        if i < lines.count, case .drawerBegin(let name) = info[i].cls, name.uppercased() == "PROPERTIES",
           let end = blockEnds[i] {
            propertyDrawer(end: end)
        }
        parseContent(limit: lines.count)
        while i < lines.count, case .heading(let child) = info[i].cls, child > level {
            parseSection(level: child)
        }
        builder.finish()
    }

    mutating func propertyDrawer(end: Int) {
        builder.start(.propertyDrawer)
        line(i)
        i += 1
        while i < end {
            if info[i].cls == .blank {
                line(i)
            } else {
                builder.start(.nodeProperty)
                line(i)
                builder.finish()
            }
            i += 1
        }
        line(i)
        i += 1
        builder.finish()
    }

    /// Elements until `limit` or the next heading.
    mutating func parseContent(limit: Int) {
        while i < limit, !isHeading(i) {
            element(limit: limit, floor: nil)
        }
    }

    /// One element starting at `i`. `floor` is the indent of the enclosing list item, if any:
    /// non-blank lines at or left of it end the element.
    mutating func element(limit: Int, floor: Int?) {
        if info[i].cls == .blank {
            line(i)
            i += 1
        } else {
            paragraph(limit: limit, floor: floor)
        }
    }

    mutating func paragraph(limit: Int, floor: Int?) {
        builder.start(.paragraph)
        line(i)
        i += 1
        while i < limit, within(floor, i), continuesParagraph(i) {
            line(i)
            i += 1
        }
        builder.finish()
    }

    func continuesParagraph(_ k: Int) -> Bool {
        switch info[k].cls {
        case .blank, .heading: return false
        default: return true
        }
    }

    func within(_ floor: Int?, _ k: Int) -> Bool {
        guard let floor else { return true }
        return info[k].indent > floor
    }

    // MARK: - Tokens

    /// A whole line as leading whitespace, content and line ending.
    mutating func line(_ k: Int) {
        let content = lines[k].content
        let rest = whitespace(content)
        builder.token(.text, rest)
        builder.token(.newline, lines[k].ending)
    }

    mutating func whitespace(_ s: Substring) -> Substring {
        let ws = s.prefix { $0 == " " || $0 == "\t" }
        builder.token(.whitespace, ws)
        return s.dropFirst(ws.count)
    }

    mutating func headingLine(_ raw: RawLine) {
        builder.start(.heading)
        var rest = raw.content
        let stars = rest.prefix { $0 == "*" }
        builder.token(.stars, stars)
        rest = whitespace(rest.dropFirst(stars.count))

        let word = rest.prefix { $0 != " " && $0 != "\t" }
        if !word.isEmpty, settings.todoKeywordNames.contains(String(word)) {
            builder.token(.todoKeyword, word)
            rest = whitespace(rest.dropFirst(word.count))
        }

        if let cookie = priorityCookie(rest) {
            builder.token(.priority, cookie)
            rest = whitespace(rest.dropFirst(cookie.count))
        }

        let parts = splitTags(rest)
        builder.token(.title, parts.title)
        builder.token(.whitespace, parts.gap)
        builder.token(.tags, parts.tags)
        builder.token(.whitespace, parts.trailing)
        builder.token(.newline, raw.ending)
        builder.finish()
    }

    /// `[#A]` or `[#10]`, followed by whitespace or end of line.
    func priorityCookie(_ s: Substring) -> Substring? {
        guard s.hasPrefix("[#"), let close = s.firstIndex(of: "]") else { return nil }
        let value = s[s.index(s.startIndex, offsetBy: 2)..<close]
        let valid = (value.count == 1 && value.first!.isLetter && value.first!.isUppercase)
            || (!value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber })
        guard valid else { return nil }
        let after = s[s.index(after: close)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return s[...close]
    }

    func splitTags(_ s: Substring) -> (title: Substring, gap: Substring, tags: Substring, trailing: Substring) {
        let trimmed = s.trimmingTrailingWhitespace
        let trailing = s[trimmed.endIndex...]
        let none = (title: trimmed, gap: Substring(), tags: Substring(), trailing: trailing)
        guard trimmed.last == ":" else { return none }
        let tagStart = trimmed.lastIndex { $0 == " " || $0 == "\t" }.map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let tags = trimmed[tagStart...]
        guard tags.count >= 3, tags.first == ":", isTagString(tags) else { return none }
        let before = trimmed[..<tagStart]
        let title = before.trimmingTrailingWhitespace
        return (title, before[title.endIndex...], tags, trailing)
    }

    func isTagString(_ tags: Substring) -> Bool {
        tags.dropFirst().dropLast().split(separator: ":", omittingEmptySubsequences: false).allSatisfy { tag in
            !tag.isEmpty && tag.allSatisfy { $0.isLetter || $0.isNumber || "_@#%".contains($0) }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ParserSectionTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "Parse document, sections and headings"
```

---

### Task 6: Parser — elements

**Files:**
- Modify: `Sources/OrgCore/Parser/Parser.swift` (replace `element`, `continuesParagraph`; add `list`, `item`, `table`, `consecutive`, `footnoteDefinition`)
- Test: `Tests/OrgCoreTests/ParserElementTests.swift`

**Interfaces:**
- Consumes: Task 5's `Parser`.
- Produces: nodes `block`, `dynamicBlock`, `drawer`, `keyword`, `affiliatedKeyword`, `comment`, `fixedWidth`, `horizontalRule`, `table`/`tableRow`/`tableFormula`, `footnoteDefinition`, `clock`, `plainList`/`item`, `planning` (after heading only), `propertyDrawer`/`nodeProperty`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

func childKinds(_ text: String) -> [SyntaxKind] {
    let root = OrgParser.parse(text).root
    let container = root.children.first { $0.kind == .zerothSection || $0.kind == .section }!
    return container.children.map(\.kind)
}

struct ParserElementTests {
    @Test func planningAndPropertiesFollowHeading() {
        let text = "* a\nSCHEDULED: <2026-10-04 Sun>\n:PROPERTIES:\n:ID: x\n:END:\nbody\n"
        #expect(childKinds(text) == [.heading, .planning, .propertyDrawer, .paragraph])
    }

    @Test func planningElsewhereIsText() {
        #expect(childKinds("SCHEDULED: <2026-10-04 Sun>\n") == [.paragraph])
    }

    @Test func blocks() {
        #expect(childKinds("#+begin_src sh\n,* escaped\n:END:\n#+end_src\nafter\n") == [.block, .paragraph])
        #expect(childKinds("#+BEGIN: clocktable\n#+END:\n") == [.dynamicBlock])
    }

    @Test func headingsEndBlocks() {
        #expect(childKinds("#+begin_src sh\n* heading\n#+end_src\n") == [.paragraph])
    }

    @Test func unclosedBlockIsParagraph() {
        #expect(childKinds("#+begin_src sh\necho\n") == [.paragraph])
    }

    @Test func drawersHoldElements() {
        let root = OrgParser.parse(":LOGBOOK:\nCLOCK: [2026-10-04 Sun 10:00]\n:END:\n").root
        let drawer = root.children[0].children[0]
        #expect(drawer.kind == .drawer)
        #expect(drawer.children.map(\.kind) == [.clock])
    }

    @Test func keywords() {
        #expect(childKinds("#+TITLE: x\n#+NAME: t\n#+ATTR_HTML: :width 10\n") == [.keyword, .affiliatedKeyword, .affiliatedKeyword])
    }

    @Test func commentsAndFixedWidthGroup() {
        #expect(childKinds("# a\n# b\n: c\n: d\n-----\n") == [.comment, .fixedWidth, .horizontalRule])
    }

    @Test func tableWithFormulas() {
        let root = OrgParser.parse("| a |\n|---|\n| 1 |\n#+TBLFM: $1=2\n#+TBLFM: $1=3\n").root
        let table = root.children[0].children[0]
        #expect(table.kind == .table)
        #expect(table.children.map(\.kind) == [.tableRow, .tableRow, .tableRow, .tableFormula, .tableFormula])
    }

    @Test func footnoteDefinition() {
        #expect(childKinds("[fn:1] note\ncontinued\n\nafter\n") == [.footnoteDefinition, .paragraph])
    }

    @Test func listsNestByIndent() {
        let text = "- a\n  more\n  - b\n- c\n\nafter\n"
        let root = OrgParser.parse(text).root
        let list = root.children[0].children[0]
        #expect(list.kind == .plainList)
        #expect(list.children.map(\.kind) == [.item, .item])
        #expect(list.children[0].children.map(\.kind) == [.paragraph, .plainList])
        #expect(childKinds(text) == [.plainList, .paragraph])
    }

    @Test func twoBlankLinesEndAList() {
        #expect(childKinds("- a\n\n\n- b\n") == [.plainList, .plainList])
        #expect(childKinds("- a\n\n- b\n") == [.plainList])
    }

    @Test func paragraphStopsAtElementStart() {
        #expect(childKinds("text\n| a |\n") == [.paragraph, .table])
        #expect(childKinds("text\n#+begin_quote\nq\n#+end_quote\n") == [.paragraph, .block])
        #expect(childKinds("text\n#+begin_quote\nq\n") == [.paragraph])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParserElementTests`
Expected: failures; every element parses as a paragraph.

- [ ] **Step 3: Replace `element` and `continuesParagraph`, add the element parsers**

```swift
    static let affiliatedKeys: Set<String> = ["NAME", "CAPTION", "RESULTS", "HEADER", "PLOT"]

    mutating func element(limit: Int, floor: Int?) {
        switch info[i].cls {
        case .blank:
            line(i)
            i += 1
        case .blockBegin, .dynamicBegin:
            if let end = blockEnds[i], end < limit {
                builder.start(info[i].cls == .dynamicBegin ? .dynamicBlock : .block)
                while i <= end {
                    line(i)
                    i += 1
                }
                builder.finish()
            } else {
                paragraph(limit: limit, floor: floor)
            }
        case .drawerBegin:
            if let end = blockEnds[i], end < limit {
                builder.start(.drawer)
                line(i)
                i += 1
                parseContent(limit: end)
                line(i)
                i += 1
                builder.finish()
            } else {
                paragraph(limit: limit, floor: floor)
            }
        case .keyword(let key):
            let affiliated = Self.affiliatedKeys.contains(key) || key.hasPrefix("ATTR_")
            single(affiliated ? .affiliatedKeyword : .keyword)
        case .comment:
            consecutive(.comment, limit: limit, floor: floor) { $0 == .comment }
        case .fixedWidth:
            consecutive(.fixedWidth, limit: limit, floor: floor) { $0 == .fixedWidth }
        case .horizontalRule:
            single(.horizontalRule)
        case .clock:
            single(.clock)
        case .tableRow:
            table(limit: limit, floor: floor)
        case .footnoteDefinition:
            footnoteDefinition(limit: limit)
        case .listItem:
            list(limit: limit, floor: floor)
        default:
            paragraph(limit: limit, floor: floor)
        }
    }

    /// Lines that don't start an element of their own.
    func continuesParagraph(_ k: Int) -> Bool {
        switch info[k].cls {
        case .plain, .planning, .blockEnd, .dynamicEnd, .drawerEnd:
            return true
        case .blockBegin, .dynamicBegin, .drawerBegin:
            return blockEnds[k] == nil
        default:
            return false
        }
    }

    mutating func single(_ kind: SyntaxKind) {
        builder.start(kind)
        line(i)
        i += 1
        builder.finish()
    }

    mutating func consecutive(_ kind: SyntaxKind, limit: Int, floor: Int?, matching: (LineClass) -> Bool) {
        builder.start(kind)
        repeat {
            line(i)
            i += 1
        } while i < limit && matching(info[i].cls) && within(floor, i)
        builder.finish()
    }

    mutating func table(limit: Int, floor: Int?) {
        builder.start(.table)
        while i < limit, info[i].cls == .tableRow, within(floor, i) {
            single(.tableRow)
        }
        while i < limit, info[i].cls == .keyword(key: "TBLFM"), within(floor, i) {
            single(.tableFormula)
        }
        builder.finish()
    }

    mutating func footnoteDefinition(limit: Int) {
        builder.start(.footnoteDefinition)
        line(i)
        i += 1
        while i < limit, info[i].cls == .plain {
            line(i)
            i += 1
        }
        builder.finish()
    }

    mutating func list(limit: Int, floor: Int?) {
        let base = info[i].indent
        builder.start(.plainList)
        while i < limit, info[i].cls == .listItem, info[i].indent == base, within(floor, i) {
            item(base: base, limit: limit)
        }
        builder.finish()
    }

    /// An item's first line, then everything indented past its bullet. One blank line stays
    /// inside the item when the item or list continues after it; two end the list.
    mutating func item(base: Int, limit: Int) {
        builder.start(.item)
        line(i)
        i += 1
        while i < limit, !isHeading(i) {
            if info[i].cls == .blank {
                var j = i
                while j < limit, info[j].cls == .blank { j += 1 }
                guard j - i < 2, j < limit else { break }
                let continuesItem = info[j].indent > base
                let nextSibling = info[j].cls == .listItem && info[j].indent == base
                guard continuesItem || nextSibling else { break }
                line(i)
                i += 1
                if nextSibling { break }
                continue
            }
            guard info[i].indent > base else { break }
            element(limit: limit, floor: base)
        }
        builder.finish()
    }
```

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: all pass, including Task 5's tests.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Parse block-level elements"
```

---

### Task 7: Round-trip fuzz, encoding fixtures and corpus test

**Files:**
- Test: `Tests/OrgCoreTests/RoundTripTests.swift`

**Interfaces:**
- Consumes: `SourceText`, `OrgParser`, `SyntaxNode`.
- Produces: a seeded fuzz test (2,000 documents), a structural invariant check, and an opt-in corpus test driven by `ORGSTAR_CORPUS`.

- [ ] **Step 1: Write the tests**

```swift
import Foundation
import Testing
@testable import OrgCore

/// SplitMix64, so failures reproduce from the seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let fragments = [
    "* ", "** TODO [#A] title :a:b:", "*** DONE", "#+TODO: NEXT | DONE", "#+begin_src sh", "#+end_src",
    "#+BEGIN_QUOTE", "#+end_quote", "#+BEGIN: clocktable", "#+END:", ":PROPERTIES:", ":ID: x", ":END:",
    ":LOGBOOK:", "CLOCK: [2026-10-04 Sun 10:00]", "SCHEDULED: <2026-10-04 Sun>", "- item", "  - nested",
    "\t+ tab", "1. one", "| a | b |", "|---+---|", "#+TBLFM: $2=$1", "# comment", ": fixed", "-----",
    "[fn:1] note", "#+NAME: x", "plain text", "é", "😀", "e\u{301}", " ", "\t", "\n", "\n", "\r\n", "\r", "",
]

func randomDocument(_ rng: inout SeededGenerator) -> String {
    (0..<Int.random(in: 0...40, using: &rng)).map { _ in
        fragments.randomElement(using: &rng)! + (Bool.random(using: &rng) ? "\n" : "")
    }.joined()
}

func checkLengths(_ node: SyntaxNode) -> Bool {
    let sum = node.green.children.reduce(0) { $0 + $1.length }
    return sum == node.green.length && node.children.allSatisfy(checkLengths)
}

struct RoundTripTests {
    @Test func fuzzedDocumentsRoundTrip() {
        var rng = SeededGenerator(state: 20261004)
        for n in 0..<2_000 {
            let text = randomDocument(&rng)
            let tree = OrgParser.parse(text)
            #expect(tree.text == text, "document \(n)")
            #expect(checkLengths(tree.root), "document \(n)")
        }
    }

    @Test(arguments: [
        [0xEF, 0xBB, 0xBF] + Array("* a\r\n".utf8),
        Array("* a\r\n- b\n\tc".utf8),
        Array("* a".utf8),
        Array("😀 e\u{301}\n".utf8),
        [0x2A, 0x20, 0xFF, 0x0A] as [UInt8],
    ])
    func encodingFixturesRoundTrip(bytes: [UInt8]) {
        let source = SourceText(bytes: bytes)
        let tree = OrgParser.parse(source.text)
        #expect(source.encode(tree.text) == bytes)
    }

    /// Private corpus: `ORGSTAR_CORPUS=/path/to/org swift test --filter corpus`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_CORPUS"] != nil))
    func corpusRoundTrips() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["org", "org_archive"].contains($0.pathExtension) }
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try [UInt8](Data(contentsOf: file))
            let source = SourceText(bytes: bytes)
            let tree = OrgParser.parse(source.text)
            #expect(source.encode(tree.text) == bytes, "\(file.path)")
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test`
Expected: all pass. The corpus test is skipped.

- [ ] **Step 3: Run the private corpus locally**

Run: `ORGSTAR_CORPUS=~/org swift test --filter corpusRoundTrips`
Expected: pass. Any failure names the file; reduce it to a fuzz fragment or a unit test before fixing.

- [ ] **Step 4: Commit**

```bash
git add Tests
git commit -m "Add round-trip fuzz, encoding and corpus tests"
```
