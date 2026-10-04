import Foundation

/// Typed facts read from one parsed document. Built once per tree; commands and the index read
/// this rather than raw text.
public struct DocumentModel: Sendable {
    public let settings: SemanticSettings
    public let orgSettings: OrgSettings
    public private(set) var headings: [HeadingInfo] = []
    public private(set) var fileTags: [String] = []
    /// `#+PROPERTY:` lines in order.
    public private(set) var fileProperties: [Property] = []
    public private(set) var tables: [TableModel] = []
    public private(set) var srcBlocks: [SrcBlockInfo] = []

    /// Always inherited, whatever the inheritance setting.
    static let alwaysInherited: Set<String> = ["CATEGORY", "ARCHIVE", "COLUMNS", "LOGGING"]
    /// Identify one heading, so never inherited.
    static let neverInherited: Set<String> = ["ID", "CUSTOM_ID"]

    private typealias PendingBlock = (node: SyntaxNode, heading: Int?, affiliated: [SyntaxNode])

    public init(tree: OrgTree, settings: SemanticSettings = .default) {
        self.settings = settings
        self.orgSettings = tree.settings
        var pending: [PendingBlock] = []
        walk(tree.root, heading: nil, pending: &pending)
        // Header arguments depend on file and heading properties, so blocks resolve last.
        srcBlocks = pending.map { srcBlock($0.node, heading: $0.heading, affiliated: $0.affiliated) }
    }

    // MARK: - Queries

    /// Ancestor indexes of a heading, outermost first.
    public func ancestors(of index: Int) -> [Int] {
        var result: [Int] = []
        var current = headings[index].parent
        while let parent = current {
            result.insert(parent, at: 0)
            current = headings[parent].parent
        }
        return result
    }

    /// Titles from the outermost ancestor down to the heading itself.
    public func outlinePath(of index: Int) -> [String] {
        (ancestors(of: index) + [index]).map { headings[$0].title }
    }

    public func inherits(_ key: String) -> Bool {
        let key = key.uppercased()
        if Self.neverInherited.contains(key) { return false }
        if Self.alwaysInherited.contains(key) || key.hasPrefix("HEADER-ARGS") { return true }
        switch settings.propertyInheritance {
        case .none: return false
        case .all: return true
        case .only(let keys): return keys.contains(key)
        }
    }

    /// The value of `key` for a heading, or for the file when `index` is nil. Inherited keys
    /// start from `#+PROPERTY` and walk down the ancestors; `KEY+` lines append with a space.
    public func property(_ key: String, of index: Int?) -> Resolved<String>? {
        let key = key.uppercased()
        var layers: [(entries: [Property], source: ValueSource)] = []
        if let index {
            if inherits(key) {
                layers.append((fileProperties, .file))
                layers += ancestors(of: index).map { (headings[$0].properties, .heading($0)) }
            }
            layers.append((headings[index].properties, .heading(index)))
        } else {
            layers.append((fileProperties, .file))
        }
        var result: Resolved<String>?
        for layer in layers {
            for entry in layer.entries where entry.key.uppercased() == key {
                if entry.additive, let current = result {
                    result = Resolved(current.value + " " + entry.value, layer.source)
                } else {
                    result = Resolved(entry.value, layer.source)
                }
            }
        }
        return result
    }

    /// Inherited tags first (file tags, then ancestors outermost first), then the heading's own.
    /// A tag the heading has itself counts as its own.
    public func tags(of index: Int) -> [Resolved<String>] {
        let local = headings[index].localTags
        var inherited: [Resolved<String>] = []
        if settings.tagInheritance {
            let layers = [(fileTags, ValueSource.file)] + ancestors(of: index).map { (headings[$0].localTags, ValueSource.heading($0)) }
            for (tags, source) in layers {
                for tag in tags where !settings.tagsExcludedFromInheritance.contains(tag)
                    && !local.contains(tag) && !inherited.contains(where: { $0.value == tag }) {
                    inherited.append(Resolved(tag, source))
                }
            }
        }
        var own: [Resolved<String>] = []
        for tag in local where !own.contains(where: { $0.value == tag }) {
            own.append(Resolved(tag, .heading(index)))
        }
        return inherited + own
    }

