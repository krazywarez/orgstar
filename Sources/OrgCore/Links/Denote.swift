import Foundation

/// Denote's file naming, as `denote-retrieve-filename-identifier` reads it: the identifier
/// starts the name (`20261119T120000--title__keywords.org`), or follows `@@` when
/// `denote-file-name-components-order` puts it elsewhere.
public enum Denote {
    /// The identifier in the file name at `path`, or nil when it has none.
    public static func identifier(ofFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let match = name.firstMatch(of: /^(\d{8}T\d{6})(?:--|__|==|@@|\.|$)/) { return String(match.1) }
        if let match = name.firstMatch(of: /@@([^.]+?)(?=--|__|==|@@|\.|$)/) { return String(match.1) }
        return nil
    }

    /// The files under `directories` whose names have an identifier, as Denote lists them.
    public static func files(in directories: [String]) -> [String] { DenoteBlocks.files(in: directories).map(\.path) }

    /// A query link's regexp, `denote:query-contents:REGEXP` (contents) or
    /// `denote:query-filenames:REGEXP`; nil for a link to an identifier.
    public static func query(_ path: String) -> (contents: Bool, regexp: String)? {
        if path.hasPrefix("query-contents:") { return (true, String(path.dropFirst("query-contents:".count))) }
        if path.hasPrefix("query-filenames:") { return (false, String(path.dropFirst("query-filenames:".count))) }
        return nil
    }

    /// A `denote:` link's path split at `::` into the identifier and the search.
    public static func split(_ path: String) -> (identifier: String, search: String?) {
        guard let range = path.range(of: "::") else { return (path, nil) }
        return (String(path[..<range.lowerBound]), String(path[range.upperBound...]))
    }

    /// The file `denote-get-path-by-id` finds: the one whose name has `identifier`, an Org
    /// file before any other.
    public static func file(withIdentifier identifier: String, in paths: [String]) -> String? {
        let matches = paths.filter { Self.identifier(ofFile: $0) == identifier }
        return matches.first { ($0 as NSString).pathExtension == "org" } ?? matches.first
    }

    // MARK: - Naming new files

    /// `denote-excluded-punctuation-regexp`.
    static let punctuation = Set("[]{}!@#$%^&*()+'\"?,.|;:~`‘’“”=/")

    /// `denote-sluggify-title`: without punctuation, spaces and underscores as one `-`, none
    /// at either end, lower case.
    public static func slug(_ title: String) -> String {
        var out = ""
        for character in title.lowercased() where !punctuation.contains(character) {
            if character.isWhitespace || character == "_" || character == "-" {
                if !out.isEmpty, out.last != "-" { out.append("-") }
            } else {
                out.append(character)
            }
        }
        while out.last == "-" { out.removeLast() }
        return out
    }

    /// `denote-sluggify-keyword`: one word, lower case, without punctuation or spaces.
    public static func keyword(_ word: String) -> String {
        String(word.lowercased().filter { !punctuation.contains($0) && !$0.isWhitespace && $0 != "_" && $0 != "-" })
    }

    /// `denote-sluggify-signature`: like a title, with `=` between words.
    public static func signature(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() where character == "=" || !punctuation.contains(character) && character != "-" {
            if character.isWhitespace || character == "_" || character == "=" {
                if !out.isEmpty, out.last != "=" { out.append("=") }
            } else {
                out.append(character)
            }
        }
        while out.last == "=" { out.removeLast() }
        return out
    }

    /// Keywords as `denote-keywords-sort` keeps them: sluggified, without empties or repeats,
    /// sorted.
    public static func keywords(_ words: [String]) -> [String] {
        Array(Set(words.map(keyword).filter { !$0.isEmpty })).sorted()
    }

    /// `%Y%m%dT%H%M%S` in `calendar`'s time zone.
    public static func identifier(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `denote-format-file-name` in the default component order: identifier, signature,
    /// title, keywords.
    public static func fileName(identifier: String, signature: String? = nil, title: String, keywords: [String], extension ext: String = "org") -> String {
        var name = identifier
        if let signature, !signature.isEmpty { name += "==" + signature }
        let slug = slug(title)
        if !slug.isEmpty { name += "--" + slug }
        if !keywords.isEmpty { name += "__" + keywords.joined(separator: "_") }
        return name + "." + ext
    }

    /// `denote-org-front-matter`, dated as an inactive Org timestamp. The signature line is
    /// left out when there's none.
    public static func frontMatter(title: String, date: Date, keywords: [String], identifier: String, signature: String = "", calendar: Calendar = .current) -> String {
        lines(title: title, date: date, keywords: keywords, identifier: identifier, signature: signature, calendar: calendar)
            .compactMap(\.line).map { $0 + "\n" }.joined() + "\n"
    }

    /// The front matter's lines by key, in its order; nil for a signature line there isn't,
    /// and for the date when `date` is nil.
    static func lines(title: String, date: Date?, keywords: [String], identifier: String, signature: String, calendar: Calendar) -> [(key: String, line: String?)] {
        let stamp = date.map { date in
            let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
            let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][c.weekday! - 1]
            return String(format: "[%04d-%02d-%02d %@ %02d:%02d]", c.year!, c.month!, c.day!, day, c.hour!, c.minute!)
        }
        let tags = keywords.isEmpty ? "" : ":" + keywords.joined(separator: ":") + ":"
        return [("title", "#+title:      \(title)"), ("date", stamp.map { "#+date:       \($0)" }), ("filetags", "#+filetags:   \(tags)"),
                ("identifier", "#+identifier: \(identifier)"), ("signature", signature.isEmpty ? nil : "#+signature:  \(signature)")]
    }

