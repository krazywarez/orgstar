# Inline Objects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse org's inline objects into the lossless tree: emphasis, links, timestamps, footnote references, statistics cookies, targets, macros, inline source blocks, LaTeX fragments, line breaks and superscripts.

**Architecture:** A character-level `InlineScanner` turns a run of text into text, newline and object nodes through the existing `GreenBuilder`. The parser feeds it whole paragraphs (so emphasis and links can cross one line break), heading titles, table cells, item paragraphs, footnote definitions, and planning and clock lines. `Timestamp` is both the recognizer and a public value type with repeaters and warnings.

**Tech Stack:** Swift 6.2 tools, Swift Testing, Foundation only.

**Spec:** `docs/design.md` ("OrgCore data model"); OrgSwift's `OrgInlineParser.swift` for the emphasis border rules.

## Global Constraints

- Every character of the input lands in exactly one token; tree text equals source text.
- Emphasis follows org's defaults: opener preceded by start, whitespace or `-({'"`; closer followed by end, whitespace or `-.,:!?;'")}\[`; body neither starts nor ends with whitespace; at most one line break.
- `OrgCore` imports Foundation only.

## Out of scope

Entities (`\alpha`), subscripts, `$...$` LaTeX, export snippets, citations, radio targets, inline footnote definitions as parsed content, and description-list terms. Each is recorded for a later plan.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/OrgCore/Timestamp.swift` | `Timestamp` value type and `scanTimestamp` recognizer |
| `Sources/OrgCore/Parser/Inline.swift` | `InlineScanner` and `Parser.inline(_:)` |
| `Sources/OrgCore/Syntax/SyntaxKind.swift` | New token and object kinds; `title` becomes a node |
| `Sources/OrgCore/Parser/Parser.swift` | Paragraph spans, item bullets and checkboxes, table cells, footnote labels, inline planning and clock lines |
| `Sources/OrgCore/Parser/Lines.swift` | Empty final line ending sliced from the source, so spans can end there |

---

### Task 1: Timestamps

**Files:**
- Create: `Sources/OrgCore/Timestamp.swift`
- Test: `Tests/OrgCoreTests/TimestampTests.swift`

**Interfaces:**
- Produces: `Timestamp` (`active`, `start: Point`, `end: Point?`, `repeater: Repeater?`, `warning: Warning?`), `Timestamp.parse(_:) -> Timestamp?`; internal `scanTimestamp(_ chars: [Character], at: Int, limit: Int) -> (stamp: Timestamp, end: Int)?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

struct TimestampTests {
    @Test func fullTimestamp() throws {
        let stamp = try #require(Timestamp.parse("<2026-10-04 Sun 10:00-11:30 .+1w/2w --2d>"))
        #expect(stamp.active)
        #expect(stamp.start == Timestamp.Point(year: 2026, month: 10, day: 4, hour: 10, minute: 0))
        #expect(stamp.end == Timestamp.Point(year: 2026, month: 10, day: 4, hour: 11, minute: 30))
        #expect(stamp.repeater == Timestamp.Repeater(
            kind: .restart,
            interval: .init(value: 1, unit: .week),
            habitDeadline: .init(value: 2, unit: .week)
        ))
        #expect(stamp.warning == Timestamp.Warning(firstOccurrenceOnly: true, interval: .init(value: 2, unit: .day)))
    }

    @Test func dateOnlyInactive() throws {
        let stamp = try #require(Timestamp.parse("[2026-10-04]"))
        #expect(!stamp.active)
        #expect(stamp.start.hour == nil)
    }

    @Test func dateRange() throws {
        let stamp = try #require(Timestamp.parse("[2026-10-04 Sun]--[2026-10-06 Tue]"))
        #expect(stamp.end?.day == 6)
    }

    @Test func repeaterKinds() {
        #expect(Timestamp.parse("<2026-10-04 +1d>")?.repeater?.kind == .cumulate)
        #expect(Timestamp.parse("<2026-10-04 ++1m>")?.repeater?.kind == .catchUp)
        #expect(Timestamp.parse("<2026-10-04 -3d +1y>")?.repeater?.interval == .init(value: 1, unit: .year))
    }

    @Test func oneDigitHourAndOtherLanguages() {
        #expect(Timestamp.parse("<2026-10-04 9:05>")?.start.hour == 9)
        #expect(Timestamp.parse("<2026-10-04 dim.>") != nil)
    }

    @Test(arguments: ["<2026-10-4>", "<2026-10-04 Sun", "[2026-10-04 Sun]x", "<2026-10-04 Sun +1x>", "<2026-10-04]", "2026-10-04"])
    func rejects(text: String) {
        #expect(Timestamp.parse(text) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TimestampTests`
Expected: build failure, `cannot find 'Timestamp' in scope`.

- [ ] **Step 3: Implement**

```swift
public struct Timestamp: Sendable, Equatable {
    public enum Unit: Character, Sendable {
        case hour = "h", day = "d", week = "w", month = "m", year = "y"
    }

    public struct Interval: Sendable, Equatable {
        public var value: Int
        public var unit: Unit
    }

    public enum RepeaterKind: String, Sendable {
        case cumulate = "+", catchUp = "++", restart = ".+"
    }

    public struct Repeater: Sendable, Equatable {
        public var kind: RepeaterKind
        public var interval: Interval
        /// The habit deadline from `.+2d/3d`.
        public var habitDeadline: Interval?
    }

    public struct Warning: Sendable, Equatable {
        /// `--` warns only for the first occurrence of a repeated timestamp.
        public var firstOccurrenceOnly: Bool
        public var interval: Interval
    }

    public struct Point: Sendable, Equatable {
        public var year: Int
        public var month: Int
        public var day: Int
        public var hour: Int?
        public var minute: Int?
    }

    public var active: Bool
    public var start: Point
    /// End of a same-day time range or of a `--` date range.
    public var end: Point?
    public var repeater: Repeater?
    public var warning: Warning?

    /// Parses exactly one timestamp or range, with nothing before or after it.
    public static func parse(_ text: some StringProtocol) -> Timestamp? {
        let chars = Array(text)
        guard let result = scanTimestamp(chars, at: 0, limit: chars.count), result.end == chars.count else { return nil }
        return result.stamp
    }
}

/// A timestamp or `--` range starting at `start`, and the index after it.
func scanTimestamp(_ chars: [Character], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
    guard let first = scanSingleTimestamp(chars, at: start, limit: limit) else { return nil }
    if first.stamp.end == nil, first.end + 2 < limit, chars[first.end] == "-", chars[first.end + 1] == "-",
       let second = scanSingleTimestamp(chars, at: first.end + 2, limit: limit),
       second.stamp.active == first.stamp.active, second.stamp.end == nil {
        var range = first.stamp
        range.end = second.stamp.start
        return (range, second.end)
    }
    return first
}

/// `<YYYY-MM-DD DAY HH:MM-HH:MM REPEATER WARNING>`, or the same in `[...]` for inactive.
private func scanSingleTimestamp(_ chars: [Character], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
    guard start < limit, chars[start] == "<" || chars[start] == "[" else { return nil }
    let active = chars[start] == "<"
    let close: Character = active ? ">" : "]"
    var j = start + 1

    func number(_ minDigits: Int, _ maxDigits: Int) -> Int? {
        var k = j
        while k < limit, k - j < maxDigits, chars[k].isASCII, chars[k].isNumber { k += 1 }
        guard k - j >= minDigits else { return nil }
        let value = Int(String(chars[j..<k]))!
        j = k
        return value
    }

    func take(_ c: Character) -> Bool {
        guard j < limit, chars[j] == c else { return false }
        j += 1
        return true
    }

    func interval() -> Timestamp.Interval? {
        let before = j
        guard let value = number(1, 9), j < limit, let unit = Timestamp.Unit(rawValue: chars[j]) else {
            j = before
            return nil
        }
        j += 1
        return Timestamp.Interval(value: value, unit: unit)
    }

    func repeater() -> Timestamp.Repeater? {
        let before = j
        let kind: Timestamp.RepeaterKind
        if j + 1 < limit, chars[j] == ".", chars[j + 1] == "+" {
            kind = .restart
            j += 2
        } else if j + 1 < limit, chars[j] == "+", chars[j + 1] == "+" {
            kind = .catchUp
            j += 2
        } else if take("+") {
            kind = .cumulate
        } else {
            return nil
        }
        guard let value = interval() else {
            j = before
            return nil
        }
        var deadline: Timestamp.Interval?
        if take("/") {
            deadline = interval()
            if deadline == nil {
                j = before
                return nil
            }
        }
        return Timestamp.Repeater(kind: kind, interval: value, habitDeadline: deadline)
    }

    func warning() -> Timestamp.Warning? {
        let before = j
        guard take("-") else { return nil }
        let firstOnly = take("-")
        guard let value = interval() else {
            j = before
            return nil
        }
        return Timestamp.Warning(firstOccurrenceOnly: firstOnly, interval: value)
    }

    guard let year = number(4, 4), take("-"), let month = number(2, 2), take("-"), let day = number(2, 2) else {
        return nil
    }
    var stamp = Timestamp(
        active: active,
        start: Timestamp.Point(year: year, month: month, day: day, hour: nil, minute: nil),
        end: nil, repeater: nil, warning: nil
    )

    // Day name: anything but digits, whitespace, `+`, `-`, `]` and `>`, in any language.
    if j < limit, chars[j] == " " {
        var k = j + 1
        while k < limit, !(chars[k].isNumber || chars[k].isWhitespace || "+-]>".contains(chars[k])) { k += 1 }
        if k > j + 1 { j = k }
    }

    let beforeTime = j
    if take(" "), let hour = number(1, 2), take(":"), let minute = number(2, 2) {
        stamp.start.hour = hour
        stamp.start.minute = minute
        let beforeEnd = j
        if take("-"), let endHour = number(1, 2), take(":"), let endMinute = number(2, 2) {
            stamp.end = Timestamp.Point(year: year, month: month, day: day, hour: endHour, minute: endMinute)
        } else {
            j = beforeEnd
        }
    } else {
        j = beforeTime
    }

    while j < limit, chars[j] == " " {
        let beforeModifier = j
        j += 1
        if let value = repeater() {
            stamp.repeater = value
        } else if let value = warning() {
            stamp.warning = value
        } else {
            j = beforeModifier
            break
        }
    }

    guard take(close) else { return nil }
    return (stamp, j)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TimestampTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrgCore/Timestamp.swift Tests/OrgCoreTests/TimestampTests.swift
git commit -m "Add timestamp recognizer and value type"
```

