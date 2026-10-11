import Foundation

/// A link as `org-element-link-parser` reads it.
public struct OrgLink: Sendable, Equatable {
    /// `https`, `file`, `id`, `custom-id`, `coderef`, `fuzzy`, or another registered type.
    public let type: String
    public let path: String
    /// What follows `::` in a file link.
    public let searchOption: String?
    /// The link as written, unescaped and with abbreviations expanded.
    public let raw: String
    /// Where an `attachment` link starts in its file, whose entry holds the attachments.
    public var position: Int?

    public init(type: String, path: String, searchOption: String? = nil, raw: String, position: Int? = nil) {
        self.type = type
        self.path = path
        self.searchOption = searchOption
        self.raw = raw
        self.position = position
    }
}

public enum Links {
    /// `org-link-parameters` in Emacs with Org's default modules, and org-attach's.
    static let types = [
        "attachment", "id", "eww", "rmail", "mhe", "irc", "info", "gnus", "docview", "bibtex", "bbdb", "w3m", "doi", "file+sys", "file+emacs",
        "shell", "news", "mailto", "https", "http", "ftp", "shortdoc", "help", "file", "elisp",
    ]

    /// `org-link-types-re`: a registered type and its colon, longest names first.
    static let typesPattern = try! NSRegularExpression(
        pattern: "^(" + types.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + "):"
    )

