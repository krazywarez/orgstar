# Phase 1 Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meet the phase 1 speed gates (open a 1 MB file under 100 ms; keystroke to restyled text under 16 ms p95, including a 1 MB single-section file and a 5,000-row table) and record the memory gate the user set.

**Architecture:** Four changes, each found by measuring first. (1) The inline scanner works on unicode scalars, rejects characters that can't start an object before trying recognizers, and slices token text from the source; this was most of the parse time. (2) A region strategy reparses a window of elements inside the innermost section's body instead of the whole top-level section, verifying the end of the window by reparsing one element past it, and reuses unchanged table rows. (3) The editor loads text through the text storage directly, styles the first screen before the first render and the rest in later run-loop turns, and restyles only the rows or items around an edit inside large tables and lists. (4) Tree queries on hot paths create only the child nodes they need.

**Tech Stack:** Swift 6.2 tools, Swift Testing, AppKit, TextKit 2.

**Spec:** `docs/design.md`, "Phases" (exit gates).

## Global Constraints

- Every reparse equals a full parse: 100,000 random edits per seed, several seeds, release build.
- Every incremental restyle equals a fresh editor's full styling: 1,500 random edits per seed, several seeds.
- Memory gate (user decision): under 10x the file size for typical documents; under 45x for worst-case dense markup.

## Results

Release build, M-series Mac; the M1 Air reference machine is still to be measured.

| Measure | Before | After | Gate |
| --- | --- | --- | --- |
| Full parse, `csg.org` (1.5 MB) | 313 ms | 62 ms | |
| Full parse, `org-manual.org` (0.86 MB) | 126 ms | 64 ms | |
| Open, `csg.org` | ~440 ms | 75 ms | 100 ms per MB |
| Typing p95, `csg.org` | 5.8 ms | 6.5 ms | 16 ms |
| Blank line p95, `csg.org` | 256 ms | 7.3 ms | 16 ms |
| Synthetic 1 MB single section: open / typing / blank line | | 76 / 7.0 / 8.1 ms | 100 / 16 / 16 ms |
| Synthetic 5,000-row table: open / typing / blank line | | 38 / 3.2 / 8.8 ms | 100 / 16 / 16 ms |
| Memory: `csg.org` / single section / table | | 9.6x / 30.4x / 42.9x | 10x / 45x / 45x |

What the measurements showed along the way:
- Line splitting and classification were never the problem (12 ms for 1.5 MB); inline scanning at about 170 ns per character was.
- `NSTextView.string` was not the problem either: the first text loaded in a process pays a one-time 40 ms set-up, after which loading 1 MB takes under 1 ms through the text storage.
- Restyling a whole table or list for one edit inside it cost 60 ms on 5,000 rows.
- Memory is mostly the tree (19x to 28x on dense markup: one token or node per piece of markup) plus about 10x for the text view. A compact tree storing token text as offsets is possible later if memory becomes a real problem.

The differential tests found three bugs during this work, each fixed and covered: the element before a reparse window can absorb the window's first line when a drawer loses its `:END:`; an emptied zeroth section must disappear as in a full parse; and the initial-styling watermark must move with edits.

Run the gates: `ORGSTAR_GATES=1 ORGSTAR_GATE_FILE=<a large real file> swift test -c release --filter GateTests`.

---

### Task 1: Inline scanning on unicode scalars

**Files:**
- Modify: `Sources/OrgCore/Parser/Inline.swift`, `Sources/OrgCore/Timestamp.swift`

- [ ] **Step 1: Rewrite the scanner and the timestamp recognizer over `[Unicode.Scalar]`**

The existing inline, timestamp and round-trip tests are the specification; they don't change.

