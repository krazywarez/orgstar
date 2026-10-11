# Semantic Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed facts over the parsed tree, so the index and commands never read raw text: headings with their planning, properties, clocks, timestamps and links; tag and property inheritance with provenance; table models; source blocks with resolved header arguments.

**Architecture:** `DocumentModel(tree:settings:)` walks the tree once. Each heading's own facts go into `HeadingInfo`; content of child sections stays with the child. Inheritance is computed on request from local values, so `HeadingInfo` stores only what is written under the heading. Every resolved value is a `Resolved<Value>` carrying a `ValueSource`. Source blocks resolve after the walk because their header arguments depend on file and heading properties.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Foundation only.

**Spec:** `docs/design.md`, "Semantic layer" and the inheritance rules under it.

## Global Constraints

- Local values and resolved values stay separate; inheritance never writes into `HeadingInfo`.
- Tags inherit by default minus an exclusion list; `#+FILETAGS` count as inherited.
- Properties don't inherit by default; `CATEGORY`, `ARCHIVE`, `COLUMNS`, `LOGGING` and `header-args*` always do; `ID` and `CUSTOM_ID` never do. `KEY+` appends with a space.
- Header arguments: org-babel defaults, then `header-args`, then `header-args:LANG` (each from `#+PROPERTY` down to the heading, a plain property replacing what is above it), then `#+HEADER` lines, then the begin line.

## Out of scope

Merging `:results` values by group (collection, type, format, handling), language default header arguments, `CATEGORY` defaulting to the file name (needs the workspace), and source body unescaping (`,*`). Each lands with the phase that needs it.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgCore/Semantic/SemanticSettings.swift` | Inheritance settings, `ValueSource`, `Resolved` |
| `Sources/OrgCore/Semantic/HeadingInfo.swift` | `HeadingInfo`, `Property`, `Clock` |
| `Sources/OrgCore/Semantic/DisplayWidth.swift` | Monospace column width of text |
| `Sources/OrgCore/Semantic/TableModel.swift` | Rows, rules, formulas, column widths |
| `Sources/OrgCore/Semantic/SrcBlockInfo.swift` | `SrcBlockInfo`, header argument parsing and defaults |
| `Sources/OrgCore/Semantic/DocumentModel.swift` | The walk, inheritance queries, header argument resolution |

---

### Task 1: Value types

**Files:**
- Create: `Sources/OrgCore/Semantic/SemanticSettings.swift`, `HeadingInfo.swift`, `DisplayWidth.swift`, `TableModel.swift`, `SrcBlockInfo.swift`
- Test: `Tests/OrgCoreTests/SemanticValueTests.swift`

**Interfaces:**
- Produces: `SemanticSettings` (`.default`, `PropertyInheritance` `.none`/`.all`/`.only(Set<String>)` of upper-cased keys), `ValueSource` (`.defaults`, `.file`, `.heading(Int)`, `.element`), `Resolved<Value>(_:_:)`, `Property(key:value:additive:)` and internal `Property(line:)`, `Clock(start:end:minutes:)`, `HeadingInfo`, `displayWidth(_:)`, `TableModel` (internal `init(node:heading:)`), `SrcBlockInfo`, `HeaderArguments.defaults`, `HeaderArguments.parse(_:) -> [(key: String, value: String)]`.

- [x] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct SemanticValueTests {
    @Test func parseHeaderArguments() {
        let pairs = HeaderArguments.parse("ignored :results output silent :dir /tmp :VAR x=1")
        #expect(pairs.map { "\($0.key)=\($0.value)" } == [":results=output silent", ":dir=/tmp", ":var=x=1"])
    }

    @Test func widths() {
        #expect(displayWidth("abc") == 3)
        #expect(displayWidth("日本") == 4)
        #expect(displayWidth("e\u{301}") == 1)
        #expect(displayWidth("😀") == 2)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter SemanticValueTests`
Expected: build failure, `cannot find 'HeaderArguments' in scope`.

- [x] **Step 3: Implement `SemanticSettings.swift`**