    /// `org-link-unescape`: halves each run of backslashes before a bracket or the end.
    static func unescape(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: "(\\\\+)(?=$|[\\[\\]])")
        let ns = s as NSString
        var out = s
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let run = m.range(at: 1)
            out = (out as NSString).replacingCharacters(in: run, with: String(repeating: "\\", count: run.length / 2))
        }
        return out
    }

    /// `#+LINK: key template` lines of a file.
    public static func abbreviations(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: "^[ \\t]*#\\+LINK:[ \\t]+(\\S+)[ \\t]+(.*?)[ \\t]*$", options: [.anchorsMatchLines, .caseInsensitive])
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where result[ns.substring(with: m.range(at: 1))] == nil {
            result[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return result
    }

    /// `org-link-expand-abbrev` for templates with `%s`, `%h`, or a plain prefix.
    static func expandAbbreviation(_ link: String, _ abbreviations: [String: String]) -> String {
        let regex = try! NSRegularExpression(pattern: "^([^:]*)(::?(.*))?$")
        let ns = link as NSString
        guard let m = regex.firstMatch(in: link, range: NSRange(location: 0, length: ns.length)),
              let template = abbreviations[ns.substring(with: m.range(at: 1))] else { return link }
        let tag = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: tag, options: [], range: template.range(of: "%s"))
        }
        if template.contains("%h") {
            let hex = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? tag
            return template.replacingOccurrences(of: "%h", with: hex, options: [], range: template.range(of: "%h"))
        }
        return template + tag
    }

    /// A bracket link's inside (`[[` to `]]` or `][`), as `org-element-link-parser` reads it.
    public static func parse(bracket inside: String, abbreviations: [String: String] = [:]) -> OrgLink {
        let joined = inside.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: " ", options: .regularExpression)
        let raw = expandAbbreviation(unescape(joined), abbreviations)
        let ns = raw as NSString
        var type: String
        var path: String
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../") {
            type = "file"
            path = raw
        } else if let m = typesPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            type = ns.substring(with: m.range(at: 1))
            path = ns.substring(from: NSMaxRange(m.range))
        } else if raw.hasPrefix("("), raw.hasSuffix(")"), raw.count >= 2 {
            type = "coderef"
            path = String(raw.dropFirst().dropLast())
        } else if raw.hasPrefix("#") {
            type = "custom-id"
            path = String(raw.dropFirst())
        } else {
            type = "fuzzy"
            path = raw
        }
        return fileParts(type: type, path: path, raw: raw)
    }

    /// A plain or angle link: `type:path` as written.
    public static func parse(plain: String) -> OrgLink {
        let ns = plain as NSString
        guard let m = typesPattern.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length)) else {
            return OrgLink(type: "fuzzy", path: plain, raw: plain)
        }
        let path = ns.substring(from: NSMaxRange(m.range)).replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "", options: .regularExpression)
        return fileParts(type: ns.substring(with: m.range(at: 1)), path: path, raw: plain)
    }

    /// `file` and `file+app` links keep their `::search` apart.
    static func fileParts(type: String, path: String, raw: String) -> OrgLink {
        guard type == "file" || type.hasPrefix("file+") else { return OrgLink(type: type, path: path, raw: raw) }
        var path = path
        var search: String?
        if let range = path.range(of: "::(.*)$", options: .regularExpression) {
            search = String(path[range].dropFirst(2))
            path.removeSubrange(range)
        }
        path = path.replacingOccurrences(of: "^///*([A-Za-z]:)?/", with: "$1/", options: .regularExpression)
        return OrgLink(type: "file", path: path, searchOption: search, raw: raw)
    }

    /// The link at `offset`: the link node holding it, read with the file's abbreviations.
    public static func link(at offset: Int, text: String, tree: OrgTree) -> (link: OrgLink, range: Range<Int>)? {
        var found: SyntaxNode?
        func walk(_ node: SyntaxNode) {
            for child in node.children where child.range.lowerBound <= offset && offset < child.range.upperBound
                || (child.range.upperBound == offset && child.kind == .link) {
                if child.kind == .link { found = child }
                walk(child)
            }
        }
        walk(tree.root)
        guard let node = found else { return nil }
        let whole = node.text
        var link: OrgLink
        if whole.hasPrefix("[["), let path = node.tokens.first(where: { $0.kind == .linkPath }) {
            link = parse(bracket: path.text, abbreviations: abbreviations(in: tree.settings.setupKeywords + text))
        } else if whole.hasPrefix("<") && whole.hasSuffix(">") {
            link = parse(plain: String(whole.dropFirst().dropLast()))
        } else if tree.settings.radioTargets.contains(where: { words($0) == words(whole) }) {
            link = OrgLink(type: "radio", path: whole, raw: whole)
        } else {
            link = parse(plain: whole)
        }
        if link.type == "attachment" { link.position = node.range.lowerBound }
        return (link, node.range)
    }

    /// Words without case, as radio links match their targets.
    static func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    /// `org-link--search-radio-target`: the `<<<target>>>` a radio link's text names.
    public static func searchRadio(_ target: String, tree: OrgTree) -> SearchResult {
        var found: Int?
        func walk(_ node: SyntaxNode) {
            for child in node.children where found == nil {
                if child.kind == .radioTarget, words(String(child.text.dropFirst(3).dropLast(3))) == words(target) {
                    found = child.range.lowerBound
                }
                walk(child)
            }
        }
        walk(tree.root)
        return found.map { .found($0) } ?? .failed("No match for radio target: \(target)")
    }

    /// The file `org-attach-follow` opens for an `attachment` link, with org-attach's
    /// defaults: in the entry's DIR property (or the older ATTACH_DIR), else in the folder for
    /// its ID under `data/` that exists (`org-attach-id-to-path-function-list`), both relative
    /// to the file's folder. Without an existing folder the file is relative to the file's
    /// folder, as `org-attach-expand` has it. Nil without a folder to start from.
    public static func attachmentFile(_ link: OrgLink, tree: OrgTree, path: String?, isDirectory: (String) -> Bool) -> OrgLink? {
        let model = DocumentModel(tree: tree)
        let offset = link.position ?? 0
        let heading = model.headings.lastIndex { $0.sectionRange.contains(offset) }
        let folder = path.map { ($0 as NSString).deletingLastPathComponent }
        func absolute(_ p: String, in folder: String?) -> String? {
            let expanded = (p as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
            return folder.map { (($0 as NSString).appendingPathComponent(expanded) as NSString).standardizingPath }
        }
        var candidates: [String] = []
        if let dir = model.property("DIR", of: heading) ?? model.property("ATTACH_DIR", of: heading) {
            candidates = [dir.value]
        } else if let id = model.property("ID", of: heading)?.value, let first = id.first {
            let chars = Array(id)
            if chars.count > 2 { candidates.append("data/" + String(chars[..<2]) + "/" + String(chars[2...])) }
            if chars.count > 6 { candidates.append("data/" + String(chars[..<6]) + "/" + String(chars[6...])) }
            candidates.append("data/__/\(first)/\(id)")
        }
        let dir = candidates.lazy.compactMap { absolute($0, in: folder) }.first(where: isDirectory) ?? folder
        var file = link.path
        var search: String?
        if let range = file.range(of: "::") {
            search = String(file[range.upperBound...])
            file = String(file[..<range.lowerBound])
        }
        return absolute(file, in: dir).map { OrgLink(type: "file", path: $0, searchOption: search, raw: link.raw) }
    }

    // MARK: - Searching a file

    public enum SearchResult: Sendable, Equatable {
        case found(Int)
        case failed(String)
        /// `/regexp/`: `org-occur`'s sparse tree for the regular expression.
        case occur(String)
    }

    /// The regular expression of a `[[/regexp/]]` link or a `file:…::/regexp/` search.
    public static func regexpSearch(_ link: OrgLink) -> String? {
        let s = link.type == "fuzzy" ? link.path : link.type == "file" ? (link.searchOption ?? "") : ""
        guard s.count >= 2, s.hasPrefix("/"), s.hasSuffix("/") else { return nil }
        return String(s.dropFirst().dropLast())
    }

    /// `org-link-search` in an org file: a `#custom-id`, a `<<target>>`, a `#+NAME:`, or a
    /// heading with these words (`*` asks for a heading only).
    public static func search(_ s: String, text: String, tree: OrgTree) -> SearchResult {
        guard s.contains(where: { !$0.isWhitespace }) else { return .failed("Invalid search string \"\(s)\"") }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let normalized = s.replacingOccurrences(of: "\\n[ \\t]*", with: " ", options: .regularExpression)
        let starred = normalized.hasPrefix("*")
        let words = (starred ? String(s.dropFirst()) : s).split(whereSeparator: \.isWhitespace).map(String.init)
        let model = DocumentModel(tree: tree)

        if normalized.hasPrefix("#") {
            let id = String(normalized.dropFirst())
            for heading in model.headings where heading.properties.contains(where: { $0.key.uppercased() == "CUSTOM_ID" && $0.value == id }) {
                return .found(heading.headingRange.lowerBound)
            }
            return .failed("No match for custom ID: \(id)")
        }
        if normalized.hasPrefix("("), normalized.hasSuffix(")") {
            let name = String(normalized.dropFirst().dropLast())
            return Coderef.search(name, text: text, tree: tree).map(SearchResult.found) ?? .failed("No match for coderef: \(name)")
        }
        if normalized.count >= 2, normalized.hasPrefix("/"), normalized.hasSuffix("/") {
            return .occur(String(s.dropFirst().dropLast()))
        }
        let quoted = words.map(NSRegularExpression.escapedPattern(for:))
        if !starred {
            // A dedicated target, not part of a radio target.
            let target = try! NSRegularExpression(pattern: "(?<!<)<<" + quoted.joined(separator: "(?:[ \\t\\n]+)") + ">>(?!>)", options: .caseInsensitive)
            if let m = target.firstMatch(in: text, range: all) { return .found(m.range.location) }
            let name = try! NSRegularExpression(pattern: "^[ \\t]*#\\+NAME: +" + quoted.joined(separator: "[ \\t]+") + "[ \\t]*$", options: [.anchorsMatchLines, .caseInsensitive])
            if let m = name.firstMatch(in: text, range: all) { return .found(ns.lineRange(for: m.range).location) }
        }
        let upper = words.map { $0.uppercased() }
        for heading in model.headings {
            let title = normalizedTitle(heading.title)
            if title.split(whereSeparator: \.isWhitespace).map({ $0.uppercased() }) == upper {
                return .found(heading.headingRange.lowerBound)
            }
        }
        return .failed("No match for fuzzy expression: \(normalized)")
    }

    /// `org-link--normalize-string` of a heading title: statistics cookies and runs of space go.
    static func normalizedTitle(_ title: String) -> String {
        var t = title
        if t == "COMMENT" { t = "" } else if t.hasPrefix("COMMENT ") { t = String(t.dropFirst(8)) }
        t = t.replacingOccurrences(of: "\\[[0-9]*(%|/[0-9]*)\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// `org-open-at-point` on a link or a timestamp (C-c C-o).
public struct OpenLinkAtPoint: OrgCommand {
    public init() {}
    public var id: String { "org.link.open" }
    public var title: String { "Open Link" }
    public func applies(in context: EditContext) -> Bool {
        Links.link(at: context.caret, text: context.text, tree: context.tree) != nil
            || Links.timestampDays(at: context.caret, text: context.text) != nil
    }
    public func run(in context: EditContext) -> CommandStep {
        if let found = Links.link(at: context.caret, text: context.text, tree: context.tree) {
            return .external(.openLink(found.link))
        }
        if let days = Links.timestampDays(at: context.caret, text: context.text) {
            return .external(.agenda(start: days.start, days: days.count))
        }
        return .failed("No link to follow here")
    }
}

extension Links {
    /// `org-at-date-range-p` with INACTIVE-OK: the range starting at one of the two brackets
    /// back from `offset` that reaches it.
    static func dateRange(at offset: Int, text ns: NSString) -> [Range<Int>?]? {
        let stamp = "[\\[<]([0-9]{4}-[0-9]{2}-[0-9]{2}(?: .*?)?)[\\]>]"
        let regex = try! NSRegularExpression(pattern: stamp + "--?-?" + stamp)
        func char(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        let brackets: Set<unichar> = [91, 60]
        var p = offset
        for _ in 0..<2 {
            while let c = char(p - 1), !brackets.contains(c), c != 10, c != 13 { p -= 1 }
            while let c = char(p - 1), brackets.contains(c) { p -= 1 }
            if let m = regex.firstMatch(in: ns as String, options: .anchored, range: NSRange(location: p, length: ns.length - p)),
               NSMaxRange(m.range) >= offset {
                return (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : m.range(at: i).location..<NSMaxRange(m.range(at: i)) }
            }
        }
        return nil
    }

    /// `org-follow-timestamp-link`: the agenda's first day and length for the date range or
    /// timestamp at `offset`. Point just past a timestamp isn't on it.
    public static func timestampDays(at offset: Int, text: String) -> (start: Int, count: Int)? {
        let buffer = EmacsBuffer(text, point: offset)
        func day(_ match: [Range<Int>?], _ group: Int) -> Int? {
            guard let range = match[group] else { return nil }
            let parts = buffer.substring(range.lowerBound, range.upperBound).prefix(10).split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? Days.absolute(year: parts[0], month: parts[1], day: parts[2]) : nil
        }
        if let range = dateRange(at: offset, text: text as NSString), let first = day(range, 1), let last = day(range, 2) {
            return (first, last - first + 1)
        }
        if let (part, match) = buffer.atTimestamp(), part != .after, let first = day(match, 1) {
            return (first, 1)
        }
        return nil
    }
}