    /// `denote-rewrite-front-matter`: `text` with its front matter lines set to these values,
    /// a missing one added after the one before it, an empty signature's removed, other lines
    /// kept. A nil `date` keeps the date line. Without front matter, `denote-prepend-front-matter`:
    /// all of it before the text, dated `date` or `now`.
    public static func rewritingFrontMatter(
        _ text: String, title: String, keywords: [String], signature: String, date: Date?, identifier: String, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        let wanted = Self.lines(title: title, date: date, keywords: keywords, identifier: identifier, signature: signature, calendar: calendar)
        func index(_ key: String) -> Int? {
            lines.prefix(40).firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("#+" + key + ":") }
        }
        guard wanted.contains(where: { index($0.key) != nil }) else {
            return frontMatter(title: title, date: date ?? now, keywords: keywords, identifier: identifier, signature: signature, calendar: calendar) + text
        }
        for (position, item) in wanted.enumerated() {
            if let at = index(item.key) {
                if let line = item.line { lines[at] = line } else if item.key == "signature" { lines.remove(at: at) }
            } else if let line = item.line {
                let before = wanted[..<position].reversed().compactMap { index($0.key) }.first
                let after = wanted[(position + 1)...].compactMap { index($0.key) }.first
                lines.insert(line, at: before.map { $0 + 1 } ?? after ?? 0)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading names and front matter

    /// The parts of a Denote file name, in any component order.
    public struct Name: Sendable, Equatable {
        public var identifier: String?
        public var signature: String?
        public var title: String?
        public var keywords: [String]
        public var ext: String
    }

    public static func name(ofFile path: String) -> Name {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let stem = ext.isEmpty ? file : String(file.dropLast(ext.count + 1))
        var name = Name(identifier: identifier(ofFile: file), keywords: [], ext: ext)
        for match in stem.matches(of: /(--|__|==)(.+?)(?=--|__|==|@@|$)/) {
            let value = String(match.2)
            switch match.1 {
            case "--": name.title = value
            case "__": name.keywords = value.split(separator: "_").map(String.init)
            default: name.signature = value
            }
        }
        return name
    }

    /// The `#+title`, `#+filetags`, `#+identifier` and `#+signature` of a file's front matter.
    public static func frontMatter(of text: String) -> (title: String?, keywords: [String]?, identifier: String?, signature: String?) {
        func value(_ key: String) -> String? {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("#+" + key + ":") else { continue }
                return trimmed.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        let keywords = value("filetags").map { $0.split(separator: ":").map(String.init).filter { !$0.isEmpty } }
        return (value("title"), keywords, value("identifier")?.nonEmptyOrNil, value("signature"))
    }

    /// The front matter's `#+date:`, an Org timestamp, in `calendar`'s time zone.
    public static func date(of text: String, calendar: Calendar = .current) -> Date? {
        guard let match = text.firstMatch(of: /(?im)^[ \t]*#\+date:[ \t]*[\[<](\d{4})-(\d{2})-(\d{2})(?:[^\]>\d]*(\d{1,2}):(\d{2}))?/) else { return nil }
        return calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3),
                                                  hour: match.4.flatMap { Int($0) } ?? 0, minute: match.5.flatMap { Int($0) } ?? 0))
    }

    /// `denote-rename-file-using-front-matter`: the name the file at `path` takes from its
    /// front matter's title, keywords and signature, each empty when its line is missing. Nil
    /// when the file has no front matter, or no identifier in it or its name.
    public static func renamed(_ path: String, text: String) -> String? {
        let current = name(ofFile: path)
        let front = frontMatter(of: text)
        guard front.title != nil || front.keywords != nil || front.identifier != nil || front.signature != nil,
              let identifier = front.identifier ?? current.identifier else { return nil }
        // In the front matter's order: Denote sorts keywords only as it prompts for them.
        var seen = Set<String>()
        let keywords = (front.keywords ?? []).map(keyword).filter { !$0.isEmpty && seen.insert($0).inserted }
        let file = fileName(identifier: identifier, signature: front.signature.map(signature), title: front.title ?? "", keywords: keywords,
                            extension: current.ext.isEmpty ? "org" : current.ext)
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(file)
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
