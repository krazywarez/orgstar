import Foundation

/// What ox-ascii (Org 9.8.7) makes of a section's elements and a heading's title with
/// `:ascii-charset utf-8` and links in place (`:ascii-links-to-notes nil`), as the iCalendar
/// export writes summaries and descriptions: paragraphs filled to the text width, lists with
/// `•` bullets, blocks in a partial box, tables drawn with box characters.
struct ASCIIText {
    let options: ExportOptions
    /// Heading numbers by title, for fuzzy links without a description.
    var headingNumbers: [String: String] = [:]

    static let textWidth = 72
    static let innerMargin = 2
    static let quoteMargin = 6

    /// The text width inside a section under a heading at `level` (`org-ascii--current-text-width`).
    func width(level: Int?) -> Int {
        guard let level else { return Self.textWidth }
        return Self.textWidth - (level > options.headlineLevels ? (level - options.headlineLevels) * 2 : Self.innerMargin)
    }

    // MARK: - Elements

    /// `nodes`, each followed by the blank lines after it in `source`, as `org-export-data`
    /// joins elements. Elements the export leaves out add nothing.
    func elements(_ nodes: [SyntaxNode], end: Int, source: NSString, width: Int) -> String {
        var out = ""
        for (index, node) in nodes.enumerated() {
            guard let text = element(node, source: source, width: width), !text.isEmpty else { continue }
            let next = index + 1 < nodes.count ? nodes[index + 1].range.lowerBound : end
            out += Self.normalized(text) + String(repeating: "\n", count: Self.blankLines(source, from: node.range.upperBound, to: next))
        }
        return out
    }

    /// Blank lines between `from`, a line start, and `to`.
    static func blankLines(_ source: NSString, from: Int, to: Int) -> Int {
        guard to > from, from < source.length else { return 0 }
        let gap = source.substring(with: NSRange(location: from, length: min(to, source.length) - from))
        return gap.components(separatedBy: "\n").dropLast().count
    }

    /// `org-element-normalize-string`: one final newline.
    static func normalized(_ s: String) -> String {
        var s = s
        while s.hasSuffix("\n") || s.hasSuffix(" ") || s.hasSuffix("\t") { s.removeLast() }
        return s + "\n"
    }