```swift
/// Characters allowed before an emphasis opener, besides whitespace and the start of the run.
private let emphasisPre: Set<Unicode.Scalar> = ["-", "(", "{", "'", "\""]

/// Characters allowed after an emphasis closer, besides whitespace and the end of the run.
private let emphasisPost: Set<Unicode.Scalar> = ["-", ".", ",", ":", "!", "?", ";", "'", "\"", ")", "}", "\\", "["]

private let angleLinkSchemes: Set<String> = [
    "http", "https", "mailto", "file", "id", "doi", "ftp", "news", "shell", "elisp", "info", "help", "attachment",
]

private let plainLinkPrefixes: [[Unicode.Scalar]] = ["https://", "http://", "mailto:", "file:"].map { Array($0.unicodeScalars) }

private func emphasisKind(_ c: Unicode.Scalar) -> SyntaxKind? {
    switch c {
    case "*": .bold
    case "/": .italic
    case "_": .underline
    case "+": .strikeThrough
    case "=": .verbatim
    case "~": .code
    default: nil
    }
}

func isNewline(_ c: Unicode.Scalar) -> Bool {
    c == "\n"
}

func isSpace(_ c: Unicode.Scalar) -> Bool {
    c.isASCII ? (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}") : c.properties.isWhitespace
}

func isWordScalar(_ c: Unicode.Scalar) -> Bool {
    if c.isASCII {
        let v = c.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }
    return c.properties.isAlphabetic || c.properties.numericType != nil
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

/// Turns a run of text into text, newline and object tokens. Every scalar ends up in exactly
/// one token. Works on unicode scalars: every recognizer starts on an ASCII character, so
/// grapheme clusters never need to be formed.
struct InlineScanner {
    let chars: [Unicode.Scalar]
    /// Where each scalar starts in `source`, plus its end, so token text is sliced from the
    /// source instead of rebuilt scalar by scalar.
    let source: Substring.UnicodeScalarView
    let starts: [String.Index]

    init(_ text: Substring) {
        source = text.unicodeScalars
        var chars: [Unicode.Scalar] = []
        var starts: [String.Index] = []
        chars.reserveCapacity(text.utf8.count)
        starts.reserveCapacity(text.utf8.count + 1)
        var index = source.startIndex
        while index < source.endIndex {
            chars.append(source[index])
            starts.append(index)
            index = source.index(after: index)
        }
        starts.append(source.endIndex)
        self.chars = chars
        self.starts = starts
    }

    func scan(_ range: Range<Int>, into b: inout GreenBuilder, inLink: Bool = false) {
        var textStart = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            if Self.mayStartObject(chars[i]), let match = match(at: i, in: range, inLink: inLink) {
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

    /// The first characters any recognizer accepts.
    static func mayStartObject(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "[", "<", "{", "\\", "^", "s", "h", "m", "f", "*", "/", "_", "+", "=", "~": true
        default: false
        }
    }

    /// Text with each line break as its own newline token; "\r\n" stays one token.
    func emitText(_ range: Range<Int>, into b: inout GreenBuilder) {
        var start = range.lowerBound
        var k = range.lowerBound
        while k < range.upperBound {
            if chars[k] == "\n" {
                let breakStart = k > start && chars[k - 1] == "\r" ? k - 1 : k
                if start < breakStart { b.token(.text, string(start..<breakStart)) }
                b.token(.newline, string(breakStart..<(k + 1)))
                start = k + 1
            }
            k += 1
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
        String(source[starts[range.lowerBound]..<starts[range.upperBound]])
    }

    func hasPrefix(_ s: [Unicode.Scalar], at i: Int, _ limit: Int) -> Bool {
        guard i + s.count <= limit else { return false }
        for (offset, c) in s.enumerated() where chars[i + offset] != c { return false }
        return true
    }

    func hasPrefix(_ s: String, at i: Int, _ limit: Int) -> Bool {
        hasPrefix(Array(s.unicodeScalars), at: i, limit)
    }

    // MARK: - Recognizers

    func match(at i: Int, in range: Range<Int>, inLink: Bool) -> InlineMatch? {
        let limit = range.upperBound
        let previous: Unicode.Scalar? = i > range.lowerBound ? chars[i - 1] : nil
        let afterWord = previous.map(isWordScalar) ?? false

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
        case "h", "m", "f":
            if !inLink, !afterWord, let end = plainLink(i, limit) { return .object(.link, i..<end) }
        default:
            break
        }

        if let kind = emphasisKind(chars[i]),
           previous.map({ isSpace($0) || emphasisPre.contains($0) }) ?? true,
           let close = emphasisClose(i, limit) {
            return .emphasis(kind, open: i, close: close)
        }
        return nil
    }

    /// org's emphasis rules: the body neither starts nor ends with whitespace, spans at most
    /// one line break, and the closer is followed by whitespace, punctuation or the end.
    func emphasisClose(_ i: Int, _ limit: Int) -> Int? {
        let marker = chars[i]
        guard i + 1 < limit, !isSpace(chars[i + 1]) else { return nil }
        var newlines = 0
        var j = i + 1
        while j < limit {
            if isNewline(chars[j]) {
                newlines += 1
                if newlines > 1 { return nil }
            } else if chars[j] == marker, j > i + 1, !isSpace(chars[j - 1]) {
                if j + 1 == limit || isSpace(chars[j + 1]) || emphasisPost.contains(chars[j + 1]) { return j }
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
        while j < limit, isWordScalar(chars[j]) || chars[j] == "_" || chars[j] == "-" { j += 1 }
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
        while j < limit, isASCIIDigit(chars[j]) { j += 1 }
        guard j < limit else { return nil }
        if chars[j] == "%" {
            j += 1
        } else if chars[j] == "/" {
            j += 1
            while j < limit, isASCIIDigit(chars[j]) { j += 1 }
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
              !isSpace(chars[start]), !isSpace(chars[j - 1]) else { return nil }
        return j + 2
    }

    /// `<scheme:path>` for a known scheme.
    func angleLink(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        while j < limit, chars[j].properties.isAlphabetic { j += 1 }
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
        guard let prefix = plainLinkPrefixes.first(where: { hasPrefix($0, at: i, limit) }) else { return nil }
        let bodyStart = i + prefix.count
        var j = bodyStart
        while j < limit, !isSpace(chars[j]), !"()<>[]\"".unicodeScalars.contains(chars[j]) { j += 1 }
        while j > bodyStart, ".,;:!?'".unicodeScalars.contains(chars[j - 1]) { j -= 1 }
        return j > bodyStart ? j : nil
    }

    /// `{{{name}}}` or `{{{name(arguments)}}}`.
    func macro(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("{{{", at: i, limit) else { return nil }
        var j = i + 3
        guard j < limit, chars[j].properties.isAlphabetic else { return nil }
        while j < limit, isWordScalar(chars[j]) || chars[j] == "-" || chars[j] == "_" { j += 1 }
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

    /// `\\` at the end of a line, before optional trailing blanks. The line break stays outside.
    func lineBreak(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("\\\\", at: i, limit) else { return nil }
        var j = i + 2
        while j < limit, chars[j] == " " || chars[j] == "\t" { j += 1 }
        if j + 1 < limit, chars[j] == "\r", chars[j + 1] == "\n" { return j }
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
        let closing = Array(closer.unicodeScalars)
        var j = i + 2
        while j < limit {
            if hasPrefix(closing, at: j, limit) { return j + 2 }
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
        while j < limit, isWordScalar(chars[j]) { j += 1 }
        return j > start ? j : nil
    }

    /// `src_lang{body}` or `src_lang[headers]{body}`, on one line, with balanced braces.
    func inlineSourceBlock(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("src_", at: i, limit) else { return nil }
        var j = i + 4
        let languageStart = j
        while j < limit, !isSpace(chars[j]), chars[j] != "[", chars[j] != "{" { j += 1 }
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
        let scanner = InlineScanner(text)
        scanner.scan(0..<scanner.chars.count, into: &builder)
    }
}
```