    // MARK: - Building

    private mutating func walk(_ node: SyntaxNode, heading: Int?, pending: inout [PendingBlock]) {
        var previous: SyntaxNode?
        var affiliated: [SyntaxNode] = []
        for child in node.children {
            // Blank lines between nodes detach affiliated keywords.
            if let previous, previous.range.upperBound != child.range.lowerBound { affiliated = [] }
            switch child.kind {
            case .section:
                section(child, parent: heading, pending: &pending)
            case .heading, .affiliatedKeyword:
                break
            case .planning:
                if let heading { planning(child, heading) }
            case .propertyDrawer:
                if let heading {
                    headings[heading].properties += child.children.filter { $0.kind == .nodeProperty }.compactMap { Property(line: $0.text) }
                }
            case .clock:
                if let heading, let clock = clock(child) { headings[heading].clocks.append(clock) }
            case .timestamp:
                if let heading, let stamp = Timestamp.parse(child.text) { headings[heading].timestamps.append(stamp) }
            case .link:
                if let heading { headings[heading].links.append(linkTarget(child)) }
            case .keyword:
                fileKeyword(child)
            case .table:
                tables.append(TableModel(node: child, heading: heading))
                walk(child, heading: heading, pending: &pending)
            case .block:
                if Self.isSrcBlock(child) { pending.append((child, heading, affiliated)) }
            default:
                walk(child, heading: heading, pending: &pending)
            }
            affiliated = child.kind == .affiliatedKeyword ? affiliated + [child] : []
            previous = child
        }
    }

    private mutating func section(_ node: SyntaxNode, parent: Int?, pending: inout [PendingBlock]) {
        guard let headingNode = node.children.first(where: { $0.kind == .heading }) else { return }
        let index = headings.count
        let tokens = headingNode.tokens
        let todo = tokens.first { $0.kind == .todoKeyword }?.text
        let title = headingNode.children.first { $0.kind == .title }
        headings.append(HeadingInfo(
            sectionRange: node.range,
            headingRange: headingNode.range,
            level: tokens.first { $0.kind == .stars }?.text.count ?? 0,
            parent: parent,
            todo: todo,
            isDone: todo.map(orgSettings.isDone) ?? false,
            priority: tokens.first { $0.kind == .priority }.map { String($0.text.dropFirst(2).dropLast()) },
            title: title?.text ?? "",
            localTags: tokens.first { $0.kind == .tags }.map { $0.text.split(separator: ":").map(String.init) } ?? [],
            properties: [], scheduled: nil, deadline: nil, closed: nil, clocks: [], timestamps: [], links: []
        ))
        if let title { walk(title, heading: index, pending: &pending) }
        walk(node, heading: index, pending: &pending)
    }

    /// Each timestamp belongs to the keyword just before it.
    private mutating func planning(_ node: SyntaxNode, _ heading: Int) {
        let text = node.text
        for stampNode in node.children where stampNode.kind == .timestamp {
            guard let stamp = Timestamp.parse(stampNode.text) else { continue }
            let end = String.Index(utf16Offset: stampNode.offset - node.offset, in: text)
            let before = text[..<end].trimmingCharacters(in: .whitespaces)
            if before.hasSuffix("SCHEDULED:") {
                headings[heading].scheduled = stamp
            } else if before.hasSuffix("DEADLINE:") {
                headings[heading].deadline = stamp
            } else if before.hasSuffix("CLOSED:") {
                headings[heading].closed = stamp
            }
        }
    }