    func element(_ node: SyntaxNode, source: NSString, width: Int) -> String? {
        switch node.kind {
        case .paragraph:
            return paragraph(node, width: width)
        case .plainList:
            return list(node, source: source, width: width)
        case .table:
            return table(node)
        case .tableEl:
            return Self.removeIndentation(node.text.trimmingCharacters(in: .newlines))
        case .block:
            return block(node, width: width)
        case .fixedWidth:
            let lines = node.text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix(": ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(1))
            }
            return Self.box(Self.removeIndentation(lines.joined(separator: "\n")))
        case .horizontalRule:
            return String(repeating: "―", count: width)
        case .drawer:
            let name = node.text.firstMatch(of: /^[ \t]*:([\w-]+):/).map { String($0.1).uppercased() } ?? ""
            if name == "LOGBOOK" { return nil }
            return elements(node.children, end: node.range.upperBound, source: source, width: width)
        case .dynamicBlock:
            return elements(node.children, end: node.range.upperBound, source: source, width: width)
        case .latexEnvironment:
            return options.tex ? Self.removeIndentation(node.text.trimmingCharacters(in: .newlines)) : nil
        case .keyword:
            guard let m = node.text.firstMatch(of: /(?i)^[ \t]*#\+ASCII:[ \t]*(.*?)[ \t]*\n?$/) else { return nil }
            return String(m.1)
        default:
            // Planning, drawers of properties, clocks, comments, keywords and footnote
            // definitions export nothing here.
            return nil
        }
    }

    // MARK: Paragraphs

    func paragraph(_ node: SyntaxNode, width: Int) -> String {
        var text = inline(node, skippingTimestamps: Self.isolatedTimestamps(node))
        // `org-remove-blank-lines`.
        text = text.replacing(#/\n[ \t]*\n(?:[ \t]*\n)*/#, with: "\n")
        return Self.fill(text, width: width)
    }

    /// Whether the paragraph holds only timestamps and whitespace, whose timestamps
    /// `:with-timestamps` decides.
    static func isolatedTimestamps(_ node: SyntaxNode) -> Bool {
        var any = false
        for element in node.elements {
            switch element {
            case .token(let token):
                if !token.text.allSatisfy(\.isWhitespace) { return false }
            case .node(let child):
                guard child.kind == .timestamp else { return false }
                any = true
            }
        }
        return any
    }

    /// `org-ascii--fill-string`: `fill-region` with `fill-column` `width`,
    /// `sentence-end-double-space` and hard newlines from line breaks.
    static func fill(_ text: String, width: Int) -> String {
        text.components(separatedBy: hardNewline).map { fillParagraph($0, width: width) }.joined(separator: "\n")
    }

    static let hardNewline = "\u{1}"

    static func fillParagraph(_ text: String, width: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.count > 1, lines.last!.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        func indentation(_ line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }
        let first = indentation(lines[0])
        // `fill-context-prefix`: the second line's indentation when the first starts with it.
        let prefix = lines.count >= 2 ? (lines[0].hasPrefix(indentation(lines[1])) ? indentation(lines[1]) : "") : first
        var parts: [String] = []
        for (i, line) in lines.enumerated() {
            var content = String(line.dropFirst(indentation(line).count))
            while content.hasSuffix(" ") || content.hasSuffix("\t") { content.removeLast() }
            // A sentence ending a line gets the second space it would have.
            if i < lines.count - 1, content.range(of: "[.?!…‽][]\"'”’)}»›]*$", options: .regularExpression) != nil { content += " " }
            parts.append(content)
        }
        let joined = parts.joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        // Words and the spaces after them, with `canonically-space-region`'s spacing.
        var words: [(word: String, spaces: Int)] = []
        var index = joined.startIndex
        while index < joined.endIndex {
            let wordEnd = joined[index...].firstIndex(of: " ") ?? joined.endIndex
            let word = String(joined[index..<wordEnd])
            let spaceEnd = joined[wordEnd...].firstIndex { $0 != " " } ?? joined.endIndex
            var spaces = joined.distance(from: wordEnd, to: spaceEnd)
            if spaces >= 2 {
                let closers = word.reversed().drop { "]})\"'".contains($0) }
                spaces = closers.first.map { ".?!".contains($0) } == true ? 2 : 1
            }
            if !word.isEmpty { words.append((word, spaces)) } else if var last = words.popLast() {
                last.spaces += spaces
                words.append(last)
            }
            index = spaceEnd
        }
        guard !words.isEmpty else { return first }
        /// `fill-nobreak-p`: not after a period followed by a single space.
        func breakable(after i: Int) -> Bool { !(words[i].spaces == 1 && words[i].word.hasSuffix(".")) }
        var out: [String] = []
        var start = 0
        while start < words.count {
            let lead = out.isEmpty ? first : prefix
            var length = lead.count + words[start].word.count
            var end = start
            var lastBreak: Int?
            while end + 1 < words.count {
                let next = length + words[end].spaces + words[end + 1].word.count
                if next > width {
                    if breakable(after: end) {
                        lastBreak = end
                        break
                    }
                    if lastBreak != nil { break }
                } else if breakable(after: end) {
                    lastBreak = end
                }
                length = next
                end += 1
            }
            let stop = end + 1 < words.count ? (lastBreak ?? end) : end
            var line = lead
            for i in start...stop {
                line += words[i].word
                if i < stop { line += String(repeating: " ", count: words[i].spaces) }
            }
            out.append(line)
            start = stop + 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: Lists

    func list(_ node: SyntaxNode, source: NSString, width: Int) -> String {
        let items = node.children.filter { $0.kind == .item }
        var out = ""
        var number = 0
        // The first item decides the list's type, as `org-list-get-list-type` does.
        let firstBullet = (items.first?.tokens.first { $0.kind == .bullet }?.text ?? "-").trimmingCharacters(in: .whitespaces)
        let descriptive = items.first?.firstChild(.itemTag) != nil
        let ordered = !descriptive && firstBullet.first.map { $0.isNumber || $0.isLetter } == true
        for (index, item) in items.enumerated() {
            let bulletText = (item.tokens.first { $0.kind == .bullet }?.text ?? "-").trimmingCharacters(in: .whitespaces)
            let checkbox: String = switch item.tokens.first(where: { $0.kind == .checkbox })?.text {
            case "[X]"?, "[x]"?: "☑ "
            case "[ ]"?: "☐ "
            case "[-]"?: "☒ "
            default: ""
            }
            let tag = descriptive ? item.firstChild(.itemTag) : nil
            let bullet: String
            let indentation: Int
            if descriptive {
                bullet = checkbox + (tag.map { inline($0).trimmingCharacters(in: .whitespaces) } ?? "")
                indentation = Self.quoteMargin
            } else if ordered {
                if let counter = item.tokens.first(where: { $0.kind == .counter })?.text,
                   let n = Int(counter.trimmingCharacters(in: CharacterSet(charactersIn: "[@] "))) {
                    number = n
                } else {
                    number += 1
                }
                bullet = bulletText.replacing(/[0-9A-Za-z]+/, with: String(number)) + " "
                indentation = bullet.count
            } else {
                bullet = ["-": "• ", "+": "⁃ ", "*": "‣ "][bulletText] ?? bulletText + " "
                indentation = bullet.count
            }
            let children = item.children.filter { $0.kind != .itemTag }
            let inner = descriptive ? width - Self.quoteMargin : width - indentation - checkbox.count
            let contents = elements(children, end: item.range.upperBound, source: source, width: inner)
            let indented = Self.indent(contents, indentation)
            let firstIsParagraph = children.first { (element($0, source: source, width: inner) ?? "").contains(where: { !$0.isWhitespace }) }?.kind == .paragraph
            var text = bullet + checkbox
            if !descriptive, indented.contains(where: { !$0.isWhitespace }), firstIsParagraph {
                text += indented.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text += "\n" + indented
            }
            let next = index + 1 < items.count ? items[index + 1].range.lowerBound : item.range.upperBound
            out += Self.normalized(text) + String(repeating: "\n", count: Self.blankLines(source, from: item.range.upperBound, to: next))
        }
        return out
    }

    /// `org-ascii--indent-string`: `width` spaces before each line that isn't blank.
    static func indent(_ s: String, _ width: Int) -> String {
        let pad = String(repeating: " ", count: width)
        return s.components(separatedBy: "\n").map { $0.contains(where: { !$0.isWhitespace }) ? pad + $0 : $0 }.joined(separator: "\n")
    }

    static func removeIndentation(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let common = lines.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }

    /// `org-ascii--box-string` in UTF-8.
    static func box(_ s: String) -> String {
        let body = s.replacing(#/\n[ \t]*\z/#, with: "")
        return "┌────\n" + body.components(separatedBy: "\n").map { "│ " + $0 }.joined(separator: "\n") + "\n└────"
    }

    // MARK: Blocks

    func block(_ node: SyntaxNode, width: Int) -> String? {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first, let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return nil }
        let type = m.1.lowercased()
        var body = Array(lines.dropFirst().dropLast()).map {
            $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression)
        }
        body = Self.removeIndentation(body.joined(separator: "\n")).components(separatedBy: "\n")
        switch type {
        case "src", "example":
            let code = body.joined(separator: "\n")
            return code.isEmpty ? "" : Self.box(code)
        case "quote":
            return Self.indent(nested(body.joined(separator: "\n"), width: width - 2 * Self.quoteMargin), Self.quoteMargin)
        case "verse":
            let tree = OrgParser.parse(body.joined(separator: "\n"))
            let text = tree.root.descendants().filter { $0.kind == .paragraph }.map { inline($0) }.joined(separator: "\n\n")
            return Self.indent(text, Self.quoteMargin)
        case "export":
            return m.2.lowercased().hasPrefix("ascii") ? body.joined(separator: "\n") : nil
        case "comment":
            return nil
        default:
            return nested(body.joined(separator: "\n"), width: width)
        }
    }

    /// A block's contents, parsed as elements.
    func nested(_ text: String, width: Int) -> String {
        let tree = OrgParser.parse(text)
        let ns = text as NSString
        let children = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        return elements(children, end: ns.length, source: ns, width: width)
    }

    // MARK: Tables

    func table(_ node: SyntaxNode) -> String {
        let rows = node.children.filter { $0.kind == .tableRow }
        let cells: [[String]?] = rows.map { row in
            let cells = row.children.filter { $0.kind == .tableCell }
            if cells.isEmpty { return nil }
            return cells.map { inline($0).trimmingCharacters(in: .whitespaces) }
        }
        let data = cells.compactMap { $0 }
        guard !data.isEmpty else { return "" }
        let columns = data.map(\.count).max() ?? 0
        let filled = data.map { $0 + Array(repeating: "", count: columns - $0.count) }
        var widths = (0..<columns).map { c in filled.map { $0[c].count }.max() ?? 0 }
        // Width cookies such as `<10>` widen the column, as `org-ascii-table-widen-columns`.
        for row in filled where row.allSatisfy({ $0.isEmpty || $0.range(of: "^<[lrc]?[0-9]*>$", options: .regularExpression) != nil }) {
            for (c, cell) in row.enumerated() { if let n = Int(cell.filter(\.isNumber)) { widths[c] = max(widths[c], n) } }
        }
        let cookieRows = Set(filled.indices.filter { r in
            filled[r].contains { !$0.isEmpty } && filled[r].allSatisfy { $0.isEmpty || $0.range(of: "^<[lrc]?[0-9]*>$", options: .regularExpression) != nil }
        })
        let right = (0..<columns).map { c -> Bool in
            let values = filled.indices.filter { !cookieRows.contains($0) }.map { filled[$0][c] }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return false }
            let numbers = values.filter { $0.range(of: "^([><]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%:]*|[-+]?0[xX][0-9a-fA-F.]+|[-+]?[0-9]+#[0-9a-zA-Z.]+|nan|[-+u]?inf)$", options: .regularExpression) != nil }
            return Double(numbers.count) / Double(values.count) >= 0.5
        }
        func line(_ char: String) -> String { widths.map { String(repeating: char, count: $0 + 2) }.joined() }
        var out = ""
        var dataIndex = 0
        let lastData = cells.lastIndex { $0 != nil }!
        let firstData = cells.firstIndex { $0 != nil }!
        for (r, row) in cells.enumerated() {
            guard row != nil else { continue }
            let rowIndex = dataIndex
            dataIndex += 1
            if cookieRows.contains(rowIndex) { continue }
            if r == firstData {
                out += line("━") + "\n"
            } else if r > 0, cells[r - 1] == nil {
                out += line("─") + "\n"
            }
            out += filled[rowIndex].enumerated().map { c, cell in
                let pad = String(repeating: " ", count: max(0, widths[c] - cell.count))
                return " " + (right[c] ? pad + cell : cell + pad) + " "
            }.joined() + "\n"
            if r == lastData { out += line("━") + "\n" }
        }
        return out
    }

    // MARK: - Objects

    /// The objects in `node`, as ox-ascii writes them.
    func inline(_ node: SyntaxNode, skippingTimestamps isolated: Bool = false) -> String {
        var out = ""
        for element in node.elements {
            switch element {
            case .token(let token):
                switch token.kind {
                case .marker, .stars, .bullet, .checkbox, .tags, .todoKeyword, .priority, .counter: continue
                default: out += special(token.text)
                }
            case .node(let child):
                if isolated, child.kind == .timestamp, ICalendarExport.skipsTimestamp(child.text, with: options.timestamps ?? "t") { continue }
                out += object(child)
            }
        }
        return out
    }

    /// `org-ascii-plain-text` with `:with-special-strings`.
    func special(_ text: String) -> String {
        guard options.specialStrings else { return text }
        return text.replacingOccurrences(of: "\\-", with: "").replacingOccurrences(of: "---", with: "—")
            .replacingOccurrences(of: "--", with: "–").replacingOccurrences(of: "...", with: "…")
    }

    /// The text between the markers.
    static func value(_ node: SyntaxNode) -> String {
        node.elements.compactMap { element -> String? in
            guard case .token(let token) = element, token.kind != .marker else { return nil }
            return token.text
        }.joined()
    }

    func object(_ node: SyntaxNode) -> String {
        switch node.kind {
        case .bold: return "*\(inline(node))*"
        case .italic: return "/\(inline(node))/"
        case .underline: return "_\(inline(node))_"
        case .strikeThrough: return "+\(inline(node))+"
        case .verbatim, .code: return "`\(Self.value(node))'"
        case .link: return link(node)
        case .linkDescription: return inline(node)
        case .timestamp: return special(Self.timestamp(node.text))
        // The iCalendar backend leaves footnote references out.
        case .footnoteReference: return ""
        case .entity:
            let name = node.text.dropFirst().replacingOccurrences(of: "{}", with: "")
            return OrgEntities.display[name] ?? node.text
        case .radioTarget: return String(node.text.dropFirst(3).dropLast(3))
        case .target: return ""
        case .superscript, .subscript:
            let body = node.text.dropFirst()
            let braced = body.hasPrefix("{") && body.hasSuffix("}")
            if options.scripts == .off || (options.scripts == .braces && !braced) { return special(node.text) }
            let mark = node.text.hasPrefix("_") ? "_" : "^"
            return braced ? mark + "{" + String(body.dropFirst().dropLast()) + "}" : mark + String(body)
        case .lineBreak: return Self.hardNewline
        case .latexFragment: return options.tex ? node.text : ""
        case .inlineSourceBlock:
            if let m = node.text.firstMatch(of: /\{(.*)\}$/) { return "`\(m.1)'" }
            return node.text
        case .exportSnippet:
            guard node.tokens.first?.text.lowercased() == "@@ascii:" else { return "" }
            return node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
        case .statisticsCookie: return node.text
        case .inlineBabelCall, .macro: return ""
        default: return inline(node)
        }
    }

    func link(_ node: SyntaxNode) -> String {
        let description = node.firstChild(.linkDescription).map { inline($0) }
        guard let path = node.tokens.first(where: { $0.kind == .linkPath })?.text else {
            var target = node.text
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            // A radio link is its text.
            if !target.contains(":") { return target }
            return "<\(target)>"
        }
        if path.hasPrefix("("), path.hasSuffix(")") { return description ?? String(path.dropFirst().dropLast()) }
        let scheme = path.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/).map { String($0.1).lowercased() }
        let isInternal = scheme == nil || scheme == "id" || path.hasPrefix("#") || path.hasPrefix("*")
        if isInternal, !(scheme == nil && (path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("~"))) {
            let title = path.hasPrefix("*") ? String(path.dropFirst()) : path
            let number = headingNumbers[title]
            if let description { return "[\(description)]" + (number.map { " (See section \($0))" } ?? "") }
            return number ?? title
        }
        guard let description, description.contains(where: { !$0.isWhitespace }) else { return "<\(path)>" }
        return "[\(description)] (<\(path)>)"
    }

    /// `org-timestamp-translate`: the timestamp as Org writes it, `9:00` as `09:00`.
    static func timestamp(_ text: String) -> String {
        guard let stamp = Timestamp.parse(text) else { return text }
        let open = stamp.active ? "<" : "["
        let close = stamp.active ? ">" : "]"
        func day(_ p: Timestamp.Point) -> String {
            let name = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Days.weekday(Days.absolute(year: p.year, month: p.month, day: p.day))]
            return String(format: "%04d-%02d-%02d ", p.year, p.month, p.day) + name
        }
        func time(_ p: Timestamp.Point) -> String { p.hour.map { String(format: " %02d:%02d", $0, p.minute ?? 0) } ?? "" }
        var suffix = ""
        if let r = stamp.repeater {
            suffix += " " + r.kind.rawValue + "\(r.interval.value)\(r.interval.unit.rawValue)"
            if let d = r.habitDeadline { suffix += "/\(d.value)\(d.unit.rawValue)" }
        }
        if let w = stamp.warning { suffix += " " + (w.firstOccurrenceOnly ? "--" : "-") + "\(w.interval.value)\(w.interval.unit.rawValue)" }
        let start = stamp.start
        guard let end = stamp.end else { return open + day(start) + time(start) + suffix + close }
        if (end.year, end.month, end.day) == (start.year, start.month, start.day), start.hour != nil, end.hour != nil {
            return open + day(start) + time(start) + "-" + String(time(end).dropFirst()) + suffix + close
        }
        return open + day(start) + time(start) + suffix + close + "--" + open + day(end) + time(end) + suffix + close
    }
}
