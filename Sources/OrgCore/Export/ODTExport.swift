import Foundation
import ImageIO

/// OpenDocument text export written from the parse tree, in the shape ox-odt (Org 9.8.7) gives
/// `content.xml` under `emacs -Q`: LaTeX left verbatim, as without a MathML converter, and source
/// blocks without colors. `styles.xml` is a reduced template holding ox-odt's style names.
public enum ODTExport {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The `.odt` file: `content.xml`, `styles.xml`, `meta.xml`, the images and the manifest,
    /// with `mimetype` first and stored. `path` is the file's, for `#+INCLUDE`, macros and
    /// images; `author` is used without `#+AUTHOR` (`user-full-name`); `language` is
    /// `org-export-default-language`. Throws what makes ox-odt stop: broken links and missing
    /// images among them.
    public static func document(
        _ text: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date(),
        author: String? = nil, language: String = "en"
    ) throws -> Data {
        var zip = ZipWriter()
        for part in try parts(text, settings: settings, path: path, now: now, author: author, language: language) {
            zip.add(part.name, data: part.data)
        }
        return zip.data()
    }

    /// The image files `text` embeds, for the sandbox to reach before exporting.
    public static func imageFiles(_ text: String, settings: OrgSettings = .default, path: String) -> [String] {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return OrgParser.parse(text, defaults: settings).root.descendants().compactMap { node in
            guard node.kind == .link, node.firstChild(.linkDescription) == nil,
                  let file = ODTRenderer.filePath(node.tokens.first { $0.kind == .linkPath }?.text ?? ""), ODTRenderer.isImage(file) else { return nil }
            return ODTRenderer.expand(file, directory: directory).path
        }
    }

    static func parts(
        _ text: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date(),
        author: String? = nil, language: String = "en"
    ) throws -> [(name: String, data: Data)] {
        let directory = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let text = ExportPreprocess.macros(ExportPreprocess.includes(text, directory: directory), path: path, now: now, setup: settings.setupKeywords)
        let options = ExportOptions.parse(settings.setupKeywords + text)
        let meta = HTMLExport.metadata(text, settings: settings)
        let keywords = Self.keywords(text, settings: settings)
        let renderer = ODTRenderer(settings: settings, options: options, directory: directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        renderer.language = meta.language ?? language

        // The title isn't part of the document Org processes citations in: they drop out.
        renderer.inTitle = true
        let title = meta.title.map(renderer.inlineString) ?? ""
        let subtitle = keywords["SUBTITLE"].map(renderer.inlineString) ?? ""
        let authorName = (meta.author ?? author).flatMap { $0.isEmpty ? nil : $0 }.map(renderer.inlineString)
        renderer.inTitle = false
        renderer.author = authorName
        renderer.dated = !(meta.date ?? "").isEmpty
        renderer.citations = CiteProcessor(text: text, directory: directory)
        let body = renderer.document(renderer.citations == nil ? text : renderer.citations!.inliningNotes(CiteProcessor.removingNocite(text)))
        let date = options.date ? meta.date.flatMap { $0.isEmpty ? nil : renderer.inlineString($0) } : nil
        if let failure = renderer.failure { throw failure }

        var preamble = ""
        if options.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preamble += "\n<text:p text:style-name=\"OrgTitle\">\n<text:title>\(title)</text:title></text:p>\n"
            preamble += "\n<text:p text:style-name=\"OrgTitle\"/>\n"
            if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preamble += "<text:p text:style-name=\"OrgSubtitle\">\n<text:user-defined style:data-style-name=\"N0\" text:name=\"subtitle\">\n\(subtitle)</text:user-defined>\n\n</text:p>\n"
                preamble += "<text:p text:style-name=\"OrgSubtitle\"/>\n"
            }
        }
        if options.author, let authorName {
            preamble += "\n<text:p text:style-name=\"OrgSubtitle\"><text:initial-creator>\(authorName)</text:initial-creator></text:p>"
            preamble += "\n<text:p text:style-name=\"OrgSubtitle\"/>"
        }
        if let date { preamble += "\n<text:p text:style-name=\"OrgSubtitle\">\(date)</text:p><text:p text:style-name=\"OrgSubtitle\"/>" }
        let contents = ODTTemplate.content(automaticStyles: renderer.automaticStyles(), body: preamble + renderer.tableOfContents() + body)

        let stamp = meta.date.flatMap(Timestamp.parse).map { stamp -> String in
            let p = stamp.start
            return String(format: "%04d-%02d-%02dT%02d:%02d:00", p.year, p.month, p.day, p.hour ?? 0, p.minute ?? 0)
        } ?? Self.isoDate(now)
        let metaXML = ODTTemplate.meta(
            author: authorName.map(ODTRenderer.stripped) ?? "", date: options.date ? stamp : nil, keywords: keywords["KEYWORDS"] ?? "",
            description: keywords["DESCRIPTION"] ?? "", title: ODTRenderer.stripped(title), subtitle: ODTRenderer.stripped(subtitle)
        )

        var parts: [(name: String, data: Data)] = [("mimetype", Data(ODTTemplate.mimetype.utf8))]
        parts.append(("content.xml", Data(contents.utf8)))
        parts.append(("styles.xml", Data(ODTTemplate.styles(numbered: options.num ?? 0).utf8)))
        parts.append(("meta.xml", Data(metaXML.utf8)))
        parts += renderer.images.map { ($0.name, $0.data) }
        parts.append(("META-INF/manifest.xml", Data(ODTTemplate.manifest(images: renderer.images.map(\.name)).utf8)))
        return parts
    }

    /// `#+SUBTITLE`, `#+KEYWORDS` and `#+DESCRIPTION`: lines of the same keyword joined.
    static func keywords(_ text: String, settings: OrgSettings) -> [String: String] {
        let tree = OrgParser.parse(text, defaults: settings)
        let own = tree.root.children.filter { $0.kind == .zerothSection }.flatMap { $0.children.filter { $0.kind == .keyword } }.map(\.text)
        var values: [String: String] = [:]
        for line in settings.setupKeywords.split(separator: "\n").map(String.init) + own {
            guard let m = line.firstMatch(of: /^[ \t]*#\+([A-Za-z_]+):[ \t]*(.*?)[ \t]*\n?$/) else { continue }
            let key = m.1.uppercased()
            guard ["SUBTITLE", "KEYWORDS", "DESCRIPTION"].contains(key) else { continue }
            values[key] = values[key].map { $0 + (key == "DESCRIPTION" ? "\n" : " ") + m.2 } ?? String(m.2)
        }
        return values
    }

    static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}

final class ODTRenderer {
    let settings: OrgSettings
    let options: ExportOptions
    let directory: URL
    var language = "en"
    var citations: CiteProcessor?
    /// Rendering the title, where Org exports citations as nothing.
    var inTitle = false
    /// The document's author, rendered, and whether it has a date, for annotations.
    var author: String?
    var dated = false
    /// The first error, which stops the export as ox-odt's errors do.
    private(set) var failure: ODTExport.Failure?
    private(set) var images: [(name: String, data: Data)] = []

    init(settings: OrgSettings, options: ExportOptions, directory: URL) {
        self.settings = settings
        self.options = options
        self.directory = directory
    }

    private func fail(_ message: String) -> String {
        if failure == nil { failure = ODTExport.Failure(message: message) }
        return ""
    }

    // MARK: - Collecting

    /// An exported heading, by its start in the document.
    struct Heading {
        var key: Int
        var level: Int
        var ancestors: [Int]
        var info: HeadingInfo?
        var node: SyntaxNode
        var relative = 1
        var number: [Int]?
        var lowLevel = false
        var reference = ""
    }

    /// A captioned or named table, source block or image: its category, sequence and label.
    struct Label {
        var category: String
        var variable: String
        var sequence: String
        var reference: String?
    }

    private var headings: [Int: Heading] = [:]
    private var headingOrder: [Int] = []
    private var targets: [(words: [String], key: Int, reference: String)] = []
    private var names: [(words: [String], key: Int)] = []
    private var labels: [Int: Label] = [:]
    private var enumerables: [(key: Int, category: String, ancestors: [Int])] = []
    private var references = 0
    private var selected: Set<Int>?
    private var documentTree: OrgTree?
    private var blockLocs: [String: [Int?]] = [:]
    private var definitions: [String: (text: String, base: Int)] = [:]

