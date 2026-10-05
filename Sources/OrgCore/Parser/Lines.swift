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
        lines.append(RawLine(content: text[lineStart...], ending: text[text.endIndex...]))
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

    // As org's `org-outline-regexp`: stars and then a space. A lone `*`, or stars before a tab,
    // is not a heading.
    if columnZero, rest.first == "*" {
        let stars = rest.prefix { $0 == "*" }
        if rest.dropFirst(stars.count).first == " " {
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
