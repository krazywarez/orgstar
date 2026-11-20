import Foundation

/// Plain text export as ox-ascii (Org 9.8.7) writes it under `emacs -Q`, in its `ascii`,
/// `latin1` or `utf-8` charset: a centered title block, a table of contents, underlined and
/// numbered headings, links described at the end of their section, footnotes at the end. What
/// it can't write as Emacs would throws `Unsupported`, naming the construct, instead of writing
/// something else.
public enum ASCIIExport {
    public typealias Unsupported = LaTeXExport.Unsupported

    /// `org-ascii-charset`.
    public enum Charset: String, Sendable, CaseIterable {
        case ascii, latin1
        case utf8 = "utf-8"
    }

    /// A `.txt` document, or with `bodyOnly` the text without the title block and contents.
    /// `author` stands for `user-full-name`, `language` for `org-export-default-language`.
    public static func document(
        _ text: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date(), charset: Charset = .ascii,
        bodyOnly: Bool = false, author: String = "", language: String = "en"
    ) throws -> String {
        let text = try LaTeXExport.expanded(text, settings: settings, path: path, now: now)
        let tree = OrgParser.parse(text, defaults: settings)
        let keywords = settings.setupKeywords.split(separator: "\n").map(String.init)
            + tree.root.descendants().filter { $0.kind == .keyword }.map { $0.text.trimmingCharacters(in: .newlines) }
        let renderer = try ASCIIRenderer(tree: tree, text: text, settings: settings, keywords: keywords, language: language, charset: charset)
        var output = try renderer.body()
        if !bodyOnly { output = try renderer.template(output, author: author) }
        return output.replacingOccurrences(of: ASCIIRenderer.hardNewline, with: "\n")
    }
}

final class ASCIIRenderer {
    typealias Unsupported = LaTeXExport.Unsupported
    typealias Inline = LaTeXRenderer.Inline

    enum Justify { case left, center, right }

    /// Where an element is: the text width `org-ascii--current-text-width` gives it and the
    /// justification of the blocks around it.
    struct Context {
        var width: Int
        var justify = Justify.left
    }

    /// `hard-newline`: a newline that ends a line when filling.
    static let hardNewline = ASCIIText.hardNewline + "\n"

    static let textWidth = 72
    static let innerMargin = 2
    static let quoteMargin = 6

    let tree: OrgTree
    let source: NSString
    let settings: OrgSettings
    let options: ExportOptions
    /// Keyword values by name, in order.
    let keywords: [String: [String]]
    let language: String
    let charset: ASCIIExport.Charset
    var utf8: Bool { charset == .utf8 }
    let numbered: Bool
    let num: Int?
    let withTOC: Bool
    let toc: Int?
    private var selected: Set<Int>?
    /// Added to heading levels.
    private var levelOffset = 0
    private var exportSource: ExportSource
    private let model: DocumentModel
    /// Section numbers of the numbered headings the export writes, by heading start.
    private var numbers: [Int: [Int]] = [:]
    /// The headings the export writes, by start, with their relative level.
    private var exported: [(start: Int, level: Int)] = []
    /// `:ascii-links-to-notes`, off in the title block and footnotes.
    private var linksToNotes = true

