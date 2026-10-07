import Foundation

/// An entry of `org-stored-links`.
public struct StoredLink: Sendable, Equatable, Codable {
    public let link: String
    public let description: String?

    public init(link: String, description: String?) {
        self.link = link
        self.description = description
    }
}

extension Links {
    /// `org-store-link` in an org file, with `org-link-context-for-files` t: a file link to
    /// `path` with a search string for the target, named element, heading or line at the
    /// caret (the selection when there is one). `path` is as `abbreviate-file-name` gives it.
    public static func store(in context: EditContext, path: String) -> StoredLink {
        let link = "file:" + path
        guard let target = targetAtCaret(context) else {
            guard let (search, description, _) = preciseTarget(context) else { return StoredLink(link: link, description: nil) }
            return StoredLink(link: link + "::" + search, description: description.map(displayFormat))
        }
        return StoredLink(link: link + "::" + target, description: nil)
    }

    /// `org-id-store-link` after `org-id-get-create`: an `id:` link to the entry at the caret,
    /// described by its title, or before the first heading by `#+TITLE` or the file name.
    public static func storeID(in context: EditContext, fileName: String) -> StoredLink? {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        buffer.backToHeadingOrPointMin()
        guard let id = buffer.entryID() else { return nil }
        let link = "id:" + id
        // With `org-id-link-use-context`, a target after the entry's start narrows the link.
        if let (search, description, position) = preciseTarget(context), position > buffer.point {
            return StoredLink(link: link + "::" + search, description: description)
        }
        if buffer.beforeFirstHeading { return StoredLink(link: link, description: buffer.keyword("TITLE") ?? fileName) }
        guard let match = buffer.lookingAt(buffer.complexHeadingPattern), let all = match[0] else { return StoredLink(link: link, description: link) }
        let title = match[4] ?? all
        return StoredLink(link: link, description: buffer.substring(title.lowerBound, title.upperBound))
    }

    /// A `<<target>>` on the caret's line that the caret touches, as `org-in-regexp` finds it.
    static func targetAtCaret(_ context: EditContext) -> String? {
        let ns = context.text as NSString
        let line = ns.lineRange(for: NSRange(location: min(context.caret, ns.length), length: 0))
        var end = NSMaxRange(line)
        if end > line.location, ns.character(at: end - 1) == 10 { end -= 1 }
        let regex = try! NSRegularExpression(pattern: "[^<]<<([^<>]+)>>[^>]")
        var from = line.location
        while from < end, let m = regex.firstMatch(in: context.text, range: NSRange(from..<end)), m.range.location <= context.caret {
            if NSMaxRange(m.range) >= context.caret { return ns.substring(with: m.range(at: 1)) }
            from = m.range.location + 1
        }
        return nil
    }

    /// `org-link-precise-link-target`: the search string and description for the caret, and
    /// where the search matches.
    static func preciseTarget(_ context: EditContext) -> (String, String?, Int)? {
        let ns = context.text as NSString
        let result: (String, String?, Int)
        if let range = context.selection.first, !range.isEmpty {
            result = (normalize(ns.substring(with: NSRange(range)), context: true), nil, range.lowerBound)
        } else if let (name, start) = namedElement(at: context.caret, in: context.tree) {
            result = (name, name, start)
        } else if let heading = DocumentModel(tree: context.tree).headings.last(where: { $0.headingRange.lowerBound <= context.caret }) {
            let title = normalizedTitle(heading.title)
            let customID = heading.properties.last { $0.key.uppercased() == "CUSTOM_ID" }?.value
            result = (customID.map { "#" + $0 } ?? "*" + title, title, heading.headingRange.lowerBound)
        } else {
            let line = ns.lineRange(for: NSRange(location: min(context.caret, ns.length), length: 0))
            result = (normalize(ns.substring(with: line).trimmingCharacters(in: .newlines), context: true), nil, line.location)
        }
        return result.0.contains(where: { !$0.isWhitespace }) ? result : nil
    }

    /// The `#+NAME` of the element at `offset`, and where the element starts (its first
    /// affiliated keyword).
    static func namedElement(at offset: Int, in tree: OrgTree) -> (String, Int)? {
        let containers: Set<SyntaxKind> = [.document, .zerothSection, .section, .plainList, .item, .drawer, .footnoteDefinition]
        var node = tree.root
        while true {
            let children = node.children
            guard let index = children.firstIndex(where: { $0.range.contains(offset) || ($0.range.upperBound == offset && offset == tree.root.range.upperBound) }) else { return nil }
            var element = index
            while element < children.count, children[element].kind == .affiliatedKeyword { element += 1 }
            if element > index, element == children.count || children[element - 1].range.upperBound != children[element].range.lowerBound { return nil }
            if element == index, containers.contains(children[index].kind) {
                node = children[index]
                continue
            }
            var first = element
            while first > 0, children[first - 1].kind == .affiliatedKeyword, children[first - 1].range.upperBound == children[first].range.lowerBound { first -= 1 }
            for keyword in children[first..<element].reversed() {
                if let range = keyword.text.range(of: "^[ \\t]*#\\+NAME:[ \\t]*(.*?)[ \\t]*\\n?$", options: [.regularExpression, .caseInsensitive]) {
                    let value = keyword.text[range].replacingOccurrences(of: "^[ \\t]*#\\+[Nn][Aa][Mm][Ee]:[ \\t]*|[ \\t]*\\n?$", with: "", options: .regularExpression)
                    if !value.isEmpty { return (value, children[first].range.lowerBound) }
                }
            }
            return nil
        }
    }