```diff
diff --git a/Sources/OrgCore/Timestamp.swift b/Sources/OrgCore/Timestamp.swift
index da5ac94..bd71851 100644
--- a/Sources/OrgCore/Timestamp.swift
+++ b/Sources/OrgCore/Timestamp.swift
@@ -42,14 +42,14 @@ public struct Timestamp: Sendable, Equatable {
 
     /// Parses exactly one timestamp or range, with nothing before or after it.
     public static func parse(_ text: some StringProtocol) -> Timestamp? {
-        let chars = Array(text)
+        let chars = Array(text.unicodeScalars)
         guard let result = scanTimestamp(chars, at: 0, limit: chars.count), result.end == chars.count else { return nil }
         return result.stamp
     }
 }
 
 /// A timestamp or `--` range starting at `start`, and the index after it.
-func scanTimestamp(_ chars: [Character], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
+func scanTimestamp(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
     guard let first = scanSingleTimestamp(chars, at: start, limit: limit) else { return nil }
     if first.stamp.end == nil, first.end + 2 < limit, chars[first.end] == "-", chars[first.end + 1] == "-",
        let second = scanSingleTimestamp(chars, at: first.end + 2, limit: limit),
@@ -62,22 +62,23 @@ func scanTimestamp(_ chars: [Character], at start: Int, limit: Int) -> (stamp: T
 }
 
 /// `<YYYY-MM-DD DAY HH:MM-HH:MM REPEATER WARNING>`, or the same in `[...]` for inactive.
-private func scanSingleTimestamp(_ chars: [Character], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
+private func scanSingleTimestamp(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
     guard start < limit, chars[start] == "<" || chars[start] == "[" else { return nil }
     let active = chars[start] == "<"
-    let close: Character = active ? ">" : "]"
+    let close: Unicode.Scalar = active ? ">" : "]"
     var j = start + 1
 
     func number(_ minDigits: Int, _ maxDigits: Int) -> Int? {
         var k = j
-        while k < limit, k - j < maxDigits, chars[k].isASCII, chars[k].isNumber { k += 1 }
+        while k < limit, k - j < maxDigits, isASCIIDigit(chars[k]) { k += 1 }
         guard k - j >= minDigits else { return nil }
-        let value = Int(String(chars[j..<k]))!
+        var value = 0
+        for digit in chars[j..<k] { value = value * 10 + Int(digit.value - 48) }
         j = k
         return value
     }
 
-    func take(_ c: Character) -> Bool {
+    func take(_ c: Unicode.Scalar) -> Bool {
         guard j < limit, chars[j] == c else { return false }
         j += 1
         return true
@@ -85,7 +86,7 @@ private func scanSingleTimestamp(_ chars: [Character], at start: Int, limit: Int
 
     func interval() -> Timestamp.Interval? {
         let before = j
-        guard let value = number(1, 9), j < limit, let unit = Timestamp.Unit(rawValue: chars[j]) else {
+        guard let value = number(1, 9), j < limit, let unit = Timestamp.Unit(rawValue: Character(chars[j])) else {
             j = before
             return nil
         }
@@ -145,7 +146,7 @@ private func scanSingleTimestamp(_ chars: [Character], at start: Int, limit: Int
     // Day name: anything but digits, whitespace, `+`, `-`, `]` and `>`, in any language.
     if j < limit, chars[j] == " " {
         var k = j + 1
-        while k < limit, !(chars[k].isNumber || chars[k].isWhitespace || "+-]>".contains(chars[k])) { k += 1 }
+        while k < limit, !(isDigit(chars[k]) || chars[k].properties.isWhitespace || "+-]>".unicodeScalars.contains(chars[k])) { k += 1 }
         if k > j + 1 { j = k }
     }
 
@@ -179,3 +180,12 @@ private func scanSingleTimestamp(_ chars: [Character], at start: Int, limit: Int
     guard take(close) else { return nil }
     return (stamp, j)
 }
+
+func isASCIIDigit(_ c: Unicode.Scalar) -> Bool {
+    c.value >= 48 && c.value <= 57
+}
+
+/// Any numeric character, as `Character.isNumber` would see it in a day name.
+func isDigit(_ c: Unicode.Scalar) -> Bool {
+    c.properties.numericType != nil
+}
```

- [ ] **Step 2: Run tests, the corpus and the reparse gate; commit**

Run: `swift test`; `ORGSTAR_CORPUS=<folder> swift test -c release --filter corpusRoundTrips` for each local folder; `ORGSTAR_FUZZ_EDITS=100000 swift test -c release --filter incrementalEqualsFull`.

```bash
git add Sources/OrgCore/Parser/Inline.swift Sources/OrgCore/Timestamp.swift
git commit -m "Scan inline objects over unicode scalars"
```

---

### Task 2: Region reparse

**Files:**
- Modify: `Sources/OrgCore/Syntax/SyntaxNode.swift`, `Sources/OrgCore/Syntax/GreenTree.swift`, `Sources/OrgCore/Parser/Parser.swift`, `Sources/OrgCore/Parser/Incremental.swift`
- Test: `Tests/OrgCoreTests/IncrementalTests.swift`

**Interfaces:**
- Produces: `ReparseStrategy.region`; `SyntaxNode.children(overlapping:)`, `child(containing:)`, `firstChild(_:)`; `GreenBuilder.node(_:)`; `Parser.reusableRows`.

- [ ] **Step 1: Write the failing tests**

```diff
@@ -49,8 +49,23 @@ struct IncrementalTests {
         #expect(checkReparse("* a\nx\ny\n* b\n", 6..<6, "* c\n") == .sections)
     }
 
-    @Test func joiningParagraphsReparsesSections() {
-        #expect(checkReparse("a\n\nb\n", 1..<2, "") == .sections)
+    @Test func joiningParagraphsReparsesARegion() {
+        #expect(checkReparse("a\n\nb\n", 1..<2, "") == .region)
+        #expect(checkReparse("* h\nfirst\nsecond\n\nthird\n** child\n", 15..<15, "\n\n") == .region)
+    }
+
+    @Test func regionGrowsUntilABoundaryHolds() {
+        // Splitting a paragraph next to a table and a list.
+        #expect(checkReparse("* h\nx\ntext\nmore\n| a |\n- i\n", 9..<9, "\n") == .region)
+        // A new begin line without its end runs to the end of the body.
+        #expect(checkReparse("* h\nx\none\ntwo\n#+end_src\nthree\n", 6..<6, "\n#+begin_src") == .region)
+    }
+
+    @Test func regionDefersToSectionsNearHeadings() {
+        // The first body line could become a planning line.
+        #expect(checkReparse("* h\nbody\n", 4..<4, "\n") != .region)
+        // An added end delimiter could close a block that starts before the window.
+        #expect(checkReparse("x\n#+begin_src\na\n\nb\n", 16..<16, "#+end_src\n") != .region)
     }
 
     @Test func runGrowsUntilAHeadingEndsIt() {
```