---

### Task 2: Inline scanner and parser integration

**Files:**
- Create: `Sources/OrgCore/Parser/Inline.swift`
- Modify: `Sources/OrgCore/Syntax/SyntaxKind.swift`, `Sources/OrgCore/Parser/Parser.swift`, `Sources/OrgCore/Parser/Lines.swift`
- Test: `Tests/OrgCoreTests/InlineTests.swift`; update `Tests/OrgCoreTests/ParserSectionTests.swift` (title is a node)

**Interfaces:**
- Consumes: `scanTimestamp` (Task 1), `GreenBuilder`, `Parser`.
- Produces: `InlineScanner(chars:)` with `scan(_:into:inLink:)`; `Parser.inline(_ text: Substring)`; `Parser.span(from:through:)`; node kinds `title`, `tableCell`, `bold`, `italic`, `underline`, `strikeThrough`, `verbatim`, `code`, `link`, `linkDescription`, `timestamp`, `footnoteReference`, `statisticsCookie`, `target`, `macro`, `inlineSourceBlock`, `latexFragment`, `lineBreak`, `superscript`; token kinds `marker`, `linkPath`, `bullet`, `checkbox`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OrgCore

/// `kind:text` for each object directly inside the first paragraph.
func objects(_ text: String) -> [String] {
    let paragraph = OrgParser.parse(text).root.descendants().first { $0.kind == .paragraph }!
    return paragraph.children.map { "\($0.kind.rawValue):\($0.text)" }
}

