import Foundation

/// Citations as the `basic` processor (oc-basic.el, Org 9.8.7) exports them: author-year,
/// author, noauthor, text, nocite and numeric styles with the bare and caps variants, from
/// the BibTeX or CSL-JSON files `#+bibliography:` names, and the bibliography
/// `#+print_bibliography:` asks for. Note styles, and `#+cite_export:` processors other than
/// `basic`, leave citations as they are written.
struct CiteProcessor {
    /// What a citation or bibliography entry exports as: text, Org markup (prefixes and
    /// suffixes) and an italic title.
    enum Piece: Equatable {
        case text(String)
        case org(String)
        case italic(String)
    }

    struct Reference {
        var prefix: String?
        var key: String
        var suffix: String?
    }

    struct Citation {
        var text: String
        var style: String?
        var variant: String?
        var prefix: String?
        var suffix: String?
        var references: [Reference]
    }

    typealias Entry = [String: String]

    /// Each citation's export by its text, in document order.
    private var outputs: [String: [[Piece]]] = [:]
    private(set) var bibliography: [[Piece]] = []

    // MARK: - Reading

    static let keyPattern = "@([-.:?!`'/*@+|(){}<>&_^$#%~\\p{L}\\p{N}_]+)"

    /// `org-element-citation-parser`: style, the common prefix and suffix, and references.
    static func parse(_ text: String) -> Citation? {
        guard let m = text.firstMatch(of: #/^\[cite(?:/([^:/\]]*)(?:/([^:\]]*))?)?:(.*)\]$/#.dotMatchesNewlines()) else { return nil }
        let body = String(m.3)
        var parts = body.components(separatedBy: ";")
        let key = try! NSRegularExpression(pattern: keyPattern)
        func hasKey(_ s: String) -> Bool { key.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
        guard let first = parts.firstIndex(where: hasKey), let last = parts.lastIndex(where: hasKey) else { return nil }
        let prefix = first > 0 ? parts[..<first].joined(separator: ";") : nil
        let suffix = last < parts.count - 1 ? parts[(last + 1)...].joined(separator: ";") : nil
        parts = Array(parts[first...last])
        var references: [Reference] = []
        for part in parts {
            let ns = part as NSString
            guard let k = key.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)) else { continue }
            let before = ns.substring(to: k.range.location)
            let after = ns.substring(from: NSMaxRange(k.range))
            references.append(Reference(prefix: before.isEmpty ? nil : before, key: ns.substring(with: k.range(at: 1)), suffix: after.isEmpty ? nil : after))
        }
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        return Citation(text: text, style: m.1.map(String.init).flatMap { $0.isEmpty ? nil : $0 }, variant: m.2.map(String.init),
                        prefix: nonEmpty(prefix), suffix: nonEmpty(suffix), references: references)
    }

    /// `#+cite_export:`: the processor, bibliography style and citation style.
    static func exportSettings(_ text: String) -> (processor: String, bibStyle: String?, citeStyle: String?)? {
        guard let line = text.matches(of: #/(?mi)^[ \t]*#\+cite_export:[ \t]*(.*?)[ \t]*$/#).last else { return nil }
        let words = line.1.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let processor = words.first else { return nil }
        return (processor, words.count > 1 ? words[1] : nil, words.count > 2 ? words[2] : nil)
    }

    static func isNocite(_ citation: Citation, defaultStyle: String?) -> Bool {
        let style = citation.style ?? defaultStyle.map { String($0.split(separator: "/").first ?? "") }
        return style == "nocite" || style == "n"
    }

    /// The text with nocite citations removed, and the blanks before them, as
    /// `org-cite--set-previous-post-blank` leaves it.
    static func removingNocite(_ text: String) -> String {
        guard text.range(of: "[cite", options: .caseInsensitive) != nil else { return text }
        let defaultStyle = exportSettings(text)?.citeStyle
        let regex = try! NSRegularExpression(pattern: "[ \\t]*(\\[cite[/:][^\\]]*\\])")
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            let ns = out as NSString
            guard let citation = parse(ns.substring(with: m.range(at: 1))), isNocite(citation, defaultStyle: defaultStyle) else { continue }
            // Blanks before a citation that starts its line are indentation.
            let lineStart = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
            let blanksOnly = ns.substring(with: NSRange(location: lineStart, length: m.range(at: 1).location - lineStart)).allSatisfy { $0 == " " || $0 == "\t" }
            out = ns.replacingCharacters(in: blanksOnly ? m.range(at: 1) : m.range, with: "")
        }
        return out
    }

    // MARK: - Bibliographies