- [ ] **Step 2: Implement**

```diff
diff --git a/Sources/OrgCore/Parser/Incremental.swift b/Sources/OrgCore/Parser/Incremental.swift
index b34284a..9f8347a 100644
--- a/Sources/OrgCore/Parser/Incremental.swift
+++ b/Sources/OrgCore/Parser/Incremental.swift
@@ -22,6 +22,8 @@ public struct TextEdit: Sendable, Equatable {
 enum ReparseStrategy: Equatable {
     /// One element reparsed in place; everything else reused.
     case element
+    /// A run of elements in one section's body reparsed; everything else reused.
+    case region
     /// A run of top-level sections reparsed; the sections before and after reused.
     case sections
     case full
@@ -41,6 +43,7 @@ extension OrgParser {
         let context = EditContext(oldText: oldText, newText: newText, edit: edit)
         if context.touchesSettings() { return (parse(newText, defaults: defaults), .full) }
         if let tree = context.reparseElement(old) { return (tree, .element) }
+        if let tree = context.reparseRegion(old) { return (tree, .region) }
         if let tree = context.reparseSections(old) { return (tree, .sections) }
         return (parse(newText, defaults: defaults), .full)
     }
@@ -113,10 +116,7 @@ private struct EditContext {
     func leaf(in root: SyntaxNode) -> SyntaxNode? {
         let range = edit.range
         var current = root
-        while let child = current.children.first(where: {
-            $0.range.lowerBound <= range.lowerBound && range.lowerBound < $0.range.upperBound
-                && range.upperBound <= $0.range.upperBound
-        }) {
+        while let child = current.child(containing: range.lowerBound), range.upperBound <= child.range.upperBound {
             if Self.leafKinds.contains(child.kind) { return child }
             current = child
         }
@@ -140,6 +140,151 @@ private struct EditContext {
         return replacement
     }
 
+    // MARK: - Body region
+
+    /// Reparses a window of the innermost section's own body (the elements between its heading
+    /// lines and its first child section) and splices it into the old section.
+    ///
+    /// The window starts one element before the element holding the line before the edit. It ends at the first
+    /// later element boundary that the reparse reproduces at the same shifted offset. The
+    /// window is parsed one element past that boundary, so every decision about where an element
+    /// ends was made with the following line in view; from a reproduced boundary on, elements
+    /// parse the same as before. Edits that touch heading lines, the first line after a heading
+    /// (where planning lines and property drawers are only recognized), or that add an end
+    /// delimiter (which could pair with a begin line before the window) are left to the
+    /// section strategy.
+    func reparseRegion(_ old: OrgTree) -> OrgTree? {
+        let start = lineStart(oldText, edit.range.lowerBound)
+        let oldLines = classes(slice(oldText, start, lineEnd(oldText, edit.range.upperBound)))
+        let newLines = classes(slice(newText, start, lineEnd(newText, edit.range.lowerBound + edit.replacement.utf16.count)))
+        for line in oldLines + newLines {
+            if case .heading = line.cls { return nil }
+        }
+        for line in newLines {
+            switch line.cls {
+            case .blockEnd, .dynamicEnd, .drawerEnd: return nil
+            default: break
+            }
+        }
+
+        // The innermost section or zeroth section holding the edited lines.
+        let damaged = start..<max(lineEnd(oldText, edit.range.upperBound), start + 1)
+        var container = old.root
+        while let child = container.child(containing: damaged.lowerBound),
+              child.kind == .section || child.kind == .zerothSection,
+              damaged.upperBound <= child.range.upperBound {
+            container = child
+        }
+        guard container.kind == .section || container.kind == .zerothSection else { return nil }
+
+        // Body children with their offsets.
+        var body: [(element: GreenElement, offset: Int)] = []
+        var bodyStart = container.range.lowerBound
+        var bodyEnd = container.range.upperBound
+        var offset = container.range.lowerBound
+        var prefixCount = 0
+        for (index, element) in container.green.children.enumerated() {
+            defer { offset += element.length }
+            if case .node(let node) = element {
+                if [.heading, .planning, .propertyDrawer].contains(node.kind), body.isEmpty {
+                    prefixCount = index + 1
+                    bodyStart = offset + node.length
+                    continue
+                }
+                if node.kind == .section {
+                    bodyEnd = offset
+                    break
+                }
+            }
+            body.append((element, offset))
+        }
+        // The first body line of a heading section can become a planning line or drawer.
+        let firstEditable = container.kind == .section ? lineEnd(oldText, bodyStart) : bodyStart
+        guard start >= firstEditable, edit.range.upperBound <= bodyEnd, !body.isEmpty else { return nil }
+
+        // Window start: the body element holding the line before the edit, and one more before
+        // it, which could absorb the window's first line if that line changes meaning (a drawer
+        // that loses its end turns into paragraph text).
+        let anchor = max(bodyStart, start - 1)
+        guard var first = body.lastIndex(where: { $0.offset <= anchor }) else { return nil }
+        while first > 0, case .token = body[first].element { first -= 1 }
+        if first > 0 {
+            first -= 1
+            while first > 0, case .token = body[first].element { first -= 1 }
+        }
+        let windowStart = body[first].offset
+
+        var next = body.firstIndex { $0.offset > edit.range.upperBound } ?? body.count
+        var attempts = 0
+        while attempts < 8 {
+            attempts += 1
+            // Parse through one node past the candidate boundary.
+            var verifyEnd = next
+            while verifyEnd < body.count, case .token = body[verifyEnd].element { verifyEnd += 1 }
+            let boundary = next < body.count ? body[next].offset : bodyEnd
+            let oldWindowEnd = verifyEnd < body.count ? body[verifyEnd].offset + body[verifyEnd].element.length : bodyEnd
+            let rows = reusableRows(body[first..<min(verifyEnd + 1, body.count)].map(\.element))
+            guard let window = parseBody(slice(newText, windowStart, oldWindowEnd + delta), settings: old.settings, rows: rows) else { return nil }
+            if window.unmatchedBegin, oldWindowEnd < bodyEnd {
+                next = body.count
+                continue
+            }
+            // The reparsed elements up to the boundary, if the reparse has one there.
+            let target = boundary + delta - windowStart
+            var reparsed: [GreenElement] = []
+            var at = 0
+            for element in window.elements where at < target {
+                reparsed.append(element)
+                at += element.length
+            }
+            guard at == target else {
+                next += 1
+                if next > body.count { return nil }
+                continue
+            }
+            let before = container.green.children[..<(prefixCount + first)]
+            let after = next < body.count ? Array(body[next...].map(\.element)) : []
+            let tail = container.green.children[(prefixCount + body.count)...]
+            let green = GreenNode(kind: container.kind, children: Array(before) + reparsed + after + Array(tail))
+            // A full parse has no zeroth section for empty text.
+            if green.children.isEmpty { return nil }
+            return OrgTree(green: replacing(container, with: green), settings: old.settings)
+        }
+        return nil
+    }
+
+    /// Rows of the tables among `elements`, keyed by their text.
+    func reusableRows(_ elements: [GreenElement]) -> [Substring: GreenNode] {
+        var rows: [Substring: GreenNode] = [:]
+        for case .node(let table) in elements where table.kind == .table {
+            for case .node(let row) in table.children where row.kind == .tableRow {
+                rows[Substring(row.text)] = row
+            }
+        }
+        return rows
+    }
+
+    /// Body elements parsed from `text`, or nil if the text holds a heading.
+    func parseBody(_ text: Substring, settings: OrgSettings, rows: [Substring: GreenNode] = [:]) -> (elements: [GreenElement], unmatchedBegin: Bool)? {
+        var parser = Parser(text: String(text), settings: settings)
+        parser.reusableRows = rows
+        let count = parser.lines.count
+        parser.builder.start(.zerothSection)
+        parser.parseContent(limit: count)
+        guard parser.i == count else { return nil }
+        parser.builder.finish()
+        var unmatched = false
+        for (index, line) in parser.info.enumerated() {
+            switch line.cls {
+            case .blockBegin, .dynamicBegin, .drawerBegin:
+                if parser.blockEnds[index] == nil { unmatched = true }
+            default:
+                break
+            }
+        }
+        return (parser.builder.build().children, unmatched)
+    }
+
     // MARK: - Sections
 
     /// Reparses from the top-level section before the edit up to the first later top-level
diff --git a/Sources/OrgCore/Parser/Parser.swift b/Sources/OrgCore/Parser/Parser.swift
index 8478c72..2f2addf 100644
--- a/Sources/OrgCore/Parser/Parser.swift
+++ b/Sources/OrgCore/Parser/Parser.swift
@@ -14,6 +14,9 @@ struct Parser {
     let settings: OrgSettings
     var builder = GreenBuilder()
     var i = 0
+    /// Table rows from a previous version, by their line text. A row parses from its own line
+    /// alone, so a row with the same text can be reused instead of scanned again.
+    var reusableRows: [Substring: GreenNode] = [:]
 
     init(text: String, defaults: OrgSettings) {
         let lines = splitRawLines(text)
@@ -230,6 +233,14 @@ struct Parser {
     /// A rule row (`|---+---|`) is one text token. Other rows alternate `|` markers and cells;
     /// every pair of pipes gets a cell, even an empty one, so columns line up.
     mutating func tableRow() {
+        if !reusableRows.isEmpty {
+            let content = lines[i].content
+            if let row = reusableRows[content.base[content.startIndex..<lines[i].ending.endIndex]] {
+                builder.node(row)
+                i += 1
+                return
+            }
+        }
         builder.start(.tableRow)
         let rest = whitespace(lines[i].content)
         if rest.hasPrefix("|-") {
diff --git a/Sources/OrgCore/Syntax/GreenTree.swift b/Sources/OrgCore/Syntax/GreenTree.swift
index 10b11c6..47019e4 100644
--- a/Sources/OrgCore/Syntax/GreenTree.swift
+++ b/Sources/OrgCore/Syntax/GreenTree.swift
@@ -70,6 +70,11 @@ struct GreenBuilder {
         stack[stack.count - 1].children.append(.token(GreenToken(kind: kind, text: String(text))))
     }
 
+    /// Appends an already-built node, for reuse across versions.
+    mutating func node(_ green: GreenNode) {
+        stack[stack.count - 1].children.append(.node(green))
+    }
+
     mutating func finish() {
         let (kind, children) = stack.removeLast()
         let node = GreenNode(kind: kind, children: children)
diff --git a/Sources/OrgCore/Syntax/SyntaxNode.swift b/Sources/OrgCore/Syntax/SyntaxNode.swift
index 3473728..0430409 100644
--- a/Sources/OrgCore/Syntax/SyntaxNode.swift
+++ b/Sources/OrgCore/Syntax/SyntaxNode.swift
@@ -38,6 +38,46 @@ public final class SyntaxNode: Sendable {
         return result
     }
 
+    /// Child nodes overlapping `range`. Only those are created, so a section with thousands of
+    /// children costs little when the range is small.
+    public func children(overlapping range: Range<Int>) -> [SyntaxNode] {
+        var result: [SyntaxNode] = []
+        var at = offset
+        for child in green.children {
+            let childRange = at..<(at + child.length)
+            if childRange.lowerBound >= range.upperBound, !range.isEmpty { break }
+            if case .node(let node) = child, childRange.overlaps(range) {
+                result.append(SyntaxNode(green: node, offset: at, parent: self))
+            }
+            at = childRange.upperBound
+        }
+        return result
+    }
+
+    /// The child node whose range contains `position`.
+    public func child(containing position: Int) -> SyntaxNode? {
+        var at = offset
+        for child in green.children {
+            let end = at + child.length
+            if position < end {
+                if case .node(let node) = child, position >= at { return SyntaxNode(green: node, offset: at, parent: self) }
+                return nil
+            }
+            at = end
+        }
+        return nil
+    }
+
+    /// The first child node of `kind`.
+    public func firstChild(_ kind: SyntaxKind) -> SyntaxNode? {
+        var at = offset
+        for child in green.children {
+            if case .node(let node) = child, node.kind == kind { return SyntaxNode(green: node, offset: at, parent: self) }
+            at += child.length
+        }
+        return nil
+    }
+
     /// This node and every node below it, in document order.
     public func descendants() -> [SyntaxNode] {
         [self] + children.flatMap { $0.descendants() }
```

