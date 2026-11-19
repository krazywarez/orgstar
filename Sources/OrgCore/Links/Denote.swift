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
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][c.weekday! - 1]
        let stamp = String(format: "[%04d-%02d-%02d %@ %02d:%02d]", c.year!, c.month!, c.day!, day, c.hour!, c.minute!)
        let tags = keywords.isEmpty ? "" : ":" + keywords.joined(separator: ":") + ":"
        return "#+title:      \(title)\n#+date:       \(stamp)\n#+filetags:   \(tags)\n#+identifier: \(identifier)\n"
            + (signature.isEmpty ? "" : "#+signature:  \(signature)\n") + "\n"
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
