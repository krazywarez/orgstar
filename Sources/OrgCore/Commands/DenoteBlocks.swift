import Foundation

// denote-org 0.3's dynamic blocks: `denote-links`, `denote-missing-links`, `denote-backlinks`,
// `denote-files`, `denote-files-as-headings` and `denote-sequence`, over the files in `denote-directory`
// (`EditingOptions.denoteDirectories`), read from disk. `:excluded-dirs-regexp`,
// `:this-heading-only` and `rx` forms for regexps aren't supported.

enum DenoteBlocks {
    static let names: Set<String> = ["denote-links", "denote-missing-links", "denote-backlinks", "denote-files", "denote-files-as-headings", "denote-sequence"]

    /// `denote--directory-get-files`: the files under `directories` whose names have an
    /// identifier, without hidden ones or backups, as `directory-files-recursively` lists them:
    /// a folder's subfolders' files before its own.
    static func files(in directories: [String]) -> [(path: String, relative: String)] {
        func walk(_ folder: String, _ relative: String) -> [(String, String)] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            var inner: [(String, String)] = [], own: [(String, String)] = []
            for name in names {
                let path = (folder as NSString).appendingPathComponent(name), rel = relative.isEmpty ? name : relative + "/" + name
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    inner += walk(path, rel)
                } else if Denote.identifier(ofFile: name) != nil, !name.hasSuffix("~") {
                    own.append((path, rel))
                }
            }
            return inner + own
        }
        return directories.flatMap { walk($0, "") }
    }

    static func regex(_ regexp: String?) throws -> NSRegularExpression? {
        guard let regexp, !regexp.isEmpty else { return nil }
        do { return try NSRegularExpression(pattern: EmacsRegex.translate(regexp)) } catch { throw EmacsBuffer.UserError(message: "Invalid regexp \(regexp)") }
    }

    static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        regex?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// `denote-retrieve-title-or-filename`: an Org file's `#+title`, else the file name's.
    static func title(_ path: String) -> String {
        if (path as NSString).pathExtension == "org", let title = Denote.frontMatter(of: read(path)).title { return title }
        return Denote.name(ofFile: path).title ?? ""
    }

    /// `denote-link-description-with-signature-and-title`.
    static func description(_ path: String) -> String {
        let signature = Denote.name(ofFile: path).signature, title = title(path)
        switch (signature, title.isEmpty) {
        case (let signature?, false): return signature + "  " + title
        case (nil, false): return title
        case (let signature?, true): return signature
        default: return ""
        }
    }

    /// `denote-link--prepare-links` as a list, unsorted.
    static func links(_ paths: [String], idOnly: Bool, includeDate: Bool) -> String {
        paths.map { path in
            let id = Denote.identifier(ofFile: path) ?? ""
            var description = description(path)
            if includeDate {
                let date = id.count >= 8 ? "\(id.prefix(4))-\(id.dropFirst(4).prefix(2))-\(id.dropFirst(6).prefix(2))" : id
                description = "\(title(path)) (\(date))"
            }
            return "- " + (idOnly || description.isEmpty ? "[[denote:\(id)]]" : "[[denote:\(id)][\(description)]]") + "\n"
        }.joined()
    }

    /// `denote-sort-files`: by a file name component (those without it last), by last
    /// modified, or kept in identifier order; then reversed with `reverse`.
    static func sorted(_ paths: [String], by component: String?, reverse: Bool) -> [String] {
        var result = paths
        func value(_ path: String) -> String? {
            let name = Denote.name(ofFile: path)
            switch component {
            case "identifier": return name.identifier
            case "title": return name.title
            case "keywords": return name.keywords.isEmpty ? nil : name.keywords.joined(separator: "_")
            case "signature": return name.signature
            default: return nil
            }
        }
        switch component {
        case "identifier", "title", "keywords", "signature":
            result = paths.enumerated().sorted { a, b in
                let one = value(a.element), two = value(b.element)
                switch (one, two) {
                case (nil, _): return a.offset < b.offset && two == nil
                case (_, nil): return true
                case (let one?, let two?): return one == two ? a.offset < b.offset : one < two
                }
            }.map(\.element)
        case "last-modified":
            func modified(_ path: String) -> Date { (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast }
            result = paths.enumerated().sorted { a, b in
                let one = modified(a.element), two = modified(b.element)
                return one == two ? a.offset < b.offset : one > two
            }.map(\.element)
        case "random": result.shuffle()
        default: break
        }
        return reverse ? result.reversed() : result
    }

    /// `denote-org-escape-code-in-region`: `#+` at a line's start behind a zero-width space.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^([ \\t]*)#\\+", with: "$1\u{200B}#+", options: .regularExpression)
    }
}