- [ ] **Step 3: Run the gate on several seeds; commit**

Run: `ORGSTAR_FUZZ_SEED=<n> ORGSTAR_FUZZ_EDITS=100000 swift test -c release --filter incrementalEqualsFull` for at least five seeds.

```bash
git add Sources/OrgCore Tests/OrgCoreTests/IncrementalTests.swift
git commit -m "Reparse structural edits within one section's body"
```

---

### Task 3: Editor styling

**Files:**
- Modify: `Sources/OrgEditorAppKit/OrgEditor.swift`, `Sources/OrgPresentation/Presentation.swift`, `Sources/OrgDocument/ViewState.swift`
- Test: `Tests/OrgEditorAppKitTests/EditorTests.swift`

**Interfaces:**
- Produces: `OrgEditor.finishStyling()`, `OrgEditor.styledUpTo`, `OrgEditor.firstStyleChunk`, `OrgEditor.styleChunk`; test `Harness(_:layout:)`, `Harness.drainStyling()`.

- [ ] **Step 1: Write the failing tests**

```diff
@@ -10,13 +10,24 @@ final class Harness {
     let editor: OrgEditor
     let window: NSWindow
 
-    init(_ text: String) {
+    convenience init(_ text: String) {
+        self.init(DocumentState(bytes: Array(text.utf8)))
+        drainStyling()
+        layout()
+    }
+
+    /// The editor as a window would show it first: background styling not yet run.
+    init(_ document: DocumentState, layout: Bool = true) {
         _ = NSApplication.shared
-        editor = OrgEditor(document: DocumentState(bytes: Array(text.utf8)))
+        editor = OrgEditor(document: document)
         window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
         window.contentView = editor.makeScrollView()
         window.makeFirstResponder(editor.textView)
-        layout()
+        if layout { self.layout() }
+    }
+
+    func drainStyling() {
+        editor.finishStyling()
     }
 
     var textView: NSTextView { editor.textView }
@@ -246,3 +257,26 @@ struct RestyleFuzzTests {
         h.checkInSync()
     }
 }
+
+@MainActor
+struct InitialStylingTests {
+    @Test func stylesTheFirstScreenThenTheRest() throws {
+        let line = "* heading *bold*\nbody text\n"
+        let text = String(repeating: line, count: 4_000)
+        let h = Harness(DocumentState(bytes: Array(text.utf8)), layout: false)
+        let length = (text as NSString).length
+        #expect(h.editor.styledUpTo >= OrgEditor.firstStyleChunk && h.editor.styledUpTo < length)
+        h.textView.insertText("x", replacementRange: NSRange(location: length - 3, length: 0))
+        h.drainStyling()
+        #expect(h.editor.styledUpTo == length + 1)
+        #expect(h.textView.textStorage!.isEqual(to: Harness(h.string).textView.textStorage!))
+    }
+
+    @Test func editsBeforeTheWatermarkShiftIt() {
+        let text = String(repeating: "line of text\n", count: 5_000)
+        let h = Harness(DocumentState(bytes: Array(text.utf8)), layout: false)
+        let before = h.editor.styledUpTo
+        h.textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
+        #expect(h.editor.styledUpTo == before + 3)
+    }
+}
```