    init(tree: OrgTree, text: String, settings: OrgSettings, keywords lines: [String], language: String, charset: ASCIIExport.Charset) throws {
        self.tree = tree
        source = text as NSString
        self.settings = settings
        self.charset = charset
        exportSource = ExportSource(tree: tree, text: text)
        model = DocumentModel(tree: tree)
        var keywords: [String: [String]] = [:]
        for line in lines {
            guard let m = line.firstMatch(of: #/^[ \t]*#\+([^:\s]+):(?:[ \t]+(.*?))?[ \t]*$/#) else { continue }
            keywords[m.1.uppercased(), default: []].append(m.2.map(String.init) ?? "")
        }
        self.keywords = keywords
        options = ExportOptions.parse(lines.joined(separator: "\n"))
        self.language = keywords["LANGUAGE"]?.last ?? language

        // `#+OPTIONS` this export follows; any other item only at its default.
        let defaults = ["\\n": "nil", ":": "t", "*": "t", "e": "t", "f": "t", "|": "t", "p": "nil", "c": "nil", "prop": "nil",
                        "stat": "t", "tasks": "t", "inline": "t", "arch": "headline", "email": "nil", "creator": "nil",
                        "broken-links": "nil", "'": "nil", "d": "(not \"LOGBOOK\")", "expand-links": "t"]
        for (key, value) in options.items {
            if let standard = defaults[key], standard != value { throw Unsupported(reason: "#+OPTIONS: \(key):\(value)") }
        }
        let items = options.items
        func depth(_ key: String) throws -> (Bool, Int?) {
            guard let v = items[key] else { return (true, nil) }
            if v == "nil" { return (false, nil) }
            if v == "t" { return (true, nil) }
            guard let n = Int(v) else { throw Unsupported(reason: "#+OPTIONS: \(key):\(v)") }
            return (true, n)
        }
        (numbered, num) = try depth("num")
        (withTOC, toc) = try depth("toc")
        if let tex = items["tex"], tex != "t", tex != "nil" { throw Unsupported(reason: "#+OPTIONS: tex:\(tex)") }
        for key in ["CITE_EXPORT", "BIBLIOGRAPHY", "PRINT_BIBLIOGRAPHY", "CALL"] where keywords[key] != nil {
            throw Unsupported(reason: "#+\(key)")
        }
        // Radio links: links that are only words.
        if tree.root.descendants().contains(where: { $0.kind == .link && !$0.tokens.contains { $0.kind == .linkPath } && !$0.text.hasPrefix("<") && !$0.text.contains(":") }) {
            throw Unsupported(reason: "Radio targets")
        }
        let kinds = Set(tree.root.descendants().map(\.kind))
        for (kind, name) in [(SyntaxKind.radioTarget, "Radio targets"), (.citation, "Citations"), (.inlineTask, "Inline tasks"),
                             (.inlineSourceBlock, "Inline source blocks"), (.inlineBabelCall, "Inline calls"), (.tableEl, "table.el tables"),
                             (.diarySexp, "Diary sexps")] where kinds.contains(kind) {
            throw Unsupported(reason: name)
        }
        // Emacs measures text in columns, where these take two or none.
        if text.unicodeScalars.contains(where: Self.isWideOrZeroWidth) { throw Unsupported(reason: "Wide or combining characters") }
        // Tabs fill and align by column; in code they are copied.
        let code = tree.root.descendants().filter { $0.kind == .block && $0.text.firstMatch(of: /^[ \t]*#\+(?i:begin_(?:src|example))\b/) != nil }.map(\.range)
        if Array(text.utf16).enumerated().contains(where: { offset, unit in unit == 9 && !code.contains { $0.contains(offset) } }) {
            throw Unsupported(reason: "Tabs outside code")
        }
        // A definition goes on to the next one, a heading or two blank lines.
        for node in tree.root.descendants() where node.kind == .footnoteDefinition {
            guard let parent = node.parent, let index = parent.children.firstIndex(where: { $0.range == node.range }), index + 1 < parent.children.count else { continue }
            let next = parent.children[index + 1]
            let gap = (text as NSString).substring(with: NSRange(location: node.range.lowerBound, length: next.range.lowerBound - node.range.lowerBound))
            if next.kind != .footnoteDefinition, next.kind != .section, !gap.hasSuffix("\n\n\n") {
                throw Unsupported(reason: "Footnote definitions of several paragraphs")
            }
        }
        for heading in model.headings {
            let keys = heading.properties.map { $0.key.uppercased() }
            if keys.contains("UNNUMBERED") || keys.contains("ALT_TITLE") { throw Unsupported(reason: "UNNUMBERED and ALT_TITLE properties") }
        }
        selected = HTMLRenderer.selection(tree, tags: options.selectTags)
        let options = options
        let selected = selected
        let top = tree.root.children.compactMap { $0.kind == .section ? $0.firstChild(.heading) : nil }
            .filter { HTMLRenderer.sectionExport($0, options: options, selected: selected) != .nothing }
        levelOffset = 1 - (top.compactMap { $0.tokens.first { $0.kind == .stars }?.text.count }.min() ?? 1)
        collectHeadings(tree.root.children)
    }

    static func isWideOrZeroWidth(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        case 0x200B...0x200F, 0xFE00...0xFE0F:
            return true
        default:
            return s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .enclosingMark
        }
    }

    /// `org-export--collect-headline-numbering` over the headings the export writes.
    private func collectHeadings(_ nodes: [SyntaxNode]) {
        var counters: [Int] = []
        func walk(_ nodes: [SyntaxNode]) {
            for node in nodes where node.kind == .section {
                guard let heading = node.firstChild(.heading), !isFootnoteSection(heading) else { continue }
                let export = HTMLRenderer.sectionExport(heading, options: options, selected: selected)
                if export == .nothing { continue }
                let level = self.level(heading)
                exported.append((heading.range.lowerBound, level))
                if isNumbered(level) {
                    while counters.count < level { counters.append(0) }
                    counters[level - 1] += 1
                    for deeper in level..<counters.count { counters[deeper] = 0 }
                    numbers[heading.range.lowerBound] = Array(counters.prefix(level))
                }
                if export == .all { walk(node.children) }
            }
        }
        walk(nodes)
    }

    private func isFootnoteSection(_ heading: SyntaxNode) -> Bool { heading.firstChild(.title)?.text == "Footnotes" }

    private func level(_ heading: SyntaxNode) -> Int {
        (heading.tokens.first { $0.kind == .stars }?.text.count ?? 1) + levelOffset
    }

    private func isNumbered(_ level: Int) -> Bool { numbered && (num.map { level <= $0 } ?? true) }

    // MARK: - Template

    /// `org-ascii-template`: the title block and table of contents before `body`.
    func template(_ body: String, author: String) throws -> String {
        var out = try titleBlock(author: author)
        if withTOC { out += try tableOfContents(depth: toc, width: Self.textWidth, keyword: false) + "\n\n\n" }
        return out + body
    }

    /// `org-ascii-template--document-title`.
    private func titleBlock(author defaultAuthor: String) throws -> String {
        let width = Self.textWidth
        linksToNotes = false
        defer { linksToNotes = true }
        let title = options.title ? try keywords["TITLE"].map(parsed) ?? "" : ""
        let subtitle = options.title ? try keywords["SUBTITLE"].map(parsed) ?? "" : ""
        var author: String?
        if options.author { author = try keywords["AUTHOR"].map(parsed) ?? (defaultAuthor.isEmpty ? nil : try inlineString(defaultAuthor)) }
        let date = options.date ? try keywords["DATE"].map(parsed) : nil
        func nw(_ s: String?) -> String? { s.flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil } }
        if title.isEmpty {
            switch (nw(date), nw(author)) {
            case (let date?, let author?):
                return author + String(repeating: " ", count: max(0, width - date.count - author.count)) + date + "\n\n\n"
            case (let date?, nil):
                return Self.justifyLines(date, width: width, .right) + "\n\n\n"
            case (nil, let author?):
                return author + "\n\n\n"
            default:
                return ""
            }
        }
        let titleLength = min((title + "\n" + subtitle).components(separatedBy: "\n").map(\.count).max() ?? 0, 2 * width / 3)
        let formattedTitle = ASCIIText.fill(title, width: titleLength)
        let formattedSubtitle = nw(subtitle).map { ASCIIText.fill($0, width: titleLength) }
        let line = String(repeating: utf8 ? "━" : "_", count: min(max(titleLength, author?.count ?? 0) + 2, width))
        var block = line + "\n" + (utf8 ? "" : "\n") + formattedTitle.uppercased()
        if let formattedSubtitle { block += "\n" + formattedSubtitle }
        if let author = nw(author) { block += "\n\n" + author }
        block += "\n" + line
        if let date = nw(date) { block += "\n\n\n" + date }
        return Self.justifyLines(block + "\n\n\n", width: width, .center)
    }

    /// A keyword parsed as Org text, its lines joined with spaces.
    private func parsed(_ values: [String]) throws -> String {
        if values.count > 1, values.contains("") { throw Unsupported(reason: "Repeated keywords with an empty value") }
        return try inlineString(values.joined(separator: " "))
    }

    /// `org-ascii--build-toc` over the whole document.
    private func tableOfContents(depth: Int?, width: Int, keyword: Bool) throws -> String {
        let title = translate("Table of Contents")
        var out = title + "\n" + String(repeating: utf8 ? "─" : "_", count: title.count) + "\n\n"
        let limit = min(depth ?? options.headlineLevels, options.headlineLevels)
        var lines: [String] = []
        for (start, level) in exported where level <= limit {
            guard let heading = tree.root.descendants().first(where: { $0.kind == .heading && $0.range.lowerBound == start }) else { continue }
            let indent = (level - 1) * 3
            let prefix = indent == 0 ? "" : String(repeating: ".", count: indent - 1) + " "
            lines.append(prefix + (try buildTitle(heading, width: width - indent, underline: false, notags: !options.tags || !options.tagsInTOC, toc: true)))
        }
        out += lines.joined(separator: "\n")
        _ = keyword
        return out
    }

    // MARK: - Strings

    /// `org-ascii--translate`.
    func translate(_ term: String) -> String {
        ExportDictionary.translate(term, language: language, encoding: utf8 ? .utf8 : charset == .latin1 ? .latin1 : .ascii)
    }

    /// `org-ascii--justify-lines`: each line centered or flushed right in `width`. `tabs`
    /// indents as `fill-region` does, with tabs where they fit.
    static func justifyLines(_ s: String, width: Int, _ how: Justify, tabs: Bool = false) -> String {
        guard how != .left else { return s }
        return s.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !trimmed.isEmpty else { return trimmed }
            let room = width - trimmed.count
            let indent = max(0, how == .center ? room / 2 : room)
            return (tabs ? Self.indentation(indent) : String(repeating: " ", count: indent)) + trimmed
        }.joined(separator: "\n")
    }

    /// `org-ascii--justify-element` for anything but a paragraph: the lines moved as a block
    /// so the widest is centered or flushed right.
    static func justifyBlock(_ s: String, context: Context) -> String {
        guard context.justify != .left, s.contains(where: { !$0.isWhitespace }) else { return s }
        let lines = s.components(separatedBy: "\n")
        var widest = 0
        for line in lines where line.contains(where: { $0 != " " && $0 != "\t" }) {
            if line.count >= context.width { return s }
            widest = max(widest, line.count)
        }
        let offset = (context.width - widest) / (context.justify == .right ? 1 : 2)
        guard offset > 0 else { return s }
        return lines.map { line in
            line.contains(where: { $0 != " " && $0 != "\t" }) ? indentation(offset) + line : line
        }.joined(separator: "\n")
    }

    /// `indent-to` from the line start with `indent-tabs-mode`.
    static func indentation(_ columns: Int) -> String {
        String(repeating: "\t", count: columns / 8) + String(repeating: " ", count: columns % 8)
    }