extension EmacsBuffer {
    /// A denote-org block's new contents.
    func denoteBlock(_ name: String, paramText: String) throws -> String {
        let params = try ClockTable.Params(paramText, defaults: [:])
        if params.values[":this-heading-only"].map({ $0.symbol != "nil" }) == true {
            throw UserError(message: ":this-heading-only isn't supported")
        }
        let all = DenoteBlocks.files(in: options.denoteDirectories ?? [])
        let current = options.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let rx = try DenoteBlocks.regex(params.symbol(":regexp")), notRx = try DenoteBlocks.regex(params.symbol(":not-regexp"))
        let sort = params.symbol(":sort-by-component").flatMap { $0 == "nil" ? nil : $0 }, reverse = params.flag(":reverse-sort")
        /// `denote-directory-files` with `:omit-current`, then sorted.
        func files(_ omitCurrent: Bool = true) -> [String] {
            let found = all.filter { file in
                !(omitCurrent && file.path == current) && (rx == nil || DenoteBlocks.matches(rx, file.relative)) && !DenoteBlocks.matches(notRx, file.path)
            }.map(\.path)
            return DenoteBlocks.sorted(found, by: sort, reverse: reverse)
        }
        let blockName = params.symbol(":block-name").map { "#+name: \($0)\n" } ?? ""
        let idOnly = params.flag(":id-only"), includeDate = params.flag(":include-date")
        var out: String
        switch name {
        case "denote-links":
            out = blockName + DenoteBlocks.links(files(), idOnly: idOnly, includeDate: includeDate)
        case "denote-missing-links":
            // The identifiers this file links to, as `denote-get-links` collects them.
            let linked = Set(string.matches(of: /\[\[denote:(\d{8}T\d{6})/).map { String($0.1) })
            out = blockName + DenoteBlocks.links(files().filter { !linked.contains(Denote.identifier(ofFile: $0) ?? "") }, idOnly: idOnly, includeDate: includeDate)
        case "denote-backlinks":
            guard let current, let id = Denote.identifier(ofFile: current) else { throw UserError(message: "The file does not have a Denote identifier") }
            // As the xref search finds them: by path.
            let linking = all.map(\.path).sorted().filter { path in
                let text = path == current ? string : DenoteBlocks.read(path)
                return text.contains("[denote:\(id)]") || text.contains("[denote:\(id)::")
            }
            out = DenoteBlocks.links(DenoteBlocks.sorted(linking.filter { !DenoteBlocks.matches(notRx, $0) }, by: sort, reverse: reverse), idOnly: idOnly, includeDate: includeDate)
        case "denote-files":
            guard rx != nil else { out = blockName; break }
            let separator: String
            switch params.values[":file-separator"] {
            case nil, .symbol("nil")?: separator = ""
            case .string(let s)?: separator = s
            default: separator = "\n\n" + String(repeating: "-", count: 50) + "\n\n\n"
            }
            let addLinks = params.values[":add-links"].flatMap { $0.symbol == "nil" ? nil : $0 }
            let noFrontMatter = params.values[":no-front-matter"].flatMap { $0.symbol == "nil" ? nil : $0 }
            out = blockName + files().map { path in
                var text = DenoteBlocks.read(path)
                if let noFrontMatter {
                    var lines = text.components(separatedBy: "\n")
                    if let count = noFrontMatter.integer {
                        lines.removeFirst(min(count, lines.count))
                    } else if let blank = lines.firstIndex(of: "") {
                        lines.removeFirst(blank + 1)
                    }
                    text = lines.joined(separator: "\n")
                }
                if let addLinks {
                    let id = Denote.identifier(ofFile: path) ?? "", description = DenoteBlocks.description(path)
                    let link = addLinks.symbol == "id-only" || description.isEmpty ? "[[denote:\(id)]]" : "[[denote:\(id)][\(description)]]"
                    text = "- \(link)\n\n" + text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : "  " + $0 }.joined(separator: "\n")
                }
                return DenoteBlocks.escaped(text)
            }.joined(separator: separator)
        case "denote-sequence":
            // A note and its descendants down to `:depth` levels, or with `:sequence` "" every
            // note with a sequence, indented under their parents.
            let model = DenoteSequence(scheme: options.denoteSequenceScheme)
            let numbered = DenoteSequence.files(all.map(\.path))
            let sequence = params.symbol(":sequence") ?? ""
            var family = numbered
            if sequence != "" && sequence != ".+" {
                let children = (try? model.relatives(of: sequence, .allChildren, in: numbered)) ?? []
                let parent = DenoteSequence.path(of: sequence, in: numbered)
                family = numbered.filter { $0.path == parent || children.contains($0.path) }
            }
            let sorted = family.indices.sorted {
                let a = model.sortKey(family[$0].sequence), b = model.sortKey(family[$1].sequence)
                return a == b ? $0 < $1 : a < b
            }.map { family[$0] }
            guard let root = sorted.first, let rootDepth = try? model.depth(root.sequence) else { out = ""; break }
            let maxDepth = params.int(":depth").map { rootDepth + $0 - 1 } ?? Int.max
            out = blockName + sorted.compactMap { file -> String? in
                guard let depth = try? model.depth(file.sequence), depth <= maxDepth else { return nil }
                let id = Denote.identifier(ofFile: file.path) ?? ""
                return String(repeating: " ", count: 2 * (depth - rootDepth)) + "- [[denote:\(id)][\(file.sequence): \(DenoteBlocks.description(file.path))]]\n"
            }.joined()
        default: // denote-files-as-headings
            guard rx != nil else { out = blockName; break }
            let addLinks = params.flag(":add-links"), excludeTags = params.flag(":exclude-tags")
            out = blockName + files().filter { ($0 as NSString).pathExtension == "org" }.map { path in
                var lines = DenoteBlocks.read(path).components(separatedBy: "\n")
                func value(_ key: String) -> String? {
                    lines.first { $0.lowercased().hasPrefix("#+\(key):") }.map { String($0.dropFirst(key.count + 3)).trimmingCharacters(in: .whitespaces) }
                }
                let title = value("title"), tags = excludeTags ? "" : value("filetags")
                if let blank = lines.firstIndex(of: ""), blank + 1 < lines.count { lines.removeFirst(blank + 1) }
                var body = lines.joined(separator: "\n").replacingOccurrences(of: "(?m)^(\\*+) ", with: "*$1 ", options: .regularExpression)
                if let title, let tags {
                    let id = Denote.identifier(ofFile: path) ?? ""
                    var heading = LineBuffer(addLinks ? "* [[denote:\(id)][\(title)]] \(tags)" : "* \(title) \(tags)", caret: nil)
                    if !excludeTags { OrgCore.alignTags(&heading, options: options) }
                    body = heading.string + "\n\n" + body
                }
                return DenoteBlocks.escaped(body)
            }.joined()
        }
        // `join-line` at the end: the last newline goes.
        if out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