- [ ] **Step 2: Implement**

```diff
diff --git a/Sources/OrgDocument/ViewState.swift b/Sources/OrgDocument/ViewState.swift
index 7590ffe..9cdf35a 100644
--- a/Sources/OrgDocument/ViewState.swift
+++ b/Sources/OrgDocument/ViewState.swift
@@ -30,7 +30,7 @@ public struct ViewState: Sendable, Equatable {
 /// Descends only through the sections containing `offset`.
 func isHeadingStart(_ offset: Int, _ root: SyntaxNode) -> Bool {
     var node = root
-    while let child = node.children.first(where: { $0.range.contains(offset) }) {
+    while let child = node.child(containing: offset) {
         if child.kind == .heading { return child.range.lowerBound == offset }
         guard child.kind == .section || child.kind == .zerothSection else { return false }
         node = child
diff --git a/Sources/OrgEditorAppKit/OrgEditor.swift b/Sources/OrgEditorAppKit/OrgEditor.swift
index ecea416..b7c3dc4 100644
--- a/Sources/OrgEditorAppKit/OrgEditor.swift
+++ b/Sources/OrgEditorAppKit/OrgEditor.swift
@@ -55,6 +55,15 @@ public final class OrgEditor: NSObject {
     let theme = Theme()
     private var isLoading = false
     private var previousSelection = 0
+    /// Text before this offset is styled; after it, only base attributes until the background
+    /// passes reach it. Always at a line start.
+    private(set) var styledUpTo = 0
+    private var stylingScheduled = false
+
+    /// Styled before the first render: more than a screenful.
+    static let firstStyleChunk = 30_000
+    /// Styled per run-loop turn afterwards.
+    static let styleChunk = 200_000
 
     public init(document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800)) {
         self.document = document
@@ -77,10 +86,46 @@ public final class OrgEditor: NSObject {
         textLayoutManager.delegate = self
         textContentStorage.delegate = self
 
+        load(document.text)
+    }
+
+    /// Replaces the storage's text. Setting the attributed string directly is about 100x
+    /// faster than `NSTextView.string` for large files.
+    private func load(_ text: String) {
         isLoading = true
-        textView.string = document.text
+        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
         isLoading = false
-        restyleOutsideEditing(0..<utf16Length)
+        styledUpTo = 0
+        styleNextChunk(Self.firstStyleChunk)
+        scheduleStyling()
+    }
+
+    // MARK: - Initial styling
+
+    /// Styles whole lines from the watermark onward, about `size` units.
+    private func styleNextChunk(_ size: Int) {
+        let text = textView.textStorage!.string as NSString
+        guard styledUpTo < text.length else { return }
+        let target = min(text.length, styledUpTo + size)
+        let end = target == text.length ? target : NSMaxRange(text.lineRange(for: NSRange(location: target, length: 0)))
+        restyleOutsideEditing(styledUpTo..<end)
+        styledUpTo = end
+    }
+
+    private func scheduleStyling() {
+        guard !stylingScheduled, styledUpTo < utf16Length else { return }
+        stylingScheduled = true
+        DispatchQueue.main.async { [weak self] in
+            guard let self else { return }
+            self.stylingScheduled = false
+            self.styleNextChunk(Self.styleChunk)
+            self.scheduleStyling()
+        }
+    }
+
+    /// Styles everything still waiting for a background pass.
+    public func finishStyling() {
+        while styledUpTo < utf16Length { styleNextChunk(Self.styleChunk) }
     }
 
     public var textLayoutManager: NSTextLayoutManager { textView.textLayoutManager! }
@@ -107,10 +152,7 @@ public final class OrgEditor: NSObject {
         let outcome = try saver.save(&document, to: url)
         if document.text != before {
             let edits = lineEdits(from: before, to: document.text)
-            isLoading = true
-            textView.string = document.text
-            isLoading = false
-            restyleOutsideEditing(0..<utf16Length)
+            load(document.text)
             setFolds(view.mapped(through: edits).folds)
         }
         return outcome
@@ -190,23 +232,30 @@ public final class OrgEditor: NSObject {
         let lineRange = lines.location..<(lines.location + lines.length)
         let around = max(0, lineRange.lowerBound - 1)..<min(text.length, lineRange.upperBound + 1)
         var container = tree.root
-        while let child = container.children.first(where: {
-            ($0.kind == .section || $0.kind == .zerothSection)
-                && $0.range.lowerBound <= lineRange.lowerBound && lineRange.upperBound <= $0.range.upperBound
-        }) {
+        while let child = container.child(containing: lineRange.lowerBound),
+              child.kind == .section || child.kind == .zerothSection,
+              lineRange.upperBound <= child.range.upperBound {
             container = child
         }
         var lower = lineRange.lowerBound
         var upper = lineRange.upperBound
-        let children = container.children
-        for child in children where child.range.overlaps(around) {
+        // Tables and lists carry no styling of their own, so inside them only the rows or
+        // items around the edit change, however large they are.
+        func overlapping(_ nodes: [SyntaxNode]) -> [SyntaxNode] {
+            nodes.filter { $0.range.overlaps(around) }.flatMap { node -> [SyntaxNode] in
+                guard [.table, .plainList, .item].contains(node.kind) else { return [node] }
+                let inner = overlapping(node.children(overlapping: around))
+                return inner.isEmpty ? [node] : inner
+            }
+        }
+        for child in overlapping(container.children(overlapping: around)) {
             lower = min(lower, child.range.lowerBound)
             upper = max(upper, child.range.upperBound)
         }
-        let heading = children.first { $0.kind == .heading }
+        let heading = container.firstChild(.heading)
         if touchedHeadings || heading.map({ $0.range.overlaps(lineRange) }) == true {
             lower = min(lower, container.range.lowerBound)
-            upper = max(upper, children.first { $0.kind == .section }?.range.lowerBound ?? container.range.upperBound)
+            upper = max(upper, container.firstChild(.section)?.range.lowerBound ?? container.range.upperBound)
         }
         return lower..<min(upper, text.length)
     }
@@ -231,6 +280,13 @@ public final class OrgEditor: NSObject {
             assertionFailure("text view and document disagree: \(error)")
             return
         }
+        // Keep the watermark on unstyled text: shift it past the edit, or pull it back to the
+        // edited line when the edit reaches into unstyled text.
+        if styledUpTo >= edit.range.upperBound {
+            styledUpTo += edit.replacement.utf16.count - edit.range.count
+        } else if styledUpTo > edit.range.lowerBound {
+            styledUpTo = (storage.string as NSString).lineRange(for: NSRange(location: edit.range.lowerBound, length: 0)).location
+        }
         let oldHidden = hidden.all
         view = view.mapped(through: [edit]).pruned(to: document.tree)
         folded.set(view.folds)
diff --git a/Sources/OrgPresentation/Presentation.swift b/Sources/OrgPresentation/Presentation.swift
index 312d7f8..504e0b5 100644
--- a/Sources/OrgPresentation/Presentation.swift
+++ b/Sources/OrgPresentation/Presentation.swift
@@ -77,7 +77,7 @@ public enum Presentation {
         default:
             break
         }
-        for child in node.children where child.range.overlaps(range) {
+        for child in node.children(overlapping: range) {
             visit(child, range, settings, &runs)
         }
     }
@@ -118,12 +118,11 @@ public enum Presentation {
     }
 
     private static func collectIndents(_ node: SyntaxNode, _ range: Range<Int>, _ runs: inout [IndentRun]) {
-        for section in node.children where section.kind == .section && section.range.overlaps(range) {
-            let children = section.children
-            guard let heading = children.first(where: { $0.kind == .heading }) else { continue }
+        for section in node.children(overlapping: range) where section.kind == .section {
+            guard let heading = section.firstChild(.heading) else { continue }
             let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
             runs.append(IndentRun(range: heading.range, firstLine: 0, wrapped: level + 1))
-            let bodyEnd = children.first { $0.kind == .section }?.range.lowerBound ?? section.range.upperBound
+            let bodyEnd = section.firstChild(.section)?.range.lowerBound ?? section.range.upperBound
             if heading.range.upperBound < bodyEnd {
                 runs.append(IndentRun(range: heading.range.upperBound..<bodyEnd, firstLine: level + 1, wrapped: level + 1))
             }
@@ -156,7 +155,7 @@ public enum Presentation {
     /// Start offset of the heading whose line contains `offset`.
     public static func heading(containing offset: Int, in tree: OrgTree) -> Int? {
         var node = tree.root
-        while let child = node.children.first(where: { $0.range.contains(offset) }) {
+        while let child = node.child(containing: offset) {
             if child.kind == .heading { return child.range.lowerBound }
             guard child.kind == .section || child.kind == .zerothSection else { return nil }
             node = child
```

