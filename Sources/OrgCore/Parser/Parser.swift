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
            single(.planning)
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

    static let affiliatedKeys: Set<String> = ["NAME", "CAPTION", "RESULTS", "HEADER", "PLOT"]

    /// One element starting at `i`. `floor` is the indent of the enclosing list item, if any:
    /// non-blank lines at or left of it end the element.
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

    /// Kinds whose single line holds inline objects (timestamps on planning and clock lines).
    static let inlineLineKinds: Set<SyntaxKind> = [.planning, .clock]

    mutating func single(_ kind: SyntaxKind) {
        builder.start(kind)
        if Self.inlineLineKinds.contains(kind) {
            let rest = whitespace(lines[i].content)
            inline(rest)
            builder.token(.newline, lines[i].ending)
        } else {
            line(i)
        }
        i += 1
        builder.finish()
    }

    /// Source text from `start` through the end of line `last`, including its line ending.
    func span(from start: Substring.Index, through last: Int) -> Substring {
        let base = lines[last].ending.base
        return base[start..<lines[last].ending.endIndex]
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
            tableRow()
        }
        while i < limit, info[i].cls == .keyword(key: "TBLFM"), within(floor, i) {
            single(.tableFormula)
        }
        builder.finish()
    }

    /// A rule row (`|---+---|`) is one text token. Other rows alternate `|` markers and cells;
    /// every pair of pipes gets a cell, even an empty one, so columns line up.
    mutating func tableRow() {
        builder.start(.tableRow)
        let rest = whitespace(lines[i].content)
        if rest.hasPrefix("|-") {
            builder.token(.text, rest)
        } else {
            var cellStart = rest.startIndex
            var index = rest.startIndex
            while index < rest.endIndex {
                if rest[index] == "|" {
                    if index > rest.startIndex { tableCell(rest[cellStart..<index]) }
                    builder.token(.marker, "|")
                    cellStart = rest.index(after: index)
                }
                index = rest.index(after: index)
            }
            if cellStart < rest.endIndex { tableCell(rest[cellStart...]) }
        }
        builder.token(.newline, lines[i].ending)
        builder.finish()
        i += 1
    }

    mutating func tableCell(_ text: Substring) {
        builder.start(.tableCell)
        inline(text)
        builder.finish()
    }

    mutating func footnoteDefinition(limit: Int) {
        var end = i + 1
        while end < limit, info[end].cls == .plain { end += 1 }
        let content = lines[i].content
        let close = content.firstIndex(of: "]")!
        builder.start(.footnoteDefinition)
        builder.token(.marker, content[...close])
        inline(span(from: content.index(after: close), through: end - 1))
        builder.finish()
        i = end
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
        var rest = whitespace(lines[i].content)
        let bullet = rest.prefix { $0 != " " && $0 != "\t" }
        builder.token(.bullet, bullet)
        rest = whitespace(rest.dropFirst(bullet.count))
        if let box = checkbox(rest) {
            builder.token(.checkbox, box)
            rest = whitespace(rest.dropFirst(box.count))
        }
        // The rest of the bullet line and its continuation lines are the item's first paragraph.
        var end = i + 1
        while end < limit, within(base, end), continuesParagraph(end) { end += 1 }
        if rest.isEmpty, end == i + 1 {
            builder.token(.newline, lines[i].ending)
        } else {
            builder.start(.paragraph)
            inline(span(from: rest.startIndex, through: end - 1))
            builder.finish()
        }
        i = end
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

    /// `[ ]`, `[X]`, `[x]` or `[-]`, followed by whitespace or end of line.
    func checkbox(_ s: Substring) -> Substring? {
        guard s.count >= 3, s.first == "[", "Xx -".contains(s.dropFirst().first!),
              s.dropFirst(2).first == "]" else { return nil }
        let after = s.dropFirst(3)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return s.prefix(3)
    }

    /// The paragraph's lines are one inline run, so emphasis and links can cross a line break.
    mutating func paragraph(limit: Int, floor: Int?) {
        var end = i + 1
        while end < limit, within(floor, end), continuesParagraph(end) { end += 1 }
        builder.start(.paragraph)
        inline(span(from: lines[i].content.startIndex, through: end - 1))
        builder.finish()
        i = end
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

    func within(_ floor: Int?, _ k: Int) -> Bool {
        guard let floor else { return true }
        return info[k].indent > floor
    }

    // MARK: - Tokens

    /// A whole line as leading whitespace, content and line ending.
    mutating func line(_ k: Int) {
        let rest = whitespace(lines[k].content)
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
        if !parts.title.isEmpty {
            builder.start(.title)
            inline(parts.title)
            builder.finish()
        }
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
