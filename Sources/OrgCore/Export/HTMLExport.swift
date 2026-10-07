import Foundation

/// Document metadata from `#+TITLE`, `#+AUTHOR` and `#+DATE`.
public struct ExportMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var date: String?
}

/// HTML export. The body follows the shape orgo produces, which the org-conformance corpus
/// holds as the reference: headings one level down (`*` is `<h2>`), timestamps as `<time>`,
/// footnotes collected at the end, captioned images as figures.
public enum HTMLExport {
    public static func body(_ text: String, settings: OrgSettings = .default) -> String {
        let renderer = HTMLRenderer(settings: settings, options: .orgo)
        return renderer.document(text)
    }

    public static func metadata(_ text: String, settings: OrgSettings = .default) -> ExportMetadata {
        let tree = OrgParser.parse(text, defaults: settings)
        var meta = ExportMetadata()
        // Setup files' keywords come first, as Org reads them where `#+SETUPFILE` is.
        let setup = settings.setupKeywords.split(separator: "\n").map(String.init)
        let own = tree.root.children.filter { $0.kind == .zerothSection }.flatMap { $0.children.filter { $0.kind == .keyword } }.map(\.text)
        for text in setup + own {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line.dropFirst(2).prefix { $0 != ":" }.uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "TITLE": meta.title = value
            case "AUTHOR": meta.author = value
            case "DATE": meta.date = value
            default: break
            }
        }
        return meta
    }

    /// A standalone page: the body under the document's title, with a small stylesheet, as
    /// `#+OPTIONS` and the export keywords ask. `path` is the file's, for `#+INCLUDE` and
    /// `{{{input-file}}}`.
    public static func page(_ text: String, fallbackTitle: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date()) -> String {
        let directory = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let text = ExportPreprocess.macros(ExportPreprocess.includes(text, directory: directory), path: path, now: now, setup: settings.setupKeywords)
        let options = ExportOptions.parse(settings.setupKeywords + text)
        let meta = metadata(text, settings: settings)
        let title = meta.title ?? fallbackTitle
        let renderer = HTMLRenderer(settings: settings, options: options)
        // The title isn't part of the document Org processes citations in: they drop out.
        renderer.inTitle = true
        let titleHTML = renderer.inlineString(title)
        renderer.inTitle = false
        renderer.citations = CiteProcessor(text: text, directory: directory)
        var header = options.title ? "<h1 class=\"title\">\(titleHTML)</h1>\n" : ""
        let byline = [options.author ? meta.author : nil, options.date ? meta.date : nil].compactMap { $0 }.filter { !$0.isEmpty }
        if !byline.isEmpty { header += "<p class=\"byline\">\(byline.map(HTMLRenderer.escape).joined(separator: " · "))</p>\n" }
        let body = renderer.document(renderer.citations == nil ? text : renderer.citations!.inliningNotes(CiteProcessor.removingNocite(text)))
        header += renderer.tableOfContents()
        var head = options.htmlHead.map { $0 + "\n" }.joined()
        if renderer.hasMath {
            head += """
            <script>window.MathJax = { tex: { inlineMath: [['\\\\(', '\\\\)']], displayMath: [['\\\\[', '\\\\]'], ['$$', '$$']] } };</script>
            <script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>

            """
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLRenderer.escape(title))</title>
        <style>
        body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #222; }
        @media (prefers-color-scheme: dark) { body { background: #1d1d1f; color: #ddd; } a { color: #6cb6ff; } }
        pre { background: rgba(127, 127, 127, 0.12); padding: 0.75em; overflow-x: auto; }
        code { font: 0.9em ui-monospace, Menlo, monospace; }
        table { border-collapse: collapse; } th, td { border: 1px solid rgba(127, 127, 127, 0.4); padding: 0.25em 0.6em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid rgba(127, 127, 127, 0.4); }
        .tag { font-size: 0.75em; padding: 0 0.3em; border-radius: 3px; background: rgba(127, 127, 127, 0.18); }
        .todo { color: #c33; } .done { color: #393; } .byline { color: #888; } .center { text-align: center; }
        figure { margin: 1em 0; } img { max-width: 100%; }
        #table-of-contents ul { list-style: none; padding-left: 1.2em; } #table-of-contents > div > ul { padding-left: 0; }
        </style>
        \(head)</head>
        <body>
        \(header)\(body)</body>
        </html>

        """
    }
}

final class HTMLRenderer {
    let settings: OrgSettings
    let options: ExportOptions
    /// With select tags in the document: the sections to export, by heading start.
    private var selected: Set<Int>?
    private var numbers: [Int] = []
    private var tocEntries: [(level: Int, id: String, html: String)] = []
    /// A LaTeX fragment was exported, for MathJax.
    private(set) var hasMath = false
    private var footnoteNumbers: [String: Int] = [:]
    private var footnoteOrder: [(label: String, content: FootnoteContent)] = []
    private var definitions: [String: String] = [:]
    private var anonymous = 0
    private var figures = 0
    private var ids: Set<String> = []
    /// Citations and the bibliography, as `oc-basic` exports them.
    var citations: CiteProcessor?
    /// Rendering the title, where Org exports citations as nothing.
    var inTitle = false

    enum FootnoteContent {
        case definition(String)
        case inline(String)
    }

    init(settings: OrgSettings, options: ExportOptions = .orgo) {
        self.settings = settings
        self.options = options
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - Document

    func document(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        collectDefinitions(tree.root)
        selected = Self.selection(tree, tags: options.selectTags)
        var out = ""
        for child in tree.root.children { out += element(child) }
        out += footnoteSection()
        return out
    }

    private func collectDefinitions(_ node: SyntaxNode) {
        for child in node.children {
            if child.kind == .footnoteDefinition {
                let text = child.text
                if let m = text.firstMatch(of: /^\[fn:([^\]]+)\][ \t]*/) {
                    definitions[String(m.1)] = String(text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                collectDefinitions(child)
            }
        }
    }

    private func footnoteSection() -> String {
        guard !footnoteOrder.isEmpty else { return "" }
        var out = "<section class=\"footnotes\" aria-label=\"Footnotes\">\n<hr>\n<ol>\n"
        for (index, note) in footnoteOrder.enumerated() {
            let n = index + 1
            let content: String
            switch note.content {
            case .definition(let text): content = blocks(text).trimmingCharacters(in: .newlines)
            case .inline(let text): content = inlineString(text)
            }
            out += "<li id=\"fn-\(n)\">\(content)\n <a class=\"footnote-back\" href=\"#fnr-\(n)\" aria-label=\"Back to reference \(n)\">&#8617;</a></li>\n"
        }
        return out + "</ol>\n</section>\n"
    }

    /// Org text rendered as elements, for block and footnote contents.
    func blocks(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        var out = ""
        for child in tree.root.children { out += element(child) }
        return out
    }

    /// One line of org text rendered inline.
    func inlineString(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return Self.escape(text) }
        return inline(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A citation's or a bibliography entry's pieces: text escaped, prefixes and suffixes as
    /// Org markup with their blanks kept.
    private func render(_ pieces: [CiteProcessor.Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let s): Self.escape(s)
            case .italic(let s): "<i>" + Self.escape(s) + "</i>"
            case .org(let s) where s.allSatisfy(\.isWhitespace): s
            case .org(let s):
                String(s.prefix { $0.isWhitespace }) + inlineString(s) + (s.allSatisfy(\.isWhitespace) ? "" : String(s.reversed().prefix { $0.isWhitespace }))
            }
        }.joined()
    }

    // MARK: - Elements

    private var affiliated: [String: String] = [:]
    /// `:exports` of the last src block: its results are exported only for `results` and
    /// `both`; nothing runs.
    private var lastExports = "code"

    func element(_ node: SyntaxNode) -> String {
        defer { if node.kind != .affiliatedKeyword { affiliated = [:] } }
        if node.kind != .affiliatedKeyword, affiliated["RESULTS"] != nil {
            defer { lastExports = "code" }
            if lastExports != "results", lastExports != "both" { return "" }
        }
        if node.kind == .block, let exports = Self.srcExports(node) {
            lastExports = exports
            if exports == "results" || exports == "none" { return "" }
        }
        switch node.kind {
        case .section:
            guard let heading = node.firstChild(.heading) else { fallthrough }
            let tags = heading.tokens.first { $0.kind == .tags }?.text.split(separator: ":").map(String.init) ?? []
            let title = heading.firstChild(.title)?.text.trimmingCharacters(in: .whitespaces) ?? ""
            // `org-export--skip-p`: excluded tags, COMMENT, unselected trees.
            if tags.contains(where: options.excludeTags.contains) || title == "COMMENT" || title.hasPrefix("COMMENT ") { return "" }
            if let selected, !selected.contains(heading.range.lowerBound) { return "" }
            // Archived trees export their heading only.
            if tags.contains("ARCHIVE") { return self.heading(heading) }
            var out = ""
            for child in node.children { out += element(child) }
            return out
        case .zerothSection, .document:
            var out = ""
            for child in node.children { out += element(child) }
            return out
        case .heading:
            return heading(node)
        case .affiliatedKeyword:
            let line = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = line.firstMatch(of: /^#\+([A-Za-z_]+):[ \t]*(.*)$/) {
                affiliated[m.1.uppercased()] = String(m.2)
            }
            return ""
        case .paragraph:
            return paragraph(node)
        case .keyword where citations != nil && node.text.range(of: "^[ \\t]*#\\+print_bibliography:", options: [.regularExpression, .caseInsensitive]) != nil:
            return citations!.bibliography.map { "<p>" + render($0) + "</p>\n" }.joined()
        case .plainList:
            return list(node)
        case .table:
            return table(node)
        case .block:
            return block(node)
        case .horizontalRule:
            return "<hr>\n"
        case .inlineTask:
            // As ox-html: the title in bold, then the contents.
            var out = "<div class=\"inlinetask\">\n"
            for child in node.children {
                if child.kind == .heading {
                    guard child.range.lowerBound == node.range.lowerBound else { continue }
                    let title = child.firstChild(.title).map { inline($0).trimmingCharacters(in: .whitespaces) } ?? ""
                    let todo = options.todo ? child.tokens.first { $0.kind == .todoKeyword }.map { "<span class=\"todo \(Self.escape($0.text))\">\(Self.escape($0.text))</span> " } ?? "" : ""
                    out += "<b>\(todo)\(title)</b><br>\n"
                } else {
                    out += element(child)
                }
            }
            return out + "</div>\n"
        case .latexEnvironment:
            // For MathJax, as ox-html leaves it with `tex:t`.
            guard options.tex else { return "" }
            hasMath = true
            return Self.escape(node.text.trimmingCharacters(in: .newlines)) + "\n"
        case .fixedWidth:
            let lines = node.text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix(": ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(trimmed.hasPrefix(":") ? 1 : 0))
            }
            return "<pre class=\"example\">" + Self.escape(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) + "</pre>\n"
        case .tableEl:
            let lines = node.text.components(separatedBy: "\n").filter { !$0.lowercased().contains("#+tblfm") }
            // As `org-html-table--table.el-table`: cells with their spans, lines kept apart.
            if let cells = TableEl.cells(lines.joined(separator: "\n")) {
                var out = "<table class=\"table-el\">\n"
                for row in Dictionary(grouping: cells, by: \.row).keys.sorted() {
                    out += "<tr>"
                    for cell in cells where cell.row == row {
                        let spans = (cell.colspan > 1 ? " colspan=\"\(cell.colspan)\"" : "") + (cell.rowspan > 1 ? " rowspan=\"\(cell.rowspan)\"" : "")
                        let content = cell.lines.reversed().drop { $0.isEmpty }.reversed().map(Self.escape).joined(separator: "<br>")
                        out += "<td\(spans)>\(content)</td>"
                    }
                    out += "</tr>\n"
                }
                return out + "</table>\n"
            }
            return "<pre class=\"example\">" + Self.escape(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) + "</pre>\n"
        case .dynamicBlock:
            let lines = node.text.components(separatedBy: "\n")
            return blocks(lines.dropFirst().dropLast(2).joined(separator: "\n"))
        default:
            // Keywords, comments, drawers, planning, clocks, footnote definitions, formulas.
            return ""
        }
    }

    /// The `:exports` value of a src block, or nil for other blocks.
    static func srcExports(_ node: SyntaxNode) -> String? {
        guard DocumentModel.isSrcBlock(node) else { return nil }
        let first = node.text.components(separatedBy: "\n").first ?? ""
        if let m = first.firstMatch(of: /:exports[ \t]+(\S+)/) { return m.1.lowercased() }
        return "code"
    }

    private func slug(_ text: String) -> String {
        var slug = ""
        var dash = false
        for c in text.lowercased() {
            if c.isLetter || c.isNumber {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        if slug.isEmpty { slug = "section" }
        var candidate = slug
        var n = 1
        while ids.contains(candidate) {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        ids.insert(candidate)
        return candidate
    }

    /// `org-export--selected-trees`: headings with a select tag, everything below them and
    /// their ancestors; nil when no heading has one.
    static func selection(_ tree: OrgTree, tags: [String]) -> Set<Int>? {
        let model = DocumentModel(tree: tree)
        let picked = model.headings.indices.filter { model.headings[$0].localTags.contains(where: tags.contains) }
        guard !picked.isEmpty else { return nil }
        var set: Set<Int> = []
        for index in picked {
            set.insert(model.headings[index].headingRange.lowerBound)
            for a in model.ancestors(of: index) { set.insert(model.headings[a].headingRange.lowerBound) }
            let level = model.headings[index].level
            for d in model.headings[(index + 1)...].prefix(while: { $0.level > level }) { set.insert(d.headingRange.lowerBound) }
        }
        return set
    }

    /// The table of contents, as ox-html writes it, or nothing.
    func tableOfContents() -> String {
        guard options.toc != nil, !tocEntries.isEmpty else { return "" }
        var out = "<div id=\"table-of-contents\" role=\"doc-toc\">\n<h2>Table of Contents</h2>\n<div id=\"text-table-of-contents\" role=\"doc-toc\">\n"
        var depth = 0
        var open: [Bool] = []
        let base = tocEntries.map(\.level).min() ?? 1
        for entry in tocEntries {
            let level = entry.level - base + 1
            if level > depth {
                while depth < level {
                    out += "\n<ul>\n"
                    depth += 1
                    open.append(false)
                }
            } else {
                out += "</li>\n"
                while depth > level {
                    out += "</ul>\n</li>\n"
                    depth -= 1
                    open.removeLast()
                }
            }
            out += "<li><a href=\"#\(Self.escape(entry.id))\">\(entry.html)</a>"
        }
        out += "</li>\n"
        while depth > 1 {
            out += "</ul>\n</li>\n"
            depth -= 1
        }
        return out + "</ul>\n</div>\n</div>\n"
    }

    private func heading(_ node: SyntaxNode) -> String {
        let tokens = node.tokens
        let level = tokens.first { $0.kind == .stars }?.text.count ?? 1
        let title = node.firstChild(.title)
        let titleText = title?.text.trimmingCharacters(in: .whitespaces) ?? ""
        // `CUSTOM_ID` from the property drawer that follows.
        var customID: String?
        if let section = node.parent, let drawer = section.firstChild(.propertyDrawer) {
            for property in drawer.children where property.kind == .nodeProperty {
                if let m = property.text.firstMatch(of: /^[ \t]*:CUSTOM_ID:[ \t]*(\S+)/) { customID = String(m.1) }
            }
        }
        let id = customID ?? slug(titleText)
        if customID != nil { ids.insert(id) }
        var parts: [String] = []
        let h = min(level + 1, 6)
        if let num = options.num, level <= num {
            if numbers.count < level { numbers += Array(repeating: 0, count: level - numbers.count) }
            numbers = Array(numbers.prefix(level))
            numbers[level - 1] += 1
            parts.append("<span class=\"section-number-\(h)\">\(numbers.map(String.init).joined(separator: ".")).</span>")
        }
        if options.todo, let todo = tokens.first(where: { $0.kind == .todoKeyword })?.text {
            parts.append("<span class=\"todo \(settings.isDone(todo) ? "done " : "")\(Self.escape(todo))\">\(Self.escape(todo))</span>")
        }
        if options.priority, let priority = tokens.first(where: { $0.kind == .priority })?.text {
            parts.append("<span class=\"priority\">\(Self.escape(priority))</span>")
        }
        if let title, !titleText.isEmpty { parts.append(inline(title).trimmingCharacters(in: .whitespaces)) }
        var tagParts: [String] = []
        if options.tags, let tags = tokens.first(where: { $0.kind == .tags })?.text {
            tagParts = tags.split(separator: ":").map { "<span class=\"tag\">\(Self.escape(String($0)))</span>" }
        }
        if let toc = options.toc, level <= toc {
            tocEntries.append((level, id, (parts + (options.tagsInTOC ? tagParts : [])).joined(separator: " ")))
        }
        parts += tagParts
        return "<h\(h) id=\"\(Self.escape(id))\">\(parts.joined(separator: " "))</h\(h)>\n"
    }

    private func paragraph(_ node: SyntaxNode) -> String {
        let body = inline(node).trimmingCharacters(in: .whitespacesAndNewlines)
        if let image = soleImage(node), affiliated["CAPTION"] != nil || affiliated["ATTR_HTML"] != nil {
            var out = "<figure>\n" + image + "\n"
            if let caption = affiliated["CAPTION"] {
                figures += 1
                out += "<figcaption>Figure \(figures): \(inlineString(caption))</figcaption>\n"
            }
            return out + "</figure>\n"
        }
        return "<p>\(body)</p>\n"
    }

    /// The `<img>` of a paragraph that is only an image link.
    private func soleImage(_ node: SyntaxNode) -> String? {
        let links = node.children.filter { $0.kind == .link }
        guard links.count == 1, node.children.count == 1,
              node.tokens.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let html = link(links[0])
        return html.hasPrefix("<img") ? html : nil
    }

    // MARK: - Lists

    private func isOrdered(_ item: SyntaxNode) -> Bool {
        let bullet = item.tokens.first { $0.kind == .bullet }?.text ?? "-"
        return bullet.first.map { $0.isNumber || $0.isLetter } ?? false
    }

    /// As orgo does, a change between ordered and unordered bullets starts another list.
    private func list(_ node: SyntaxNode) -> String {
        var runs: [[SyntaxNode]] = []
        for item in node.children where item.kind == .item {
            if let last = runs.last?.last, isOrdered(last) == isOrdered(item) {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
        }
        return runs.map(list).joined()
    }

    private func list(_ items: [SyntaxNode]) -> String {
        guard let first = items.first else { return "" }
        let ordered = isOrdered(first)
        // `org-list-get-list-type`: descriptive when the first item has a tag.
        let description = !ordered && first.firstChild(.itemTag) != nil
        if description {
            var out = "<dl>\n"
            for item in items {
                let (term, rest) = descriptionParts(item)
                out += "<dt>\(term)</dt>\n<dd>\(rest)</dd>\n"
            }
            return out + "</dl>\n"
        }
        let tag = ordered ? "ol" : "ul"
        var out = "<\(tag)>\n"
        for item in items { out += listItem(item) }
        return out + "</\(tag)>\n"
    }

    /// A description item's term, `(no term)` without one, and the rest of the item.
    private func descriptionParts(_ item: SyntaxNode) -> (String, String) {
        var term = item.firstChild(.itemTag).map { inline($0).trimmingCharacters(in: .whitespaces) } ?? "(no term)"
        if let box = item.tokens.first(where: { $0.kind == .checkbox })?.text {
            term = "<code>\(box == "[ ]" ? "[&nbsp;]" : box.uppercased())</code> " + term
        }
        var rest = ""
        for (index, child) in item.children.filter({ $0.kind != .itemTag }).enumerated() {
            rest += index == 0 && child.kind == .paragraph ? inline(child).trimmingCharacters(in: .whitespacesAndNewlines) : element(child)
        }
        return (term, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func listItem(_ item: SyntaxNode) -> String {
        // ox-html gives an ordered item's counter as its value.
        var open = "<li>"
        if isOrdered(item), let counter = item.tokens.first(where: { $0.kind == .counter })?.text.firstMatch(of: /([0-9]+|[A-Za-z])\]/) {
            open = "<li value=\"\(counter.1)\">"
        }
        var prefix = ""
        if let box = item.tokens.first(where: { $0.kind == .checkbox })?.text {
            switch box {
            case "[X]", "[x]":
                open = "<li class=\"on\">"
                prefix = "<code>[X]</code> "
            case "[-]":
                open = "<li class=\"trans\">"
                prefix = "<code>[-]</code> "
            default:
                open = "<li class=\"off\">"
                prefix = "<code>[&nbsp;]</code> "
            }
        }
        let paragraphs = item.children.filter { $0.kind == .paragraph }.count
        var body = ""
        for child in item.children {
            if child.kind == .paragraph {
                let content = inline(child).trimmingCharacters(in: .whitespacesAndNewlines)
                body += paragraphs >= 2 ? "<p>\(content)</p>\n" : content
            } else {
                body += element(child)
            }
        }
        if paragraphs >= 2 {
            body = prefix + body
        } else {
            body = prefix + body
        }
        return open + body + (body.hasSuffix("\n") ? "" : "") + "</li>\n"
    }

    // MARK: - Tables

    private func table(_ node: SyntaxNode) -> String {
        let rows = node.children.filter { $0.kind == .tableRow }
        var groups: [[SyntaxNode]] = [[]]
        for row in rows {
            if row.children.isEmpty, row.text.trimmingCharacters(in: .whitespaces).hasPrefix("|-") {
                if !groups[groups.count - 1].isEmpty { groups.append([]) }
            } else {
                groups[groups.count - 1].append(row)
            }
        }
        groups.removeAll { $0.isEmpty }
        var out = "<table>\n"
        if let caption = affiliated["CAPTION"] { out += "<caption>\(inlineString(caption))</caption>\n" }
        let hasHeader = groups.count > 1
        for (index, group) in groups.enumerated() {
            let header = hasHeader && index == 0
            if header { out += "<thead>\n" } else if index == (hasHeader ? 1 : 0) { out += "<tbody>\n" }
            for row in group {
                out += "<tr>" + row.children.filter { $0.kind == .tableCell }.map { cell in
                    let content = inline(cell).trimmingCharacters(in: .whitespaces)
                    return header ? "<th>\(content)</th>" : "<td>\(content)</td>"
                }.joined() + "</tr>\n"
            }
            if header { out += "</thead>\n" }
        }
        if !groups.isEmpty, !(hasHeader && groups.count == 1) { out += "</tbody>\n" }
        return out + "</table>\n"
    }

    // MARK: - Blocks

    private func block(_ node: SyntaxNode) -> String {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first,
              let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return "" }
        let type = m.1.lowercased()
        let parameters = String(m.2)
        let body = Array(lines.dropFirst().dropLast())
        // Commas protect `*` and `#+` lines inside blocks.
        let unescaped = body.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        let text = unescaped.joined(separator: "\n")
        switch type {
        case "src":
            let language = parameters.split(separator: " ").first.map(String.init)
            let code = Self.escape(dedent(unescaped).joined(separator: "\n"))
            let cls = language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
            return "<pre><code\(cls)>\(code)</code></pre>\n"
        case "example":
            return "<pre>\(Self.escape(dedent(unescaped).joined(separator: "\n")))</pre>\n"
        case "quote":
            return "<blockquote>\n\(blocks(text))</blockquote>\n"
        case "center":
            return "<div class=\"center\">\n\(blocks(text))</div>\n"
        case "verse":
            let rendered = unescaped.map { line -> String in
                let indent = line.prefix { $0 == " " }.count
                return String(repeating: "&nbsp;", count: indent) + inlineString(String(line.dropFirst(indent)))
            }
            return "<p class=\"verse\">\n" + rendered.joined(separator: "<br>\n") + "\n</p>\n"
        case "export":
            return parameters.lowercased().hasPrefix("html") ? text + "\n" : ""
        case "comment":
            return ""
        default:
            return "<div class=\"\(Self.escape(type))\">\n\(blocks(text))</div>\n"
        }
    }

    private func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }
    }

    // MARK: - Inline

    func inline(_ node: SyntaxNode) -> String {
        var out = ""
        for element in node.elements {
            switch element {
            case .token(let token):
                switch token.kind {
                case .marker, .stars, .bullet, .checkbox, .tags, .todoKeyword, .priority:
                    continue
                default:
                    out += entities(token.text)
                }
            case .node(let child):
                out += object(child)
            }
        }
        return out
    }

    /// Text: LaTeX fragments left for MathJax, `\alpha` and friends as characters, `_` and `^`
    /// scripts as `<sub>` and `<sup>`, as `#+OPTIONS` says.
    static let textObjects = try! NSRegularExpression(pattern: [
        #"\\\((.+?)\\\)"#, #"\\\[(.+?)\\\]"#, #"\$\$(.+?)\$\$"#,
        #"(?<![$\w])\$([^\s$.,;](?:[^$]*?[^\s$.,\\])?)\$(?=[\s.,;:!?'")\]-]|$)"#,
        #"\\([a-zA-Z]+)(\{\})?"#,
        #"(?<=\S)([_^])(\{[^{}]*\}|[+-]?[\p{L}\p{N}.,\\]*[\p{L}\p{N}])"#,
    ].joined(separator: "|"))

    private func entities(_ text: String) -> String {
        guard text.contains(where: { $0 == "\\" || $0 == "$" || $0 == "_" || $0 == "^" }) else { return Self.escape(text) }
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in Self.textObjects.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += Self.escape(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = NSMaxRange(m.range)
            let whole = ns.substring(with: m.range)
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if group(1) != nil || group(2) != nil || group(3) != nil || group(4) != nil {
                guard options.tex else { continue }
                hasMath = true
                out += Self.escape(whole)
            } else if let name = group(5) {
                out += Self.escape(OrgEntities.display[name] ?? whole)
            } else if let marker = group(7), let body = group(8) {
                let braced = body.hasPrefix("{")
                if options.scripts == .off || (options.scripts == .braces && !braced) {
                    out += Self.escape(whole)
                    continue
                }
                let inner = braced ? String(body.dropFirst().dropLast()) : body
                out += marker == "_" ? "<sub>\(Self.escape(inner))</sub>" : "<sup>\(Self.escape(inner))</sup>"
            } else {
                out += Self.escape(whole)
            }
        }
        return out + Self.escape(ns.substring(from: at))
    }

    private func object(_ node: SyntaxNode) -> String {
        switch node.kind {
        case .bold: return "<strong>\(inline(node))</strong>"
        case .italic: return "<em>\(inline(node))</em>"
        case .underline: return "<u>\(inline(node))</u>"
        case .strikeThrough: return "<del>\(inline(node))</del>"
        case .verbatim: return "<code class=\"verbatim\">\(inline(node))</code>"
        case .code: return "<code>\(inline(node))</code>"
        case .link: return link(node)
        case .linkDescription: return inline(node)
        case .timestamp: return timestamp(node.text)
        case .footnoteReference: return footnote(node.text)
        case .entity:
            let name = node.text.dropFirst().replacingOccurrences(of: "{}", with: "")
            return Self.escape(OrgEntities.display[name] ?? node.text)
        case .radioTarget:
            let inner = String(node.text.dropFirst(3).dropLast(3))
            return "<a id=\"\(Self.escape(slugOnly(inner)))\">\(Self.escape(inner))</a>"
        case .superscript, .subscript:
            let text = node.text
            let body = text.dropFirst()
            let braced = body.hasPrefix("{") && body.hasSuffix("}")
            if options.scripts == .off || (options.scripts == .braces && !braced) { return Self.escape(text) }
            let inner = braced ? String(body.dropFirst().dropLast()) : String(body)
            return text.hasPrefix("_") ? "<sub>\(Self.escape(inner))</sub>" : "<sup>\(Self.escape(inner))</sup>"
        case .lineBreak: return "<br>\n"
        case .target, .macro: return ""
        case .inlineSourceBlock:
            if let m = node.text.firstMatch(of: /\{(.*)\}$/) { return "<code>\(Self.escape(String(m.1)))</code>" }
            return Self.escape(node.text)
        case .latexFragment:
            // For MathJax, as ox-html leaves them with `tex:t`; `tex:nil` drops them.
            guard options.tex else { return "" }
            hasMath = true
            return Self.escape(node.text)
        case .statisticsCookie: return Self.escape(node.text)
        // `org-html-export-snippet`: only HTML snippets.
        case .exportSnippet:
            guard node.tokens.first?.text == "@@html:" else { return "" }
            return node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
        case .citation:
            if inTitle { return "" }
            guard let pieces = citations?.next(node.text) else { return Self.escape(node.text) }
            return render(pieces)
        case .inlineBabelCall: return Self.escape(node.text)
        default: return inline(node)
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "avif"]

    private func link(_ node: SyntaxNode) -> String {
        let path = node.tokens.first { $0.kind == .linkPath }?.text
        let description = node.firstChild(.linkDescription)
        guard let path else {
            // A radio link goes to its target.
            if !node.text.hasPrefix("<"), !node.text.contains(":") {
                return "<a href=\"#\(Self.escape(slugOnly(node.text)))\">\(Self.escape(node.text))</a>"
            }
            // A plain or angle link.
            var target = node.text
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            return "<a href=\"\(Self.escape(target))\">\(Self.escape(target))</a>"
        }
        var href = path
        var label = path
        if path.hasPrefix("file:") {
            href = String(path.dropFirst(5))
            label = href
        } else if path.hasPrefix("id:") {
            href = "#" + path.dropFirst(3)
            label = String(path.dropFirst(3))
        } else if path.hasPrefix("*") {
            href = "#" + slugOnly(String(path.dropFirst()))
        } else if !path.hasPrefix("#"), !path.contains(":"), !path.contains("/"), !path.contains(".") {
            href = "#" + slugOnly(path)
        }
        let isFile = path.hasPrefix("file:") || (!path.contains(":") && (path.contains("/") || path.contains(".")))
        if isFile, href.lowercased().hasSuffix(".org") { href = String(href.dropLast(4)) + ".html" }
        if isFile, let range = href.range(of: ".org::") { href = String(href[..<range.lowerBound]) + ".html" }
        let ext = (href.split(separator: "?").first.map(String.init) ?? href).split(separator: ".").last.map { $0.lowercased() } ?? ""
        if description == nil, Self.imageExtensions.contains(ext) {
            var attributes = ""
            if let attrs = affiliated["ATTR_HTML"] {
                for (key, value) in parseAttributes(attrs) where key != "src" {
                    attributes += " \(key)=\"\(Self.escape(value))\""
                }
            }
            if !attributes.contains(" alt=") { attributes = " alt=\"\(Self.escape((href as NSString).lastPathComponent))\"" + attributes }
            return "<img src=\"\(Self.escape(href))\"\(attributes)>"
        }
        let text = description.map(inline) ?? Self.escape(label)
        return "<a href=\"\(Self.escape(href))\">\(text)</a>"
    }

    private func slugOnly(_ text: String) -> String {
        var slug = ""
        var dash = false
        for c in text.lowercased() {
            if c.isLetter || c.isNumber {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        return slug
    }

    /// `:key value :other "quoted value"`.
    private func parseAttributes(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let regex = try! NSRegularExpression(pattern: ":([A-Za-z_-]+)[ \\t]+(\"[^\"]*\"|[^:\\s][^\\s]*)")
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var value = ns.substring(with: m.range(at: 2))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            pairs.append((ns.substring(with: m.range(at: 1)), value))
        }
        return pairs
    }

    private func timestamp(_ text: String) -> String {
        guard let stamp = Timestamp.parse(text) else { return Self.escape(text) }
        func date(_ p: Timestamp.Point) -> String { String(format: "%04d-%02d-%02d", p.year, p.month, p.day) }
        func time(_ p: Timestamp.Point) -> String? {
            guard let h = p.hour, let m = p.minute else { return nil }
            return String(format: "%02d:%02d", h, m)
        }
        func element(_ p: Timestamp.Point, full: Bool) -> String {
            let datetime = date(p) + (time(p).map { "T" + $0 } ?? "")
            let shown = full ? date(p) + (time(p).map { " " + $0 } ?? "") : (time(p) ?? date(p))
            return "<time class=\"timestamp\" datetime=\"\(datetime)\">\(shown)</time>"
        }
        guard let end = stamp.end else { return element(stamp.start, full: true) }
        let sameDay = end.year == stamp.start.year && end.month == stamp.start.month && end.day == stamp.start.day
        return element(stamp.start, full: true) + "–" + element(end, full: !sameDay)
    }

    private func footnote(_ text: String) -> String {
        guard let m = text.firstMatch(of: /^\[fn:([^:\]]*)(?::(.*))?\]$/) else { return Self.escape(text) }
        var label = String(m.1)
        let inlineText = m.2.map(String.init)
        if label.isEmpty {
            anonymous += 1
            label = "anonymous-\(anonymous)"
        }
        let number: Int
        if let existing = footnoteNumbers[label] {
            number = existing
        } else {
            let content: FootnoteContent
            if let inlineText {
                content = .inline(inlineText)
            } else if let definition = definitions[label] {
                content = .definition(definition)
            } else {
                return Self.escape(text)
            }
            footnoteOrder.append((label, content))
            number = footnoteOrder.count
            footnoteNumbers[label] = number
        }
        return "<sup class=\"footnote-ref\"><a id=\"fnr-\(number)\" href=\"#fn-\(number)\">\(number)</a></sup>"
    }
}