    /// `org-cite-basic--parse-bibtex`: entries with lower-case field names, `id` and `type`,
    /// values without delimiters, `@string`s expanded, blanks collapsed.
    static func parseBibTeX(_ text: String) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        var strings: [String: String] = [:]
        let chars = Array(text.unicodeScalars)
        var i = 0
        func skipSpace() { while i < chars.count, chars[i].properties.isWhitespace { i += 1 } }
        func word() -> String {
            var out = ""
            while i < chars.count, !chars[i].properties.isWhitespace, !"{}(),=#\"".unicodeScalars.contains(chars[i]) {
                out.unicodeScalars.append(chars[i])
                i += 1
            }
            return out
        }
        func braced() -> String {
            var depth = 0
            var out = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" {
                    depth += 1
                    if depth == 1 { continue }
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                out.unicodeScalars.append(c)
            }
            return out
        }
        func quoted() -> String {
            var depth = 0
            var out = ""
            i += 1
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "\"", depth == 0 { break }
                out.unicodeScalars.append(c)
            }
            return out
        }
        func value() -> String {
            var parts: [String] = []
            while true {
                skipSpace()
                guard i < chars.count else { break }
                if chars[i] == "{" {
                    parts.append(braced())
                } else if chars[i] == "\"" {
                    parts.append(quoted())
                } else {
                    let w = word()
                    parts.append(strings[w.lowercased()] ?? w)
                }
                skipSpace()
                if i < chars.count, chars[i] == "#" { i += 1 } else { break }
            }
            return parts.joined().replacingOccurrences(of: "[ \\t\\n]+", with: " ", options: .regularExpression)
        }
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            i += 1
            let type = word().lowercased()
            skipSpace()
            guard i < chars.count, chars[i] == "{" || chars[i] == "(" else { continue }
            let close: Unicode.Scalar = chars[i] == "{" ? "}" : ")"
            i += 1
            if type == "comment" || type == "preamble" {
                var depth = 1
                while i < chars.count, depth > 0 {
                    if chars[i] == "{" || chars[i] == "(" { depth += 1 } else if chars[i] == "}" || chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                continue
            }
            if type == "string" {
                skipSpace()
                let name = word().lowercased()
                skipSpace()
                if i < chars.count, chars[i] == "=" { i += 1 }
                strings[name] = value()
                skipSpace()
                if i < chars.count, chars[i] == close { i += 1 }
                continue
            }
            skipSpace()
            var key = ""
            while i < chars.count, chars[i] != ",", chars[i] != close, !chars[i].properties.isWhitespace {
                key.unicodeScalars.append(chars[i])
                i += 1
            }
            var entry: Entry = ["id": key, "type": type]
            while i < chars.count {
                skipSpace()
                if i < chars.count, chars[i] == "," { i += 1; skipSpace() }
                guard i < chars.count, chars[i] != close else { i += 1; break }
                let field = word().lowercased()
                skipSpace()
                guard !field.isEmpty, i < chars.count, chars[i] == "=" else { i += 1; continue }
                i += 1
                entry[field] = value()
            }
            if entries[key] == nil { entries[key] = entry }
        }
        return entries
    }

    /// `org-cite-basic--parse-json`, for CSL-JSON: authors as "family given" joined by "and",
    /// and the year from `issued`.
    static func parseJSON(_ data: Data) -> [String: Entry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var entries: [String: Entry] = [:]
        for item in items {
            guard let id = item["id"] as? String else { continue }
            var entry: Entry = [:]
            for (field, value) in item {
                switch field {
                case "author", "editor":
                    let people = (value as? [[String: Any]]) ?? []
                    entry[field] = people.map { ($0["family"] as? String ?? "") + " " + ($0["given"] as? String ?? "") }.joined(separator: " and ")
                case "issued":
                    let issued = value as? [String: Any] ?? [:]
                    if let parts = issued["date-parts"] as? [[Any]], let year = parts.first?.first {
                        entry["year"] = (year as? Int).map(String.init) ?? year as? String
                    } else if let raw = (issued["literal"] ?? issued["raw"]) as? String, let m = raw.firstMatch(of: /[0-9]{4}/) {
                        entry["year"] = String(m.0)
                    }
                default:
                    if let s = value as? String { entry[field] = s } else if let n = value as? NSNumber { entry[field] = n.stringValue }
                }
            }
            entries[id] = entry
        }
        return entries
    }

    // MARK: - Formatting

    private var entries: [String: Entry] = [:]
    private var yearCache: [(author: String?, year: String?, keys: [(key: String, suffix: String)])] = []

    func author(_ key: String) -> String? { entries[key].flatMap { $0["author"] ?? $0["editor"] } }

    /// `org-cite-basic--get-year`: the year, with a letter telling apart works by the same
    /// authors in the same year.
    mutating func year(_ key: String, noSuffix: Bool = false) -> String? {
        let entry = entries[key]
        var year = entry?["year"]
        if year == nil, let date = entry?["date"], let m = date.firstMatch(of: /^([0-9]{4})(?:[^0-9]|$)/) { year = String(m.1) }
        let author = self.author(key)
        guard let index = yearCache.firstIndex(where: { $0.author == author && $0.year == year }) else {
            yearCache.insert((author, year, [(key, "")]), at: 0)
            return year
        }
        let suffix: String
        if let known = yearCache[index].keys.first(where: { $0.key == key }) {
            suffix = known.suffix
        } else {
            suffix = Self.suffix(yearCache[index].keys.count - 1)
            yearCache[index].keys.insert((key, suffix), at: 0)
        }
        return noSuffix ? year : (year ?? "") + suffix
    }

    /// `org-cite-basic--number-to-suffix`.
    static func suffix(_ number: Int) -> String {
        var n = number
        var result: [Int] = []
        while true {
            result.insert(n % 26, at: 0)
            n /= 26
            if n == 0 { break }
            if n < 27 { result.insert(n - 1, at: 0); break }
            if n == 27 { result.insert(contentsOf: [0, 0], at: 0); break }
        }
        return String(String.UnicodeScalarView(result.compactMap { Unicode.Scalar(97 + $0) }))
    }

    /// `org-cite-basic--field-less-p` with the author: `org-string<` ignoring case.
    func authorLess(_ a: String, _ b: String) -> Bool {
        (author(a) ?? "nil").lowercased() < (author(b) ?? "nil").lowercased()
    }

    /// `org-cite-basic-export-citation`. Nil for a style it doesn't do.
    mutating func format(_ citation: Citation, keys: [String], defaultStyle: String?) -> [Piece]? {
        let defaults = defaultStyle.map { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) } ?? []
        let style = citation.style ?? defaults.first
        let variant = citation.variant.flatMap { $0.isEmpty ? nil : $0 } ?? (citation.style == nil && defaults.count > 1 ? defaults[1] : nil)
        let bare = ["bare", "bare-caps", "b", "bc"].contains(variant ?? "")
        let caps = ["caps", "bare-caps", "c", "bc"].contains(variant ?? "")
        func org(_ s: String?) -> [Piece] { s.map { [.org($0)] } ?? [] }
        func authorYear(_ cite: ([Piece], [Piece], [Piece]) -> [Piece], _ ref: (Reference, String, String) -> [Piece]) -> [Piece] {
            var contents: [Piece] = []
            for (n, reference) in citation.references.enumerated() {
                if n > 0 { contents.append(.text(", ")) }
                let author = self.author(reference.key) ?? "??"
                let year = self.year(reference.key) ?? "????"
                contents += ref(reference, author, year)
            }
            return cite(org(citation.prefix), contents, org(citation.suffix))
        }
        func capitalized(_ s: String) -> String { caps ? s.capitalized : s }
        switch style {
        case "author", "a":
            let caps = ["caps", "c"].contains(variant ?? "")
            return authorYear({ $0 + $1 + $2 }) { r, a, _ in org(r.prefix) + [.text(caps ? a.capitalized : a)] + org(r.suffix) }
        case "noauthor", "na":
            return authorYear({ (bare ? [] : [.text("(")]) + $0 + $1 + $2 + (bare ? [] : [.text(")")]) }) { r, _, y in org(r.prefix) + [.text(y)] + org(r.suffix) }
        case "nocite", "n":
            return []
        case "note", "ft":
            return nil
        case "text", "t":
            return authorYear({ $0 + $1 + $2 }) { r, a, y in
                org(r.prefix) + [.text(capitalized(a) + (bare ? " " : " (") + y + (bare ? "" : ")"))] + org(r.suffix)
            }
        case "numeric", "nb":
            let single = citation.references.count == 1 ? citation.references[0] : nil
            let prefix = single.map { $0.prefix } ?? citation.prefix
            let suffix = single.map { $0.suffix } ?? citation.suffix
            let sorted = keys.sorted(by: authorLess)
            let numbers = citation.references.compactMap { r in sorted.firstIndex(of: r.key).map { $0 + 1 } }.sorted()
            return [.text("(")] + org(prefix) + [.text(Self.compact(numbers))] + org(suffix) + [.text(")")]
        default:
            return authorYear({ (bare ? [] : [.text("(")]) + $0 + $1 + $2 + (bare ? [] : [.text(")")]) }) { r, a, y in
                org(r.prefix) + [.text(capitalized(a) + ", " + y)] + org(r.suffix)
            }
        }
    }

    /// `org-cite-basic--citation-numbers`: runs of three or more as `1-3`.
    static func compact(_ numbers: [Int]) -> String {
        guard var last = numbers.first else { return "" }
        var result = [String(last)]
        var rest = Array(numbers.dropFirst())
        while !rest.isEmpty {
            let current = rest.removeFirst()
            let next = rest.first
            if let next, current == last + 1, current == next - 1 {
                if result.last != "-" { result.append("-") }
            } else if result.last == "-" {
                result.append(String(current))
            } else {
                result.append(", \(current)")
            }
            last = current
        }
        return result.joined()
    }

    /// `org-cite-basic--shorten-names`.
    static func shortenNames(_ names: String) -> String {
        names.components(separatedBy: " and ").map { name in
            name.count == 1 ? "" : String(name.components(separatedBy: ", ")[0])
        }.joined(separator: ", ")
    }

    /// `org-cite-basic--print-entry`. `org-cite-basic--print-bibtex-string` strips braces only
    /// in the italic title, the one string inside an object.
    mutating func entry(_ key: String, style: String?, keys: [String]) -> [Piece]? {
        guard let entry = entries[key] else { return nil }
        func clean(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "[{}]", with: "", options: .regularExpression) }
        let author = self.author(key) ?? ""
        let title = entry["title"]
        let from = entry["publisher"] ?? entry["journal"] ?? entry["institution"] ?? entry["school"]
        let fromText = from.map { ", " + $0 } ?? ""
        switch style {
        case "plain":
            let year = self.year(key, noSuffix: true) ?? ""
            return [.text(Self.shortenNames(author) + ". " + (title ?? "") + fromText + ", " + year + ".")]
        case "numeric":
            let n = (keys.sorted(by: authorLess).firstIndex(of: key) ?? 0) + 1
            let year = self.year(key, noSuffix: true) ?? ""
            return [.text("[\(n)] " + author + ", "), .italic(clean(title)), .text(fromText + ", " + year + ".")]
        default:
            let year = self.year(key) ?? ""
            return [.text(author + " (" + year + "). "), .italic(clean(title)), .text(fromText + ".")]
        }
    }

    // MARK: - Building

    /// The citations of `text` (as written, nocite citations included) worked out in document
    /// order, then the bibliography; nil when the export leaves citations alone.
    init?(text: String, directory: URL?) {
        guard text.range(of: "[cite", options: .caseInsensitive) != nil else { return nil }
        let settings = Self.exportSettings(text)
        if let settings, settings.processor != "basic" { return nil }
        // Each `#+bibliography:` names one file.
        for m in text.matches(of: #/(?mi)^[ \t]*#\+bibliography:[ \t]*(.*?)[ \t]*$/#) {
            for name in [String(m.1)].map({ $0.count > 1 && $0.hasPrefix("\"") && $0.hasSuffix("\"") ? String($0.dropFirst().dropLast()) : $0 }) where !name.isEmpty {
                let path = (name as NSString).expandingTildeInPath
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (directory ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url) else { continue }
                let parsed = url.pathExtension.lowercased() == "json" ? Self.parseJSON(data) : Self.parseBibTeX(String(decoding: data, as: UTF8.self))
                for (key, entry) in parsed where entries[key] == nil { entries[key] = entry }
            }
        }
        let tree = OrgParser.parse(text)
        let citations = tree.root.descendants().filter { $0.kind == .citation }.compactMap { Self.parse($0.text) }
        var keys: [String] = []
        for citation in citations { for r in citation.references where !keys.contains(r.key) { keys.append(r.key) } }
        for citation in citations {
            guard let pieces = format(citation, keys: keys, defaultStyle: settings?.citeStyle) else { continue }
            outputs[citation.text, default: []].append(pieces)
        }
        let style = settings?.bibStyle
        // `sort` is stable: keys with the same author keep their order.
        bibliography = keys.enumerated().sorted { a, b in
            authorLess(a.element, b.element) || (!authorLess(b.element, a.element) && a.offset < b.offset)
        }.compactMap { entry($0.element, style: style, keys: keys) }
    }

    /// The export of the next citation written as `text`; nil leaves it as written.
    mutating func next(_ text: String) -> [Piece]? {
        guard var queue = outputs[text], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        outputs[text] = queue
        return first
    }
}
