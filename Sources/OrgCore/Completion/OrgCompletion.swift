import Foundation

// Completion at point (Org 9.8.7's org-pcomplete): `org-thing-at-point` picks what the caret
// is on, and each context offers what its `pcomplete/org-mode/…` function does. Link types
// after `[[`, workspace tags and org-tempo's `<` templates are added.

public struct Completion: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case keyword, keywordValue, link, entity, tag, todo, heading, drawer, property, srcLanguage, srcHeader, clocktable, template
    }

    public var kind: Kind
    /// The text the chosen candidate replaces: from the start of what's typed to the caret.
    public var range: Range<Int>
    /// Candidates starting with what's typed, sorted.
    public var candidates: [String]

    /// How the list shows `candidate`: a template with the block it makes.
    public func label(_ candidate: String) -> String {
        guard kind == .template, let value = OrgCompletion.templateKeys.first(where: { "<" + $0.key == candidate })?.value else { return candidate }
        return candidate + "  " + value
    }

    /// Text to insert for `candidate`, and where the caret goes in it.
    public func insertion(_ candidate: String) -> (text: String, caret: Int) {
        guard kind == .template, let expansion = OrgCompletion.templateExpansion(candidate) else { return (candidate, candidate.utf16.count) }
        return expansion
    }
}