    /// `org-link--normalize-string`: statistics cookies and runs of blanks become one space;
    /// with `context`, enclosing parentheses and leading `#` and `*` go too.
    static func normalize(_ s: String, context: Bool) -> String {
        var t = s.replacingOccurrences(of: "\\[[0-9]*(%|/[0-9]*)\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context else { return t }
        while true {
            if t.hasPrefix("("), t.hasSuffix(")"), t.count >= 2 {
                t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let range = t.range(of: "^[#*]+[ \\t]*", options: .regularExpression) {
                t.removeSubrange(range)
            } else {
                return t
            }
        }
    }

    /// `org-link-display-format`: bracket links become their descriptions.
    static func displayFormat(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: "\\[\\[((?:[^\\]\\[\\\\]|\\\\(?:\\\\\\\\)*[\\]\\[]|\\\\+[^\\]\\[])+)\\](?:\\[((?:.|\\n)+?)\\])?\\]")
        let ns = s as NSString
        var out = s
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let group = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            out = (out as NSString).replacingCharacters(in: m.range, with: ns.substring(with: group))
        }
        return out
    }

    /// `org-link-escape`.
    static func escape(_ link: String) -> String {
        let regex = try! NSRegularExpression(pattern: "(\\\\*)([\\[\\]]|$)")
        let ns = link as NSString
        var out = link
        for m in regex.matches(in: link, range: NSRange(location: 0, length: ns.length)).reversed() {
            let run = ns.substring(with: m.range(at: 1))
            out = (out as NSString).replacingCharacters(in: m.range(at: 1), with: run + run + (m.range(at: 2).length > 0 ? "\\" : ""))
        }
        return out
    }