- [ ] **Step 3: Run the restyle fuzz on several seeds; commit**

Run: `ORGSTAR_FUZZ_SEED=<n> ORGSTAR_RESTYLE_EDITS=1500 swift test -c release --filter RestyleFuzzTests` for at least three seeds.

```bash
git add Sources/OrgEditorAppKit Sources/OrgPresentation Sources/OrgDocument Tests/OrgEditorAppKitTests/EditorTests.swift
git commit -m "Style the first screen first and narrow restyles"
```

---

### Task 4: Gate tests

**Files:**
- Create: `Tests/OrgEditorAppKitTests/GateTests.swift`
- Modify: `docs/design.md` (memory gate)

- [ ] **Step 1: Add the gate suite**

```swift
import AppKit
import Foundation
import OrgDocument
import Testing
@testable import OrgEditorAppKit

/// The phase 1 performance gates (design, "Phases"). Skipped unless `ORGSTAR_GATES` is set;
/// run in a release build on the reference machine:
///
///     ORGSTAR_GATES=1 swift test -c release --filter GateTests
///
/// `ORGSTAR_GATE_FILE` adds a real file to the synthetic ones. Memory limits follow the design:
/// 10x the file size for typical documents, 45x for the synthetic worst cases.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_GATES"] != nil))
struct GateTests {
    /// About 1 MB of body text under a single top-level heading.
    static let singleSection: String = {
        var text = "* One big section\n"
        var n = 0
        while text.utf8.count < 1_000_000 {
            text += "Paragraph \(n) with *bold*, /italic/, a [[https://example.com/\(n)][link]] and <2026-10-04 Sun>.\n"
            text += "It continues on a second line with =code= and ~more~.\n\n"
            text += "- item \(n)\n  - nested [ ] task\n\n"
            n += 1
        }
        return text
    }()

    /// A 5,000-row table.
    static let bigTable: String = {
        var text = "* Table\n| id | name | note |\n|----+------+------|\n"
        for n in 0..<5_000 { text += "| \(n) | row \(n) | *bold* and [[https://example.com][link]] |\n" }
        return text
    }()

    struct Result: CustomStringConvertible {
        var name: String
        var bytes: Int
        var open: Duration
        var typingP95: Duration
        var newlineP95: Duration
        var memoryRatio: Double

        var description: String {
            "\(name) (\(bytes / 1000) kB): open \(open), typing p95 \(typingP95), blank line p95 \(newlineP95), memory \(String(format: "%.1f", memoryRatio))x"
        }
    }

    /// Heap bytes in use, which unlike resident size isn't hidden by memory freed earlier.
    static func heapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func measure(_ name: String, _ text: String) -> Result {
        let clock = ContinuousClock()
        let bytes = Array(text.utf8)
        let before = Self.heapBytes()
        var harness: Harness!
        let open = clock.measure {
            harness = Harness(DocumentState(bytes: bytes), layout: false)
        }
        harness.drainStyling()
        let memoryRatio = Double(Self.heapBytes() - before) / Double(bytes.count)

        var timings: [Duration] = []
        harness.editor.onEditTiming = { timings.append($0) }
        let paragraphs = harness.editor.document.tree.root.descendants().filter { $0.kind == .paragraph || $0.kind == .tableCell }
        harness.caret(at: paragraphs[paragraphs.count / 2].range.lowerBound + 1)
        for _ in 0..<100 { harness.textView.insertText("x", replacementRange: harness.textView.selectedRange()) }
        let typing = timings.sorted()[95]

        timings = []
        for _ in 0..<20 {
            harness.textView.insertNewline(nil)
            harness.textView.insertNewline(nil)
            harness.textView.deleteBackward(nil)
            harness.textView.deleteBackward(nil)
        }
        let sorted = timings.sorted()
        return Result(name: name, bytes: bytes.count, open: open, typingP95: typing, newlineP95: sorted[sorted.count * 95 / 100], memoryRatio: memoryRatio)
    }

    @Test func gates() throws {
        // The first text view, and the first text loaded into one, set up the text system once
        // per process; an app pays that at launch, not per file.
        NSTextView(usingTextLayoutManager: true).textStorage?.setAttributedString(NSAttributedString(string: "warm up"))
        // Memory limits: worst-case dense markup for the synthetic files, typical for real ones.
        var inputs = [("single 1 MB section", Self.singleSection, 45.0), ("5,000-row table", Self.bigTable, 45.0)]
        if let path = ProcessInfo.processInfo.environment["ORGSTAR_GATE_FILE"] {
            inputs.append((URL(fileURLWithPath: path).lastPathComponent, try String(contentsOfFile: path, encoding: .utf8), 10.0))
        }
        for (name, text, memoryLimit) in inputs {
            let result = measure(name, text)
            print("GATE \(result)")
            let perMegabyte = Double(result.bytes) / 1_000_000
            #expect(result.open < .milliseconds(100) * max(1, perMegabyte), "\(name): open")
            #expect(result.typingP95 < .milliseconds(16), "\(name): typing")
            #expect(result.newlineP95 < .milliseconds(16), "\(name): blank line")
            #expect(result.memoryRatio < memoryLimit, "\(name): memory")
        }
    }
}
```

- [ ] **Step 2: Run the gates; commit**

Run: `ORGSTAR_GATES=1 ORGSTAR_GATE_FILE=<large real file> swift test -c release --filter GateTests`

```bash
git add Tests/OrgEditorAppKitTests/GateTests.swift
git commit -m "Add performance gate tests"
```