    /// `org-ascii--box-string`.
    func box(_ s: String) -> String {
        let body = s.replacing(#/\n[ \t]*\z/#, with: "")
        let bar = utf8 ? "│ " : "| "
        // `replace-regexp-in-string' finds no line start in the empty string.
        let lines = body.isEmpty ? "" : body.components(separatedBy: "\n").map { bar + $0 }.joined(separator: "\n")
        return utf8 ? "┌────\n" + lines + "\n└────" : ",----\n" + lines + "\n`----"
    }

    /// `org-element-normalize-string`.
    static func normalize(_ s: String) -> String { LaTeXRenderer.normalize(s) }

    /// The headline and section filter: whatever blank lines end `s`, two.
    static func spaced(_ s: String) -> String {
        var end = s.endIndex
        var cut: String.Index?
        while end > s.startIndex {
            let before = s.index(before: end)
            if s[before] == " " || s[before] == "\t" {
                end = before
            } else if s[before] == "\n" {
                end = before
                cut = before
            } else {
                break
            }
        }
        guard let cut else { return s }
        return String(s[..<cut]) + "\n\n\n"
    }

    // MARK: - Document

    /// The transcoded document with its footnotes, `org-ascii-inner-template`.
    func body() throws -> String {
        var nodes = tree.root.children
        // With a select tag, the text before the first heading isn't exported.
        if selected != nil { nodes.removeAll { $0.kind == .zerothSection } }
        var out = ""
        for node in nodes {
            if node.kind == .zerothSection {
                out += try section(node.children, end: node.range.upperBound, heading: nil)
            } else if node.kind == .section {
                out += try headline(node) ?? ""
            }
        }
        out = Self.normalize(out)
        let notes = try footnotes()
        if !notes.isEmpty {
            let title = translate("Footnotes")
            out += "\n\n\n" + title + "\n" + String(repeating: utf8 ? "─" : "_", count: title.count) + "\n\n" + notes
        }
        return Self.normalize(out)
    }

    /// Blank lines at the end of `source[from..<to]`.
    func blankLines(from: Int, to: Int) -> Int {
        guard to > from else { return 0 }
        let source = currentSource ?? self.source
        let lines = source.substring(with: NSRange(location: from, length: min(to, source.length) - from)).components(separatedBy: "\n").dropLast()
        return lines.reversed().prefix { $0.allSatisfy { $0 == " " || $0 == "\t" } }.count
    }

    /// The text being transcoded when it isn't the document: a block's contents.
    private var currentSource: NSString?

    /// A section's elements as `org-ascii-section` writes them, the section filter applied: its
    /// contents indented under a heading, then for the text before the first heading the
    /// links it holds. `heading` is the relative level of the heading above, nil for none.
    private func section(_ nodes: [SyntaxNode], end: Int, heading: Int?) throws -> String {
        let low = heading.map { $0 > options.headlineLevels }
        let width = Self.textWidth - (heading.map { $0 > options.headlineLevels ? ($0 - options.headlineLevels) * 2 : Self.innerMargin } ?? 0)
        let linkStart = noted.count
        var contents = try elements(nodes, end: end, context: Context(width: width))
        if heading == nil {
            let links = describeLinks(from: linkStart, width: width)
            if !links.isEmpty { contents = Self.normalize(contents) + "\n\n" + links }
        }
        if heading != nil, low == false { contents = ASCIIText.indent(contents, Self.innerMargin) }
        return Self.spaced(Self.normalize(contents))
    }

    /// `org-ascii-headline`, the headline filter applied; nil when not exported.
    private func headline(_ node: SyntaxNode) throws -> String? {
        guard let heading = node.firstChild(.heading), !isFootnoteSection(heading) else { return nil }
        let export = HTMLRenderer.sectionExport(heading, options: options, selected: selected)
        if export == .nothing { return nil }
        let level = self.level(heading)
        let low = level > options.headlineLevels ? level - options.headlineLevels : nil
        let width = Self.textWidth - (low.map { $0 * 2 } ?? 0)
        let linkStart = noted.count
        let title = try buildTitle(heading, width: width, underline: low == nil, notags: false, toc: false)
        var body = ""
        if export == .all {
            let children = node.children.filter { $0.kind != .heading }
            let elements = children.filter { $0.kind != .section }
            let subsections = children.filter { $0.kind == .section }
            var sectionText: String?
            if !elements.isEmpty {
                let end = subsections.first?.range.lowerBound ?? node.range.upperBound
                sectionText = try section(elements, end: end, heading: level)
            }
            let links = describeLinks(from: linkStart, width: width)
            let sub = try subsections.compactMap { try headline($0) }.joined()
            if links.isEmpty {
                body = (sectionText ?? "") + sub
            } else {
                body = (sectionText.map { Self.normalize($0) + "\n\n" } ?? "") + links + sub
            }
        } else {
            _ = describeLinks(from: linkStart, width: width)
        }
        let out: String
        if let low {
            let bullets: [Character] = switch charset {
            case .ascii: ["*", "+", "-"]
            case .latin1: ["§", "¶"]
            case .utf8: ["◊"]
            }
            let bullet = "\(bullets[(low - 1) % bullets.count]) "
            out = bullet + title + "\n\n" + ASCIIText.indent(body, bullet.count)
        } else {
            out = title + "\n\n" + body
        }
        return Self.spaced(Self.normalize(out))
    }

    /// `org-ascii--build-title` for a heading.
    private func buildTitle(_ heading: SyntaxNode, width: Int, underline: Bool, notags: Bool, toc: Bool) throws -> String {
        let tokens = heading.tokens
        let level = self.level(heading)
        var first = ""
        if let number = numbers[heading.range.lowerBound] {
            first += toc ? "\(number.last!). " : number.map(String.init).joined(separator: ".") + " "
        }
        if options.todo, let todo = tokens.first(where: { $0.kind == .todoKeyword })?.text { first += plainText(todo) + " " }
        if options.priority, let priority = tokens.first(where: { $0.kind == .priority })?.text, let letter = priority.firstMatch(of: /\[#(.+)\]/)?.1 {
            first += "(#\(letter)) "
        }
        let titleNode = heading.firstChild(.title)
        if titleNode?.descendants().contains(where: { $0.kind == .footnoteReference }) == true { throw Unsupported(reason: "Footnotes in headings") }
        first += try titleText(heading, toc: toc)
        var out = first
        if !notags, options.tags, let tags = tokens.first(where: { $0.kind == .tags })?.text {
            let names = tags.split(separator: ":").map(String.init)
            if !names.isEmpty {
                let tagString = ":" + names.joined(separator: ":") + ":"
                let column = max(width - (first.count + 1), tagString.count)
                out += " " + String(repeating: " ", count: column - tagString.count) + tagString
            }
        }
        let underlines: [Character] = switch charset {
        case .ascii, .latin1: ["=", "~", "-"]
        case .utf8: ["═", "─", "╌", "┄", "┈"]
        }
        if underline, level <= underlines.count {
            out += "\n" + String(repeating: underlines[level - 1], count: first.count)
        }
        return out
    }

    /// A heading's title transcoded and trimmed, once: links in it are noted where it is first
    /// written.
    private func titleText(_ heading: SyntaxNode, toc: Bool) throws -> String {
        if let cached = titles[heading.range.lowerBound] { return cached }
        let text = try heading.firstChild(.title).map { LaTeXRenderer.trim(try transcode(inlineItems($0))) } ?? ""
        titles[heading.range.lowerBound] = text
        return text
    }

    private var titles: [Int: String] = [:]

    // MARK: - Elements

    /// Affiliated keywords of the element being transcoded.
    typealias Affiliated = LaTeXRenderer.Affiliated

    private func blockType(_ node: SyntaxNode) -> String {
        node.text.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)/).map { $0.1.lowercased() } ?? ""
    }