    /// `org-link-make-string`.
    static func makeString(_ link: String, _ description: String?) -> String {
        let zeroWidthSpace = "\u{200B}"
        let description = description.flatMap { d -> String? in
            guard d.contains(where: { !$0.isWhitespace }) else { return nil }
            return d.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\]$", with: "]" + zeroWidthSpace, options: .regularExpression)
                .replacingOccurrences(of: "\\]\\]", with: "]" + zeroWidthSpace + "]", options: .regularExpression)
        }
        return "[[" + escape(link) + "]" + (description.map { "[" + $0 + "]" } ?? "") + "]"
    }

    /// `expand-file-name` of `path` in `directory`, with `~` for `home`.
    static func expand(_ path: String, directory: String?, home: String) -> String {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
        if !p.hasPrefix("/"), let directory { p = (directory as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    /// `abbreviate-file-name`: `~` for the home folder.
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `org-link-make-string-for-buffer` before its description prompt: the link a buffer
    /// visiting `file` gets, and the description to offer.
    static func forBuffer(_ link: String, description: String?, file: String?, home: String) -> (link: String, description: String?) {
        var link = link
        var description = description
        if link.hasPrefix("<"), link.hasSuffix(">"), typesPattern.firstMatch(in: String(link.dropFirst()), range: NSRange(location: 0, length: (link as NSString).length - 1)) != nil {
            link = String(link.dropFirst().dropLast())
        }
        let directory = file.map { ($0 as NSString).deletingLastPathComponent }
        if let file, let range = link.range(of: "^file:(.+?)::", options: .regularExpression) {
            let path = String(link[range].dropFirst(5).dropLast(2))
            if expand(path, directory: directory, home: home) == expand(file, directory: nil, home: home) {
                link = String(link[range.upperBound...])
            }
        }
        if let prefix = ["file:", "docview:"].first(where: link.hasPrefix) {
            var rest = String(link.dropFirst(prefix.count))
            var search: String?
            if let range = rest.range(of: "::(.*)$", options: .regularExpression) {
                search = String(rest[range].dropFirst(2))
                rest.removeSubrange(range)
            }
            let original = rest.contains(where: { !$0.isWhitespace }) ? rest : file ?? ""
            let expanded = expand(original, directory: directory, home: home)
            let base = directory.map { expand($0, directory: nil, home: home) + "/" }
            let path = base.map(expanded.hasPrefix) == true ? String(expanded.dropFirst(base!.count)) : abbreviate(expanded, home: home)
            link = prefix + path + (search.map { "::" + $0 } ?? "")
            if description == original { description = path }
        }
        return (link, description)
    }
}

/// `org-insert-link` (C-c C-l): asks for a link, offering stored links and link types, and a
/// description; on a link, edits it.
public struct InsertLink: OrgCommand {
    /// `org-stored-links`, most recent first.
    public let stored: [StoredLink]
    /// The file the buffer visits.
    public let file: String?
    public let home: String

    public init(stored: [StoredLink] = [], file: String? = nil, home: String = NSHomeDirectory()) {
        self.stored = stored
        self.file = file
        self.home = home
    }

    public var id: String { "org.link.insert" }
    public var title: String { "Insert Link" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let ns = context.text as NSString
        var remove: Range<Int>?
        var description: String?
        if let range = context.selection.first, !range.isEmpty {
            remove = range
            description = ns.substring(with: NSRange(range))
        }
        var link: String
        if let found = Links.link(at: context.caret, text: context.text, tree: context.tree) {
            let whole = ns.substring(with: NSRange(found.range))
            remove = found.range
            let initial: String
            if whole.hasPrefix("[[") {
                let inside = whole.dropFirst(2).dropLast(1)
                let split = inside.range(of: "][")
                initial = Links.unescape(String(split.map { inside[..<$0.lowerBound] } ?? inside.dropLast()))
                description = split.map { String(inside[$0.upperBound...].dropLast()) }
            } else {
                initial = whole.hasPrefix("<") && whole.hasSuffix(">") ? String(whole.dropFirst().dropLast()) : whole
            }
            guard let answer = context.answers["link"] else { return .prompt(Prompt(key: "link", message: "Link:", initial: initial)) }
            link = answer
        } else {
            let prefixes = Array(Links.abbreviations(in: context.tree.settings.setupKeywords + context.text).keys).sorted() + Links.types
            guard let answer = context.answers["link"] else {
                let message = stored.first.map { "Insert link (default \($0.link)):" } ?? "Insert link:"
                let choices = stored.map(\.link) + stored.compactMap(\.description) + prefixes.map { $0 + ":" }
                return .prompt(Prompt(key: "link", message: message, choices: choices, requireMatch: false))
            }
            link = answer.isEmpty ? stored.first?.link ?? "" : answer
            guard link.contains(where: { !$0.isWhitespace }) else { return .failed("No link selected") }
            if let byDescription = stored.last(where: { $0.description == link }) { link = byDescription.link }
            let type = link.hasSuffix(":") ? String(link.dropLast()) : link
            if prefixes.contains(type) {
                guard let special = context.answers["special"] else {
                    return .prompt(Prompt(key: "special", message: "Link (no completion support):", initial: type + ":"))
                }
                link = special
            }
            description = description ?? stored.first { $0.link == link }?.description
        }
        let used = link
        let prepared = Links.forBuffer(link, description: description, file: file, home: home)
        guard let typed = context.answers["description"] else {
            return .prompt(Prompt(key: "description", message: "Description:", initial: prepared.description ?? ""))
        }
        let text = Links.makeString(prepared.link, typed)
        let at = remove ?? context.caret..<context.caret
        let end = at.lowerBound + (text as NSString).length
        let effects: [Effect] = stored.contains { $0.link == used } ? [.storedLinkUsed(used)] : []
        return .commit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: at, replacement: text)], selection: [end..<end], effects: effects))
    }
}

/// `org-id-get-create`: gives the entry an `ID` property unless it has one.
public struct CreateID: OrgCommand {
    let newID: @Sendable () -> String

    public init(newID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.newID = newID
    }

    public var id: String { "org.id.create" }
    public var title: String { "Create ID" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            buffer.saveExcursion {
                buffer.backToHeadingOrPointMin()
                if buffer.entryID() == nil { buffer.entryPut("ID", newID()) }
            }
        }
    }
}

extension EmacsBuffer {
    /// The entry's own `ID` when it has non-blank one, from point at its heading (or the
    /// start of the file).
    func entryID() -> String? {
        saveExcursion {
            if beforeFirstHeading {
                while bolp, lookingAt("^[ \\t]*#[ \\t]") != nil || lookingAt("^[ \\t]*#$") != nil { if forwardLine(1) != 0 { break } }
            } else {
                forwardLine(1)
                if lookingAt(planningPattern) != nil { forwardLine(1) }
            }
            guard let drawer = looking(Self.propertyDrawerPattern, caseInsensitive: true) else { return nil }
            let body = substring(drawer[0]!.lowerBound, drawer[0]!.upperBound)
            guard let range = body.range(of: "(?m)^[ \\t]*:ID:[ \\t]+(\\S.*?)[ \\t]*$", options: [.regularExpression, .caseInsensitive]) else { return nil }
            return body[range].replacingOccurrences(of: "^[ \\t]*:[Ii][Dd]:[ \\t]+|[ \\t]+$", with: "", options: .regularExpression)
        }
    }
}