public enum OrgCompletion {
    public static func at(_ context: EditContext) -> Completion? {
        let ns = context.text as NSString
        let caret = min(context.caret, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        let line = ns.substring(with: NSRange(location: lineRange.location, length: contentsEnd - lineRange.location))
        let start = lineRange.location
        let toHere = ns.substring(with: NSRange(location: start, length: caret - start))
        let afterBlank = ns.substring(with: NSRange(location: caret, length: contentsEnd - caret)).allSatisfy { $0 == " " || $0 == "\t" }
        /// `pcomplete`'s current argument: from the last blank or `[` on the line to the caret.
        let argStart: Int = {
            var p = caret
            while p > start, ![32, 9, 91].contains(ns.character(at: p - 1)) { p -= 1 }
            return p
        }()
        func make(_ kind: Completion.Kind, from: Int, _ candidates: [String]) -> Completion {
            let typed = ns.substring(with: NSRange(location: from, length: caret - from))
            var seen = Set<String>()
            let matching = candidates.filter { $0.hasPrefix(typed) && seen.insert($0).inserted }
            return Completion(kind: kind, range: from..<caret, candidates: matching.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        func matches(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> NSTextCheckingResult? {
            let regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        }
        /// Arguments before the current one on the line.
        func arguments() -> [String] {
            ns.substring(with: NSRange(location: start, length: argStart - start)).split { " \t[".contains($0) }.map(String.init)
        }

        // Templates (org-tempo): `<` and a key after only blanks.
        if let m = matches("^[ \\t]*<[A-Za-z]*$", toHere, caseInsensitive: false) {
            // The expansion replaces the indentation too.
            var completion = make(.template, from: start + (toHere as NSString).range(of: "<").location, templateKeys.map { "<" + $0.key })
            completion.range = start..<(start + m.range.length)
            return completion
        }
        if matches("^[ \\t]*#\\+BEGIN: clocktable[ \\t]", line) != nil {
            return make(.clocktable, from: argStart, clocktableOptions)
        }
        if matches("^[ \\t]*#\\+BEGIN_SRC[ \\t]", line) != nil {
            return arguments().count == 1 ? make(.srcLanguage, from: argStart, languages) : make(.srcHeader, from: argStart, srcHeaders)
        }
        if let m = matches("^[ \\t]*#\\+(\\S+):", line) {
            let keyword = (line as NSString).substring(with: m.range(at: 1)).lowercased()
            let arguments = arguments()
            // The keyword's own text, or (as pcomplete would) nothing past the value.
            guard argStart >= start + m.range.upperBound else { return nil }
            let values: [String]
            switch keyword {
            case "startup":
                values = startupOptions.filter { !(arguments.contains("hidestars") && $0 == "showstars") }
            case "options":
                values = exportOptions
            case _ where arguments.count > 1:
                return nil
            case "date":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = context.calendar
                formatter.timeZone = context.calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd EEE"
                values = ["<" + formatter.string(from: context.now) + ">"]
            case "exclude_tags": values = ["noexport"]
            case "select_tags": values = ["export"]
            case "language": values = ["en"]
            case "priorities":
                let p = context.tree.settings.priorities
                values = ["\(p.highest) \(p.lowest) \(p.default)"]
            default:
                return nil
            }
            return make(.keywordValue, from: argStart, values)
        }
        if matches("^[ \\t]*#\\+[a-zA-Z_]*$", line) != nil, afterBlank {
            let from = start + NSMaxRange((line as NSString).range(of: "#+"))
            return make(.keyword, from: from, caseDouble(fileOptions))
        }
        // Link abbreviations and types after `[[`.
        do {
            var p = caret
            while p > start, let ch = UnicodeScalar(ns.character(at: p - 1)), CharacterSet(charactersIn: "-_").union(.alphanumerics).contains(ch), ch.isASCII { p -= 1 }
            if p - 2 >= start, ns.character(at: p - 1) == 91, ns.character(at: p - 2) == 91 {
                let abbreviations = Links.abbreviations(in: context.tree.settings.setupKeywords + context.text).keys.map { $0 + ":" }
                return make(.link, from: p, abbreviations + linkTypes.map { $0 + ":" })
            }
        }
        // Entities after `\`.
        do {
            var p = caret
            while p > start, (48...57).contains(ns.character(at: p - 1)) { p -= 1 }
            while p > start, let ch = UnicodeScalar(ns.character(at: p - 1)), ch.isASCII, CharacterSet.letters.contains(ch) { p -= 1 }
            if p > start, ns.character(at: p - 1) == 92 {
                return make(.entity, from: p, Array(OrgEntities.display.keys))
            }
        }
        // Tags at the end of a heading.
        if let m = matches("^\\*+ (?:.+? )?(:)((?::|[\\p{L}\\p{N}_@#%]+)+)?[ \\t]*$", line, caseInsensitive: false) {
            let colon = start + m.range(at: 1).location + 1
            let group = m.range(at: 2)
            let inGroup = group.location != NSNotFound && caret >= start + group.location && caret <= start + group.location + group.length
            if inGroup || caret == colon {
                let typed = ns.substring(with: NSRange(location: colon, length: caret - colon))
                let from = colon + ((typed as NSString).range(of: ":", options: .backwards).toOptional.map { NSMaxRange($0) } ?? 0)
                let heading = DocumentModel(tree: context.tree).headings.last { $0.headingRange.lowerBound <= caret }
                let own = Set(heading?.localTags ?? [])
                let alist = FastSelection.tagTable(context.tree.settings.setupKeywords + context.text)?.compactMap { item -> String? in
                    if case .option(_, let name) = item { return name }
                    return nil
                } ?? []
                let pool = alist.isEmpty ? SetTags.bufferTags(context) + context.knownTags() : alist
                return make(.tag, from: from, pool.filter { !own.contains($0) }.map { $0 + ":" })
            }
        }
        // TODO keywords on an empty heading.
        if matches("^\\*+ +\\S*$", toHere, caseInsensitive: false) != nil, afterBlank {
            let keywords = context.tree.settings.todoSequences.flatMap { $0.active + $0.done }.map(\.name)
            return make(.todo, from: argStart, keywords)
        }
        // Headings after `[[*`.
        if let star = (toHere as NSString).range(of: "*", options: .backwards).toOptional, star.location >= 2,
           (toHere as NSString).substring(with: NSRange(location: star.location - 2, length: 2)) == "[[" {
            let titles = DocumentModel(tree: context.tree).headings.map { Links.normalizedTitle($0.title) }
            return make(.heading, from: start + star.location + 1, titles)
        }
        // Property or drawer names.
        if matches("^[ \\t]*:\\S*$", toHere, caseInsensitive: false) != nil, afterBlank {
            let from = start + NSMaxRange((toHere as NSString).range(of: ":"))
            if let entry = propertyEntry(context, lineStart: start) {
                return make(.property, from: from, caseDouble(propertyKeys(context).filter { !entry.contains($0) }.map { $0 + ": " }))
            }
            return make(.drawer, from: from, caseDouble((["PROPERTIES"] + drawerNames(context.tree)).map { $0 + ":" }))
        }
        return nil
    }

    // MARK: - Sources

    /// Upper and lower case of each, as `org-pcomplete-case-double`.
    static func caseDouble(_ list: [String]) -> [String] { list.flatMap { [$0.uppercased(), $0.lowercased()] } }

    /// When the line is in a heading's property drawer, the properties the entry already has.
    static func propertyEntry(_ context: EditContext, lineStart: Int) -> Set<String>? {
        guard let heading = DocumentModel(tree: context.tree).headings.last(where: { $0.headingRange.lowerBound < lineStart }),
              let drawer = context.tree.root.descendants().first(where: {
                  $0.kind == .propertyDrawer && $0.range.lowerBound > heading.headingRange.lowerBound && $0.range.contains(lineStart)
              }) else { return nil }
        let ns = context.text as NSString
        // Only on the line after the last property, as `org-pcomplete` checks.
        var p = drawer.range.lowerBound
        p = NSMaxRange(ns.lineRange(for: NSRange(location: p, length: 0)))
        while p < drawer.range.upperBound {
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: p, length: 0)))
            guard line.range(of: "^[ \\t]*:\\S+:", options: .regularExpression) != nil, line.range(of: "^[ \\t]*:END:", options: [.regularExpression, .caseInsensitive]) == nil else { break }
            p = NSMaxRange(ns.lineRange(for: NSRange(location: p, length: 0)))
        }
        guard p == lineStart else { return nil }
        return Set(heading.properties.map { $0.key.uppercased() } + ["CATEGORY"])
    }

    /// `org-buffer-property-keys` with defaults and column keys.
    static func propertyKeys(_ context: EditContext) -> [String] {
        var keys: [String] = []
        for heading in DocumentModel(tree: context.tree).headings {
            for property in heading.properties {
                keys.append(property.key)
                if property.key.uppercased().hasSuffix("_ALL") { keys.append(String(property.key.dropLast(4))) }
            }
        }
        let ns = context.text as NSString
        let columnLines = try! NSRegularExpression(pattern: "^[ \\t]*#\\+COLUMNS:(.*)$|^[ \\t]*:COLUMNS:(.*)$", options: [.anchorsMatchLines, .caseInsensitive])
        let columns = columnLines.matches(in: context.text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1).location != NSNotFound ? $0.range(at: 1) : $0.range(at: 2))
        }
        for spec in columns {
            for m in try! NSRegularExpression(pattern: "%[0-9]*([-\\w]+)").matches(in: spec, range: NSRange(location: 0, length: (spec as NSString).length)) {
                keys.append((spec as NSString).substring(with: m.range(at: 1)))
            }
        }
        return keys + defaultProperties + ["EFFORT"]
    }

    static func drawerNames(_ tree: OrgTree) -> [String] {
        let ns = tree.text as NSString
        return tree.root.descendants().filter { $0.kind == .drawer }.compactMap { node in
            let first = ns.substring(with: ns.lineRange(for: NSRange(location: node.range.lowerBound, length: 0)))
            return first.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
    }

    static let templateKeys: [(key: String, value: String)] = [
        ("a", "export ascii"), ("c", "center"), ("C", "comment"), ("e", "example"), ("E", "export"), ("h", "export html"),
        ("l", "export latex"), ("q", "quote"), ("s", "src"), ("v", "verse"),
        ("L", "latex"), ("H", "html"), ("A", "ascii"), ("i", "index"),
    ]

    /// org-tempo's expansion of `<key`: a block, or for keywords a `#+key: ` line.
    static func templateExpansion(_ candidate: String) -> (text: String, caret: Int)? {
        let key = String(candidate.dropFirst())
        guard let index = templateKeys.firstIndex(where: { $0.key == key }) else { return nil }
        let value = templateKeys[index].value
        if index >= 10 {
            let text = "#+\(value): "
            return (text, text.utf16.count)
        }
        let name = value.split(separator: " ").first.map(String.init) ?? value
        let begin = "#+begin_\(value)" + (["src", "export"].contains(value) ? " " : "")
        return (begin + "\n#+end_\(name)", begin.utf16.count)
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}