    /// `elements`, each `org-element-normalize-string`'d and followed by its blank lines, as
    /// `org-export-data` joins a greater element's contents.
    /// `firstParagraph` says which paragraph's first line follows a bullet; `written` hears
    /// what each element wrote.
    func elements(
        _ nodes: [SyntaxNode], end: Int, context: Context,
        firstParagraph: ((SyntaxNode) -> Bool)? = nil, written: ((SyntaxNode, String) -> Void)? = nil
    ) throws -> String {
        var out = ""
        var affiliated = Affiliated()
        // The element before and its blank lines, which a comment after it may add to; they
        // show only when it wrote something.
        var pendingBlank = 0
        var previous: SyntaxNode?
        var previousWrote = false
        var afterSrc = false
        for (index, node) in nodes.enumerated() {
            let next = index + 1 < nodes.count ? nodes[index + 1].range.lowerBound : end
            if node.kind == .affiliatedKeyword {
                let line = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let m = line.firstMatch(of: /^#\+([A-Za-z_]+)(\[[^\]]*\])?:[ \t]*(.*)$/) else { continue }
                let key = m.1.uppercased()
                if m.2 != nil, key != "CAPTION", key != "RESULTS" { throw Unsupported(reason: "#+\(key)[…]") }
                switch key {
                case "CAPTION":
                    if m.2 != nil { throw Unsupported(reason: "Short captions") }
                    affiliated.caption.append(String(m.3))
                case "NAME": affiliated.name = String(m.3)
                case "ATTR_ASCII": affiliated.attr.append(String(m.3))
                case "RESULTS": affiliated.results = String(m.3)
                default: break
                }
                continue
            }
            defer { affiliated = Affiliated() }
            // `org-babel-exp-process-buffer`: a src block's results go, and with `:exports none`
            // the block too, as if they had never been there.
            if node.kind == .block, blockType(node) == "src" {
                let exports = exportSource.exports(at: node.range.lowerBound) ?? "code"
                if exports != "code", exports != "none" { throw Unsupported(reason: ":exports \(exports)") }
                afterSrc = true
                if exports == "none" { continue }
            } else if let results = affiliated.results {
                if afterSrc {
                    afterSrc = false
                    continue
                }
                if results.isEmpty { throw Unsupported(reason: "#+RESULTS without a source block") }
                if affiliated.name == nil { affiliated.name = results }
            } else {
                afterSrc = false
            }
            if node.kind == .comment || (node.kind == .block && blockType(node) == "comment") {
                // `org-export--skip-p`: the element before keeps at least one blank line.
                if previous != nil {
                    let blank = max(pendingBlank, blankLines(from: node.range.lowerBound, to: next), 1)
                    if previousWrote { out += String(repeating: "\n", count: blank - pendingBlank) }
                    pendingBlank = blank
                }
                continue
            }
            let result: String?
            if node.kind == .paragraph, let firstParagraph {
                result = try paragraph(node, context: context, ignoreFirst: firstParagraph(node))
            } else {
                result = try element(node, affiliated: affiliated, context: context)
            }
            guard let result else {
                if !pruned(node) {
                    previous = node
                    previousWrote = false
                    pendingBlank = blankLines(from: node.range.lowerBound, to: next)
                }
                continue
            }
            previous = node
            previousWrote = true
            pendingBlank = blankLines(from: node.range.lowerBound, to: next)
            written?(node, result)
            out += Self.normalize(result) + String(repeating: "\n", count: pendingBlank)
        }
        return out
    }

    /// Elements `org-export--prune-tree` takes out of the tree.
    private func pruned(_ node: SyntaxNode) -> Bool {
        switch node.kind {
        case .planning, .propertyDrawer, .clock: return true
        case .drawer: return drawerName(node).uppercased() == "LOGBOOK"
        case .latexEnvironment: return !options.tex
        default: return false
        }
    }

    private func drawerName(_ node: SyntaxNode) -> String {
        node.text.firstMatch(of: /^[ \t]*:([\w-]+):/).map { String($0.1) } ?? ""
    }

    /// One element's transcoding, nil for none.
    private func element(_ node: SyntaxNode, affiliated: Affiliated, context: Context) throws -> String? {
        switch node.kind {
        case .paragraph:
            return try paragraph(node, context: context, ignoreFirst: false)
        case .plainList:
            return try list(node, context: context)
        case .table:
            return try table(node, affiliated: affiliated, context: context)
        case .block:
            return try block(node, affiliated: affiliated, context: context)
        case .fixedWidth:
            let lines = node.text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix(": ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(1))
            }
            return Self.justifyBlock(box(try LaTeXRenderer.removeIndentation(lines.joined(separator: "\n"))), context: context)
        case .horizontalRule:
            let width = affiliated.value("width").flatMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil } ?? context.width
            return Self.justifyLines(String(repeating: utf8 ? "―" : "-", count: width), width: context.width, .center)
        case .drawer:
            if drawerName(node).uppercased() == "LOGBOOK" { return nil }
            guard hasContents(node.children) else { return nil }
            return Self.normalize(try elements(node.children, end: node.range.upperBound, context: context))
        case .dynamicBlock:
            let lines = node.text.components(separatedBy: "\n")
            return try blockContents(Array(lines.dropFirst().dropLast(2)), context: context)
        case .latexEnvironment:
            guard options.tex else { return nil }
            return Self.justifyBlock(try LaTeXRenderer.removeIndentation(node.text), context: context)
        case .keyword:
            return try keyword(node, context: context)
        case .planning, .propertyDrawer, .clock, .footnoteDefinition:
            return nil
        default:
            throw Unsupported(reason: "\(node.kind)")
        }
    }

    /// Whether `nodes` hold an element the export keeps.
    private func hasContents(_ nodes: [SyntaxNode]) -> Bool {
        nodes.indices.contains { index in
            let node = nodes[index]
            switch node.kind {
            case .comment: return false
            case .affiliatedKeyword:
                // Org parses affiliated keywords with no element right after them as keywords.
                var last = index
                while last + 1 < nodes.count, nodes[last + 1].kind == .affiliatedKeyword,
                      nodes[last].range.upperBound == nodes[last + 1].range.lowerBound { last += 1 }
                return last + 1 == nodes.count || nodes[last].range.upperBound != nodes[last + 1].range.lowerBound
            case .block:
                let type = blockType(node)
                if type == "comment" { return false }
                if type == "src", exportSource.exports(at: node.range.lowerBound) == "none" { return false }
                return !isResults(node)
            default: return !pruned(node)
            }
        }
    }