```swift
/// App-wide settings that change what a document means without changing how it parses.
public struct SemanticSettings: Sendable, Equatable {
    public enum PropertyInheritance: Sendable, Equatable {
        /// org's default: properties apply only to their own heading.
        case none
        case all
        /// Upper-cased property keys that inherit.
        case only(Set<String>)
    }

    public var tagInheritance: Bool
    public var tagsExcludedFromInheritance: Set<String>
    public var propertyInheritance: PropertyInheritance

    public init(
        tagInheritance: Bool = true,
        tagsExcludedFromInheritance: Set<String> = [],
        propertyInheritance: PropertyInheritance = .none
    ) {
        self.tagInheritance = tagInheritance
        self.tagsExcludedFromInheritance = tagsExcludedFromInheritance
        self.propertyInheritance = propertyInheritance
    }

    public static let `default` = SemanticSettings()
}

/// Where a resolved value came from.
public enum ValueSource: Sendable, Equatable {
    case defaults
    /// A file-level keyword such as `#+FILETAGS` or `#+PROPERTY`.
    case file
    /// A heading, by index into `DocumentModel.headings`.
    case heading(Int)
    /// The element itself: a `#+HEADER` line or a block's begin line.
    case element
}

public struct Resolved<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let source: ValueSource

    public init(_ value: Value, _ source: ValueSource) {
        self.value = value
        self.source = source
    }
}
```

- [x] **Step 4: Implement `HeadingInfo.swift`**

```swift
import Foundation

public struct Property: Sendable, Equatable {
    public let key: String
    public let value: String
    /// `:KEY+:` appends to the value instead of replacing it.
    public let additive: Bool

    public init(key: String, value: String, additive: Bool = false) {
        self.key = key
        self.value = value
        self.additive = additive
    }

    /// A `:KEY: value` or `:KEY+: value` drawer line.
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return nil }
        let rest = trimmed.dropFirst()
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        var key = rest[..<colon]
        guard !key.isEmpty else { return nil }
        let additive = key.hasSuffix("+")
        if additive { key = key.dropLast() }
        let value = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        self.init(key: String(key), value: value, additive: additive)
    }
}

public struct Clock: Sendable, Equatable {
    public let start: Timestamp.Point
    /// Nil while the clock is running.
    public let end: Timestamp.Point?
    /// From `=> H:MM`, when present.
    public let minutes: Int?
}

/// One heading and the facts that belong to it directly, not to its children.
public struct HeadingInfo: Sendable, Equatable {
    public internal(set) var sectionRange: Range<Int>
    public internal(set) var headingRange: Range<Int>
    public internal(set) var level: Int
    /// Index of the parent heading in `DocumentModel.headings`.
    public internal(set) var parent: Int?
    public internal(set) var todo: String?
    public internal(set) var isDone: Bool
    /// The cookie's value (`A`, `10`), when the heading has one.
    public internal(set) var priority: String?
    /// The title as written, markup included.
    public internal(set) var title: String
    public internal(set) var localTags: [String]
    /// Property drawer lines in order.
    public internal(set) var properties: [Property]
    public internal(set) var scheduled: Timestamp?
    public internal(set) var deadline: Timestamp?
    public internal(set) var closed: Timestamp?
    public internal(set) var clocks: [Clock]
    /// Timestamps in the title and body, excluding planning and clock lines.
    public internal(set) var timestamps: [Timestamp]
    /// Link targets in the title and body.
    public internal(set) var links: [String]

    /// The heading's own `ID`. Never inherited.
    public var id: String? {
        properties.last { $0.key.uppercased() == "ID" && !$0.additive }?.value
    }
}
```

- [x] **Step 5: Implement `DisplayWidth.swift`**

```swift
/// Columns a string occupies in a monospaced table: East Asian wide and fullwidth characters
/// and emoji take two, everything else one. Combining marks belong to their Character.
public func displayWidth(_ text: some StringProtocol) -> Int {
    text.reduce(0) { $0 + displayWidth(of: $1) }
}

func displayWidth(of character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 0 }
    if scalar.properties.isEmojiPresentation { return 2 }
    switch scalar.value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
         0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}
```

- [x] **Step 6: Implement `TableModel.swift`**

```swift
import Foundation

