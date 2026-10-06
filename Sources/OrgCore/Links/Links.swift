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

    public init(type: String, path: String, searchOption: String? = nil, raw: String) {
        self.type = type
        self.path = path
        self.searchOption = searchOption
        self.raw = raw
    }
}

public enum Links {
    /// `org-link-parameters` in Emacs with Org's default modules.
    static let types = [
        "id", "eww", "rmail", "mhe", "irc", "info", "gnus", "docview", "bibtex", "bbdb", "w3m", "doi", "file+sys", "file+emacs",
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
        if whole.hasPrefix("[["), let path = node.tokens.first(where: { $0.kind == .linkPath }) {
            return (parse(bracket: path.text, abbreviations: abbreviations(in: text)), node.range)
        }
        let plain = whole.hasPrefix("<") && whole.hasSuffix(">") ? String(whole.dropFirst().dropLast()) : whole
        return (parse(plain: plain), node.range)
    }

    // MARK: - Searching a file

    public enum SearchResult: Sendable, Equatable {
        case found(Int)
        case failed(String)
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
            return .failed("Coderef links aren't supported")
        }
        if normalized.count >= 2, normalized.hasPrefix("/"), normalized.hasSuffix("/") {
            return .failed("Regexp links aren't supported")
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

/// `org-open-at-point` on a link (C-c C-o).
public struct OpenLinkAtPoint: OrgCommand {
    public init() {}
    public var id: String { "org.link.open" }
    public var title: String { "Open Link" }
    public func applies(in context: EditContext) -> Bool {
        Links.link(at: context.caret, text: context.text, tree: context.tree) != nil
    }
    public func run(in context: EditContext) -> CommandStep {
        guard let found = Links.link(at: context.caret, text: context.text, tree: context.tree) else { return .failed("No link to follow here") }
        return .external(.openLink(found.link))
    }
}