    private func keyword(_ node: SyntaxNode, context: Context) throws -> String? {
        guard let m = node.text.firstMatch(of: /^[ \t]*#\+([^:\s]+):[ \t]*(.*?)[ \t]*\n?$/) else { return nil }
        let value = String(m.2)
        switch m.1.uppercased() {
        case "ASCII":
            return Self.justifyBlock(value, context: context)
        case "TOC":
            guard value.range(of: "\\bheadlines\\b", options: [.regularExpression, .caseInsensitive]) != nil else {
                throw Unsupported(reason: "#+TOC: \(value)")
            }
            if value.range(of: "\\blocal\\b|:target", options: [.regularExpression, .caseInsensitive]) != nil { throw Unsupported(reason: "#+TOC: \(value)") }
            let depth = value.firstMatch(of: /\b([0-9]+)\b/).flatMap { Int($0.1) }
            return Self.justifyBlock(try tableOfContents(depth: depth, width: context.width, keyword: true), context: context)
        default:
            return nil
        }
    }

    // MARK: Paragraphs

    private func paragraph(_ node: SyntaxNode, context: Context, ignoreFirst: Bool, prefix: String = "") throws -> String {
        // `:with-timestamps` decides on timestamps alone in a paragraph.
        isolatedTimestamps = ASCIIText.isolatedTimestamps(node)
        defer { isolatedTimestamps = false }
        let items = LaTeXRenderer.normalizeIndentation(inlineItems(node), ignoreFirst: ignoreFirst)
        // `org-remove-blank-lines`, whose newline isn't a hard one.
        let contents = (prefix + (try transcode(items))).replacing(#/\x{1}?\n(?:[ \t]*\x{1}?\n)+/#, with: "\n")
        guard contents.contains(where: { !$0.isWhitespace && $0 != "\u{1}" }) else { return contents }
        return Self.fill(contents.replacingOccurrences(of: Self.hardNewline, with: ASCIIText.hardNewline), context: context)
    }

    /// `org-ascii--fill-string` with the context's justification.
    static func fill(_ s: String, context: Context) -> String {
        let filled = ASCIIText.fill(s, width: context.width)
        return justifyLines(filled, width: context.width, context.justify, tabs: true)
    }

    // MARK: Lists

    private func list(_ node: SyntaxNode, context: Context) throws -> String {
        let items = node.children.filter { $0.kind == .item }
        guard let first = items.first else { return "" }
        let firstBullet = (first.tokens.first { $0.kind == .bullet }?.text ?? "-").trimmingCharacters(in: .whitespaces)
        let ordered = firstBullet.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        let descriptive = !ordered && first.firstChild(.itemTag) != nil
        var out = ""
        var number = 0
        for (index, item) in items.enumerated() {
            let next = index + 1 < items.count ? items[index + 1].range.lowerBound : node.range.upperBound
            let bulletText = (item.tokens.first { $0.kind == .bullet }?.text ?? "-").trimmingCharacters(in: .whitespaces)
            let checkbox: String = switch item.tokens.first(where: { $0.kind == .checkbox })?.text.uppercased() {
            case "[X]"?: utf8 ? "☑ " : "[X] "
            case "[ ]"?: utf8 ? "☐ " : "[ ] "
            case "[-]"?: utf8 ? "☒ " : "[-] "
            default: ""
            }
            let bullet: String
            if descriptive {
                let tag = try item.firstChild(.itemTag).map { LaTeXRenderer.trim(try transcode(inlineItems($0))) } ?? ""
                bullet = checkbox + tag
            } else if ordered {
                if let counter = item.tokens.first(where: { $0.kind == .counter })?.text {
                    guard let n = Int(counter.trimmingCharacters(in: CharacterSet(charactersIn: "[@] "))) else { throw Unsupported(reason: "Alphabetical counters") }
                    number = n
                } else {
                    number += 1
                }
                bullet = bulletText.replacing(/[0-9A-Za-z]+/, with: String(number)) + " "
            } else {
                bullet = utf8 ? (["-": "• ", "+": "⁃ ", "*": "‣ "][bulletText] ?? bulletText + " ") : bulletText + " "
            }
            let indentation = descriptive ? Self.quoteMargin : bullet.count
            let inner = Context(width: context.width - (descriptive ? Self.quoteMargin : bullet.count + checkbox.count), justify: context.justify)
            let children = item.children.filter { $0.kind != .itemTag }
            if children.isEmpty { throw Unsupported(reason: "Empty list items") }
            let bulletLine = source.lineRange(for: NSRange(location: item.range.lowerBound, length: 0))
            var firstWriter: SyntaxNode?
            let contents = try elements(children, end: item.range.upperBound, context: inner, firstParagraph: { paragraph in
                paragraph.range == children[0].range && paragraph.range.lowerBound < NSMaxRange(bulletLine)
            }, written: { node, text in
                if firstWriter == nil, text.contains(where: { !$0.isWhitespace }) { firstWriter = node }
            })
            if children.contains(where: { $0.kind == .affiliatedKeyword }) { throw Unsupported(reason: "Affiliated keywords in list items") }
            let indented = ASCIIText.indent(children.isEmpty ? "" : Self.normalize(contents), indentation)
            var text = bullet + checkbox
            if !descriptive, indented.contains(where: { !$0.isWhitespace }), firstWriter?.kind == .paragraph {
                text += LaTeXRenderer.trim(indented)
            } else {
                text += "\n" + indented
            }
            out += Self.normalize(text) + String(repeating: "\n", count: blankLines(from: item.range.lowerBound, to: next))
        }
        return out
    }

    // MARK: Tables

    private func table(_ node: SyntaxNode, affiliated: Affiliated, context: Context) throws -> String {
        let rows = node.children.filter { $0.kind == .tableRow }
        // Each row's cells, nil for a rule.
        let raw: [[SyntaxNode]?] = rows.map { row in
            let cells = row.children.filter { $0.kind == .tableCell }
            return cells.isEmpty ? nil : cells
        }
        let cookie = /^<[lrc]?[0-9]*>$/
        func value(_ cell: SyntaxNode) -> String { cell.text.trimmingCharacters(in: CharacterSet(charactersIn: " |\n")) }
        // Rows of only alignment cookies and empty cells.
        let special = raw.map { cells -> Bool in
            guard let cells else { return false }
            let values = cells.map(value)
            return values.contains { $0.wholeMatch(of: cookie) != nil } && values.allSatisfy { $0.isEmpty || $0.wholeMatch(of: cookie) != nil }
        }
        for cells in raw.compactMap({ $0 }) {
            let first = value(cells[0])
            if first == "/" || ["#", "!", "$", "*", "_", "^"].contains(first) { throw Unsupported(reason: "Tables with special columns or column groups") }
        }
        // Transcoded cells.
        var data: [[String]?] = []
        for (r, cells) in raw.enumerated() {
            guard let cells, !special[r] else { data.append(nil); continue }
            data.append(try cells.map { try LaTeXRenderer.trim(transcode(inlineItems($0, trimmed: true))) })
        }
        let columns = raw.compactMap { $0?.count }.max() ?? 0
        var widths = Array(repeating: 0, count: columns)
        var cookieWidth = Array(repeating: Int?.none, count: columns)
        var cookieAlign = Array(repeating: String?.none, count: columns)
        for (r, cells) in raw.enumerated() where special[r] {
            for (c, cell) in cells!.enumerated() {
                guard let m = value(cell).wholeMatch(of: /<([lrc])?([0-9]+)?>/) else { continue }
                if let w = m.2.flatMap({ Int($0) }), cookieWidth[c] == nil { cookieWidth[c] = w }
                if let a = m.1 { cookieAlign[c] = String(a) }
            }
        }
        for row in data.compactMap({ $0 }) { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.count) } }
        for c in 0..<columns { if let w = cookieWidth[c] { widths[c] = max(widths[c], w) } }
        let number = LaTeXRenderer.numberPattern
        let align: [Justify] = (0..<columns).map { c in
            switch cookieAlign[c] {
            case "l": return .left
            case "r": return .right
            case "c": return .center
            default: break
            }
            var numbers = 0
            var total = 0
            var previousNumber = false
            for (r, row) in data.enumerated() where raw[r] != nil && !special[r] {
                let cell = c < row!.count ? row![c] : ""
                total += 1
                let isNumber = number.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) != nil || (cell.isEmpty && previousNumber)
                previousNumber = isNumber
                if isNumber { numbers += 1 }
            }
            return total > 0 && Double(numbers) / Double(total) >= 0.5 ? .right : .left
        }
        let standard = data.indices.filter { data[$0] != nil }
        var out = ""
        for (position, r) in standard.enumerated() {
            let row = data[r]!
            let ruleAbove = raw[(position == 0 ? 0 : standard[position - 1] + 1)..<r].contains { $0 == nil }
            let ruleBelow = raw[(r + 1)..<(position + 1 < standard.count ? standard[position + 1] : raw.count)].contains { $0 == nil }
            func hline(_ char: String) -> String { row.indices.map { String(repeating: char, count: widths[$0] + 2) }.joined() + "\n" }
            if position == 0, utf8 || ruleAbove {
                out += hline(utf8 ? "━" : "-")
            } else if position > 0, ruleAbove {
                out += hline(utf8 ? "─" : "-")
            }
            out += row.enumerated().map { c, cell in
                let pad = widths[c] - cell.count
                let justified: String = switch align[c] {
                case .left: cell + String(repeating: " ", count: pad)
                case .right: String(repeating: " ", count: pad) + cell
                case .center: String(repeating: " ", count: pad / 2) + cell + String(repeating: " ", count: pad - pad / 2)
                }
                return " " + justified + " "
            }.joined() + "\n"
            if position == standard.count - 1, utf8 || ruleBelow { out += hline(utf8 ? "━" : "-") }
        }
        let caption = try buildCaption(affiliated, type: "Table %d:", counter: &tableCount, context: context)
        return Self.justifyBlock(out + (caption ?? ""), context: context)
    }

    private var isolatedTimestamps = false
    private var tableCount = 0
    private var listingCount = 0

    /// `org-ascii--build-caption`.
    private func buildCaption(_ affiliated: Affiliated, type: String, counter: inout Int, context: Context) throws -> String? {
        guard !affiliated.caption.isEmpty else { return nil }
        if affiliated.caption.count > 1 { throw Unsupported(reason: "Several captions") }
        counter += 1
        let saved = noting
        noting = false
        defer { noting = saved }
        let text = try inlineString(affiliated.caption[0])
        return ASCIIText.fill(translate(type).replacingOccurrences(of: "%d", with: String(counter)) + " " + text, width: context.width)
    }

    // MARK: Blocks

    private func block(_ node: SyntaxNode, affiliated: Affiliated, context: Context) throws -> String? {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first, let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return nil }
        let type = m.1.lowercased()
        let parameters = String(m.2)
        let body = Array(lines.dropFirst().dropLast())
        let unescaped = body.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        let text = unescaped.joined(separator: "\n")
        switch type {
        case "src", "example":
            let code = try formatCode(lines)
            var out = box(code)
            if type == "src", let caption = try buildCaption(affiliated, type: "Listing %d:", counter: &listingCount, context: context) {
                out += "\n" + caption
            }
            return Self.justifyBlock(out, context: context)
        case "quote":
            guard let contents = try blockContents(unescaped, context: Context(width: context.width - 2 * Self.quoteMargin, justify: context.justify)) else { return nil }
            return ASCIIText.indent(contents, Self.quoteMargin)
        case "center":
            return try blockContents(unescaped, context: Context(width: context.width, justify: .center))
        case "verse":
            return ASCIIText.indent(Self.justifyBlock(try verse(unescaped), context: context), Self.quoteMargin)
        case "export":
            let backend = parameters.split(separator: " ").first.map { $0.uppercased() } ?? ""
            guard backend == "ASCII" else { return nil }
            return Self.justifyBlock(text + "\n", context: context)
        case "comment":
            return nil
        default:
            var inner = context
            if m.1 == "JUSTIFYRIGHT" { inner.justify = .right }
            if m.1 == "JUSTIFYLEFT" { inner.justify = .left }
            return try blockContents(unescaped, context: inner)
        }
    }

    /// A greater block's contents, parsed as elements; nil when it has none.
    private func blockContents(_ lines: [String], context: Context) throws -> String? {
        guard !lines.isEmpty else { return nil }
        if lines[0].allSatisfy({ $0 == " " || $0 == "\t" }) { throw Unsupported(reason: "Blocks opening with a blank line") }
        let text = lines.joined(separator: "\n") + "\n"
        let tree = OrgParser.parse(text, defaults: settings)
        let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        if nodes.contains(where: { $0.kind == .section }) { throw Unsupported(reason: "Headings inside blocks") }
        let saved = (currentSource, exportSource)
        currentSource = text as NSString
        exportSource = ExportSource(tree: tree, text: text)
        defer { (currentSource, exportSource) = saved }
        guard hasContents(nodes) else { return nil }
        return Self.normalize(try elements(nodes, end: (text as NSString).length, context: context))
    }

    /// `org-export-format-code-default` for a src or example block's lines.
    private func formatCode(_ lines: [String]) throws -> String {
        guard let parsed = Coderef.block(lines) else { return "\n" }
        let blockLoc = try blockLoc(lines, numbered: parsed.switches.numberLines != nil)
        var value = parsed.body.joined(separator: "\n")
        if !value.isEmpty { value += "\n" }
        let preserve = lines[0].firstMatch(of: /^[ \t]*#\+(?i:begin_(?:src|example))\b.*\s-i\b/) != nil
        var code = preserve ? value : try LaTeXRenderer.removeIndentation(value)
        // Emacs writes a src block's leading tabs as spaces.
        if !preserve, lines[0].firstMatch(of: /^[ \t]*#\+(?i:begin_src)\b/) != nil {
            code = code.components(separatedBy: "\n").map { line in
                var column = 0
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                for c in indentation { column = c == "\t" ? (column / 8 + 1) * 8 : column + 1 }
                return String(repeating: " ", count: column) + line.dropFirst(indentation.count)
            }.joined(separator: "\n")
        }
        if code.hasSuffix("\n") { code.removeLast() }
        let (lines, refs) = Coderef.unravel(code.components(separatedBy: "\n"), format: parsed.switches.labelFormat)
        let loc = parsed.switches.numberLines == nil ? nil : blockLoc
        guard loc != nil || (parsed.switches.retainLabels && !refs.isEmpty) else { return lines.joined(separator: "\n") + "\n" }
        let width = loc.map { String($0 + lines.count).count } ?? 0
        let numberWidth = loc == nil ? 0 : width + 2
        let maxWidth = (lines.map(\.count).max() ?? 0) + numberWidth
        return lines.enumerated().map { index, line in
            var out = loc.map { String(repeating: " ", count: max(0, width - String($0 + index + 1).count)) + "\($0 + index + 1)  " } ?? ""
            out += line
            if parsed.switches.retainLabels, let ref = refs[index + 1] {
                out += String(repeating: " ", count: maxWidth + 6 - out.count) + "(\(ref))"
            }
            return out
        }.joined(separator: "\n") + "\n"
    }

    /// The src and example blocks the export writes, in order, as their lines.
    private lazy var exportedBlocks: [[String]] = {
        let source = ExportSource(tree: tree, text: self.source as String)
        return tree.root.descendants().filter { $0.kind == .block }.compactMap { node in
            var lines = node.text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            guard Coderef.block(lines) != nil, !excluded(node), !isResults(node) else { return nil }
            if blockType(node) == "src", source.exports(at: node.range.lowerBound) == "none" { return nil }
            return lines
        }
    }()

    /// Whether `node` is the results of the src block before it, which the export removes.
    private func isResults(_ node: SyntaxNode) -> Bool {
        guard let siblings = node.parent?.children, let index = siblings.firstIndex(where: { $0.range == node.range }) else { return false }
        let keywords = siblings[..<index].reversed().prefix { $0.kind == .affiliatedKeyword }
        guard keywords.contains(where: { $0.text.firstMatch(of: /^[ \t]*#\+(?i:results)[\[:]/) != nil }) else { return false }
        let before = index - keywords.count - 1
        return before >= 0 && siblings[before].kind == .block && blockType(siblings[before]) == "src"
    }

    /// Each src and example block's `org-export-get-loc`, by the block's text, in order.
    private lazy var blockLocs: [String: [Int?]] = {
        let blocks = exportedBlocks
        var locs: [String: [Int?]] = [:]
        for (lines, loc) in zip(blocks, Coderef.locs(blocks.compactMap(Coderef.block))) {
            locs[lines.joined(separator: "\n"), default: []].append(loc)
        }
        return locs
    }()

    /// `org-export-get-loc` of the block with `lines`, the next of those with the same text.
    private func blockLoc(_ lines: [String], numbered: Bool) throws -> Int? {
        let key = lines.joined(separator: "\n")
        guard let queue = blockLocs[key], !queue.isEmpty else {
            if numbered { throw Unsupported(reason: "Numbered blocks inside other blocks") }
            return nil
        }
        blockLocs[key] = Array(queue.dropFirst())
        return queue[0]
    }

    /// Whether `node` is under a section the export leaves out.
    private func excluded(_ node: SyntaxNode) -> Bool {
        var current: SyntaxNode? = node
        while let n = current {
            if n.kind == .section, let heading = n.firstChild(.heading),
               HTMLRenderer.sectionExport(heading, options: options, selected: selected) != .all { return true }
            current = n.parent
        }
        return false
    }

    /// A verse block's objects, their common indentation removed.
    private func verse(_ lines: [String]) throws -> String {
        let text = lines.joined(separator: "\n") + "\n"
        let tree = OrgParser.parse(text, defaults: settings)
        let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        guard nodes.allSatisfy({ $0.kind == .paragraph }), let firstNode = nodes.first else { throw Unsupported(reason: "Verse blocks with more than text") }
        let ns = text as NSString
        var raw: [Inline] = [.text(ns.substring(to: firstNode.range.lowerBound))]
        for (index, node) in nodes.enumerated() {
            raw += inlineItems(node)
            let end = index + 1 < nodes.count ? nodes[index + 1].range.lowerBound : ns.length
            raw.append(.text(ns.substring(with: NSRange(location: node.range.upperBound, length: end - node.range.upperBound))))
        }
        return try transcode(LaTeXRenderer.normalizeIndentation(LaTeXRenderer.merge(raw), ignoreFirst: false))
    }

    // MARK: - Objects

    /// The contents of `node` as `Inline`s, markers left out, a line break's newline taken in.
    func inlineItems(_ node: SyntaxNode, trimmed: Bool = false) -> [Inline] {
        var items: [Inline] = []
        var skipNewline = false
        for element in node.elements {
            switch element {
            case .token(let token):
                switch token.kind {
                case .marker, .stars, .bullet, .checkbox, .tags, .todoKeyword, .priority, .counter:
                    continue
                default:
                    var text = token.text
                    if skipNewline {
                        let rest = text.drop { $0 == " " || $0 == "\t" }
                        if rest.hasPrefix("\n") { text = String(rest.dropFirst()); skipNewline = false } else if !rest.isEmpty { skipNewline = false } else { text = "" }
                    }
                    if !text.isEmpty { items.append(.text(text)) }
                }
            case .node(let child):
                skipNewline = false
                switch child.kind {
                case .bold, .italic, .underline, .strikeThrough, .linkDescription:
                    items.append(.object(child, inlineItems(child)))
                case .link:
                    items.append(.object(child, child.firstChild(.linkDescription).map { inlineItems($0) } ?? []))
                case .superscript, .subscript:
                    let text = child.text
                    let braced = text.dropFirst().hasPrefix("{")
                    if options.scripts == .off || (options.scripts == .braces && !braced) {
                        items.append(.text(text))
                    } else if braced {
                        items.append(.object(child, inlineItems(child)))
                    } else {
                        items.append(.object(child, [.text(String(text.dropFirst()))]))
                    }
                case .lineBreak where trimmed:
                    items.append(.text(child.text))
                case .lineBreak:
                    items.append(.object(child, []))
                    skipNewline = true
                default:
                    items.append(.object(child, []))
                }
            }
        }
        if trimmed {
            if case .text(let t) = items.first { items[0] = .text(String(t.drop { $0 == " " || $0 == "\t" })) }
            if case .text(let t) = items.last { items[items.count - 1] = .text(String(t.reversed().drop { $0 == " " || $0 == "\t" }.reversed())) }
        }
        return LaTeXRenderer.merge(items)
    }

    /// One line of Org text transcoded, for keywords and captions.
    func inlineString(_ text: String) throws -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return plainText(text) }
        if tree.root.descendants().contains(where: { $0.kind == .footnoteReference }) { throw Unsupported(reason: "Footnotes in keywords and captions") }
        let saved = exportSource
        exportSource = ExportSource(tree: tree, text: text)
        defer { exportSource = saved }
        return LaTeXRenderer.trim(try transcode(inlineItems(paragraph)))
    }

    /// `org-export-data` over objects: objects that export nothing taking their blanks with
    /// them unless they are needed.
    func transcode(_ items: [Inline]) throws -> String {
        var out = ""
        var index = 0
        var dropBlanks = false
        var afterObject = false
        while index < items.count {
            let item = items[index]
            switch item {
            case .text(var t):
                if dropBlanks {
                    t = String(t.drop { $0 == " " || $0 == "\t" })
                } else if afterObject {
                    let blanks = t.prefix { $0 == " " || $0 == "\t" }
                    t = String(repeating: " ", count: blanks.count) + t.dropFirst(blanks.count)
                }
                dropBlanks = false
                afterObject = false
                out += plainText(t)
                index += 1
            case .object(let node, let children):
                dropBlanks = false
                afterObject = true
                if let result = try object(node, children) {
                    out += result
                } else {
                    // `org-export--keep-spaces`: blanks after a dropped object stay only
                    // between text that has none.
                    let previousBlank: Bool
                    if index == 0 {
                        previousBlank = true
                    } else if case .text(let t) = items[index - 1] {
                        previousBlank = t.last.map { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" } ?? false
                    } else {
                        previousBlank = false
                    }
                    dropBlanks = previousBlank
                }
                index += 1
            }
        }
        return out
    }

    private func object(_ node: SyntaxNode, _ children: [Inline]) throws -> String? {
        switch node.kind {
        case .bold: return "*\(try transcode(children))*"
        case .italic: return "/\(try transcode(children))/"
        case .underline: return "_\(try transcode(children))_"
        case .strikeThrough: return "+\(try transcode(children))+"
        case .verbatim, .code: return "`\(node.text.dropFirst().dropLast())'"
        case .link: return try link(node, children)
        case .linkDescription: return try transcode(children)
        case .timestamp:
            if isolatedTimestamps, ICalendarExport.skipsTimestamp(node.text, with: options.timestamps ?? "t") { return nil }
            return plainText(ASCIIText.timestamp(node.text))
        case .footnoteReference: return try footnoteReference(node)
        case .entity:
            let name = String(node.text.dropFirst()).replacingOccurrences(of: "{}", with: "")
            guard let entity = OrgEntities.text[name] else { throw Unsupported(reason: "Unknown entity \(node.text)") }
            return switch charset {
            case .ascii: entity.ascii
            case .latin1: entity.latin1
            case .utf8: entity.utf8
            }
        case .superscript: return node.text.dropFirst().hasPrefix("{") ? "^{\(try transcode(children))}" : "^\(try transcode(children))"
        case .subscript: return node.text.dropFirst().hasPrefix("{") ? "_{\(try transcode(children))}" : "_\(try transcode(children))"
        case .lineBreak: return Self.hardNewline
        case .latexFragment: return options.tex ? node.text : nil
        case .statisticsCookie: return node.text
        case .exportSnippet:
            let backend = node.tokens.first?.text.dropFirst(2).dropLast() ?? ""
            guard backend == "ascii" else { return nil }
            return node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
        case .target:
            return nil
        case .macro:
            guard case .some(let value) = exportSource.resultsMacro(node) else { return nil }
            return try value.map(inlineString)
        default:
            throw Unsupported(reason: "\(node.kind)")
        }
    }

    /// `org-ascii-plain-text`.
    func plainText(_ text: String) -> String {
        guard options.specialStrings else { return text }
        let text = text.replacingOccurrences(of: "\\-", with: "")
        guard utf8 else { return text }
        return text.replacingOccurrences(of: "---", with: "—").replacingOccurrences(of: "--", with: "–").replacingOccurrences(of: "...", with: "…")
    }

    // MARK: Links

    /// A link written in notes mode: its footprint and how `org-ascii--describe-links`
    /// describes it, nil for none.
    private struct Noted {
        var footprint: String
        var note: String?
    }

    /// Links written so far, for their section's notes.
    private var noted: [Noted] = []
    /// Whether links written now are noted: not in captions.
    private var noting = true

    /// `org-ascii--describe-links` for the links noted since `start`, each once.
    private func describeLinks(from start: Int, width: Int) -> String {
        guard linksToNotes else { return "" }
        var seen: Set<String> = []
        var out = ""
        for link in noted[start...] where !seen.contains(link.footprint) {
            seen.insert(link.footprint)
            if let note = link.note { out += ASCIIText.fill(note, width: width) + "\n\n" }
        }
        noted.removeSubrange(start...)
        return out
    }

    private static let externalTypes: Set<String> = ["attachment", "file+sys", "file+emacs", "shell", "news", "mailto", "https", "http", "ftp", "shortdoc", "help", "file", "elisp"]

    private func link(_ node: SyntaxNode, _ children: [Inline]) throws -> String? {
        if node.firstChild(.linkDescription)?.descendants().contains(where: { $0.kind == .link }) == true {
            throw Unsupported(reason: "Links in link descriptions")
        }
        let pathToken = node.tokens.first { $0.kind == .linkPath }?.text
        var raw = pathToken ?? node.text
        if pathToken == nil, raw.hasPrefix("<"), raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        var description: String? = node.firstChild(.linkDescription) == nil ? nil : try transcode(children)
        if description?.contains(where: { !$0.isWhitespace }) != true { description = nil }
        let footprint = raw + "\u{0}" + (node.firstChild(.linkDescription)?.text ?? "").split(whereSeparator: { " \t\n\r".contains($0) }).joined(separator: " ")
        // Only the link types Org knows have a scheme; `foo:bar` is a fuzzy link.
        let scheme = raw.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/).map { String($0.1).lowercased() }.flatMap { Self.externalTypes.contains($0) || $0 == "id" ? $0 : nil }
        if raw.hasPrefix("(") && raw.hasSuffix(")") {
            let path = String(raw.dropFirst().dropLast())
            guard let resolved = Coderef.resolve(path, blocks: exportedBlocks) else { throw Unsupported(reason: "Unable to resolve code reference: \(path)") }
            var format = description ?? "%s"
            if let range = format.range(of: "(\(path))") { format.replaceSubrange(range, with: "%s") }
            return format.replacingOccurrences(of: "%s", with: resolved).replacingOccurrences(of: "%%", with: "%")
        }
        let internalLink = raw.hasPrefix("#") || scheme == "id" || (scheme == nil && !raw.hasPrefix("/") && !raw.hasPrefix("./") && !raw.hasPrefix("../") && !raw.hasPrefix("~"))
        if internalLink {
            let type = raw.hasPrefix("#") ? "custom-id" : scheme == "id" ? "id" : "fuzzy"
            let path = type == "custom-id" ? String(raw.dropFirst()) : type == "id" ? String(raw.dropFirst(3)) : raw
            if type == "fuzzy", !path.hasPrefix("*"), target(path) || namedElement(path) {
                throw Unsupported(reason: "Links to targets and named elements")
            }
            guard let heading = resolveHeading(type: type, path: path) else {
                throw Unsupported(reason: "Unable to resolve link: \"\(type == "custom-id" ? "#" : type == "id" ? "id:" : "")\(path)\"")
            }
            let datum = try describeHeading(heading)
            if let description {
                if noting { noted.append(Noted(footprint: footprint, note: linksToNotes ? "[\(description)] \(datum.see)" : nil)) }
                return linksToNotes ? "[\(description)]" : "[\(description)] (\(datum.see))"
            }
            if noting { noted.append(Noted(footprint: footprint, note: nil)) }
            return datum.reference
        }
        if noting { noted.append(Noted(footprint: footprint, note: description.map { "[\($0)] <\(raw)>" })) }
        return description.map { "[\($0)]" + (linksToNotes ? "" : " (<\(raw)>)") } ?? "<\(raw)>"
    }

    /// A heading as a link without a description writes it, and as
    /// `org-ascii--describe-datum` does.
    private func describeHeading(_ heading: HeadingInfo) throws -> (reference: String, see: String) {
        let number = numbers[heading.headingRange.lowerBound]?.map(String.init).joined(separator: ".")
        let text: String
        if let number {
            text = number
        } else {
            guard let node = tree.root.descendants().first(where: { $0.kind == .heading && $0.range.lowerBound == heading.headingRange.lowerBound }) else { return ("", "") }
            let saved = noting
            noting = false
            defer { noting = saved }
            text = try node.firstChild(.title).map { try transcode(inlineItems($0)) } ?? ""
        }
        return (text, translate("See section %s").replacingOccurrences(of: "%s", with: text))
    }

    /// Whether a `<<target>>` has the name a fuzzy link gives.
    private func target(_ path: String) -> Bool {
        let search = LaTeXRenderer.words(path)
        return tree.root.descendants().contains { $0.kind == .target && LaTeXRenderer.words(String($0.text.dropFirst(2).dropLast(2))) == search }
    }

    /// Whether an element has the `#+NAME` a fuzzy link gives.
    private func namedElement(_ path: String) -> Bool {
        let search = path.split(whereSeparator: \.isWhitespace).map(String.init)
        return tree.root.descendants().contains { node in
            guard node.kind == .affiliatedKeyword, let m = node.text.firstMatch(of: /^[ \t]*#\+(?i:name):[ \t]*(.*?)[ \t]*\n?$/) else { return false }
            let words = String(m.1).split(whereSeparator: \.isWhitespace).map(String.init)
            return words == search || words == search.map { $0.uppercased() }
        }
    }

    /// The exported heading a link goes to: by `CUSTOM_ID`, `ID` or title.
    private func resolveHeading(type: String, path: String) -> HeadingInfo? {
        let starts = Set(exported.map(\.start))
        let headings = model.headings.filter { starts.contains($0.headingRange.lowerBound) }
        switch type {
        case "custom-id":
            return headings.first { $0.properties.contains { $0.key.uppercased() == "CUSTOM_ID" && $0.value == path } }
        case "id":
            return headings.first { $0.properties.contains { $0.key.uppercased() == "ID" && $0.value == path } }
        default:
            let search = LaTeXRenderer.words(path.hasPrefix("*") ? String(path.dropFirst()) : path)
            return headings.first { heading in
                let node = tree.root.descendants().first { $0.kind == .heading && $0.range.lowerBound == heading.headingRange.lowerBound }
                let raw = (node?.firstChild(.title)?.text ?? "").replacing(#/\[[0-9]*(?:%|/[0-9]*)\]/#, with: " ")
                return LaTeXRenderer.words(raw) == search
            }
        }
    }

    // MARK: Footnotes

    /// Footnote numbers by label, in the order of first references.
    private var footnoteNumbers: [String: Int] = [:]
    /// What each number's footnote says: a definition's label, or an inline definition.
    private var footnoteOrder: [(label: String?, inline: String?)] = []
    private var inFootnote = false

    /// `org-ascii-footnote-reference`.
    private func footnoteReference(_ node: SyntaxNode) throws -> String {
        guard let m = node.text.firstMatch(of: /^\[fn:([^:\]]*)(?::(.*))?\]$/) else { throw Unsupported(reason: "Footnote \(node.text)") }
        if inFootnote { throw Unsupported(reason: "Footnotes inside footnotes") }
        let label = String(m.1)
        if !label.isEmpty, let number = footnoteNumbers[label] { return "[\(number)]" }
        if m.2 == nil, label.isEmpty || definition(label) == nil { throw Unsupported(reason: "Definition not found for footnote \(label)") }
        footnoteOrder.append((label.isEmpty ? nil : label, m.2.map(String.init)))
        if !label.isEmpty { footnoteNumbers[label] = footnoteOrder.count }
        return "[\(footnoteOrder.count)]"
    }

    /// The definition of `label` and the text width where it is.
    private func definition(_ label: String) -> (text: String, width: Int)? {
        for node in tree.root.descendants() where node.kind == .footnoteDefinition {
            guard let m = node.text.firstMatch(of: /^\[fn:([^\]]+)\][ \t]*/), m.1 == label else { continue }
            var width = Self.textWidth
            var current = node.parent
            while let n = current {
                if n.kind == .section, let heading = n.firstChild(.heading) {
                    let level = self.level(heading)
                    width -= level > options.headlineLevels ? (level - options.headlineLevels) * 2 : Self.innerMargin
                    break
                }
                current = n.parent
            }
            if excluded(node) { return nil }
            return (String(node.text[m.range.upperBound...]), width)
        }
        return nil
    }

    /// The footnote definitions, as `org-ascii-inner-template` writes them.
    private func footnotes() throws -> String {
        linksToNotes = false
        inFootnote = true
        defer {
            linksToNotes = true
            inFootnote = false
        }
        var parts: [String] = []
        for (index, footnote) in footnoteOrder.enumerated() {
            let id = "[\(index + 1)] "
            if let inline = footnote.inline {
                parts.append(LaTeXRenderer.trim(ASCIIText.fill(id + (try inlineObjects(inline)), width: Self.textWidth)))
                continue
            }
            guard let label = footnote.label, let (text, width) = definition(label) else { continue }
            let tree = OrgParser.parse(text, defaults: settings)
            let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
            let saved = (currentSource, exportSource)
            currentSource = text as NSString
            exportSource = ExportSource(tree: tree, text: text)
            defer { (currentSource, exportSource) = saved }
            let context = Context(width: width)
            if let first = nodes.first, first.kind == .paragraph {
                var out = Self.normalize(try paragraph(first, context: context, ignoreFirst: true, prefix: id))
                out += String(repeating: "\n", count: blankLines(from: first.range.lowerBound, to: nodes.count > 1 ? nodes[1].range.lowerBound : (text as NSString).length))
                out += try elements(Array(nodes.dropFirst()), end: (text as NSString).length, context: context)
                parts.append(LaTeXRenderer.trim(out))
            } else {
                parts.append(LaTeXRenderer.trim(id + "\n" + (try elements(nodes, end: (text as NSString).length, context: context))))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// An inline definition's objects transcoded.
    private func inlineObjects(_ text: String) throws -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return plainText(text) }
        return try transcode(inlineItems(paragraph))
    }
}