public struct TableModel: Sendable, Equatable {
    public enum Row: Sendable, Equatable {
        case rule
        /// Cell text with surrounding blanks trimmed.
        case cells([String])
    }

    public let range: Range<Int>
    public let heading: Int?
    public let rows: [Row]
    /// `#+TBLFM:` values in order.
    public let formulas: [String]
    /// Widest cell per column, in display columns.
    public let columnWidths: [Int]

    public var columnCount: Int { columnWidths.count }

    init(node: SyntaxNode, heading: Int?) {
        range = node.range
        self.heading = heading
        rows = node.children.filter { $0.kind == .tableRow }.map { row in
            let cells = row.children.filter { $0.kind == .tableCell }
            if cells.isEmpty, row.text.trimmingCharacters(in: .whitespaces).hasPrefix("|-") { return .rule }
            return .cells(cells.map { $0.text.trimmingCharacters(in: .whitespaces) })
        }
        formulas = node.children.filter { $0.kind == .tableFormula }.map {
            SettingsScanner.keywordValue($0.text.trimmingCharacters(in: .whitespacesAndNewlines)[...])
                .trimmingCharacters(in: .whitespaces)
        }
        var widths: [Int] = []
        for case .cells(let cells) in rows {
            for (column, cell) in cells.enumerated() {
                if column == widths.count { widths.append(0) }
                widths[column] = max(widths[column], displayWidth(cell))
            }
        }
        columnWidths = widths
    }
}
```

- [x] **Step 7: Implement `SrcBlockInfo.swift`**

```swift
public struct SrcBlockInfo: Sendable, Equatable {
    public let range: Range<Int>
    public let heading: Int?
    /// From an attached `#+NAME:` line.
    public let name: String?
    public let language: String?
    /// Words like `-n` or `-r` between the language and the first header argument.
    public let switches: [String]
    /// The lines between the begin and end lines, unchanged.
    public let body: String
    /// Keys keep their leading colon (`:results`).
    public let headerArguments: [String: Resolved<String>]
}

public enum HeaderArguments {
    /// org-babel's global defaults.
    public static let defaults: [String: String] = [
        ":session": "none", ":results": "replace", ":exports": "code", ":cache": "no",
        ":noweb": "no", ":hlines": "no", ":tangle": "no",
    ]

    /// `:key value :other value two` as ordered pairs. Keys are lower-cased and keep their colon;
    /// words before the first key are dropped.
    public static func parse(_ text: some StringProtocol) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix(":"), word.count > 1 {
                pairs.append((word.lowercased(), ""))
            } else if !pairs.isEmpty {
                let current = pairs[pairs.count - 1].value
                pairs[pairs.count - 1].value = current.isEmpty ? String(word) : current + " " + word
            }
        }
        return pairs
    }
}
```

- [x] **Step 8: Run to verify pass**

Run: `swift test --filter SemanticValueTests`
Expected: all pass.

- [x] **Step 9: Commit**

```bash
git add Sources/OrgCore/Semantic Tests/OrgCoreTests/SemanticValueTests.swift
git commit -m "Add semantic value types"
```

---

### Task 2: Document model

**Files:**
- Create: `Sources/OrgCore/Semantic/DocumentModel.swift`
- Test: `Tests/OrgCoreTests/SemanticTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `OrgTree`, `SyntaxNode`, `Timestamp.parse`, `SettingsScanner.keywordValue`, `splitRawLines`.
- Produces: `DocumentModel(tree:settings:)` with `headings`, `fileTags`, `fileProperties`, `tables`, `srcBlocks`, `ancestors(of:)`, `outlinePath(of:)`, `inherits(_:)`, `property(_:of:) -> Resolved<String>?`, `tags(of:) -> [Resolved<String>]`.

- [x] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

func model(_ text: String, _ settings: SemanticSettings = .default) -> DocumentModel {
    DocumentModel(tree: OrgParser.parse(text), settings: settings)
}