    private func clock(_ node: SyntaxNode) -> Clock? {
        guard let stampNode = node.children.first(where: { $0.kind == .timestamp }),
              let stamp = Timestamp.parse(stampNode.text) else { return nil }
        var minutes: Int?
        if let arrow = node.text.range(of: "=>") {
            let parts = node.text[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            if parts.count == 2, let hours = Int(parts[0]), let mins = Int(parts[1]) { minutes = hours * 60 + mins }
        }
        return Clock(start: stamp.start, end: stamp.end, minutes: minutes)
    }

    private func linkTarget(_ node: SyntaxNode) -> String {
        if let path = node.tokens.first(where: { $0.kind == .linkPath }) { return path.text }
        let text = node.text
        if text.hasPrefix("<"), text.hasSuffix(">") { return String(text.dropFirst().dropLast()) }
        return text
    }

    private mutating func fileKeyword(_ node: SyntaxNode) {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return }
        let key = text[text.index(text.startIndex, offsetBy: 2)..<colon].uppercased()
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "FILETAGS":
            fileTags += value.split(whereSeparator: { $0 == ":" || $0.isWhitespace }).map(String.init)
        case "PROPERTY":
            let parts = value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard var name = parts.first.map(String.init) else { return }
            let additive = name.hasSuffix("+")
            if additive { name.removeLast() }
            fileProperties.append(Property(key: name, value: parts.count > 1 ? String(parts[1]) : "", additive: additive))
        default:
            break
        }
    }

    // MARK: - Source blocks

    static func isSrcBlock(_ node: SyntaxNode) -> Bool {
        node.text.drop { $0 == " " || $0 == "\t" }.lowercased().hasPrefix("#+begin_src")
    }

    private func srcBlock(_ node: SyntaxNode, heading: Int?, affiliated: [SyntaxNode]) -> SrcBlockInfo {
        let raw = splitRawLines(node.text)
        let beginLine = raw[0].content.drop { $0 == " " || $0 == "\t" }.dropFirst("#+begin_src".count)
        let words = beginLine.split(whereSeparator: \.isWhitespace)
        var language: String?
        var switches: [String] = []
        var rest = words[...]
        if let first = rest.first, !first.hasPrefix("-"), !first.hasPrefix("+"), !first.hasPrefix(":") {
            language = String(first)
            rest = rest.dropFirst()
        }
        while let word = rest.first, !word.hasPrefix(":") {
            switches.append(String(word))
            rest = rest.dropFirst()
        }
        let body = raw.dropFirst().dropLast().map { String($0.content) + String($0.ending) }.joined()

        var name: String?
        var headerLines: [String] = []
        for keyword in affiliated {
            let text = keyword.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = SettingsScanner.keywordValue(text[...]).trimmingCharacters(in: .whitespaces)
            if text.uppercased().hasPrefix("#+NAME:") { name = value }
            if text.uppercased().hasPrefix("#+HEADER:") { headerLines.append(value) }
        }

        var arguments = HeaderArguments.defaults.mapValues { Resolved($0, .defaults) }
        var keys = ["header-args"]
        if let language { keys.append("header-args:\(language)") }
        for key in keys {
            for pair in headerArgumentLayers(key, heading: heading) {
                arguments[pair.key] = Resolved(pair.value, pair.source)
            }
        }
        for line in headerLines + [rest.joined(separator: " ")] {
            for pair in HeaderArguments.parse(line) {
                arguments[pair.key] = Resolved(pair.value, .element)
            }
        }
        return SrcBlockInfo(
            range: node.range, heading: heading, name: name, language: language,
            switches: switches, body: body, headerArguments: arguments
        )
    }

    /// `header-args` pairs from `#+PROPERTY` down to the heading. As in org, a plain property
    /// replaces everything above it; `header-args+` adds to it.
    private func headerArgumentLayers(_ key: String, heading: Int?) -> [(key: String, value: String, source: ValueSource)] {
        var layers: [(entries: [Property], source: ValueSource)] = [(fileProperties, .file)]
        if let heading {
            layers += (ancestors(of: heading) + [heading]).map { (headings[$0].properties, .heading($0)) }
        }
        var pairs: [(key: String, value: String, source: ValueSource)] = []
        for layer in layers {
            for entry in layer.entries where entry.key.lowercased() == key {
                let parsed = HeaderArguments.parse(entry.value).map { (key: $0.key, value: $0.value, source: layer.source) }
                pairs = entry.additive ? pairs + parsed : parsed
            }
        }
        return pairs
    }
}