struct InlineTests {
    @Test(arguments: [
        ("*b* /i/ _u_ +s+ =v= ~c~", ["bold:*b*", "italic:/i/", "underline:_u_", "strikeThrough:+s+", "verbatim:=v=", "code:~c~"]),
        ("a*b* (*c*) \"*d*\"", ["bold:*c*", "bold:*d*"]),
        ("x *y * z", []),
        ("*y*z", []),
        ("*a\nb*", ["bold:*a\nb*"]),
        ("*a\nb\nc*", []),
        ("=*not bold*=", ["verbatim:=*not bold*="]),
        ("[[https://a.b][the *site*]]", ["link:[[https://a.b][the *site*]]"]),
        ("[[file:x.org]]", ["link:[[file:x.org]]"]),
        ("<https://a.b/c>", ["link:<https://a.b/c>"]),
        ("see https://a.b/c.", ["link:https://a.b/c"]),
        ("<2026-10-04 Sun 10:00-11:30 +1w -2d>", ["timestamp:<2026-10-04 Sun 10:00-11:30 +1w -2d>"]),
        ("[2026-10-04 Sun]--[2026-10-06 Tue]", ["timestamp:[2026-10-04 Sun]--[2026-10-06 Tue]"]),
        ("a [fn:1] and [fn::inline [x] note]", ["footnoteReference:[fn:1]", "footnoteReference:[fn::inline [x] note]"]),
        ("a [1/3] [50%]", ["statisticsCookie:[1/3]", "statisticsCookie:[50%]"]),
        ("a <<target>> {{{m(x, y)}}}", ["target:<<target>>", "macro:{{{m(x, y)}}}"]),
        ("\\(x^2\\) and src_sh[:results raw]{echo {a}}", ["latexFragment:\\(x^2\\)", "inlineSourceBlock:src_sh[:results raw]{echo {a}}"]),
        ("N^2 and e^{i}", ["superscript:^2", "superscript:^{i}"]),
        ("end\\\\\nnext", ["lineBreak:\\\\"]),
    ])
    func recognizes(text: String, expected: [String]) {
        #expect(objects(text) == expected)
    }

    @Test func emphasisNests() {
        let bold = OrgParser.parse("*bold /italic/ x*\n").root.descendants().first { $0.kind == .bold }!
        #expect(bold.children.map(\.kind) == [.italic])
        #expect(bold.tokens.first?.kind == .marker)
    }

    @Test func linkParts() {
        let link = OrgParser.parse("[[id:abc][desc]]\n").root.descendants().first { $0.kind == .link }!
        #expect(link.tokens.map(\.kind) == [.marker, .linkPath, .marker, .marker])
        #expect(link.tokens.first { $0.kind == .linkPath }?.text == "id:abc")
        #expect(link.children.map(\.kind) == [.linkDescription])
    }

    @Test func noLinksInsideLinkDescriptions() {
        let link = OrgParser.parse("[[a][see https://b.c]]\n").root.descendants().first { $0.kind == .link }!
        #expect(link.descendants().filter { $0.kind == .link }.count == 1)
    }

    @Test func headingTitlesHoldObjects() {
        let title = OrgParser.parse("* TODO Read [[https://a.b][it]] [1/2]\n").root.descendants().first { $0.kind == .title }!
        #expect(title.children.map(\.kind) == [.link, .statisticsCookie])
    }

    @Test func planningHoldsTimestamps() {
        let planning = OrgParser.parse("* a\nDEADLINE: <2026-10-04 Sun -2d> SCHEDULED: <2026-10-01 Thu>\n").root
            .descendants().first { $0.kind == .planning }!
        #expect(planning.children.map(\.kind) == [.timestamp, .timestamp])
    }