struct HeadingInfoTests {
    @Test func basics() {
        let m = model("* TODO [#A] Write *plan* :work:\n** DONE Sub\n")
        #expect(m.headings.count == 2)
        let top = m.headings[0]
        #expect(top.level == 1)
        #expect(top.todo == "TODO")
        #expect(!top.isDone)
        #expect(top.priority == "A")
        #expect(top.title == "Write *plan*")
        #expect(top.localTags == ["work"])
        #expect(top.parent == nil)
        #expect(m.headings[1].parent == 0)
        #expect(m.headings[1].isDone)
        #expect(m.outlinePath(of: 1) == ["Write *plan*", "Sub"])
    }

    @Test func planningPropertiesClocksAndBody() throws {
        let text = """
        * a
        SCHEDULED: <2026-10-04 Sun> DEADLINE: <2026-10-10 Sat -2d>
        :PROPERTIES:
        :ID: abc
        :Effort: 1:00
        :END:
        :LOGBOOK:
        CLOCK: [2026-10-04 Sun 10:00]--[2026-10-04 Sun 11:30] =>  1:30
        CLOCK: [2026-10-05 Mon 09:00]
        :END:
        See <2026-10-07 Wed> and [[https://a.b][x]].

        """
        let h = model(text).headings[0]
        #expect(h.scheduled?.start.day == 4)
        #expect(h.deadline?.warning?.interval.value == 2)
        #expect(h.closed == nil)
        #expect(h.id == "abc")
        #expect(h.properties == [Property(key: "ID", value: "abc"), Property(key: "Effort", value: "1:00")])
        #expect(h.clocks.count == 2)
        #expect(h.clocks[0].minutes == 90)
        #expect(h.clocks[0].end?.hour == 11)
        #expect(h.clocks[1].end == nil)
        #expect(h.timestamps == [try #require(Timestamp.parse("<2026-10-07 Wed>"))])
        #expect(h.links == ["https://a.b"])
    }

    @Test func childContentStaysWithChild() {
        let m = model("* a\n** b\n<2026-10-04 Sun>\n")
        #expect(m.headings[0].timestamps.isEmpty)
        #expect(m.headings[1].timestamps.count == 1)
    }

    @Test func titleTimestampsAndLinks() {
        let h = model("* Call <2026-10-04 Sun> [[id:x][y]]\n").headings[0]
        #expect(h.timestamps.count == 1)
        #expect(h.links == ["id:x"])
    }

    @Test func doneStatesComeFromFileSettings() {
        let m = model("#+TODO: NEXT | SHIPPED\n* SHIPPED x\n")
        #expect(m.headings[0].isDone)
    }
}

struct InheritanceTests {
    @Test func tagInheritance() {
        let text = "#+FILETAGS: :f:\n* a :x:noinherit:\n** b :y:\n"
        let m = model(text, SemanticSettings(tagsExcludedFromInheritance: ["noinherit"]))
        #expect(m.tags(of: 1).map(\.value) == ["f", "x", "y"])
        #expect(m.tags(of: 1).map(\.source) == [.file, .heading(0), .heading(1)])
        #expect(model(text, SemanticSettings(tagInheritance: false)).tags(of: 1).map(\.value) == ["y"])
    }

    @Test func ownTagWinsOverInherited() {
        #expect(model("* a :x:\n** b :x:\n").tags(of: 1) == [Resolved("x", .heading(1))])
    }

    @Test func propertyPolicies() {
        let text = "#+PROPERTY: owner team\n* a\n:PROPERTIES:\n:OWNER: alice\n:CATEGORY: work\n:ID: p\n:END:\n** b\n"
        let plain = model(text)
        #expect(plain.property("OWNER", of: 1) == nil)
        #expect(plain.property("CATEGORY", of: 1) == Resolved("work", .heading(0)))
        #expect(plain.property("OWNER", of: nil) == Resolved("team", .file))

        let all = model(text, SemanticSettings(propertyInheritance: .all))
        #expect(all.property("owner", of: 1) == Resolved("alice", .heading(0)))
        #expect(all.property("ID", of: 1) == nil)

        let some = model(text, SemanticSettings(propertyInheritance: .only(["OWNER"])))
        #expect(some.property("OWNER", of: 1) == Resolved("alice", .heading(0)))
    }