    /// Where the tree being read starts in the document, so elements read from a block's or a
    /// footnote's contents keep their place; how deep in such contents it is.
    private var base = 0
    private var depth = 0
    /// Elements after a footnote definition that belong to it, by their start.
    private var absorbed: Set<Int> = []

    private func newReference() -> String {
        references += 1
        return String(format: "org%07x", references &* 2_654_435_761 & 0xFFF_FFFF)
    }

    private static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func collect(_ tree: OrgTree) {
        let model = DocumentModel(tree: tree)
        var infos: [Int: HeadingInfo] = [:]
        for heading in model.headings { infos[heading.headingRange.lowerBound] = heading }
        collect(tree.root, ancestors: [], infos: infos)
        let top = headingOrder.compactMap { headings[$0]?.level }.min() ?? 1
        var counters: [Int] = []
        for key in headingOrder {
            var heading = headings[key]!
            heading.relative = heading.level - top + 1
            heading.lowLevel = heading.relative > options.headlineLevels
            heading.reference = newReference()
            let unnumbered = (heading.ancestors + [key]).contains { key in
                guard let value = headings[key]?.info?.properties.last(where: { $0.key.uppercased() == "UNNUMBERED" })?.value else { return false }
                return value.trimmingCharacters(in: .whitespaces) != "nil"
            }
            if let num = options.num, heading.relative <= num, !unnumbered {
                let index = heading.relative - 1
                if counters.count <= index { counters += Array(repeating: 0, count: index + 1 - counters.count) }
                counters[index] += 1
                for i in (index + 1)..<counters.count { counters[i] = 0 }
                heading.number = Array(counters.prefix(index + 1))
            }
            headings[key] = heading
        }
        // `org-odt--enumerate`: numbered within the closest numbered heading at level 2 or
        // above, else through the document.
        var counts: [String: Int] = [:]
        for (index, item) in enumerables.enumerated() {
            let scope = item.ancestors.reversed().first { headings[$0].map { $0.relative <= 2 && $0.number != nil } ?? false }
            let ordinal = enumerables[...index].filter { $0.category == item.category && (scope.map($0.ancestors.contains) ?? true) }.count
            counts[item.category, default: 0] += 1
            let sequence = (scope.flatMap { headings[$0]?.number }.map { $0.map(String.init).joined(separator: ".") + "." } ?? "") + String(ordinal)
            let named = names.contains { $0.key == item.key }
            let variable = ["Table": "Table", "Figure": "Illustration", "Listing": "Listing"][item.category]!
            labels[item.key] = Label(category: item.category, variable: variable, sequence: sequence, reference: named ? newReference() : nil)
        }
    }