    @Test func itemsSplitBulletAndCheckbox() {
        let item = OrgParser.parse("  - [X] done *now*\n    more\n").root.descendants().first { $0.kind == .item }!
        #expect(item.tokens.map(\.kind) == [.whitespace, .bullet, .whitespace, .checkbox, .whitespace])
        #expect(item.children.map(\.kind) == [.paragraph])
        #expect(item.children[0].text == "done *now*\n    more\n")
    }

    @Test func emptyItem() {
        let item = OrgParser.parse("-\n").root.descendants().first { $0.kind == .item }!
        #expect(item.tokens.map(\.kind) == [.bullet, .newline])
    }

    @Test func tableCells() {
        let rows = OrgParser.parse("| *a* || b\n|---+---|\n").root.descendants().filter { $0.kind == .tableRow }
        #expect(rows[0].children.map(\.text) == [" *a* ", "", " b"])
        #expect(rows[0].children[0].children.map(\.kind) == [.bold])
        #expect(rows[1].children.isEmpty)
    }

    @Test func footnoteDefinitionLabelIsNotAReference() {
        let definition = OrgParser.parse("[fn:1] see [fn:2]\n").root.descendants().first { $0.kind == .footnoteDefinition }!
        #expect(definition.tokens.first?.text == "[fn:1]")
        #expect(definition.children.map(\.kind) == [.footnoteReference])
    }
}
```

Update the two `ParserSectionTests` expectations that assumed `title` was a token:

```diff
@@ -17,7 +17,7 @@ struct ParserSectionTests {
     }
 
     @Test func zerothSectionHoldsPreamble() {
-        #expect(nodeKinds("text\n* a\n") == [.document, .zerothSection, .paragraph, .section, .heading])
+        #expect(nodeKinds("text\n* a\n") == [.document, .zerothSection, .paragraph, .section, .heading, .title])
     }
 
     @Test func sectionsNestByLevel() {
@@ -30,10 +30,11 @@ struct ParserSectionTests {
     }
 
     @Test func headingTokens() {
-        let parts = tokens(of: .heading, in: "** TODO [#A] Write the plan  :work:urgent:  \n")
-        #expect(parts.map(\.kind) == [.stars, .whitespace, .todoKeyword, .whitespace, .priority, .whitespace, .title, .whitespace, .tags, .whitespace, .newline])
+        let text = "** TODO [#A] Write the plan  :work:urgent:  \n"
+        let parts = tokens(of: .heading, in: text)
+        #expect(parts.map(\.kind) == [.stars, .whitespace, .todoKeyword, .whitespace, .priority, .whitespace, .whitespace, .tags, .whitespace, .newline])
         #expect(parts.first { $0.kind == .tags }?.text == ":work:urgent:")
-        #expect(parts.first { $0.kind == .title }?.text == "Write the plan")
+        #expect(OrgParser.parse(text).root.descendants().first { $0.kind == .title }?.text == "Write the plan")
     }
 
     @Test func todoKeywordsComeFromSettings() {
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter InlineTests`
Expected: build failure on the new `SyntaxKind` cases.

- [ ] **Step 3: Replace `SyntaxKind.swift`**

```swift
public enum SyntaxKind: String, Sendable {
    // Tokens
    case text, newline, whitespace
    case stars, todoKeyword, priority, tags
    case marker, linkPath, bullet, checkbox

    // Elements
    case document, zerothSection, section, heading, title
    case planning, propertyDrawer, nodeProperty, drawer, clock
    case paragraph, plainList, item, table, tableRow, tableCell, tableFormula
    case block, dynamicBlock, keyword, affiliatedKeyword
    case comment, fixedWidth, horizontalRule, footnoteDefinition

    // Objects
    case bold, italic, underline, strikeThrough, verbatim, code
    case link, linkDescription, timestamp, footnoteReference, statisticsCookie
    case target, macro, inlineSourceBlock, latexFragment, lineBreak, superscript
}
```

- [ ] **Step 4: Create `Inline.swift`**

```swift
/// Characters allowed before an emphasis opener, besides whitespace and the start of the run.
private let emphasisPre: Set<Character> = ["-", "(", "{", "'", "\""]

/// Characters allowed after an emphasis closer, besides whitespace and the end of the run.
private let emphasisPost: Set<Character> = ["-", ".", ",", ":", "!", "?", ";", "'", "\"", ")", "}", "\\", "["]

private let emphasisKinds: [Character: SyntaxKind] = [
    "*": .bold, "/": .italic, "_": .underline, "+": .strikeThrough, "=": .verbatim, "~": .code,
]

private let angleLinkSchemes: Set<String> = [
    "http", "https", "mailto", "file", "id", "doi", "ftp", "news", "shell", "elisp", "info", "help", "attachment",
]

private let plainLinkPrefixes = ["https://", "http://", "mailto:", "file:"]

/// "\r\n" is a single Character, so both forms count.
func isNewline(_ c: Character) -> Bool {
    c == "\n" || c == "\r\n"
}

enum InlineMatch {
    case emphasis(SyntaxKind, open: Int, close: Int)
    case link(path: Range<Int>, description: Range<Int>?, whole: Range<Int>)
    case object(SyntaxKind, Range<Int>)

    var end: Int {
        switch self {
        case .emphasis(_, _, let close): close + 1
        case .link(_, _, let whole): whole.upperBound
        case .object(_, let range): range.upperBound
        }
    }
}

/// Turns a run of text into text, newline and object tokens. Every character ends up in
/// exactly one token.
struct InlineScanner {
    let chars: [Character]

    func scan(_ range: Range<Int>, into b: inout GreenBuilder, inLink: Bool = false) {
        var textStart = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            if let match = match(at: i, in: range, inLink: inLink) {
                emitText(textStart..<i, into: &b)
                emit(match, into: &b, inLink: inLink)
                i = match.end
                textStart = i
            } else {
                i += 1
            }
        }
        emitText(textStart..<range.upperBound, into: &b)
    }

    func emitText(_ range: Range<Int>, into b: inout GreenBuilder) {
        var start = range.lowerBound
        for k in range where isNewline(chars[k]) {
            if start < k { b.token(.text, string(start..<k)) }
            b.token(.newline, String(chars[k]))
            start = k + 1
        }
        if start < range.upperBound { b.token(.text, string(start..<range.upperBound)) }
    }

    func emit(_ match: InlineMatch, into b: inout GreenBuilder, inLink: Bool) {
        switch match {
        case .emphasis(let kind, let open, let close):
            b.start(kind)
            b.token(.marker, string(open..<(open + 1)))
            if kind == .verbatim || kind == .code {
                emitText((open + 1)..<close, into: &b)
            } else {
                scan((open + 1)..<close, into: &b, inLink: inLink)
            }
            b.token(.marker, string(close..<(close + 1)))
            b.finish()
        case .link(let path, let description, let whole):
            b.start(.link)
            b.token(.marker, string(whole.lowerBound..<path.lowerBound))
            b.token(.linkPath, string(path))
            if let description {
                b.token(.marker, string(path.upperBound..<description.lowerBound))
                b.start(.linkDescription)
                scan(description, into: &b, inLink: true)
                b.finish()
                b.token(.marker, string(description.upperBound..<whole.upperBound))
            } else {
                b.token(.marker, string(path.upperBound..<whole.upperBound))
            }
            b.finish()
        case .object(let kind, let range):
            b.start(kind)
            emitText(range, into: &b)
            b.finish()
        }
    }

    func string(_ range: Range<Int>) -> String {
        String(chars[range])
    }

    func hasPrefix(_ s: String, at i: Int, _ limit: Int) -> Bool {
        var j = i
        for c in s {
            guard j < limit, chars[j] == c else { return false }
            j += 1
        }
        return true
    }

    // MARK: - Recognizers

    func match(at i: Int, in range: Range<Int>, inLink: Bool) -> InlineMatch? {
        let limit = range.upperBound
        let previous: Character? = i > range.lowerBound ? chars[i - 1] : nil
        let afterWord = previous.map { $0.isLetter || $0.isNumber } ?? false

        switch chars[i] {
        case "[":
            if !inLink, let link = bracketLink(i, limit) { return link }
            if let end = footnoteReference(i, limit) { return .object(.footnoteReference, i..<end) }
            if let end = scanTimestamp(chars, at: i, limit: limit)?.end { return .object(.timestamp, i..<end) }
            if let end = statisticsCookie(i, limit) { return .object(.statisticsCookie, i..<end) }
        case "<":
            if let end = scanTimestamp(chars, at: i, limit: limit)?.end { return .object(.timestamp, i..<end) }
            if let end = target(i, limit) { return .object(.target, i..<end) }
            if !inLink, let end = angleLink(i, limit) { return .object(.link, i..<end) }
        case "{":
            if let end = macro(i, limit) { return .object(.macro, i..<end) }
        case "\\":
            if let end = lineBreak(i, limit) { return .object(.lineBreak, i..<end) }
            if let end = latexFragment(i, limit) { return .object(.latexFragment, i..<end) }
        case "^":
            if afterWord, let end = superscript(i, limit) { return .object(.superscript, i..<end) }
        case "s":
            if !afterWord, let end = inlineSourceBlock(i, limit) { return .object(.inlineSourceBlock, i..<end) }
        default:
            break
        }

        if !inLink, !afterWord, let end = plainLink(i, limit) { return .object(.link, i..<end) }

        if let kind = emphasisKinds[chars[i]],
           previous.map({ $0.isWhitespace || emphasisPre.contains($0) }) ?? true,
           let close = emphasisClose(i, limit) {
            return .emphasis(kind, open: i, close: close)
        }
        return nil
    }

    /// org's emphasis rules: the body neither starts nor ends with whitespace, spans at most
    /// one line break, and the closer is followed by whitespace, punctuation or the end.
    func emphasisClose(_ i: Int, _ limit: Int) -> Int? {
        let marker = chars[i]
        guard i + 1 < limit, !chars[i + 1].isWhitespace else { return nil }
        var newlines = 0
        var j = i + 1
        while j < limit {
            if isNewline(chars[j]) {
                newlines += 1
                if newlines > 1 { return nil }
            } else if chars[j] == marker, j > i + 1, !chars[j - 1].isWhitespace {
                if j + 1 == limit || chars[j + 1].isWhitespace || emphasisPost.contains(chars[j + 1]) { return j }
            }
            j += 1
        }
        return nil
    }

    /// `[[path]]` or `[[path][description]]`.
    func bracketLink(_ i: Int, _ limit: Int) -> InlineMatch? {
        guard i + 1 < limit, chars[i + 1] == "[" else { return nil }
        var j = i + 2
        while j < limit, chars[j] != "]" {
            if chars[j] == "[" || isNewline(chars[j]) { return nil }
            if chars[j] == "\\", j + 1 < limit { j += 1 }
            j += 1
        }
        guard j > i + 2, j + 1 < limit else { return nil }
        let path = (i + 2)..<j
        if chars[j + 1] == "]" { return .link(path: path, description: nil, whole: i..<(j + 2)) }
        guard chars[j + 1] == "[" else { return nil }
        let descriptionStart = j + 2
        var depth = 0
        var k = descriptionStart
        while k < limit {
            if chars[k] == "[" {
                depth += 1
            } else if chars[k] == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            k += 1
        }
        guard k > descriptionStart, k + 1 < limit, chars[k + 1] == "]" else { return nil }
        return .link(path: path, description: descriptionStart..<k, whole: i..<(k + 2))
    }

    /// `[fn:label]`, `[fn:label:definition]` or `[fn::definition]`.
    func footnoteReference(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("[fn:", at: i, limit) else { return nil }
        var j = i + 4
        while j < limit, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" { j += 1 }
        guard j < limit else { return nil }
        if chars[j] == "]" { return j > i + 4 ? j + 1 : nil }
        guard chars[j] == ":" else { return nil }
        var depth = 0
        j += 1
        while j < limit {
            if chars[j] == "[" {
                depth += 1
            } else if chars[j] == "]" {
                if depth == 0 { return j + 1 }
                depth -= 1
            }
            j += 1
        }
        return nil
    }

    /// `[1/3]`, `[/]`, `[50%]` or `[%]`.
    func statisticsCookie(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        while j < limit, chars[j].isASCII, chars[j].isNumber { j += 1 }
        guard j < limit else { return nil }
        if chars[j] == "%" {
            j += 1
        } else if chars[j] == "/" {
            j += 1
            while j < limit, chars[j].isASCII, chars[j].isNumber { j += 1 }
        } else {
            return nil
        }
        guard j < limit, chars[j] == "]" else { return nil }
        return j + 1
    }

    /// `<<target>>`.
    func target(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("<<", at: i, limit), i + 2 < limit, chars[i + 2] != "<" else { return nil }
        let start = i + 2
        var j = start
        while j < limit, chars[j] != ">" {
            if chars[j] == "<" || isNewline(chars[j]) { return nil }
            j += 1
        }
        guard j > start, j + 1 < limit, chars[j + 1] == ">",
              !chars[start].isWhitespace, !chars[j - 1].isWhitespace else { return nil }
        return j + 2
    }

    /// `<scheme:path>` for a known scheme.
    func angleLink(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        while j < limit, chars[j].isLetter { j += 1 }
        guard j < limit, chars[j] == ":", angleLinkSchemes.contains(string((i + 1)..<j).lowercased()) else { return nil }
        j += 1
        let bodyStart = j
        while j < limit, chars[j] != ">" {
            if chars[j] == "<" || isNewline(chars[j]) { return nil }
            j += 1
        }
        guard j < limit, j > bodyStart else { return nil }
        return j + 1
    }

    /// A bare URL. Trailing sentence punctuation stays outside the link.
    func plainLink(_ i: Int, _ limit: Int) -> Int? {
        guard "hmf".contains(chars[i]),
              let prefix = plainLinkPrefixes.first(where: { hasPrefix($0, at: i, limit) }) else { return nil }
        let bodyStart = i + prefix.count
        var j = bodyStart
        while j < limit, !chars[j].isWhitespace, !"()<>[]\"".contains(chars[j]) { j += 1 }
        while j > bodyStart, ".,;:!?'".contains(chars[j - 1]) { j -= 1 }
        return j > bodyStart ? j : nil
    }

    /// `{{{name}}}` or `{{{name(arguments)}}}`.
    func macro(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("{{{", at: i, limit) else { return nil }
        var j = i + 3
        guard j < limit, chars[j].isLetter else { return nil }
        while j < limit, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" { j += 1 }
        if j < limit, chars[j] == "(" {
            var k = j + 1
            while k < limit, !hasPrefix(")}}}", at: k, limit) {
                if isNewline(chars[k]) { return nil }
                k += 1
            }
            return k < limit ? k + 4 : nil
        }
        return hasPrefix("}}}", at: j, limit) ? j + 3 : nil
    }

    /// `\\` at the end of a line, before optional trailing blanks. The newline stays outside.
    func lineBreak(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("\\\\", at: i, limit) else { return nil }
        var j = i + 2
        while j < limit, chars[j] == " " || chars[j] == "\t" { j += 1 }
        guard j == limit || isNewline(chars[j]) else { return nil }
        return j
    }

    /// `\(...\)` or `\[...\]`.
    func latexFragment(_ i: Int, _ limit: Int) -> Int? {
        guard i + 1 < limit else { return nil }
        let closer: String
        switch chars[i + 1] {
        case "(": closer = "\\)"
        case "[": closer = "\\]"
        default: return nil
        }
        var j = i + 2
        while j < limit {
            if hasPrefix(closer, at: j, limit) { return j + 2 }
            j += 1
        }
        return nil
    }

    /// `^word` or `^{group}` after a letter or digit.
    func superscript(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        guard j < limit else { return nil }
        if chars[j] == "{" {
            j += 1
            while j < limit, chars[j] != "}" {
                if isNewline(chars[j]) { return nil }
                j += 1
            }
            return j < limit ? j + 1 : nil
        }
        let start = j
        while j < limit, chars[j].isLetter || chars[j].isNumber { j += 1 }
        return j > start ? j : nil
    }

    /// `src_lang{body}` or `src_lang[headers]{body}`, on one line, with balanced braces.
    func inlineSourceBlock(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("src_", at: i, limit) else { return nil }
        var j = i + 4
        let languageStart = j
        while j < limit, !chars[j].isWhitespace, chars[j] != "[", chars[j] != "{" { j += 1 }
        guard j > languageStart, j < limit else { return nil }
        if chars[j] == "[" {
            while j < limit, chars[j] != "]" {
                if isNewline(chars[j]) { return nil }
                j += 1
            }
            guard j < limit else { return nil }
            j += 1
        }
        guard j < limit, chars[j] == "{" else { return nil }
        var depth = 0
        while j < limit {
            if isNewline(chars[j]) { return nil }
            if chars[j] == "{" {
                depth += 1
            } else if chars[j] == "}" {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }
}

extension Parser {
    mutating func inline(_ text: Substring) {
        let chars = Array(text)
        InlineScanner(chars: chars).scan(0..<chars.count, into: &builder)
    }
}
```

- [ ] **Step 5: Wire the scanner into the parser**

```diff
diff --git a/Sources/OrgCore/Parser/Lines.swift b/Sources/OrgCore/Parser/Lines.swift
index 32a778a..5e9a077 100644
--- a/Sources/OrgCore/Parser/Lines.swift
+++ b/Sources/OrgCore/Parser/Lines.swift
@@ -27,7 +27,7 @@ func splitRawLines(_ text: String) -> [RawLine] {
         }
     }
     if lineStart != scalars.endIndex {
-        lines.append(RawLine(content: text[lineStart...], ending: ""))
+        lines.append(RawLine(content: text[lineStart...], ending: text[text.endIndex...]))
     }
     return lines
 }
diff --git a/Sources/OrgCore/Parser/Parser.swift b/Sources/OrgCore/Parser/Parser.swift
index ac210ff..6460486 100644
--- a/Sources/OrgCore/Parser/Parser.swift
+++ b/Sources/OrgCore/Parser/Parser.swift
@@ -77,10 +77,7 @@ struct Parser {
         headingLine(lines[i])
         i += 1
         if i < lines.count, info[i].cls == .planning {
-            builder.start(.planning)
-            line(i)
-            i += 1
-            builder.finish()
+            single(.planning)
         }
         if i < lines.count, case .drawerBegin(let name) = info[i].cls, name.uppercased() == "PROPERTIES",
            let end = blockEnds[i] {
@@ -173,13 +170,28 @@ struct Parser {
         }
     }
 
+    /// Kinds whose single line holds inline objects (timestamps on planning and clock lines).
+    static let inlineLineKinds: Set<SyntaxKind> = [.planning, .clock]
+
     mutating func single(_ kind: SyntaxKind) {
         builder.start(kind)
-        line(i)
+        if Self.inlineLineKinds.contains(kind) {
+            let rest = whitespace(lines[i].content)
+            inline(rest)
+            builder.token(.newline, lines[i].ending)
+        } else {
+            line(i)
+        }
         i += 1
         builder.finish()
     }
 
+    /// Source text from `start` through the end of line `last`, including its line ending.
+    func span(from start: Substring.Index, through last: Int) -> Substring {
+        let base = lines[last].ending.base
+        return base[start..<lines[last].ending.endIndex]
+    }
+
     mutating func consecutive(_ kind: SyntaxKind, limit: Int, floor: Int?, matching: (LineClass) -> Bool) {
         builder.start(kind)
         repeat {
@@ -192,7 +204,7 @@ struct Parser {
     mutating func table(limit: Int, floor: Int?) {
         builder.start(.table)
         while i < limit, info[i].cls == .tableRow, within(floor, i) {
-            single(.tableRow)
+            tableRow()
         }
         while i < limit, info[i].cls == .keyword(key: "TBLFM"), within(floor, i) {
             single(.tableFormula)
@@ -200,15 +212,47 @@ struct Parser {
         builder.finish()
     }
 
-    mutating func footnoteDefinition(limit: Int) {
-        builder.start(.footnoteDefinition)
-        line(i)
-        i += 1
-        while i < limit, info[i].cls == .plain {
-            line(i)
-            i += 1
+    /// A rule row (`|---+---|`) is one text token. Other rows alternate `|` markers and cells;
+    /// every pair of pipes gets a cell, even an empty one, so columns line up.
+    mutating func tableRow() {
+        builder.start(.tableRow)
+        let rest = whitespace(lines[i].content)
+        if rest.hasPrefix("|-") {
+            builder.token(.text, rest)
+        } else {
+            var cellStart = rest.startIndex
+            var index = rest.startIndex
+            while index < rest.endIndex {
+                if rest[index] == "|" {
+                    if index > rest.startIndex { tableCell(rest[cellStart..<index]) }
+                    builder.token(.marker, "|")
+                    cellStart = rest.index(after: index)
+                }
+                index = rest.index(after: index)
+            }
+            if cellStart < rest.endIndex { tableCell(rest[cellStart...]) }
         }
+        builder.token(.newline, lines[i].ending)
         builder.finish()
+        i += 1
+    }
+
+    mutating func tableCell(_ text: Substring) {
+        builder.start(.tableCell)
+        inline(text)
+        builder.finish()
+    }
+
+    mutating func footnoteDefinition(limit: Int) {
+        var end = i + 1
+        while end < limit, info[end].cls == .plain { end += 1 }
+        let content = lines[i].content
+        let close = content.firstIndex(of: "]")!
+        builder.start(.footnoteDefinition)
+        builder.token(.marker, content[...close])
+        inline(span(from: content.index(after: close), through: end - 1))
+        builder.finish()
+        i = end
     }
 
     mutating func list(limit: Int, floor: Int?) {
@@ -224,8 +268,25 @@ struct Parser {
     /// inside the item when the item or list continues after it; two end the list.
     mutating func item(base: Int, limit: Int) {
         builder.start(.item)
-        line(i)
-        i += 1
+        var rest = whitespace(lines[i].content)
+        let bullet = rest.prefix { $0 != " " && $0 != "\t" }
+        builder.token(.bullet, bullet)
+        rest = whitespace(rest.dropFirst(bullet.count))
+        if let box = checkbox(rest) {
+            builder.token(.checkbox, box)
+            rest = whitespace(rest.dropFirst(box.count))
+        }
+        // The rest of the bullet line and its continuation lines are the item's first paragraph.
+        var end = i + 1
+        while end < limit, within(base, end), continuesParagraph(end) { end += 1 }
+        if rest.isEmpty, end == i + 1 {
+            builder.token(.newline, lines[i].ending)
+        } else {
+            builder.start(.paragraph)
+            inline(span(from: rest.startIndex, through: end - 1))
+            builder.finish()
+        }
+        i = end
         while i < limit, !isHeading(i) {
             if info[i].cls == .blank {
                 var j = i
@@ -245,15 +306,23 @@ struct Parser {
         builder.finish()
     }
 
+    /// `[ ]`, `[X]`, `[x]` or `[-]`, followed by whitespace or end of line.
+    func checkbox(_ s: Substring) -> Substring? {
+        guard s.count >= 3, s.first == "[", "Xx -".contains(s.dropFirst().first!),
+              s.dropFirst(2).first == "]" else { return nil }
+        let after = s.dropFirst(3)
+        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
+        return s.prefix(3)
+    }
+
+    /// The paragraph's lines are one inline run, so emphasis and links can cross a line break.
     mutating func paragraph(limit: Int, floor: Int?) {
+        var end = i + 1
+        while end < limit, within(floor, end), continuesParagraph(end) { end += 1 }
         builder.start(.paragraph)
-        line(i)
-        i += 1
-        while i < limit, within(floor, i), continuesParagraph(i) {
-            line(i)
-            i += 1
-        }
+        inline(span(from: lines[i].content.startIndex, through: end - 1))
         builder.finish()
+        i = end
     }
 
     /// Lines that don't start an element of their own.
@@ -307,7 +376,11 @@ struct Parser {
         }
 
         let parts = splitTags(rest)
-        builder.token(.title, parts.title)
+        if !parts.title.isEmpty {
+            builder.start(.title)
+            inline(parts.title)
+            builder.finish()
+        }
         builder.token(.whitespace, parts.gap)
         builder.token(.tags, parts.tags)
         builder.token(.whitespace, parts.trailing)
```

- [ ] **Step 6: Run all tests**

Run: `swift test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "Parse inline objects"
```

---

### Task 3: Fuzz the inline layer

**Files:**
- Modify: `Tests/OrgCoreTests/RoundTripTests.swift` (fragment list)

- [ ] **Step 1: Add inline fragments**

```diff
@@ -20,6 +20,10 @@ let fragments = [
     ":LOGBOOK:", "CLOCK: [2026-10-04 Sun 10:00]", "SCHEDULED: <2026-10-04 Sun>", "- item", "  - nested",
     "\t+ tab", "1. one", "| a | b |", "|---+---|", "#+TBLFM: $2=$1", "# comment", ": fixed", "-----",
     "[fn:1] note", "#+NAME: x", "plain text", "é", "😀", "e\u{301}", " ", "\t", "\n", "\n", "\r\n", "\r", "",
+    "*bold*", "/it/ ", "=v=", "~c~", "_u_", "+s+", "*", "/", "=", "[[https://a.b][d *b*]]", "[[x]]", "[[", "]]",
+    "<2026-10-04 Sun 10:00 +1w -2d>", "[2026-10-04]--[2026-10-05]", "<", ">", "[fn:2]", "[fn::in [x]]", "[1/3]",
+    "[50%]", "<<t>>", "{{{m(a)}}}", "\\(x\\)", "a\\\\", "x^2", "^{y}", "src_sh{echo}", "https://e.com.",
+    "<https://e.com>", "| *a* | b |", "||", "- [X] done", "+ [ ] todo", "-",
 ]
 
 func randomDocument(_ rng: inout SeededGenerator) -> String {
```

- [ ] **Step 2: Run the fuzz test and the private corpus**

Run: `swift test` then `ORGSTAR_CORPUS=~/Documents/notes swift test --filter corpusRoundTrips`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Tests
git commit -m "Fuzz inline objects"
```