    @Test func additiveProperties() {
        let text = "* a\n:PROPERTIES:\n:VAR: x=1\n:END:\n** b\n:PROPERTIES:\n:VAR+: y=2\n:END:\n"
        #expect(model(text, SemanticSettings(propertyInheritance: .all)).property("VAR", of: 1) == Resolved("x=1 y=2", .heading(1)))
        #expect(model(text).property("VAR", of: 1) == Resolved("y=2", .heading(1)))
    }
}

struct SrcBlockTests {
    @Test func resolution() throws {
        let text = """
        #+PROPERTY: header-args :dir /a :cache yes
        #+PROPERTY: header-args:sh :results output
        * a
        :PROPERTIES:
        :header-args+: :dir /b
        :END:
        #+NAME: hello
        #+HEADER: :var x=1
        #+begin_src sh -n :results silent
        echo $x
        #+end_src

        """
        let block = try #require(model(text).srcBlocks.first)
        #expect(block.name == "hello")
        #expect(block.language == "sh")
        #expect(block.switches == ["-n"])
        #expect(block.body == "echo $x\n")
        #expect(block.heading == 0)
        #expect(block.headerArguments[":dir"] == Resolved("/b", .heading(0)))
        #expect(block.headerArguments[":cache"] == Resolved("yes", .file))
        #expect(block.headerArguments[":results"] == Resolved("silent", .element))
        #expect(block.headerArguments[":var"] == Resolved("x=1", .element))
        #expect(block.headerArguments[":exports"] == Resolved("code", .defaults))
    }

    @Test func plainPropertyReplacesInheritedHeaderArguments() {
        let text = "#+PROPERTY: header-args :dir /a\n* a\n:PROPERTIES:\n:header-args: :cache yes\n:END:\n#+begin_src sh\n#+end_src\n"
        let block = model(text).srcBlocks[0]
        #expect(block.headerArguments[":dir"] == nil)
        #expect(block.headerArguments[":cache"] == Resolved("yes", .heading(0)))
    }

    @Test func blankLineDetachesAffiliatedKeywords() {
        #expect(model("#+NAME: x\n\n#+begin_src sh\n#+end_src\n").srcBlocks[0].name == nil)
    }

    @Test func otherBlocksAreNotSourceBlocks() {
        #expect(model("#+begin_example\nx\n#+end_example\n").srcBlocks.isEmpty)
    }
}