    private func collect(_ node: SyntaxNode, ancestors: [Int], infos: [Int: HeadingInfo]) {
        var affiliated: [String: String] = [:]
        for child in node.children {
            if child.kind == .affiliatedKeyword {
                if let m = child.text.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^#\+([A-Za-z_]+):[ \t]*(.*)$/) {
                    affiliated[m.1.uppercased()] = String(m.2)
                }
                continue
            }
            defer { affiliated = [:] }
            if depth == 0, absorbed.contains(child.range.lowerBound) { continue }
            let key = base + child.range.lowerBound
            if let name = affiliated["NAME"] { names.append((Self.words(name), key)) }
            let captioned = affiliated["CAPTION"] != nil || affiliated["NAME"] != nil
            switch child.kind {
            case .section:
                guard let heading = child.firstChild(.heading) else { collect(child, ancestors: ancestors, infos: infos); continue }
                let export = HTMLRenderer.sectionExport(heading, options: options, selected: selected)
                if export == .nothing { continue }
                let headingKey = base + heading.range.lowerBound
                let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
                headings[headingKey] = Heading(key: headingKey, level: level, ancestors: ancestors, info: infos[heading.range.lowerBound], node: heading)
                headingOrder.append(headingKey)
                collect(heading, ancestors: ancestors, infos: infos)
                if export == .all { collect(child, ancestors: ancestors + [headingKey], infos: infos) }
            case .heading, .footnoteDefinition:
                continue
            case .target, .radioTarget:
                let inner = child.kind == .target ? child.text.dropFirst(2).dropLast(2) : child.text.dropFirst(3).dropLast(3)
                targets.append((Self.words(inner.uppercased()), key, newReference()))
            case .table:
                if captioned { enumerables.append((key, "Table", ancestors)) }
                collect(child, ancestors: ancestors, infos: infos)
            case .paragraph:
                if captioned, soleImage(child) != nil { enumerables.append((key, "Figure", ancestors)) }
                collect(child, ancestors: ancestors, infos: infos)
            case .block:
                let (type, _, _, body) = Self.blockParts(child)
                if type == "src", captioned { enumerables.append((key, "Listing", ancestors)) }
                if ["src", "example", "export", "comment", "verse"].contains(type) { continue }
                within(body.text, base: key + body.offset) { tree in collect(tree.root, ancestors: ancestors, infos: [:]) }
            case .drawer, .dynamicBlock:
                guard let inner = Self.inner(child) else { continue }
                within(inner.text, base: key + inner.offset) { tree in collect(tree.root, ancestors: ancestors, infos: [:]) }
            default:
                collect(child, ancestors: ancestors, infos: infos)
            }
        }
    }

    /// A drawer's or dynamic block's contents and their offset in it; nil for `LOGBOOK`, which
    /// isn't exported.
    static func inner(_ node: SyntaxNode) -> (text: String, offset: Int)? {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { return nil }
        if node.kind == .drawer, first.trimmingCharacters(in: .whitespaces).uppercased() == ":LOGBOOK:" { return nil }
        return (lines.dropFirst().dropLast().joined(separator: "\n"), first.utf16.count + 1)
    }

    /// `body` with `text`, which starts at `base` in the document, parsed.
    private func within<T>(_ text: String, base: Int, _ body: (OrgTree) -> T) -> T {
        let saved = self.base
        self.base = base
        depth += 1
        defer { self.base = saved; depth -= 1 }
        return body(OrgParser.parse(text, defaults: settings))
    }

    // MARK: - Document

    private var source: ExportSource?

    /// `body` with `tree` as the source of `:exports`.
    private func rendering<T>(_ tree: OrgTree, _ text: String, _ body: () -> T) -> T {
        let saved = source
        source = ExportSource(tree: tree, text: text)
        defer { source = saved }
        return body()
    }

    func document(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        documentTree = tree
        let codeBlocks = Coderef.blocks(tree)
        for (lines, loc) in zip(codeBlocks, Coderef.locs(codeBlocks.compactMap(Coderef.block))) {
            blockLocs[lines.joined(separator: "\n"), default: []].append(loc)
        }
        // A definition runs to the next definition or heading, or two blank lines.
        let ns = text as NSString
        for node in tree.root.descendants() where node.kind == .footnoteDefinition {
            guard let m = node.text.firstMatch(of: /^\[fn:([^\]]+)\][ \t]*/) else { continue }
            let start = node.range.lowerBound + node.text.utf16.distance(from: node.text.startIndex, to: m.range.upperBound)
            var end = node.range.upperBound
            let siblings = node.parent?.children ?? []
            if let index = siblings.firstIndex(where: { $0.range == node.range }) {
                for sibling in siblings[(index + 1)...] {
                    if [.footnoteDefinition, .section, .heading].contains(sibling.kind) { break }
                    let gap = ns.substring(with: NSRange(location: node.range.lowerBound, length: sibling.range.lowerBound - node.range.lowerBound))
                    if gap.range(of: "\n[ \t]*\n[ \t]*\n[ \t]*$", options: .regularExpression) != nil { break }
                    absorbed.insert(sibling.range.lowerBound)
                    end = sibling.range.upperBound
                }
            }
            definitions[String(m.1)] = (ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines), start)
        }
        selected = HTMLRenderer.selection(tree, tags: options.selectTags)
        collect(tree)
        return rendering(tree, text) { tree.root.children.map(element).joined() }
    }

    /// Org text that starts at `base` in the document, rendered as elements.
    private func blocks(_ text: String, base: Int) -> String {
        within(text, base: base) { tree in rendering(tree, text) { tree.root.children.map(element).joined() } }
    }

    /// One line of org text rendered inline.
    func inlineString(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return Self.escape(text) }
        return rendering(tree, text) { inline(paragraph).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Table of contents

    /// `org-odt-toc` for the whole document: headings to `toc`, or nothing.
    func tableOfContents() -> String {
        guard let depth = options.toc else { return "" }
        return toc(depth: depth, scope: nil)
    }

    private func toc(depth: Int, scope: Int?) -> String {
        let keys = headingOrder.filter { key in
            let heading = headings[key]!
            let notoc = heading.info?.properties.last { $0.key.uppercased() == "UNNUMBERED" }?.value.trimmingCharacters(in: .whitespaces) == "notoc"
            return heading.relative <= depth && !notoc && (scope.map { heading.ancestors.contains($0) } ?? true)
        }
        guard !keys.isEmpty else { return "" }
        let title = scope == nil ? ExportDictionary.translate("Table of Contents", language: language, encoding: .utf8) : nil
        var out = "\n<text:table-of-content text:style-name=\"OrgIndexSection\" text:protected=\"true\" text:name=\"Table of Contents\">\n"
        out += "  <text:table-of-content-source text:outline-level=\"\(depth)\">"
        if let title { out += "\n    <text:index-title-template text:style-name=\"Contents_20_Heading\">\(Self.escape(title))</text:index-title-template>\n" }
        for level in 1...10 {
            out += """

                  <text:table-of-content-entry-template text:outline-level="\(level)" text:style-name="Contents_20_\(level)">
                   <text:index-entry-link-start text:style-name="Internet_20_link"/>
                   <text:index-entry-chapter/>
                   <text:index-entry-text/>
                   <text:index-entry-link-end/>
                  </text:table-of-content-entry-template>

            """
        }
        out += "\n  </text:table-of-content-source>\n  <text:index-body>"
        if let title {
            out += "\n    <text:index-title text:style-name=\"Sect1\" text:name=\"Table of Contents1_Head\">\n      <text:p text:style-name=\"Contents_20_Heading\">\(Self.escape(title))</text:p>\n    </text:index-title>\n"
        }
        tocEntry = true
        out += keys.map { key in
            let heading = headings[key]!
            var entry = heading.number.map { $0.map(String.init).joined(separator: ".") + ". " } ?? ""
            let parts = headlineParts(heading.node)
            if let todo = parts.todo { entry += "<text:span text:style-name=\"\(settings.isDone(todo) ? "OrgDone" : "OrgTodo")\">\(Self.escape(todo))</text:span> " }
            if let priority = parts.priority { entry += "<text:span text:style-name=\"OrgPriority-\(priority)\">[#\(priority)]</text:span> " }
            entry += parts.title
            if options.tagsInTOC, !parts.tags.isEmpty { entry += " " + tagsSpan(parts.tags) }
            return "\n<text:p text:style-name=\"Contents_20_\(heading.relative)\"><text:a xlink:type=\"simple\" xlink:href=\"#\(heading.reference)\">\(entry)</text:a></text:p>"
        }.joined(separator: "\n")
        tocEntry = false
        return out + "\n  </text:index-body>\n</text:table-of-content>"
    }

    /// Rendering a table of contents entry: footnotes and targets drop out, links become text.
    private var tocEntry = false

    // MARK: - Elements

    private var affiliated: [String: String] = [:]
    /// `:exports` of the last src block or call: its results are exported only for `results`
    /// and `both`; nothing runs.
    private var lastExports = "code"

    func element(_ node: SyntaxNode) -> String {
        if depth == 0, absorbed.contains(node.range.lowerBound) { return "" }
        defer { if node.kind != .affiliatedKeyword { affiliated = [:] } }
        if node.kind != .affiliatedKeyword, affiliated["RESULTS"] != nil {
            defer { lastExports = "code" }
            if lastExports != "results", lastExports != "both" { return "" }
        }
        if node.kind == .block || node.kind == .keyword, let exports = source?.exports(at: node.range.lowerBound) {
            lastExports = exports
            if exports == "results" || exports == "none" { return "" }
        }
        switch node.kind {
        case .section:
            guard let heading = node.firstChild(.heading) else { fallthrough }
            switch HTMLRenderer.sectionExport(heading, options: options, selected: selected) {
            case .nothing: return ""
            case .heading: return section(node, heading: heading, contents: false)
            case .all: return section(node, heading: heading, contents: true)
            }
        case .zerothSection, .document:
            return node.children.map(element).joined()
        case .affiliatedKeyword:
            let line = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = line.firstMatch(of: /^#\+([A-Za-z_]+):[ \t]*(.*)$/) {
                affiliated[m.1.uppercased()] = String(m.2)
            }
            return ""
        case .paragraph:
            return paragraph(node)
        case .keyword:
            return keyword(node)
        case .plainList:
            return list(node)
        case .table:
            return table(node)
        case .block:
            return block(node)
        case .horizontalRule:
            return "\n<text:p text:style-name=\"Horizontal_20_Line\"></text:p>"
        case .drawer, .dynamicBlock:
            guard let inner = Self.inner(node) else { return "" }
            return blocks(inner.text, base: base + node.range.lowerBound + inner.offset)
        case .inlineTask:
            // `emacs -Q` doesn't load org-inlinetask, so ox-odt reads them as headings.
            return fail("ODT export doesn't support inline tasks")
        case .latexEnvironment:
            guard options.tex else { return "" }
            // Its value ends with a newline, which ox-odt writes as an empty last line.
            return code(Self.dedent(node.text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")), emptyLast: node.text.hasSuffix("\n"))
        case .fixedWidth:
            let lines = node.text.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix(": ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(trimmed.hasPrefix(":") ? 1 : 0))
            }
            return code(lines)
        case .tableEl:
            // ox-odt strips table.el tables, the list around them closed and opened again.
            return frames.isEmpty ? "" : "\n" + reopening(nil)
        default:
            // Comments, property drawers, planning, clocks, footnote definitions, formulas.
            return ""
        }
    }

    // MARK: - Headings

    private func headlineParts(_ node: SyntaxNode) -> (todo: String?, priority: String?, title: String, tags: [String]) {
        let tokens = node.tokens
        let todo = options.todo ? tokens.first { $0.kind == .todoKeyword }?.text : nil
        let priority = options.priority ? tokens.first { $0.kind == .priority }?.text.firstMatch(of: /\[#(.+)\]/).map { String($0.1) } : nil
        let title = node.firstChild(.title).map { inline($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let tags = options.tags ? tokens.first { $0.kind == .tags }?.text.split(separator: ":").map(String.init) ?? [] : []
        return (todo, priority, title, tags)
    }

    private func tagsSpan(_ tags: [String]) -> String {
        "<text:span text:style-name=\"OrgTags\">[" + tags.map { "<text:span text:style-name=\"OrgTag\">\(Self.escape($0))</text:span>" }.joined(separator: " : ") + "]</text:span>"
    }

    /// `org-odt-format-headline-default-function`.
    private func headline(_ node: SyntaxNode) -> String {
        let parts = headlineParts(node)
        var out = ""
        if let todo = parts.todo { out += "<text:span text:style-name=\"\(settings.isDone(todo) ? "OrgDone" : "OrgTodo")\">\(Self.escape(todo))</text:span> " }
        if let priority = parts.priority { out += "<text:span text:style-name=\"OrgPriority-\(priority)\">[#\(priority)]</text:span> " }
        out += parts.title
        if !parts.tags.isEmpty { out += "<text:tab/>" + tagsSpan(parts.tags) }
        return out
    }

    private static func target(_ text: String, _ id: String) -> String {
        "\n<text:bookmark-start text:name=\"OrgXref.\(id)\"/>\n<text:bookmark text:name=\"\(id)\"/>\(text)\n<text:bookmark-end text:name=\"OrgXref.\(id)\"/>"
    }

    private func section(_ node: SyntaxNode, heading node0: SyntaxNode, contents: Bool) -> String {
        guard let heading = headings[base + node0.range.lowerBound] else { return "" }
        let extra = heading.info?.id.map { Self.target("", "ID-" + $0) } ?? ""
        let anchored = Self.target(headline(node0), heading.reference)
        let numbered = heading.number != nil
        headingStack.append(heading.key)
        defer { headingStack.removeLast() }
        guard heading.lowLevel else {
            let open = "\n<text:h text:style-name=\"Heading_20_\(heading.relative)\(numbered ? "" : "_unnumbered")\" text:outline-level=\"\(heading.relative)\" text:is-list-header=\"\(numbered ? "false" : "true")\">\(extra)\(anchored)</text:h>"
            return open + (contents ? node.children.filter { $0.kind != .heading }.map(element).joined() : "")
        }
        // A heading deeper than `H` is a list item, its siblings in one list.
        let siblings = (node.parent?.children ?? []).filter { section in
            section.kind == .section && section.firstChild(.heading).map { headings[base + $0.range.lowerBound] != nil } ?? false
        }
        let style = numbered ? "OrgNumberedList" : "OrgBulletedList"
        var out = ""
        if siblings.first?.range == node.range {
            let parentLow = heading.ancestors.last.flatMap { headings[$0]?.lowLevel } ?? false
            out += "\n<text:list text:style-name=\"\(style)\" text:continue-numbering=\"\(parentLow)\">"
        }
        frames.append(Frame(style: style))
        let body = "\n<text:p text:style-name=\"Text_20_body\">\(extra)\(anchored)</text:p>" + (contents ? node.children.filter { $0.kind != .heading }.map(element).joined() : "")
        let frame = frames.removeLast()
        out += "\n<text:list-item>\n\(body)\n\(frame.header ? "</text:list-header>" : "</text:list-item>")"
        if siblings.last?.range == node.range { out += "</text:list>" }
        return out
    }

    // MARK: - Paragraphs

    private enum Container { case quote, center }
    /// The quote or center block paragraphs are in.
    private var container: Container?
    /// Paragraph styles outside, in a center block and in a quote block.
    private var paragraphStyles = ("Text_20_body", "OrgCenter", "Quotations")
    /// Rendering a paragraph that is only an image link.
    private var standalone = false

    private func paragraph(_ node: SyntaxNode, prefix: String = "", style: String? = nil) -> String {
        let named = style ?? paragraphStyles.0
        let chosen = container == .quote ? paragraphStyles.2 : container == .center ? paragraphStyles.1 : named
        standalone = soleImage(node) != nil
        defer { standalone = false }
        imageKey = base + node.range.lowerBound
        imageCaptioned = affiliated["CAPTION"] != nil || affiliated["NAME"] != nil
        imageCaption = affiliated["CAPTION"]
        imageAttributes = affiliated["ATTR_ODT"]
        defer { imageKey = nil; imageCaptioned = false; imageCaption = nil; imageAttributes = nil }
        return "\n<text:p text:style-name=\"\(chosen)\">\(prefix)\(inline(node).trimmingCharacters(in: .whitespacesAndNewlines))</text:p>"
    }

    /// The link of a paragraph that is only an image link.
    private func soleImage(_ node: SyntaxNode) -> SyntaxNode? {
        let links = node.children.filter { $0.kind == .link }
        guard links.count == 1, node.children.count == 1,
              node.tokens.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              links[0].firstChild(.linkDescription) == nil,
              let file = Self.filePath(links[0].tokens.first { $0.kind == .linkPath }?.text ?? ""), Self.isImage(file) else { return nil }
        return links[0]
    }

    private func keyword(_ node: SyntaxNode) -> String {
        guard let m = node.text.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^#\+([A-Za-z_]+):[ \t]*(.*)$/) else { return "" }
        let value = String(m.2)
        switch m.1.uppercased() {
        case "ODT":
            return value
        case "TOC":
            guard value.range(of: "\\bheadlines\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return "" }
            let depth = value.firstMatch(of: /\b([0-9]+)\b/).flatMap { Int($0.1) } ?? options.headlineLevels
            if value.range(of: ":target", options: .caseInsensitive) != nil { return fail("ODT export doesn't support #+TOC with :target") }
            let local = value.range(of: "\\blocal\\b", options: [.regularExpression, .caseInsensitive]) != nil
            return toc(depth: depth, scope: local ? currentHeading() : nil)
        case "PRINT_BIBLIOGRAPHY":
            guard let citations else { return "" }
            return citations.bibliography.map { "\n<text:p text:style-name=\"Text_20_body\">" + render($0) + "</text:p>" }.joined()
        default:
            return ""
        }
    }

    /// The heading whose section is being rendered.
    private var headingStack: [Int] = []
    private func currentHeading() -> Int? { headingStack.last }

    // MARK: - Lists

    /// An open list item, closed and opened again around a table.
    private struct Frame {
        var style: String
        var header = false
    }

    private var frames: [Frame] = []

    private func list(_ node: SyntaxNode) -> String {
        let items = node.children.filter { $0.kind == .item }
        guard let first = items.first else { return "" }
        let bullet = first.tokens.first { $0.kind == .bullet }?.text ?? "-"
        let ordered = bullet.first.map { $0.isNumber || $0.isLetter } ?? false
        let descriptive = !ordered && first.firstChild(.itemTag) != nil
        let style = ordered ? "OrgNumberedList" : descriptive ? "OrgDescriptionList" : "OrgBulletedList"
        let nested = node.parent?.kind == .item
        var out = "\n<text:list text:style-name=\"\(style)\" text:continue-numbering=\"\(nested)\">\n"
        for item in items {
            let box = checkbox(item)
            if descriptive {
                // As `org-odt--translate-description-lists`: the term in bold, the definition
                // an item of a list inside.
                frames.append(Frame(style: style))
                let term = item.firstChild(.itemTag).map { inline($0).trimmingCharacters(in: .whitespaces) } ?? "(no term)"
                var body = paragraphText(term, prefix: box, style: "Text_20_body_20_bold")
                body += "\n<text:list text:style-name=\"\(style)\" text:continue-numbering=\"true\">\n"
                body += itemBody(item, prefix: "")
                body += "</text:list>"
                out += close(body, start: nil)
            } else {
                frames.append(Frame(style: style))
                let counter = item.tokens.first { $0.kind == .counter }?.text.firstMatch(of: /\[@([0-9A-Za-z]+)\]/).map { String($0.1) }
                out += closeItem(item, prefix: box, start: counter)
            }
        }
        return out + "</text:list>"
    }

    private func itemBody(_ item: SyntaxNode, prefix: String) -> String {
        frames.append(Frame(style: "OrgDescriptionList"))
        return closeItem(item, prefix: prefix, start: nil)
    }

    /// The item's contents, the first paragraph after `prefix`, in the open frame.
    private func closeItem(_ item: SyntaxNode, prefix: String, start: String?) -> String {
        var body = ""
        for (index, child) in item.children.filter({ $0.kind != .itemTag }).enumerated() {
            body += index == 0 && child.kind == .paragraph ? paragraph(child, prefix: prefix) : element(child)
        }
        return close(body, start: start)
    }

    private func close(_ body: String, start: String?) -> String {
        let frame = frames.removeLast()
        return "\n<text:list-item\(start.map { " text:start-value=\"\($0)\"" } ?? "")>\n\(body)\n\(frame.header ? "</text:list-header>" : "</text:list-item>")"
    }

    private func paragraphText(_ content: String, prefix: String, style: String) -> String {
        let chosen = container == .quote ? paragraphStyles.2 : container == .center ? paragraphStyles.1 : style
        return "\n<text:p text:style-name=\"\(chosen)\">\(prefix)\(content)</text:p>"
    }

    private func checkbox(_ item: SyntaxNode) -> String {
        guard let box = item.tokens.first(where: { $0.kind == .checkbox })?.text else { return "" }
        let mark = ["[X]": "[&#x2713;] ", "[x]": "[&#x2713;] ", "[-]": "[-] "][box] ?? "[ ] "
        return "<text:span text:style-name=\"OrgCode\">\(mark)</text:span>"
    }

    /// `org-odt-table`'s list handling: the open lists closed, `inner` in an indented section,
    /// the lists opened again, the innermost item as a header.
    private func reopening(_ inner: String?) -> String {
        var closing: [String] = []
        for frame in frames.reversed() {
            closing.append(frame.header ? "</text:list-header>" : "</text:list-item>")
            closing.append("</text:list>")
        }
        var opening: [String] = []
        for (index, frame) in frames.enumerated() {
            opening.append("\n<text:list text:style-name=\"\(frame.style)\" text:continue-numbering=\"true\">")
            opening.append(index == frames.count - 1 || frame.header ? "<text:list-header>" : "<text:list-item>")
        }
        if !frames.isEmpty { frames[frames.count - 1].header = true }
        let section = inner.map { inner -> String in
            sections += 1
            return "\n<text:section text:style-name=\"OrgIndentedSection-Level-\(closing.count / 2)\" text:name=\"Section\(sections)\">\n\(inner)\n</text:section>"
        } ?? ""
        return closing.joined(separator: "\n") + section + opening.joined(separator: "\n")
    }

    private var sections = 0

    // MARK: - Tables

    private var tableStyles: [(name: String, width: String)] = []

    private func table(_ node: SyntaxNode) -> String {
        let attributeLine = affiliated["ATTR_ODT"]
        let attributes = attributeLine.map(Self.attributes) ?? [:]
        if attributes["style"] != nil { return fail("ODT export doesn't support table templates (#+ATTR_ODT: :style)") }
        let caption = label(base + node.range.lowerBound, caption: affiliated["CAPTION"])
        let rows = node.children.filter { $0.kind == .tableRow }
        enum Kind { case rule, special, data }
        var cells: [[SyntaxNode]] = rows.map { $0.children.filter { $0.kind == .tableCell } }
        var kinds: [Kind] = rows.indices.map { cells[$0].isEmpty && rows[$0].text.trimmingCharacters(in: .whitespaces).hasPrefix("|-") ? .rule : .data }
        func value(_ cell: SyntaxNode) -> String { cell.text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).trimmingCharacters(in: .whitespaces) }
        // `org-export-table-has-special-column-p`.
        let firsts = rows.indices.filter { kinds[$0] == .data }.map { cells[$0].first.map(value) ?? "" }
        let specialColumn = firsts.contains { !$0.isEmpty } && firsts.allSatisfy { ["", "/", "#", "!", "$", "*", "_", "^"].contains($0) }
        for r in rows.indices where kinds[r] == .data {
            let values = cells[r].map(value)
            let cookies = values.allSatisfy { $0.isEmpty || $0.range(of: "^<[lrc]?[0-9]*>$", options: .regularExpression) != nil } && values.contains { !$0.isEmpty }
            if values.first == "/" || (specialColumn && ["^", "_", "$", "!"].contains(values.first ?? "")) || cookies { kinds[r] = .special }
        }
        let firstValues = rows.indices.map { cells[$0].first.map(value) ?? "" }
        if specialColumn { cells = cells.map { Array($0.dropFirst()) } }
        let columns = rows.indices.filter { kinds[$0] != .rule }.map { cells[$0].count }.max() ?? 0
        // Alignment and width cookies, and column groups.
        var align = Array(repeating: "", count: columns)
        var width = Array(repeating: 0, count: columns)
        var groups = Array(repeating: "", count: columns)
        for r in rows.indices where kinds[r] == .special {
            let values = cells[r].map(value)
            for (c, v) in values.enumerated() {
                if let m = v.firstMatch(of: /^<([lrc])?([0-9]+)?>$/) {
                    if let a = m.1 { align[c] = String(a) }
                    if let w = m.2 { width[c] = Int(w) ?? 0 }
                }
                if firstValues[r] == "/" { groups[c] = v }
            }
        }
        let data = rows.indices.filter { kinds[$0] == .data }
        for c in 0..<columns where align[c].isEmpty {
            var numbers = 0
            var total = 0
            var previousNumber = false
            for r in data {
                let v = c < cells[r].count ? value(cells[r][c]) : ""
                total += 1
                if TablePlot.isNumber(v) || (v.isEmpty && previousNumber) {
                    previousNumber = true
                    numbers += 1
                } else {
                    previousNumber = false
                }
            }
            align[c] = total > 0 && Double(numbers) / Double(total) >= 0.5 ? "r" : "l"
        }
        // Row groups: data rows between rules.
        var group: [Int: Int] = [:]
        var current = 1
        var seen = false
        for r in rows.indices {
            if kinds[r] == .rule, seen { current += 1; seen = false }
            if kinds[r] == .data { group[r] = current; seen = true }
        }
        let firstData = rows.indices.first { kinds[$0] == .data || kinds[$0] == .special }
        let hasHeader = firstData.map { start in
            guard let rule = rows.indices.first(where: { $0 > start && kinds[$0] == .rule }) else { return false }
            return rule + 1 < rows.count
        } ?? false
        let headerColumns = attributes["header-columns"].map { Int($0) ?? 1 } ?? 0
        var body = ""
        for (index, r) in data.enumerated() {
            let previous = rows.indices.reversed().first { $0 < r && kinds[$0] != .special }
            let next = rows.indices.first { $0 > r && kinds[$0] != .special }
            let starts = previous.map { kinds[$0] == .rule } ?? true
            let ends = next.map { kinds[$0] == .rule } ?? true
            let header = group[r] == 1 && hasHeader
            if starts { body += header ? "\n<table:table-header-rows>" : "\n<table:table-rows>" }
            var row = ""
            for c in 0..<columns {
                let cell = c < cells[r].count ? cells[r][c] : nil
                let startsGroup = c == 0 || ["<", "<>"].contains(groups[c]) || [">", "<>"].contains(groups[c - 1])
                let style = "OrgTblCell" + (starts || index == 0 ? "T" : "") + (ends ? "B" : "") + (startsGroup && c != 0 ? "L" : "")
                let paragraph = (header || c < headerColumns ? "OrgTableHeading" : "OrgTableContents") + ["l": "Left", "r": "Right", "c": "Center"][align[c]]!
                let span = width[c]
                row += "\n<table:table-cell table:style-name=\"\(style)\"\(span > 0 ? " table:number-columns-spanned=\"\(span + 1)\"" : "")>\n"
                row += "\n<text:p text:style-name=\"\(paragraph)\">\(cell.map { inline($0).trimmingCharacters(in: .whitespaces) } ?? "")</text:p>"
                row += "\n</table:table-cell>" + String(repeating: "\n<table:covered-table-cell/>", count: span) + "\n"
            }
            body += "\n<table:table-row>\n\(row)\n</table:table-row>"
            if ends { body += header ? "\n</table:table-header-rows>" : "\n</table:table-rows>" }
        }
        var style = "OrgTable"
        if attributeLine != nil {
            style = "OrgTable\(tableStyles.count + 1)"
            tableStyles.append((style, attributes["rel-width"] ?? "96"))
        }
        let firstRow = data.first.map { cells[$0] } ?? []
        let columnSpecs = firstRow.indices.map { c in
            String(repeating: "\n<table:table-column table:style-name=\"OrgTableColumn\"/>", count: (c < width.count ? width[c] : 0) + 1)
        }.joined(separator: "\n")
        var out = caption.map { "\n<text:p text:style-name=\"Table\">\($0)</text:p>" } ?? ""
        out += "\n<table:table table:style-name=\"\(style)\">" + columnSpecs + "\n" + body + "</table:table>"
        return "\n" + reopening(out)
    }

    /// `org-odt-format-label` as a definition: a bookmark, then the category, sequence number
    /// and caption; nil without a caption or name.
    private func label(_ key: Int, caption: String?) -> String? {
        guard let label = labels[key] else { return nil }
        let reference = label.reference ?? "nil"
        let category = ExportDictionary.translate(label.category, language: language, encoding: .utf8)
        let number = "<text:sequence text:ref-name=\"\(reference)\" text:name=\"\(label.variable)\" text:formula=\"ooow:\(label.variable)+1\" style:num-format=\"1\">\(label.sequence)</text:sequence>"
        let format = ExportDictionary.translate("%e %n: %c", language: language, encoding: .utf8)
        let text = format.replacingOccurrences(of: "%e", with: category).replacingOccurrences(of: "%n", with: number)
            .replacingOccurrences(of: "%c", with: caption.map(inlineString) ?? "")
        return "\n<text:bookmark text:name=\"\(reference)\"/>" + text
    }

    // MARK: - Blocks

    /// A block's type, parameters, its first line and its contents with their offset in the block.
    static func blockParts(_ node: SyntaxNode) -> (type: String, parameters: String, lines: [String], body: (text: String, offset: Int)) {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first, let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return ("", "", lines, ("", 0)) }
        let body = lines.dropFirst().dropLast().map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        return (m.1.lowercased(), String(m.2), lines, (body.joined(separator: "\n"), first.utf16.count + 1))
    }

    private func block(_ node: SyntaxNode) -> String {
        let (type, parameters, lines, body) = Self.blockParts(node)
        guard !lines.isEmpty, !type.isEmpty else { return "" }
        let key = base + node.range.lowerBound
        let unescaped = body.text.isEmpty && lines.count <= 2 ? [] : body.text.components(separatedBy: "\n")
        switch type {
        case "src":
            let caption = label(key, caption: affiliated["CAPTION"]).map { "\n<text:p text:style-name=\"Listing\">\($0)</text:p>" } ?? ""
            let attributes = affiliated["ATTR_ODT"].map(Self.attributes) ?? [:]
            let formatted = numbered(lines, Self.dedent(unescaped))
            if let textbox = attributes["textbox"], textbox != "nil" {
                return caption + "\n<text:p text:style-name=\"Text_20_body\">\(self.textbox(formatted, width: nil, height: nil, style: nil, extra: nil, anchor: nil))</text:p>"
            }
            return caption + formatted
        case "example":
            return numbered(lines, Self.dedent(unescaped))
        case "quote", "center":
            let saved = container
            container = type == "quote" ? .quote : .center
            defer { container = saved }
            return blocks(body.text, base: key + body.offset)
        case "verse":
            let rendered = unescaped.map { line -> String in
                inlineString(line, verse: true).replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            }
            var out = rendered.map { $0 + "<text:line-break/>" }.joined()
            if let indent = out.firstMatch(of: /^[ \t]+/) {
                out = Self.encodeSpaces(String(indent.output)) + out[indent.range.upperBound...]
            }
            return "\n<text:p text:style-name=\"OrgVerse\">\(out)</text:p>"
        case "export":
            return parameters.split(separator: " ").first?.lowercased() == "odt" ? Self.dedent(unescaped).joined(separator: "\n") : ""
        case "comment":
            return ""
        default:
            let attributes = affiliated["ATTR_ODT"].map(Self.attributes) ?? [:]
            let contents = blocks(body.text, base: key + body.offset)
            switch type {
            case "textbox":
                let size = { (key: String) in attributes[key].flatMap(Double.init) }
                return "\n<text:p text:style-name=\"Text_20_body\">\(textbox(contents, width: size("width"), height: size("height"), style: attributes["style"], extra: attributes["extra"], anchor: attributes["anchor"]))</text:p>"
            case "annotation":
                if attributes["date"] != nil || dated { return fail("ODT export doesn't support dated annotations") }
                let author = attributes["author"].map { Self.escape($0) } ?? author
                return "\n<text:p><office:annotation>\n\(author.map { "<dc:creator>\($0)</dc:creator>" } ?? "")\(contents)\n</office:annotation></text:p>"
            default:
                return contents
            }
        }
    }

    /// The code of a src or example block, labels and numbers as its switches ask.
    private func numbered(_ block: [String], _ body: [String]) -> String {
        let switches = Coderef.block(block)?.switches ?? Coderef.Switches(nil)
        let (lines, refs) = Coderef.unravel(body, format: switches.labelFormat)
        let key = block.joined(separator: "\n")
        let loc = blockLocs[key]?.isEmpty == false ? blockLocs[key]!.removeFirst() : nil
        return code(lines, refs: refs, retain: switches.retainLabels, loc: switches.numberLines == nil ? nil : loc)
    }

    /// `org-odt-do-format-code`: one paragraph per line, the last one styled apart.
    private func code(_ lines: [String], refs: [Int: String] = [:], retain: Bool = false, loc: Int? = nil, emptyLast: Bool = false) -> String {
        var lines = lines
        if emptyLast { lines.append("") }
        let out = lines.enumerated().map { index, line -> String in
            var text = line
            if let ref = refs[index + 1], retain { text += " (\(ref))" }
            var encoded = Self.escape(text, quotes: true).replacingOccurrences(of: " ", with: "<text:s/>").replacingOccurrences(of: "\t", with: "<text:tab/>")
            if let ref = refs[index + 1] { encoded = Self.target(encoded, "coderef-" + ref) }
            let paragraph = "\n<text:p text:style-name=\"OrgSrcBlock\(index == lines.count - 1 ? "LastLine" : "")\">\(encoded)</text:p>"
            return loc == nil ? paragraph : "\n<text:list-item>\(paragraph)\n</text:list-item>"
        }.joined()
        guard let loc else { return out }
        return "\n<text:list text:style-name=\"OrgSrcBlockNumberedLine\" text:continue-numbering=\"\(loc != 0)\">\(out)</text:list>"
    }

    static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }
    }

    // MARK: - Frames

    private var frameCount = 0

    /// `org-odt--frame`.
    private func frame(_ text: String, width: Double?, height: Double?, style: String?, extra: String?, anchor: String?) -> String {
        frameCount += 1
        var attributes = width.map { String(format: " svg:width=\"%0.2fcm\"", $0) } ?? ""
        attributes += height.map { String(format: " svg:height=\"%0.2fcm\"", $0) } ?? ""
        attributes += (extra ?? "") + " text:anchor-type=\"\(anchor ?? "paragraph")\" draw:name=\"Frame\(frameCount)\""
        return "\n<draw:frame draw:style-name=\"\(style ?? "nil")\"\(attributes)>\n\(text)\n</draw:frame>"
    }

    /// `org-odt--textbox`.
    private func textbox(_ text: String, width: Double?, height: Double?, style: String?, extra: String?, anchor: String?) -> String {
        let box = String(format: " fo:min-height=\"%0.2fcm\"", height ?? 0.2) + (width == nil ? String(format: " fo:min-width=\"%0.2fcm\"", 0.2) : "")
        return frame("\n<draw:text-box \(box)>\(text)\n</draw:text-box>", width: width, height: nil, style: style, extra: extra, anchor: anchor)
    }

    // MARK: - Images

    /// The paragraph holding the image being rendered, and its caption and attributes.
    private var imageKey: Int?
    private var imageCaptioned = false
    private var imageCaption: String?
    private var imageAttributes: String?

    /// A link's file, for `file:` links and paths Org reads as files.
    static func filePath(_ path: String) -> String? {
        var file: String
        if path.hasPrefix("file:") {
            file = String(path.dropFirst(5))
        } else if ["/", "./", "../", "~/"].contains(where: path.hasPrefix) {
            file = path
        } else {
            return nil
        }
        if let range = file.range(of: "::") { file = String(file[..<range.lowerBound]) }
        return file
    }

    static func isImage(_ file: String) -> Bool {
        file.range(of: "\\.(jpeg|jpg|png|gif|svg)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func expand(_ file: String, directory: URL) -> URL {
        let path = OrgPaths.expandingTilde(file)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path).standardizedFileURL
    }

    /// `org-odt-link--inline-image`: the file embedded under `Images/`, sized from its pixels
    /// at 96 dpi or `#+ATTR_ODT`, within 17 by 20 cm.
    private func image(_ file: String) -> String {
        let url = Self.expand(file, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return fail("Opening input file: No such file or directory, \(url.path)") }
        let ext = (file as NSString).pathExtension
        let name = String(format: "Images/%04d.%@", images.count + 1, ext)
        images.append((name, data))
        let attributes = imageAttributes.map(Self.attributes) ?? [:]
        let user = { (key: String) in attributes[key].flatMap(Double.init) }
        let scale = user("scale")
        let userWidth = scale == nil ? user("width") : nil
        let userHeight = scale == nil ? user("length") : nil
        var size = (width: 5.0, height: 5.0)
        if userWidth == nil || userHeight == nil {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = properties[kCGImagePropertyPixelWidth] as? Double, let h = properties[kCGImagePropertyPixelHeight] as? Double {
                size = (w / 96 * 2.54, h / 96 * 2.54)
            }
        }
        if let scale {
            size = (size.width * scale, size.height * scale)
        } else if let userWidth, let userHeight {
            size = (userWidth, userHeight)
        } else if let userHeight {
            size = (userHeight * size.width / size.height, userHeight)
        } else if let userWidth {
            size = (userWidth, userWidth * size.height / size.width)
        }
        if size.width > 17 || size.height > 20 {
            let factor = min(17 / size.width, 20 / size.height)
            size = (size.width * factor, size.height * factor)
        }
        let href = "\n<draw:image xlink:href=\"\(name)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"
        if !standalone, imageCaptioned { return fail("Don't know how to format label for an image inside text") }
        let caption = standalone ? imageKey.flatMap { label($0, caption: imageCaption) } : nil
        guard let caption else {
            return frame(href, width: size.width, height: size.height, style: standalone ? "OrgDisplayImage" : "OrgInlineImage", extra: nil, anchor: standalone ? "paragraph" : "as-char")
        }
        let inner = frame(href, width: size.width, height: size.height, style: "OrgCaptionedImage", extra: " style:rel-width=\"100%\" style:rel-height=\"scale\"", anchor: "paragraph")
        return textbox("\n<text:p text:style-name=\"Illustration\">\(inner)\(caption)</text:p>", width: size.width, height: size.height, style: "OrgImageCaptionFrame", extra: nil, anchor: "paragraph")
    }

    // MARK: - Inline

    func inline(_ node: SyntaxNode) -> String {
        afterFootnote = false
        var out = ""
        var text = ""
        for element in node.elements {
            switch element {
            case .token(let token):
                switch token.kind {
                case .marker, .stars, .bullet, .checkbox, .tags, .todoKeyword, .priority, .counter:
                    continue
                default:
                    text += token.text
                }
            case .node(let child):
                if !text.isEmpty { afterFootnote = false }
                out += plainText(text)
                text = ""
                out += object(child)
            }
        }
        if !text.isEmpty { afterFootnote = false }
        return out + plainText(text)
    }

    private var verse = false

    private func inlineString(_ text: String, verse: Bool) -> String {
        let saved = self.verse
        self.verse = verse
        defer { self.verse = saved }
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return Self.escape(text) }
        return rendering(tree, text) { inline(paragraph) }
    }

    static let textObjects = HTMLRenderer.textObjects

    /// `org-odt-plain-text`, with the LaTeX fragments, entities and scripts the parser leaves in
    /// text.
    private func plainText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in Self.textObjects.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = NSMaxRange(m.range)
            let whole = ns.substring(with: m.range)
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if group(1) != nil || group(2) != nil || group(3) != nil || group(4) != nil {
                if options.tex { out += "<text:span text:style-name=\"OrgCode\">\(Self.escape(whole))</text:span>" }
            } else if let name = group(5) {
                out += OrgEntities.display[name].map { Self.escape($0) } ?? plain(whole)
            } else if let marker = group(7), let body = group(8) {
                let braced = body.hasPrefix("{")
                if options.scripts == .off || (options.scripts == .braces && !braced) {
                    out += plain(whole)
                    continue
                }
                let inner = braced ? String(body.dropFirst().dropLast()) : body
                out += "<text:span text:style-name=\"\(marker == "_" ? "OrgSubscript" : "OrgSuperscript")\">\(plain(inner))</text:span>"
            } else {
                out += plain(whole)
            }
        }
        return out + plain(ns.substring(from: at))
    }

    /// Escaped text with special strings, its line breaks as spaces outside verse.
    private func plain(_ text: String) -> String {
        var out = Self.escape(text)
        if options.specialStrings {
            out = out.replacingOccurrences(of: "\\\\-", with: "&#x00ad;", options: .regularExpression)
                .replacingOccurrences(of: "---([^-])", with: "&#x2014;$1", options: .regularExpression)
                .replacingOccurrences(of: "--([^-])", with: "&#x2013;$1", options: .regularExpression)
                .replacingOccurrences(of: "...", with: "&#x2026;")
        }
        return verse ? out : out.replacingOccurrences(of: "\n", with: " ")
    }

    private func span(_ style: String, _ content: String) -> String {
        "<text:span text:style-name=\"\(style)\">\(content)</text:span>"
    }

    /// The previous object was a footnote reference, for the comma between two.
    private var afterFootnote = false

    private func object(_ node: SyntaxNode) -> String {
        defer { afterFootnote = node.kind == .footnoteReference && !tocEntry }
        switch node.kind {
        case .bold: return span("Bold", inline(node))
        case .italic: return span("Emphasis", inline(node))
        case .underline: return span("Underline", inline(node))
        case .strikeThrough: return span("Strikethrough", inline(node))
        case .verbatim, .code:
            let value = node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
            return span("OrgCode", Self.encodeSpaces(Self.escape(value)))
        case .link: return link(node)
        case .linkDescription: return inline(node)
        case .timestamp:
            let text = node.text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("<%%") { return plain(text) }
            return span(text.hasPrefix("<") ? "OrgActiveTimestamp" : "OrgInactiveTimestamp", plain(text))
        case .footnoteReference:
            if tocEntry { return "" }
            let comma = afterFootnote ? span("OrgSuperscript", ",") : ""
            return comma + footnote(node.text)
        case .entity:
            let name = node.text.dropFirst().replacingOccurrences(of: "{}", with: "")
            return OrgEntities.display[name].map { Self.escape($0) } ?? plain(node.text)
        case .radioTarget:
            let inner = plain(String(node.text.dropFirst(3).dropLast(3)))
            if tocEntry { return inner }
            return Self.target(inner, targets.first { $0.key == base + node.range.lowerBound }?.reference ?? "nil")
        case .target:
            if tocEntry { return "" }
            return Self.target("", targets.first { $0.key == base + node.range.lowerBound }?.reference ?? "nil")
        case .superscript, .subscript:
            let text = node.text
            let body = text.dropFirst()
            let braced = body.hasPrefix("{") && body.hasSuffix("}")
            if options.scripts == .off || (options.scripts == .braces && !braced) { return plain(text) }
            let inner = braced ? String(body.dropFirst().dropLast()) : String(body)
            return span(text.hasPrefix("_") ? "OrgSubscript" : "OrgSuperscript", plain(inner))
        case .lineBreak: return "<text:line-break/>"
        case .macro:
            guard case .some(let value) = source?.resultsMacro(node) else { return "" }
            return value.map(inlineString) ?? ""
        case .inlineSourceBlock:
            let exports = source?.exports(at: node.range.lowerBound) ?? "results"
            source?.inlineResults = exports == "results" || exports == "both"
            guard exports == "code" || exports == "both" else { return "" }
            // ox-odt has no transcoder for them.
            return fail("ODT export doesn't support inline source blocks")
        case .latexFragment:
            guard options.tex else { return "" }
            return span("OrgCode", Self.escape(node.text))
        case .statisticsCookie: return span("OrgCode", Self.escape(node.text))
        case .exportSnippet:
            guard node.tokens.first?.text.lowercased() == "@@odt:" else { return "" }
            return node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
        case .citation:
            if inTitle { return "" }
            guard let pieces = citations?.next(node.text) else { return plain(node.text) }
            return render(pieces)
        case .inlineBabelCall:
            source?.inlineResults = (source?.exports(at: node.range.lowerBound) ?? "results") == "results"
            return ""
        default: return inline(node)
        }
    }

    /// A citation's or a bibliography entry's pieces.
    private func render(_ pieces: [CiteProcessor.Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let s): plain(s)
            case .italic(let s): span("Emphasis", plain(s))
            case .org(let s) where s.allSatisfy(\.isWhitespace): s
            case .org(let s):
                String(s.prefix { $0.isWhitespace }) + inlineString(s) + String(s.reversed().prefix { $0.isWhitespace })
            }
        }.joined()
    }

    // MARK: - Footnotes

    private var footnoteNumbers: [String: Int] = [:]
    private var anonymous = 0

    private func footnote(_ text: String) -> String {
        guard let m = text.firstMatch(of: /^\[fn:([^:\]]*)(?::(.*))?\]$/) else { return plain(text) }
        var label = String(m.1)
        let inlineText = m.2.map(String.init)
        if label.isEmpty {
            anonymous += 1
            label = "anonymous-\(anonymous)"
        }
        if let n = footnoteNumbers[label] {
            return span("OrgSuperscript", "<text:note-ref text:note-class=\"footnote\" text:reference-format=\"text\" text:ref-name=\"fn\(n)\">\(n)</text:note-ref>")
        }
        let n = footnoteNumbers.count + 1
        footnoteNumbers[label] = n
        let saved = (paragraphStyles, container, frames, afterFootnote)
        paragraphStyles = ("Footnote", "OrgFootnoteCenter", "OrgFootnoteQuotations")
        container = nil
        frames = []
        defer { (paragraphStyles, container, frames, afterFootnote) = saved }
        let definition: String
        if let inlineText {
            definition = "\n<text:p text:style-name=\"Footnote\">\(inlineString(inlineText))</text:p>"
        } else if let found = definitions[label] {
            definition = blocks(found.text, base: found.base).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return fail("Definition not found for footnote \(m.1)")
        }
        return "<text:note text:id=\"fn\(n)\" text:note-class=\"footnote\"><text:note-citation>\(n)</text:note-citation><text:note-body>\(definition)</text:note-body></text:note>"
    }

    // MARK: - Links

    private enum Destination {
        case heading(Heading)
        case target(String)
        case element(Int)
    }

    private func titleWords(_ heading: Heading) -> [String] {
        let title = heading.info?.title ?? heading.node.firstChild(.title)?.text ?? ""
        return Self.words(title.replacingOccurrences(of: "\\[[0-9]*(%|/[0-9]*)\\]", with: " ", options: .regularExpression).uppercased())
    }

    /// `org-export-resolve-fuzzy-link`: a target or name first, else the last heading with the
    /// title.
    private func resolve(_ path: String) -> Destination? {
        let all = headingOrder.compactMap { headings[$0] }
        if path.hasPrefix("*") {
            let words = Self.words(String(path.dropFirst()).uppercased())
            return all.last { titleWords($0) == words }.map(Destination.heading)
        }
        if path.hasPrefix("#") {
            let id = String(path.dropFirst())
            return all.last { $0.info?.properties.last { $0.key.uppercased() == "CUSTOM_ID" }?.value == id }.map(Destination.heading)
        }
        let words = Self.words(path)
        let upper = words.map { $0.uppercased() }
        if let name = names.last(where: { $0.words == words }) { return .element(name.key) }
        if let target = targets.last(where: { $0.words == upper }) { return .target(target.reference) }
        if let name = names.last(where: { $0.words == upper }) { return .element(name.key) }
        return all.last { titleWords($0) == upper }.map(Destination.heading)
    }

    private func link(_ node: SyntaxNode) -> String {
        let path = node.tokens.first { $0.kind == .linkPath }?.text
        let descriptionNode = node.firstChild(.linkDescription)
        var description = descriptionNode.map(inline).flatMap { $0.isEmpty ? nil : $0 }
        // `org-export-insert-image-links`: a description that is an image's path shows it.
        let describedImage = descriptionNode.flatMap { Self.filePath($0.text.trimmingCharacters(in: .whitespaces).replacing(/^\[\[(.*)\]\]$/) { String($0.1) }) }.flatMap { Self.isImage($0) ? $0 : nil }
        if let describedImage, !tocEntry { description = image(describedImage) }
        guard let path else {
            // A radio link refers to its target.
            if !node.text.hasPrefix("<"), !node.text.contains(":") {
                let words = Self.words(node.text.uppercased())
                let text = plain(node.text)
                if tocEntry { return text }
                guard let target = targets.first(where: { $0.words == words }) else { return text }
                return "<text:bookmark-ref text:reference-format=\"text\" text:ref-name=\"OrgXref.\(target.reference)\">\(text)</text:bookmark-ref>"
            }
            var target = node.text
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            if tocEntry { return plain(target) }
            return external(target, description: nil)
        }
        if tocEntry { return description ?? plain(path) }
        if let file = Self.filePath(path) {
            if description == nil, Self.isImage(file) { return image(file) }
            let uri = file.hasPrefix("/") || file.hasPrefix("~") ? "file://" + OrgPaths.expandingTilde(file) : "../" + file
            return external(uri, description: description, image: describedImage != nil)
        }
        // A code reference: its line's number.
        if path.hasPrefix("("), path.hasSuffix(")"), path.count >= 2 {
            let name = String(path.dropFirst().dropLast())
            guard let resolved = documentTree.flatMap({ Coderef.resolve(name, in: $0) }) else { return fail("Unable to resolve code reference: \(name)") }
            guard Int(resolved) != nil else { return fail("ODT export only resolves code references to numbered lines: \(name)") }
            let reference = "<text:bookmark-ref text:reference-format=\"number\" text:ref-name=\"OrgXref.coderef-\(Self.escape(name, quotes: true))\">\(resolved)</text:bookmark-ref>"
            return Coderef.linkText(reference, description: description)
        }
        if let colon = path.firstIndex(of: ":"), Links.types.contains(String(path[..<colon])) {
            if path.hasPrefix("id:") {
                let id = String(path.dropFirst(3))
                guard let heading = headingOrder.compactMap({ headings[$0] }).first(where: { $0.info?.id == id }) else { return fail("Unable to resolve link: \"\(id)\"") }
                return toHeading(heading, description: description, customID: nil)
            }
            return external(path, description: description, image: describedImage != nil)
        }
        let search = path
        guard let destination = resolve(search) else { return fail("Unable to resolve link: \"\(search)\"") }
        switch destination {
        case .heading(let heading):
            return toHeading(heading, description: description, customID: search.hasPrefix("#") ? String(search.dropFirst()) : nil)
        case .target(let reference):
            guard let description else { return fail("ODT export doesn't number links to targets without a description: \(search)") }
            return "<text:a xlink:type=\"simple\" xlink:href=\"#\(reference)\">\(description)</text:a>"
        case .element(let key):
            guard let label = labels[key], let reference = label.reference else { return fail("FIXME: Unable to resolve \(search)") }
            guard let description else {
                return "<text:sequence-ref text:reference-format=\"value\" text:ref-name=\"\(reference)\">\(label.sequence)</text:sequence-ref>"
            }
            return "<text:a xlink:type=\"simple\" xlink:href=\"#\(reference)\">\(description)</text:a>"
        }
    }

    /// A hyperlink, a clickable image when the description is only an image link.
    private func external(_ target: String, description: String?, image: Bool = false) -> String {
        let href = Self.escape(target, quotes: true)
        if image, let description { return "\n<draw:a xlink:type=\"simple\" xlink:href=\"\(href)\">\n\(description)\n</draw:a>" }
        return "<text:a xlink:type=\"simple\" xlink:href=\"\(href)\">\(description ?? Self.escape(target))</text:a>"
    }

    /// A link to a heading: with a description, a hyperlink; without, its number or title.
    private func toHeading(_ heading: Heading, description: String?, customID: String?) -> String {
        if let description {
            return "<text:a xlink:type=\"simple\" xlink:href=\"#\(Self.escape(customID ?? heading.reference, quotes: true))\">\(description)</text:a>"
        }
        let chain = (heading.ancestors + [heading.key]).compactMap { headings[$0] }
        if chain.dropLast().contains(where: \.lowLevel) { return fail("ODT export doesn't number links to items under a heading deeper than H") }
        let regular = chain.reversed().first { !$0.lowLevel }
        if heading.number != nil, let numbered = chain.reversed().first(where: { !$0.lowLevel && $0.number != nil }) {
            return "<text:bookmark-ref text:reference-format=\"chapter\" text:ref-name=\"OrgXref.\(heading.reference)\">\(numbered.number!.map(String.init).joined(separator: "."))</text:bookmark-ref>"
        }
        guard let regular else { return fail("FIXME?") }
        let title = regular.node.firstChild(.title).map { inline($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return "<text:bookmark-ref text:reference-format=\"text\" text:ref-name=\"OrgXref.\(heading.reference)\">\(title)</text:bookmark-ref>"
    }

    // MARK: - Styles

    /// The automatic styles of tables with `#+ATTR_ODT`.
    func automaticStyles() -> String {
        tableStyles.map {
            "\n<style:style style:name=\"\($0.name)\" style:family=\"table\">\n  <style:table-properties style:rel-width=\"\($0.width)%\" fo:margin-top=\"0cm\" fo:margin-bottom=\"0.20cm\" table:align=\"center\"/>\n</style:style>\n"
        }.joined()
    }

    // MARK: - Text

    /// `:key value :other "quoted value"`.
    static func attributes(_ text: String) -> [String: String] {
        var pairs: [String: String] = [:]
        for m in text.matches(of: /:([A-Za-z_-]+)(?:[ \t]+("[^"]*"|[^:\s]\S*))?/) {
            var value = m.2.map(String.init) ?? "t"
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            pairs[m.1.lowercased()] = value
        }
        return pairs
    }

    /// `&`, `<`, `>` (and `"` with `quotes`) escaped, characters XML forbids removed.
    static func escape(_ s: String, quotes: Bool = false) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where quotes: out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(c)
            case _ where c.value < 0x20 || c.value == 0xFFFE || c.value == 0xFFFF: continue
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// `org-odt--encode-tabs-and-spaces`.
    static func encodeSpaces(_ s: String) -> String {
        s.replacing(/\t| {2,}/) { m in m.output == "\t" ? "<text:tab/>" : " <text:s text:c=\"\(m.output.count - 1)\"/>" }
    }

    /// Rendered markup without its elements, for `meta.xml`.
    static func stripped(_ xml: String) -> String {
        xml.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }
}