struct TableModelTests {
    @Test func rowsFormulasAndWidths() {
        let table = model("| a | 日本 |\n|---+---|\n| 😀 | b |\n#+TBLFM: $2=$1\n").tables[0]
        #expect(table.rows == [.cells(["a", "日本"]), .rule, .cells(["😀", "b"])])
        #expect(table.formulas == ["$2=$1"])
        #expect(table.columnWidths == [2, 4])
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter HeadingInfoTests`
Expected: build failure, `cannot find 'DocumentModel' in scope`.

- [x] **Step 3: Implement**

```swift
import Foundation

/// Typed facts read from one parsed document. Built once per tree; commands and the index read
/// this rather than raw text.
public struct DocumentModel: Sendable {
    public let settings: SemanticSettings
    public let orgSettings: OrgSettings
    public private(set) var headings: [HeadingInfo] = []
    public private(set) var fileTags: [String] = []
    /// `#+PROPERTY:` lines in order.
    public private(set) var fileProperties: [Property] = []
    public private(set) var tables: [TableModel] = []
    public private(set) var srcBlocks: [SrcBlockInfo] = []

    /// Always inherited, whatever the inheritance setting.
    static let alwaysInherited: Set<String> = ["CATEGORY", "ARCHIVE", "COLUMNS", "LOGGING"]
    /// Identify one heading, so never inherited.
    static let neverInherited: Set<String> = ["ID", "CUSTOM_ID"]

    private typealias PendingBlock = (node: SyntaxNode, heading: Int?, affiliated: [SyntaxNode])

    public init(tree: OrgTree, settings: SemanticSettings = .default) {
        self.settings = settings
        self.orgSettings = tree.settings
        var pending: [PendingBlock] = []
        walk(tree.root, heading: nil, pending: &pending)
        // Header arguments depend on file and heading properties, so blocks resolve last.
        srcBlocks = pending.map { srcBlock($0.node, heading: $0.heading, affiliated: $0.affiliated) }
    }

    // MARK: - Queries

    /// Ancestor indexes of a heading, outermost first.
    public func ancestors(of index: Int) -> [Int] {
        var result: [Int] = []
        var current = headings[index].parent
        while let parent = current {
            result.insert(parent, at: 0)
            current = headings[parent].parent
        }
        return result
    }

    /// Titles from the outermost ancestor down to the heading itself.
    public func outlinePath(of index: Int) -> [String] {
        (ancestors(of: index) + [index]).map { headings[$0].title }
    }

    public func inherits(_ key: String) -> Bool {
        let key = key.uppercased()
        if Self.neverInherited.contains(key) { return false }
        if Self.alwaysInherited.contains(key) || key.hasPrefix("HEADER-ARGS") { return true }
        switch settings.propertyInheritance {
        case .none: return false
        case .all: return true
        case .only(let keys): return keys.contains(key)
        }
    }

    /// The value of `key` for a heading, or for the file when `index` is nil. Inherited keys
    /// start from `#+PROPERTY` and walk down the ancestors; `KEY+` lines append with a space.
    public func property(_ key: String, of index: Int?) -> Resolved<String>? {
        let key = key.uppercased()
        var layers: [(entries: [Property], source: ValueSource)] = []
        if let index {
            if inherits(key) {
                layers.append((fileProperties, .file))
                layers += ancestors(of: index).map { (headings[$0].properties, .heading($0)) }
            }
            layers.append((headings[index].properties, .heading(index)))
        } else {
            layers.append((fileProperties, .file))
        }
        var result: Resolved<String>?
        for layer in layers {
            for entry in layer.entries where entry.key.uppercased() == key {
                if entry.additive, let current = result {
                    result = Resolved(current.value + " " + entry.value, layer.source)
                } else {
                    result = Resolved(entry.value, layer.source)
                }
            }
        }
        return result
    }

    /// Inherited tags first (file tags, then ancestors outermost first), then the heading's own.
    /// A tag the heading has itself counts as its own.
    public func tags(of index: Int) -> [Resolved<String>] {
        let local = headings[index].localTags
        var inherited: [Resolved<String>] = []
        if settings.tagInheritance {
            let layers = [(fileTags, ValueSource.file)] + ancestors(of: index).map { (headings[$0].localTags, ValueSource.heading($0)) }
            for (tags, source) in layers {
                for tag in tags where !settings.tagsExcludedFromInheritance.contains(tag)
                    && !local.contains(tag) && !inherited.contains(where: { $0.value == tag }) {
                    inherited.append(Resolved(tag, source))
                }
            }
        }
        var own: [Resolved<String>] = []
        for tag in local where !own.contains(where: { $0.value == tag }) {
            own.append(Resolved(tag, .heading(index)))
        }
        return inherited + own
    }

    // MARK: - Building

    private mutating func walk(_ node: SyntaxNode, heading: Int?, pending: inout [PendingBlock]) {
        var previous: SyntaxNode?
        var affiliated: [SyntaxNode] = []
        for child in node.children {
            // Blank lines between nodes detach affiliated keywords.
            if let previous, previous.range.upperBound != child.range.lowerBound { affiliated = [] }
            switch child.kind {
            case .section:
                section(child, parent: heading, pending: &pending)
            case .heading, .affiliatedKeyword:
                break
            case .planning:
                if let heading { planning(child, heading) }
            case .propertyDrawer:
                if let heading {
                    headings[heading].properties += child.children.filter { $0.kind == .nodeProperty }.compactMap { Property(line: $0.text) }
                }
            case .clock:
                if let heading, let clock = clock(child) { headings[heading].clocks.append(clock) }
            case .timestamp:
                if let heading, let stamp = Timestamp.parse(child.text) { headings[heading].timestamps.append(stamp) }
            case .link:
                if let heading { headings[heading].links.append(linkTarget(child)) }
            case .keyword:
                fileKeyword(child)
            case .table:
                tables.append(TableModel(node: child, heading: heading))
                walk(child, heading: heading, pending: &pending)
            case .block:
                if Self.isSrcBlock(child) { pending.append((child, heading, affiliated)) }
            default:
                walk(child, heading: heading, pending: &pending)
            }
            affiliated = child.kind == .affiliatedKeyword ? affiliated + [child] : []
            previous = child
        }
    }

    private mutating func section(_ node: SyntaxNode, parent: Int?, pending: inout [PendingBlock]) {
        guard let headingNode = node.children.first(where: { $0.kind == .heading }) else { return }
        let index = headings.count
        let tokens = headingNode.tokens
        let todo = tokens.first { $0.kind == .todoKeyword }?.text
        let title = headingNode.children.first { $0.kind == .title }
        headings.append(HeadingInfo(
            sectionRange: node.range,
            headingRange: headingNode.range,
            level: tokens.first { $0.kind == .stars }?.text.count ?? 0,
            parent: parent,
            todo: todo,
            isDone: todo.map(orgSettings.isDone) ?? false,
            priority: tokens.first { $0.kind == .priority }.map { String($0.text.dropFirst(2).dropLast()) },
            title: title?.text ?? "",
            localTags: tokens.first { $0.kind == .tags }.map { $0.text.split(separator: ":").map(String.init) } ?? [],
            properties: [], scheduled: nil, deadline: nil, closed: nil, clocks: [], timestamps: [], links: []
        ))
        if let title { walk(title, heading: index, pending: &pending) }
        walk(node, heading: index, pending: &pending)
    }

    /// Each timestamp belongs to the keyword just before it.
    private mutating func planning(_ node: SyntaxNode, _ heading: Int) {
        let text = node.text
        for stampNode in node.children where stampNode.kind == .timestamp {
            guard let stamp = Timestamp.parse(stampNode.text) else { continue }
            let end = String.Index(utf16Offset: stampNode.offset - node.offset, in: text)
            let before = text[..<end].trimmingCharacters(in: .whitespaces)
            if before.hasSuffix("SCHEDULED:") {
                headings[heading].scheduled = stamp
            } else if before.hasSuffix("DEADLINE:") {
                headings[heading].deadline = stamp
            } else if before.hasSuffix("CLOSED:") {
                headings[heading].closed = stamp
            }
        }
    }

    private func clock(_ node: SyntaxNode) -> Clock? {
        guard let stampNode = node.children.first(where: { $0.kind == .timestamp }),
              let stamp = Timestamp.parse(stampNode.text) else { return nil }
        var minutes: Int?
        if let arrow = node.text.range(of: "=>") {
            let parts = node.text[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            if parts.count == 2, let hours = Int(parts[0]), let mins = Int(parts[1]) { minutes = hours * 60 + mins }
        }
        return Clock(start: stamp.start, end: stamp.end, minutes: minutes)
    }

    private func linkTarget(_ node: SyntaxNode) -> String {
        if let path = node.tokens.first(where: { $0.kind == .linkPath }) { return path.text }
        let text = node.text
        if text.hasPrefix("<"), text.hasSuffix(">") { return String(text.dropFirst().dropLast()) }
        return text
    }

    private mutating func fileKeyword(_ node: SyntaxNode) {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return }
        let key = text[text.index(text.startIndex, offsetBy: 2)..<colon].uppercased()
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "FILETAGS":
            fileTags += value.split(whereSeparator: { $0 == ":" || $0.isWhitespace }).map(String.init)
        case "PROPERTY":
            let parts = value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard var name = parts.first.map(String.init) else { return }
            let additive = name.hasSuffix("+")
            if additive { name.removeLast() }
            fileProperties.append(Property(key: name, value: parts.count > 1 ? String(parts[1]) : "", additive: additive))
        default:
            break
        }
    }

    // MARK: - Source blocks

    static func isSrcBlock(_ node: SyntaxNode) -> Bool {
        node.text.drop { $0 == " " || $0 == "\t" }.lowercased().hasPrefix("#+begin_src")
    }

    private func srcBlock(_ node: SyntaxNode, heading: Int?, affiliated: [SyntaxNode]) -> SrcBlockInfo {
        let raw = splitRawLines(node.text)
        let beginLine = raw[0].content.drop { $0 == " " || $0 == "\t" }.dropFirst("#+begin_src".count)
        let words = beginLine.split(whereSeparator: \.isWhitespace)
        var language: String?
        var switches: [String] = []
        var rest = words[...]
        if let first = rest.first, !first.hasPrefix("-"), !first.hasPrefix("+"), !first.hasPrefix(":") {
            language = String(first)
            rest = rest.dropFirst()
        }
        while let word = rest.first, !word.hasPrefix(":") {
            switches.append(String(word))
            rest = rest.dropFirst()
        }
        let body = raw.dropFirst().dropLast().map { String($0.content) + String($0.ending) }.joined()

        var name: String?
        var headerLines: [String] = []
        for keyword in affiliated {
            let text = keyword.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = SettingsScanner.keywordValue(text[...]).trimmingCharacters(in: .whitespaces)
            if text.uppercased().hasPrefix("#+NAME:") { name = value }
            if text.uppercased().hasPrefix("#+HEADER:") { headerLines.append(value) }
        }

        var arguments = HeaderArguments.defaults.mapValues { Resolved($0, .defaults) }
        var keys = ["header-args"]
        if let language { keys.append("header-args:\(language)") }
        for key in keys {
            for pair in headerArgumentLayers(key, heading: heading) {
                arguments[pair.key] = Resolved(pair.value, pair.source)
            }
        }
        for line in headerLines + [rest.joined(separator: " ")] {
            for pair in HeaderArguments.parse(line) {
                arguments[pair.key] = Resolved(pair.value, .element)
            }
        }
        return SrcBlockInfo(
            range: node.range, heading: heading, name: name, language: language,
            switches: switches, body: body, headerArguments: arguments
        )
    }

    /// `header-args` pairs from `#+PROPERTY` down to the heading. As in org, a plain property
    /// replaces everything above it; `header-args+` adds to it.
    private func headerArgumentLayers(_ key: String, heading: Int?) -> [(key: String, value: String, source: ValueSource)] {
        var layers: [(entries: [Property], source: ValueSource)] = [(fileProperties, .file)]
        if let heading {
            layers += (ancestors(of: heading) + [heading]).map { (headings[$0].properties, .heading($0)) }
        }
        var pairs: [(key: String, value: String, source: ValueSource)] = []
        for layer in layers {
            for entry in layer.entries where entry.key.lowercased() == key {
                let parsed = HeaderArguments.parse(entry.value).map { (key: $0.key, value: $0.value, source: layer.source) }
                pairs = entry.additive ? pairs + parsed : parsed
            }
        }
        return pairs
    }
}
```

- [x] **Step 4: Run all tests**

Run: `swift test`
Expected: all pass.

- [x] **Step 5: Commit**

```bash
git add Sources/OrgCore/Semantic/DocumentModel.swift Tests/OrgCoreTests/SemanticTests.swift
git commit -m "Add document model with inheritance and header arguments"
```

---

### Task 3: Build the model in fuzz and corpus tests

**Files:**
- Modify: `Tests/OrgCoreTests/RoundTripTests.swift`

- [x] **Step 1: Build a model for every parsed document**

```diff
@@ -45,6 +45,7 @@ struct RoundTripTests {
             let tree = OrgParser.parse(text)
             #expect(tree.text == text, "document \(n)")
             #expect(checkLengths(tree.root), "document \(n)")
+            _ = DocumentModel(tree: tree)
         }
     }
 
@@ -74,6 +75,7 @@ struct RoundTripTests {
             let source = SourceText(bytes: bytes)
             let tree = OrgParser.parse(source.text)
             #expect(source.encode(tree.text) == bytes, "\(file.path)")
+            _ = DocumentModel(tree: tree)
         }
     }
 }
```

- [x] **Step 2: Run**

Run: `swift test` then `ORGSTAR_CORPUS=~/Documents/notes swift test --filter corpusRoundTrips`
Expected: all pass, no crashes.

- [x] **Step 3: Commit**

```bash
git add Tests/OrgCoreTests/RoundTripTests.swift
git commit -m "Build document models in fuzz and corpus tests"
```
