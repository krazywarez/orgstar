import Foundation

/// LaTeX export as ox-latex (Org 9.8.7) writes it under `emacs -Q`: the default packages,
/// `article`, `report` or `book` sectioning, `verbatim` source blocks, `tabular` tables. What it
/// can't write as Emacs would throws `Unsupported`, naming the construct, instead of writing
/// something else. Labels are made from the document, where Emacs picks them at random.
public enum LaTeXExport {
    public struct Unsupported: Error, LocalizedError, Equatable, CustomStringConvertible {
        public let reason: String
        public var errorDescription: String? { reason }
        public var description: String { reason }
    }

    /// `org-latex-classes`: each class's header and its sectioning, numbered and not.
    static let classes: [String: (header: String, sections: [(String, String)])] = {
        let part = ("\\part{%s}", "\\part*{%s}")
        let chapter = ("\\chapter{%s}", "\\chapter*{%s}")
        let section = ("\\section{%s}", "\\section*{%s}")
        let subsection = ("\\subsection{%s}", "\\subsection*{%s}")
        let subsubsection = ("\\subsubsection{%s}", "\\subsubsection*{%s}")
        return [
            "article": ("\\documentclass[11pt]{article}", [section, subsection, subsubsection, ("\\paragraph{%s}", "\\paragraph*{%s}"), ("\\subparagraph{%s}", "\\subparagraph*{%s}")]),
            "report": ("\\documentclass[11pt]{report}", [part, chapter, section, subsection, subsubsection]),
            "book": ("\\documentclass[11pt]{book}", [part, chapter, section, subsection, subsubsection]),
        ]
    }()

    /// `org-latex-default-packages-alist`: options, package and the compilers it is for.
    static let packages: [(String, String, [String])] = [
        ("", "amsmath", ["lualatex", "xelatex"]), ("", "fontspec", ["lualatex", "xelatex"]),
        ("utf8", "inputenc", ["pdflatex"]), ("T1", "fontenc", ["pdflatex"]),
        ("", "graphicx", []), ("", "longtable", []), ("", "wrapfig", []), ("", "rotating", []), ("normalem", "ulem", []),
        ("", "amsmath", ["pdflatex"]), ("", "amssymb", ["pdflatex"]), ("", "capt-of", []), ("", "hyperref", []),
    ]

    static let compilers = ["pdflatex", "xelatex", "lualatex"]

    /// A `.tex` document, or with `bodyOnly` what goes between `\begin{document}` and
    /// `\end{document}` without the title and contents. `author` stands for `user-full-name`,
    /// `language` for `org-export-default-language`, `now` for the `% Created` line. `file` adds
    /// the final newline `org-export-to-file` writes.
    public static func document(
        _ text: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date(), bodyOnly: Bool = false,
        author: String = "", language: String = "en", timeZone: TimeZone = .current, file: Bool = false
    ) throws -> String {
        let directory = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let included = ExportPreprocess.includes(text, directory: directory)
        // Org expands macro objects only: `{{{…}}}` in verbatim text and blocks stays.
        let marker = "\u{E000}"
        var literal = included
        if included.contains("{{{") {
            if included.contains(marker) { throw LaTeXExport.Unsupported(reason: "U+E000 in the text") }
            let ns = included as NSString
            let kept = OrgParser.parse(included, defaults: settings).root.descendants()
                .filter { [.verbatim, .code, .block, .fixedWidth, .comment, .latexEnvironment, .exportSnippet].contains($0.kind) }.map(\.range)
            var out = ""
            var at = 0
            for range in kept.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= at {
                out += ns.substring(with: NSRange(location: at, length: range.lowerBound - at))
                out += ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).replacingOccurrences(of: "{{{", with: marker + "{{")
                at = range.upperBound
            }
            literal = out + ns.substring(from: at)
        }
        let text = ExportPreprocess.macros(literal, path: path, now: now, setup: settings.setupKeywords).replacingOccurrences(of: marker, with: "{")
        let tree = OrgParser.parse(text, defaults: settings)
        let keywords = settings.setupKeywords.split(separator: "\n").map(String.init)
            + tree.root.descendants().filter { $0.kind == .keyword }.map { $0.text.trimmingCharacters(in: .newlines) }
        let renderer = try LaTeXRenderer(tree: tree, text: text, settings: settings, keywords: keywords, language: language)
        let body = try renderer.body()
        let output = bodyOnly ? body : try renderer.template(body, author: author, now: now, timeZone: timeZone)
        return file && !output.isEmpty && !output.hasSuffix("\n") ? output + "\n" : output
    }
}

final class LaTeXRenderer {
    typealias Unsupported = LaTeXExport.Unsupported

    let tree: OrgTree
    let source: NSString
    let settings: OrgSettings
    let options: ExportOptions
    /// Keyword values by name, in order.
    let keywords: [String: [String]]
    let language: String
    let className: String
    /// `num` and `toc` as written: nil for t.
    let num: Int?
    let numbered: Bool
    let toc: Int?
    let withTOC: Bool
    let timeStampFile: Bool
    private var selected: Set<Int>?
    /// Added to heading levels.
    private var levelOffset = 0
    private var exportSource: ExportSource
    private let model: DocumentModel

    init(tree: OrgTree, text: String, settings: OrgSettings, keywords lines: [String], language: String) throws {
        self.tree = tree
        source = text as NSString
        self.settings = settings
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
        className = options.latexClass ?? "article"
        guard LaTeXExport.classes[className] != nil else { throw Unsupported(reason: "Unknown LaTeX class `\(className)'") }

        // `#+OPTIONS` this export follows; any other item only at its default.
        let defaults = ["\\n": "nil", ":": "t", "*": "t", "e": "t", "f": "t", "|": "t", "p": "nil", "c": "nil", "prop": "nil",
                        "stat": "t", "tasks": "t", "inline": "t", "arch": "headline", "email": "nil", "creator": "nil",
                        "broken-links": "nil", "'": "nil", "<": "t", "d": "(not \"LOGBOOK\")", "latex-use-sans": "nil", "expand-links": "t"]
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
        timeStampFile = items["timestamp"] != "nil"
        for key in ["CITE_EXPORT", "BIBLIOGRAPHY", "PRINT_BIBLIOGRAPHY", "LATEX_CLASS_PRE", "LATEX_FOOTNOTE_COMMAND", "CALL", "EXPORT_LATEX_CLASS"] where keywords[key] != nil {
            throw Unsupported(reason: "#+\(key)")
        }
        for line in options.latexHeader + options.latexHeaderExtra + (options.latexClassOptions.map { [$0] } ?? [])
        where line.contains("{babel}") || line.contains("{polyglossia}") || line.contains("\\babelprovide") || line.contains("[AUTO]") {
            throw Unsupported(reason: "Babel or Polyglossia in the LaTeX header")
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
        selected = HTMLRenderer.selection(tree, tags: options.selectTags)
        // `:headline-offset`: the shallowest exported heading is level 1.
        let options = options
        let selected = selected
        let top = tree.root.children.compactMap { $0.kind == .section ? $0.firstChild(.heading) : nil }
            .filter { HTMLRenderer.sectionExport($0, options: options, selected: selected) != .nothing }
        levelOffset = 1 - (top.compactMap { $0.tokens.first { $0.kind == .stars }?.text.count }.min() ?? 1)
        try countFootnotes()
    }

    // MARK: - Template

    /// `org-latex-template`.
    func template(_ body: String, author: String, now: Date, timeZone: TimeZone) throws -> String {
        var out = ""
        if timeStampFile {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
            out += "% Created \(formatter.string(from: now))\n"
        }
        let compiler = options.latexCompiler ?? "pdflatex"
        if LaTeXExport.compilers.contains(compiler) { out += "% Intended LaTeX compiler: \(compiler)\n" }
        out += preamble(compiler: compiler)
        if numbered, let num { out += "\\setcounter{secnumdepth}{\(num)}\n" }
        var authorText: String? = try keywords["AUTHOR"].map { try parsed($0) } ?? (author.isEmpty ? nil : try inlineString(author))
        if authorText?.isEmpty == true { authorText = nil }
        if options.author, let authorText { out += "\\author{\(authorText)}\n" }
        // The default, `\today`, is a LaTeX fragment, which `tex:nil` takes out.
        let date = try keywords["DATE"].map { try parsed($0) } ?? (options.tex ? "\\today" : "")
        out += "\\date{\(options.date ? date : "")}\n"
        let title = try keywords["TITLE"].map { try parsed($0) } ?? ""
        let subtitle = try keywords["SUBTITLE"].map { "\\\\\\medskip\n\\large " + (try parsed($0)) } ?? ""
        out += "\\title{\(title)\(subtitle)}\n"
        let lang = Self.languageNames[self.language] ?? self.language
        out += "\\hypersetup{\n pdfauthor={\(options.author ? authorText ?? "" : "")},\n pdftitle={\(options.title ? title : "")},\n"
        out += " pdfkeywords={\(try keywords["KEYWORDS"].map { try parsed($0) } ?? "")},\n"
        out += " pdfsubject={\(try keywords["DESCRIPTION"].map { try parsed($0) } ?? "")},\n pdfcreator={},\n pdflang={\(Self.capitalize(lang))}}\n"
        out += "\\begin{document}\n\n"
        if options.title, !title.isEmpty { out += "\\maketitle\n" }
        if withTOC {
            if let toc { out += "\\setcounter{tocdepth}{\(toc)}\n" }
            out += "\\tableofcontents\n\n"
        }
        return out + body + "\\end{document}"
    }

    /// A keyword parsed as Org text, its lines joined with spaces.
    private func parsed(_ values: [String]) throws -> String {
        try inlineString(values.joined(separator: " "))
    }

    /// `org-latex-make-preamble` with the class, its options and the header lines.
    private func preamble(compiler: String) -> String {
        var header = LaTeXExport.classes[className]!.header
        if let classOptions = options.latexClassOptions {
            header = header.replacingOccurrences(of: "[11pt]", with: classOptions)
        }
        let known = LaTeXExport.compilers.contains { $0.caseInsensitiveCompare(compiler) == .orderedSame }
        let packages = LaTeXExport.packages.filter { !known || $0.2.isEmpty || $0.2.contains { $0.caseInsensitiveCompare(compiler) == .orderedSame } }
            .map { $0.0.isEmpty ? "\\usepackage{\($0.1)}" : "\\usepackage[\($0.0)]{\($0.1)}" }
        var out = header + "\n\n" + packages.joined(separator: "\n")
        let extra = [options.latexHeader, options.latexHeaderExtra].filter { !$0.isEmpty }.map { Self.normalize($0.joined(separator: "\n")) }.joined()
        if extra.contains(where: { !$0.isWhitespace }) { out += "\n" + extra }
        return Self.normalize(out)
    }

    /// `:lang-name` in `org-latex-language-alist`.
    static let languageNames: [String: String] = [
        "af": "Afrikaans", "am": "Amharic", "ar": "Arabic", "ast": "Asturian", "bg": "Bulgarian", "bn": "Bengali", "bo": "Tibetan",
        "br": "Breton", "ca": "Catalan", "cop": "Coptic", "cs": "Czech", "cy": "Welsh", "da": "Danish", "de": "German", "de-de": "German",
        "de-at": "German", "dsb": "Lower Sorbian", "dv": "Dhivehi", "el": "Greek", "el-polyton": "Polytonic Greek", "grc": "Ancient Greek",
        "en": "English", "en-au": "English", "en-ca": "English", "en-gb": "English", "en-nz": "English", "en-us": "English",
        "eo": "Esperanto", "es": "Spanish", "es-mx": "Spanish", "et": "Estonian", "eu": "Basque", "fa": "Persian", "fi": "Finnish",
        "fr": "French", "fr-ca": "French", "fur": "Friulian", "ga": "Irish Gaelic", "gd": "Scottish Gaelic", "gl": "Galician",
        "he": "Hebrew", "hi": "Hindi", "hr": "Croatian", "hsb": "Upper Sorbian", "hu": "Magyar", "hy": "Armenian", "ia": "Interlingua",
        "id": "Indonesian", "is": "Icelandic", "it": "Italian", "kn": "Kannada", "la": "Latin", "la-classic": "Classic Latin",
        "la-medieval": "Medieval Latin", "la-ecclesiastic": "Ecclesiastic Latin", "lo": "Lao", "lt": "Lithuanian", "lv": "Latvian",
        "ml": "Malayalam", "mr": "Marathi", "ms": "Malay", "nb": "Norwegian Bokmål", "nl": "Dutch", "nn": "Norwegian Nynorsk",
        "no": "Norwegian", "oc": "Occitan", "pl": "Polish", "pms": "Piedmontese", "pt": "Portuges", "pt-br": "Portuges", "rm": "Romansh",
        "ro": "Romanian", "ru": "Russian", "sa": "Sanskrit", "sk": "Slovak", "sl": "Slovene", "sq": "Albanian", "sr": "Serbian",
        "sr-cyrl": "Serbian", "sr-latn": "Serbian", "sv": "Swedish", "syr": "Syriac", "ta": "Tamil", "te": "Telugu", "th": "Thai",
        "tk": "Turkmen", "tr": "Turkish", "uk": "Ukrainian", "ur": "Urdu", "vi": "Vietnamese", "zh": "Chinese Simplified",
        "zh-cn": "Chinese Simplified", "zh-tw": "Chinese Traditional",
    ]

    /// Emacs's `capitalize`: each word's first letter up, the rest down.
    static func capitalize(_ s: String) -> String {
        var out = ""
        var inWord = false
        for c in s {
            let word = c.isLetter || c.isNumber
            out += word ? (inWord ? c.lowercased() : c.uppercased()) : String(c)
            inWord = word
        }
        return out
    }

    // MARK: - Strings

    /// `org-element-normalize-string`: one final newline, none for the empty string.
    static func normalize(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var end = s.endIndex
        var cut = s.endIndex
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
        return String(s[..<cut]) + "\n"
    }

    /// `org-trim`.
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0C}\u{0B}")) }

    /// `org-latex--protect-text`.
    static func protect(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\{}$%&_#~^".contains(c) { out += "\\" }
            out.append(c)
        }
        return out
    }

    /// `org-latex--protect-texttt`.
    static func texttt(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("--") || rest.hasPrefix("<<") || rest.hasPrefix(">>") {
                out += "\(s[i]){}\(s[i]){}"
                i = s.index(i, offsetBy: 2)
                continue
            }
            switch s[i] {
            case "\\": out += "\\textbackslash{}"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "{", "}", "$", "%", "&", "_", "#": out += "\\\(s[i])"
            default: out.append(s[i])
            }
            i = s.index(after: i)
        }
        return "\\texttt{\(out)}"
    }

    /// `org-remove-indentation`: the common indentation of the non-blank lines removed.
    static func removeIndentation(_ s: String) throws -> String {
        let lines = s.components(separatedBy: "\n")
        let indents = lines.filter { $0.contains { $0 != " " && $0 != "\t" } }.map { $0.prefix { $0 == " " || $0 == "\t" } }
        guard let common = indents.map(\.count).min(), common > 0 else { return s }
        if indents.contains(where: { $0.contains("\t") }) { throw Unsupported(reason: "Tabs in indented code") }
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }

    // MARK: - Labels

    private var references: [String: String] = [:]
    private var usedReferences: Set<String> = []

    /// `org-export-get-reference`: a label for `key`, made from it so it stays the same between
    /// exports of the same document.
    func reference(_ key: String) -> String {
        if let existing = references[key] { return existing }
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        var value = hash & 0xFFFFFFF
        var label = String(format: "org%07x", value)
        while usedReferences.contains(label) {
            value = (value &+ 1) & 0xFFFFFFF
            label = String(format: "org%07x", value)
        }
        usedReferences.insert(label)
        references[key] = label
        return label
    }

    // MARK: - Document

    /// The transcoded document, `org-element-normalize-string`'d.
    func body() throws -> String {
        var nodes = tree.root.children
        // With a select tag, the text before the first heading isn't exported.
        if selected != nil { nodes.removeAll { $0.kind == .zerothSection } }
        var out = ""
        for node in nodes {
            if node.kind == .zerothSection {
                out += Self.normalize(try elements(node.children, end: node.range.upperBound))
            } else if node.kind == .section {
                out += try section(node) ?? ""
            }
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

    /// Affiliated keywords of the element being transcoded.
    struct Affiliated {
        var caption: [String] = []
        var name: String?
        var attr: [String] = []
        /// `#+RESULTS`' value, when it has the keyword.
        var results: String?

        /// `org-export-read-attribute :attr_latex`: values by key, nil for `nil` or nothing.
        func attribute(_ key: String) -> String?? {
            guard !attr.isEmpty else { return .none }
            var s = attr.joined(separator: " ")
            var pairs: [(String, String?)] = []
            var pending: String?
            let re = #/(?:^|[ \t]+)(:[-a-zA-Z0-9_]+)(?:[ \t]+|$)/#
            while let m = s.firstMatch(of: re) {
                if let pending { pairs.append((pending, Self.value(String(s[..<m.range.lowerBound])))) }
                pending = String(m.1)
                s = String(s[m.range.upperBound...])
            }
            if let pending { pairs.append((pending, Self.value(s))) }
            guard let pair = pairs.first(where: { $0.0 == ":" + key }) else { return .none }
            return .some(pair.1)
        }

        static func value(_ s: String) -> String? {
            if s.isEmpty || s == "nil" { return nil }
            if let m = s.wholeMatch(of: /"("+)?"/) { return m.1.map(String.init) ?? "" }
            return s
        }

        /// The attribute's value, nil when absent or nil.
        func value(_ key: String) -> String? { attribute(key) ?? nil }
        func has(_ key: String) -> Bool { attribute(key) != nil }
    }

    /// `elements`, each `org-element-normalize-string`'d and followed by its blank lines, as
    /// `org-export-data` joins a greater element's contents.
    func elements(_ nodes: [SyntaxNode], end: Int) throws -> String {
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
                case "ATTR_LATEX": affiliated.attr.append(String(m.3))
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
            guard let result = try element(node, affiliated: affiliated, previous: previous, previousBlank: pendingBlank) else {
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
            var text = Self.normalize(result) + String(repeating: "\n", count: pendingBlank)
            if node.kind == .paragraph { text = Self.cleanLineBreaks(text) }
            out += text
        }
        return out
    }

    /// Elements `org-export--prune-tree` takes out of the tree.
    private func pruned(_ node: SyntaxNode) -> Bool {
        switch node.kind {
        case .planning, .propertyDrawer, .clock, .footnoteDefinition: return true
        case .drawer: return drawerName(node).uppercased() == "LOGBOOK"
        case .latexEnvironment: return !options.tex
        default: return false
        }
    }

    private func drawerName(_ node: SyntaxNode) -> String {
        node.text.firstMatch(of: /^[ \t]*:([\w-]+):/).map { String($0.1) } ?? ""
    }

    /// `org-latex-clean-invalid-line-breaks`.
    static func cleanLineBreaks(_ s: String) -> String {
        s.replacing(#/(?m)(\\end\{[A-Za-z0-9*]+\}|^)[ \t]*\\\\[ \t]*$/#) { String($0.1) }
    }

    // MARK: - Headlines

    /// A section's heading and contents, nil when not exported.
    private func section(_ node: SyntaxNode) throws -> String? {
        guard let heading = node.firstChild(.heading) else { return nil }
        // `org-footnote-section`'s heading isn't exported.
        if heading.firstChild(.title)?.text == "Footnotes" { return nil }
        let export = HTMLRenderer.sectionExport(heading, options: options, selected: selected)
        if export == .nothing { return nil }
        let children = node.children.filter { $0.kind != .heading }
        let body = children.filter { $0.kind != .section }
        let subsections = children.filter { $0.kind == .section }
        var contents: String?
        if export == .all {
            let out = Self.normalize(try elements(body, end: subsections.first?.range.lowerBound ?? node.range.upperBound))
            contents = Self.normalize(out + (try subsections.compactMap { try section($0) }.joined()))
        }
        let first = children.first?.range.lowerBound ?? node.range.upperBound
        let preBlank = children.isEmpty ? 0 : blankLines(from: heading.range.lowerBound, to: first)
        return Self.normalize(try headline(heading, section: node, contents: contents, preBlank: preBlank))
    }

    /// `org-latex-headline`.
    private func headline(_ heading: SyntaxNode, section: SyntaxNode, contents: String?, preBlank: Int) throws -> String {
        let tokens = heading.tokens
        let level = (tokens.first { $0.kind == .stars }?.text.count ?? 1) + levelOffset
        if let index = model.headings.firstIndex(where: { $0.headingRange.lowerBound == heading.range.lowerBound }) {
            let keys = model.headings[index].properties.map { $0.key.uppercased() }
            if keys.contains("UNNUMBERED") || keys.contains("ALT_TITLE") { throw Unsupported(reason: "UNNUMBERED and ALT_TITLE properties") }
        }
        let isNumbered = numbered && (num.map { level <= $0 } ?? true)
        let titleNode = heading.firstChild(.title)
        if titleNode?.descendants().contains(where: { $0.kind == .footnoteReference }) == true { throw Unsupported(reason: "Footnotes in headings") }
        let text = try titleNode.map { try Self.trim(inline($0, sectionTitle: true)) } ?? ""
        var full = ""
        if options.todo, let todo = tokens.first(where: { $0.kind == .todoKeyword })?.text {
            full += "{\\bfseries\\sffamily \(plainText(todo))} "
        }
        if options.priority, let priority = tokens.first(where: { $0.kind == .priority })?.text,
           let letter = priority.firstMatch(of: /\[#(.+)\]/)?.1 {
            full += "\\framebox{\\#\(letter)} "
        }
        full += text
        if options.tags, let tags = tokens.first(where: { $0.kind == .tags })?.text {
            let shown = tags.split(separator: ":").map(String.init)
            if !shown.isEmpty { full += "\\hfill{}\\textsc{\(shown.map(Self.protect).joined(separator: ":"))}" }
        }
        let label = "\\label{sec:\(reference("heading@\(heading.range.lowerBound)"))}\n"
        let pre = String(repeating: "\n", count: preBlank)
        let sections = LaTeXExport.classes[className]!.sections
        if level > options.headlineLevels || level > sections.count {
            let siblings = exportedSiblings(section)
            let first = siblings.first == section.range.lowerBound
            let last = siblings.last == section.range.lowerBound
            let list = isNumbered ? "enumerate" : "itemize"
            var out = first ? "\\begin{\(list)}\n" : ""
            out += "\\item" + (full.firstMatch(of: /^[ \t]*\[/) != nil ? "\\relax" : "") + " " + full + "\n" + label + pre + (contents ?? "")
            if last {
                while let c = out.last, c == " " || c == "\t" || c == "\n" { out.removeLast() }
                out += "\n\\end{\(list)}"
            }
            return out
        }
        let format = isNumbered ? sections[level - 1].0 : sections[level - 1].1
        return format.replacingOccurrences(of: "%s", with: full) + "\n" + label + pre + (contents ?? "")
    }

    /// The headline sections exported beside `section` at its level, by start: a low-level
    /// headline opens its list when it is the first and closes it when it is the last.
    private func exportedSiblings(_ section: SyntaxNode) -> [Int] {
        guard let parent = section.parent else { return [section.range.lowerBound] }
        return parent.children.filter { child in
            guard child.kind == .section, let heading = child.firstChild(.heading) else { return false }
            return HTMLRenderer.sectionExport(heading, options: options, selected: selected) != .nothing
        }.map(\.range.lowerBound)
    }

    // MARK: - Elements

    private func blockType(_ node: SyntaxNode) -> String {
        node.text.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)/).map { $0.1.lowercased() } ?? ""
    }

    /// One element's transcoding, nil for none.
    private func element(_ node: SyntaxNode, affiliated: Affiliated, previous: SyntaxNode?, previousBlank: Int) throws -> String? {
        switch node.kind {
        case .paragraph:
            return try paragraph(node, affiliated: affiliated)
        case .plainList:
            return try list(node, affiliated: affiliated)
        case .table:
            return try table(node, affiliated: affiliated)
        case .block:
            return try block(node, affiliated: affiliated)
        case .horizontalRule:
            var out = previous != nil && previousBlank == 0 ? "\n" : ""
            out += try wrapLabel(affiliated, "\\noindent\\rule{\(affiliated.value("width") ?? "\\textwidth")}{\(affiliated.value("thickness") ?? "0.5pt")}")
            return out
        case .fixedWidth:
            let value = node.text.components(separatedBy: "\n").filter { !$0.isEmpty }
                .map { $0.replacingOccurrences(of: "^[ \\t]*: ?", with: "", options: .regularExpression) }.joined(separator: "\n")
            return try wrapLabel(affiliated, "\\begin{verbatim}\n\(try Self.removeIndentation(value))\n\\end{verbatim}")
        case .latexEnvironment:
            guard options.tex else { return nil }
            if affiliated.name != nil || !affiliated.caption.isEmpty { throw Unsupported(reason: "Named or captioned LaTeX environments") }
            var value = node.text
            while value.hasSuffix("\n") { value.removeLast() }
            return try Self.removeIndentation(value) + "\n"
        case .keyword:
            return try keyword(node)
        case .drawer:
            if drawerName(node).uppercased() == "LOGBOOK" { return nil }
            let inner = node.children
            return try wrapLabel(affiliated, Self.normalize(try elements(inner, end: node.range.upperBound)))
        case .dynamicBlock:
            let lines = node.text.components(separatedBy: "\n")
            return try wrapLabel(affiliated, Self.normalize(try blocks(lines.dropFirst().dropLast(2).joined(separator: "\n"))))
        case .planning, .propertyDrawer, .clock, .footnoteDefinition, .nodeProperty:
            return nil
        default:
            throw Unsupported(reason: "\(node.kind)")
        }
    }

    /// `org-latex--wrap-label`.
    private func wrapLabel(_ affiliated: Affiliated, _ output: String) throws -> String {
        guard let name = affiliated.name, output.contains(where: { !$0.isWhitespace }) else { return output }
        return "\\phantomsection\n\\label{\(reference("name:" + name))}\n" + output
    }

    /// Org text parsed and transcoded as elements.
    func blocks(_ text: String) throws -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        let saved = exportSource
        exportSource = ExportSource(tree: tree, text: text)
        defer { exportSource = saved }
        let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        if nodes.contains(where: { $0.kind == .section }) { throw Unsupported(reason: "Headings inside blocks") }
        let saveSource = currentSource
        currentSource = text as NSString
        defer { currentSource = saveSource }
        return try elements(nodes, end: (text as NSString).length)
    }

    /// The text blank lines are counted in, when it isn't the document's.
    private var currentSource: NSString?

    private func keyword(_ node: SyntaxNode) throws -> String? {
        let line = node.text.trimmingCharacters(in: .newlines)
        guard let m = line.firstMatch(of: #/^[ \t]*#\+([^:\s]+):(?:[ \t]+(.*?))?[ \t]*$/#) else { return nil }
        let value = m.2.map(String.init) ?? ""
        switch m.1.uppercased() {
        case "LATEX": return value
        case "INDEX": return "\\index{\(value)}"
        case "TOC":
            if value.range(of: "\\blocal\\b", options: [.regularExpression, .caseInsensitive]) != nil { throw Unsupported(reason: "#+TOC: local") }
            if value.range(of: "\\bheadlines\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                let depth = value.firstMatch(of: /\b([0-9]+)\b/).map { "\\setcounter{tocdepth}{\($0.1)}\n" } ?? ""
                return depth + "\\tableofcontents"
            }
            if value.range(of: "\\btables\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "\\listoftables" }
            if value.range(of: "\\blistings\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "\\lstlistoflistings" }
            return nil
        default: return nil
        }
    }

    // MARK: Paragraphs

    private func paragraph(_ node: SyntaxNode, affiliated: Affiliated, ignoreFirst: Bool = false) throws -> String {
        var items = Self.normalizeIndentation(try inlineItems(node), ignoreFirst: ignoreFirst)
        if let image = soleImage(items) {
            items = []
            return try inlineImage(image, affiliated: affiliated, alone: true)
        }
        if items.contains(where: { if case .object(let n, _) = $0, n.kind == .link, isImage(n) { return true } else { return false } }) {
            currentAffiliated = affiliated
            defer { currentAffiliated = nil }
            return Self.removeBlankLines(try transcode(items))
        }
        if !affiliated.caption.isEmpty { throw Unsupported(reason: "Captioned paragraphs") }
        return Self.removeBlankLines(try transcode(items))
    }

    private var currentAffiliated: Affiliated?

    /// `org-remove-blank-lines`.
    static func removeBlankLines(_ s: String) -> String {
        s.replacing(#/\n(?:[ \t]*\n)+/#, with: "\n")
    }

    // MARK: Lists

    private func isOrderedBullet(_ item: SyntaxNode) -> Bool {
        let bullet = item.tokens.first { $0.kind == .bullet }?.text ?? "-"
        return bullet.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
    }

    /// `org-latex-plain-list`, its type from the first item.
    private func list(_ node: SyntaxNode, affiliated: Affiliated, orderedDepth: Int = 0) throws -> String {
        let items = node.children.filter { $0.kind == .item }
        guard let first = items.first else { return "" }
        let ordered = isOrderedBullet(first)
        let description = !ordered && first.firstChild(.itemTag) != nil
        let type = affiliated.value("environment") ?? (ordered ? "enumerate" : description ? "description" : "itemize")
        let depth = orderedDepth + (ordered ? 1 : 0)
        var contents = ""
        for (index, item) in items.enumerated() {
            let next = index + 1 < items.count ? items[index + 1].range.lowerBound : node.range.upperBound
            let text = try self.item(item, ordered: ordered, depth: depth)
            contents += Self.normalize(text) + String(repeating: "\n", count: blankLines(from: item.range.lowerBound, to: next))
        }
        return try wrapLabel(affiliated, "\\begin{\(type)}\(affiliated.value("options") ?? "")\n\(Self.normalize(contents))\\end{\(type)}")
    }

    /// `org-latex-item`.
    private func item(_ item: SyntaxNode, ordered: Bool, depth: Int) throws -> String {
        var counter = ""
        if let value = item.tokens.first(where: { $0.kind == .counter })?.text.firstMatch(of: /([0-9]+)/) {
            guard ordered, depth < 5, let n = Int(value.1) else { throw Unsupported(reason: "Counters outside ordered lists") }
            counter = "\\setcounter{enum\(["i", "ii", "iii", "iv"][depth - 1])}{\(n - 1)}\n"
        } else if item.tokens.contains(where: { $0.kind == .counter }) {
            throw Unsupported(reason: "Alphabetical counters")
        }
        let checkbox: String? = item.tokens.first { $0.kind == .checkbox }.map {
            switch $0.text.uppercased() {
            case "[X]": "$\\boxtimes$"
            case "[-]": "$\\boxminus$"
            default: "$\\square$"
            }
        }
        var tag: String?
        if let tagNode = item.firstChild(.itemTag) {
            if tagNode.descendants().contains(where: { $0.kind == .footnoteReference }) { throw Unsupported(reason: "Footnotes in item tags") }
            tag = try transcode(Self.merge(try inlineItems(tagNode)))
        }
        let children = item.children.filter { $0.kind != .itemTag }
        var contents = ""
        var previous: SyntaxNode?
        for (index, child) in children.enumerated() {
            let next = index + 1 < children.count ? children[index + 1].range.lowerBound : item.range.upperBound
            var result: String?
            if child.kind == .paragraph, previous == nil, index == 0 {
                // The first paragraph's first line follows the bullet: its indentation doesn't count.
                let bulletLine = source.lineRange(for: NSRange(location: item.range.lowerBound, length: 0))
                let ignore = child.range.lowerBound < NSMaxRange(bulletLine)
                result = try paragraph(child, affiliated: Affiliated(), ignoreFirst: ignore)
            } else if child.kind == .plainList {
                result = try list(child, affiliated: Affiliated(), orderedDepth: depth)
            } else {
                // Elements with affiliated keywords go through `elements`.
                result = try elements([child], end: next)
                if result == "" { result = nil }
                if let r = result {
                    contents += r
                    previous = child
                    continue
                }
            }
            guard let result else { continue }
            previous = child
            var text = Self.normalize(result) + String(repeating: "\n", count: blankLines(from: child.range.lowerBound, to: next))
            if child.kind == .paragraph { text = Self.cleanLineBreaks(text) }
            contents += text
        }
        if children.contains(where: { $0.kind == .affiliatedKeyword }) { throw Unsupported(reason: "Affiliated keywords in list items") }
        contents = Self.normalize(contents)
        var out = counter + "\\item"
        if let checkbox, let tag {
            out += ordered ? "{\(checkbox) \(tag)} " : "[{\(checkbox) \(tag)}] "
        } else if let label = checkbox ?? tag {
            out += ordered ? "{\(label)} " : "[{\(label)}] "
        } else if contents.firstMatch(of: /^[ \t]*\[/) != nil {
            out += "\\relax "
        } else {
            out += " "
        }
        return out + Self.trim(contents)
    }

    // MARK: Tables

    /// `org-table-number-regexp`.
    static let numberPattern = try! NSRegularExpression(pattern: "^(?:[<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%:]*|[<>]?[-+]?0[xX][0-9a-fA-F.]+|[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+|nan|[-+u]?inf)$")

    private func table(_ node: SyntaxNode, affiliated: Affiliated) throws -> String {
        let rows = node.children.filter { $0.kind == .tableRow }
        if node.descendants().contains(where: { $0.kind == .footnoteReference }) { throw Unsupported(reason: "Footnotes in tables") }
        let mode = affiliated.value("mode") ?? "table"
        guard mode == "table" else { throw Unsupported(reason: "#+ATTR_LATEX: :mode \(mode)") }
        let environment = affiliated.value("environment") ?? "tabular"
        if ["longtable", "longtabu", "tabbing"].contains(environment) { throw Unsupported(reason: "#+ATTR_LATEX: :environment \(environment)") }
        let booktabs = affiliated.has("booktabs") ? affiliated.value("booktabs") != nil : false
        if booktabs { throw Unsupported(reason: "Booktabs tables") }
        // Cells as transcoded, rules as nil.
        var cells: [[String]?] = []
        for row in rows {
            let rowCells = row.children.filter { $0.kind == .tableCell }
            if rowCells.isEmpty, row.text.trimmingCharacters(in: .whitespaces).hasPrefix("|-") {
                cells.append(nil)
                continue
            }
            if rowCells.isEmpty { continue }
            cells.append(try rowCells.map { try transcode(Self.merge(try inlineItems($0, trimmed: true))) })
        }
        let data = cells.compactMap { $0 }
        if Self.hasSpecialRows(data.map { $0 }, raw: rows) { throw Unsupported(reason: "Tables with alignment cookies or special columns") }
        let columns = data.first?.count ?? 0
        var align = ""
        for c in 0..<columns {
            var numbers = 0, total = 0
            var previousNumber = false
            for row in data {
                let value = c < row.count ? row[c] : ""
                total += 1
                let isNumber = Self.numberPattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
                if isNumber || (value.isEmpty && previousNumber) {
                    previousNumber = true
                    numbers += 1
                } else {
                    previousNumber = false
                }
            }
            align += total > 0 && Double(numbers) / Double(total) >= 0.5 ? "r" : "l"
        }
        let alignment = affiliated.value("align") ?? align
        var contents = ""
        for row in cells {
            guard let row else {
                contents += "\\hline\n"
                continue
            }
            contents += Self.normalize(row.joined(separator: " & ") + "\\\\\n")
        }
        contents = Self.normalize(contents)
        var width = ""
        if let w = affiliated.value("width"), !["tabular", "longtable"].contains(environment) {
            if ["tabu", "longtabu"].contains(environment) { throw Unsupported(reason: "tabu tables") }
            width = "{\(w)}"
        }
        let opt = affiliated.value("options").map { "[\($0)]" } ?? ""
        let table = "\\begin{\(environment)}\(opt)\(width){\(alignment)}\n\(contents)\\end{\(environment)}"
        let caption = try captionLabel(affiliated, type: "table", prefix: "tab:")
        return decorate(table, affiliated: affiliated, caption: caption, above: true)
    }

    /// Whether a table has rows of alignment cookies or a column of row marks.
    static func hasSpecialRows(_ data: [[String]], raw: [SyntaxNode]) -> Bool {
        let cookie = /^<[lrc]?[0-9]*>$/
        for row in raw {
            let cells = row.children.filter { $0.kind == .tableCell }.map { $0.text.trimmingCharacters(in: .whitespaces) }
            guard !cells.isEmpty else { continue }
            if cells.allSatisfy({ $0.isEmpty || $0.wholeMatch(of: cookie) != nil }), cells.contains(where: { !$0.isEmpty }) { return true }
        }
        let marks: Set<String> = ["", "#", "!", "$", "*", "^", "_", "/"]
        let first = raw.compactMap { $0.children.first { $0.kind == .tableCell }?.text.trimmingCharacters(in: .whitespaces) }
        return !first.isEmpty && first.allSatisfy(marks.contains) && first.contains { !$0.isEmpty }
    }

    /// `org-latex--decorate-table`.
    private func decorate(_ table: String, affiliated: Affiliated, caption: String, above: Bool) -> String {
        let floatEnvironment: String?
        let float = affiliated.attribute("float")
        switch float {
        case .some(nil): floatEnvironment = nil
        case .some(.some(let f)) where f == "sidewaystable" || f == "sideways": floatEnvironment = "sidewaystable"
        case .some(.some("multicolumn")): floatEnvironment = "table*"
        case .some(.some("t")): floatEnvironment = "table"
        case .some(.some(let f)): floatEnvironment = f
        case .none: floatEnvironment = caption.contains(where: { !$0.isWhitespace }) ? "table" : nil
        }
        let placement = affiliated.value("placement") ?? "[htbp]"
        let center = affiliated.has("center") ? affiliated.value("center") != nil : true
        let font = affiliated.value("font").map { $0 + "\n" }
        let captionText: String? = caption.isEmpty ? nil : caption
        var out = ""
        if let floatEnvironment {
            out = "\\begin{\(floatEnvironment)}\(placement)\n" + (above ? caption : "") + (center ? "\\centering\n" : "") + (font ?? "")
        } else if captionText != nil {
            out = (center ? "\\begin{center}\n" : "") + (above ? caption : "") + (font.map { center ? $0 : "{" + $0 } ?? "")
        } else if center {
            out = "\\begin{center}\n" + (font ?? "")
        } else if let font {
            out = "{" + font
        }
        out += table
        if let floatEnvironment {
            out += (above ? "" : "\n" + caption) + "\n\\end{\(floatEnvironment)}"
        } else if captionText != nil {
            out += (above ? "" : "\n" + caption) + (center ? "\n\\end{center}" : "") + (font != nil && !center ? "}" : "")
        } else if center {
            out += "\n\\end{center}"
        } else if font != nil {
            out += "}"
        }
        return out
    }

    /// `org-latex--caption/label-string` for a float.
    private func captionLabel(_ affiliated: Affiliated, type: String, prefix: String, srcBlock: Bool = false) throws -> String {
        let nonfloat = (affiliated.attribute("float") == .some(nil) && !affiliated.caption.isEmpty) || (srcBlock && affiliated.value("float") == nil)
        let label = affiliated.name.map { "\\label{\(prefix)\(reference("name:" + $0))}\n" } ?? ""
        if let fromAttr = affiliated.value("caption"), fromAttr.contains(where: { !$0.isWhitespace }) { return fromAttr + "\n" }
        guard !affiliated.caption.isEmpty else { return label }
        let main = try inlineString(affiliated.caption.joined(separator: " "))
        let trimmedLabel = Self.trim(label)
        return nonfloat ? "\\captionof{\(type)}{\(trimmedLabel)\(main)}\n" : "\\caption{\(trimmedLabel)\(main)}\n"
    }

    // MARK: Blocks

    private func block(_ node: SyntaxNode, affiliated: Affiliated) throws -> String? {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first, let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return nil }
        let type = m.1.lowercased()
        let parameters = String(m.2)
        let body = Array(lines.dropFirst().dropLast())
        let unescaped = body.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        let text = unescaped.joined(separator: "\n")
        switch type {
        case "src":
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            if affiliated.has("float") { throw Unsupported(reason: "Floating source blocks") }
            let code = try formatCode(lines)
            let verbatim = "\\begin{verbatim}\n\(code)\\end{verbatim}"
            guard !affiliated.caption.isEmpty else { return verbatim }
            return verbatim + "\n" + (try captionLabel(affiliated, type: "figure", prefix: "lst:", srcBlock: true))
        case "example":
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            let environment = affiliated.value("environment") ?? "verbatim"
            return try wrapLabel(affiliated, "\\begin{\(environment)}\n\(try formatCode(lines))\\end{\(environment)}")
        case "quote":
            let environment = affiliated.value("environment") ?? "quote"
            return try wrapLabel(affiliated, "\\begin{\(environment)}\(affiliated.value("options") ?? "")\n\(Self.normalize(try blocks(text)))\\end{\(environment)}")
        case "center":
            return try wrapLabel(affiliated, "\\begin{center}\n\(Self.normalize(try blocks(text)))\\end{center}")
        case "verse":
            if !affiliated.attr.isEmpty { throw Unsupported(reason: "#+ATTR_LATEX on verse blocks") }
            return try wrapLabel(affiliated, try verse(unescaped))
        case "export":
            let backend = parameters.split(separator: " ").first.map { $0.uppercased() } ?? ""
            guard backend == "LATEX" || backend == "TEX" else { return nil }
            return try Self.removeIndentation(text + "\n")
        case "comment":
            return nil
        default:
            let caption = try captionLabel(affiliated, type: "figure", prefix: "")
            if !caption.isEmpty { throw Unsupported(reason: "Captioned special blocks") }
            return "\\begin{\(m.1)}\(affiliated.value("options") ?? "")\n" + Self.normalize(try blocks(text)) + "\\end{\(m.1)}"
        }
    }

    /// `org-export-format-code-default` for a src or example block's lines.
    private func formatCode(_ lines: [String]) throws -> String {
        guard let parsed = Coderef.block(lines) else { return "" }
        let blockLoc = try blockLoc(lines, numbered: parsed.switches.numberLines != nil)
        var value = parsed.body.joined(separator: "\n")
        if !value.isEmpty { value += "\n" }
        let preserve = lines[0].firstMatch(of: /^[ \t]*#\+(?i:begin_(?:src|example))\b.*\s-i\b/) != nil
        var code = preserve ? value : try Self.removeIndentation(value)
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

    /// Each src and example block's `org-export-get-loc`, by the block's text, in order.
    private lazy var blockLocs: [String: [Int?]] = {
        let blocks = Coderef.blocks(tree)
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

    /// `org-latex-verse-block` and the verse rules of `org-latex-plain-text`.
    private func verse(_ lines: [String]) throws -> String {
        let text = lines.joined(separator: "\n") + "\n"
        // The contents are objects: paragraphs and the blank lines between them.
        let tree = OrgParser.parse(text, defaults: settings)
        let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        guard nodes.allSatisfy({ $0.kind == .paragraph }), let firstNode = nodes.first else { throw Unsupported(reason: "Verse blocks with more than text") }
        let ns = text as NSString
        var raw: [Inline] = [.text(ns.substring(to: firstNode.range.lowerBound))]
        for (index, node) in nodes.enumerated() {
            raw += try inlineItems(node)
            let end = index + 1 < nodes.count ? nodes[index + 1].range.lowerBound : ns.length
            raw.append(.text(ns.substring(with: NSRange(location: node.range.upperBound, length: end - node.range.upperBound))))
        }
        inVerse = true
        defer { inVerse = false }
        let items = Self.normalizeIndentation(Self.merge(raw), ignoreFirst: false)
        var contents = try transcode(items)
        while let c = contents.last, c.isWhitespace { contents.removeLast() }
        return Self.cleanLineBreaks("\\begin{verse}\n" + contents + "\n\\end{verse}")
    }

    private var inVerse = false

    // MARK: - Objects

    /// Inline content: text runs and objects with their own contents.
    indirect enum Inline {
        case text(String)
        case object(SyntaxNode, [Inline])
    }

    /// The contents of `node` as `Inline`s, markers left out, a line break's newline taken in.
    func inlineItems(_ node: SyntaxNode, trimmed: Bool = false) throws -> [Inline] {
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
                    items.append(.object(child, try inlineItems(child)))
                case .link:
                    items.append(.object(child, try child.firstChild(.linkDescription).map { try inlineItems($0) } ?? []))
                case .superscript, .subscript:
                    let text = child.text
                    let braced = text.dropFirst().hasPrefix("{")
                    if options.scripts == .off || (options.scripts == .braces && !braced) {
                        items.append(.text(text))
                    } else if braced {
                        items.append(.object(child, try inlineItems(child)))
                    } else {
                        items.append(.object(child, [.text(String(text.dropFirst()))]))
                    }
                case .lineBreak where trimmed:
                    // A table cell has no line ends.
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
        return Self.merge(items)
    }

    /// Adjacent text runs joined.
    static func merge(_ items: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for item in items {
            if case .text(let t) = item, case .text(let previous)? = out.last {
                out[out.count - 1] = .text(previous + t)
            } else if case .text(let t) = item, t.isEmpty {
                continue
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// `org-element-normalize-contents`: the common indentation of the lines taken away.
    static func normalizeIndentation(_ items: [Inline], ignoreFirst: Bool) -> [Inline] {
        var minimum = Int.max
        var zero = false
        func scan(_ items: [Inline], _ firstFlag: inout Bool) {
            for item in items {
                if zero { return }
                if firstFlag {
                    firstFlag = false
                    guard case .text(let t) = item, let m = t.firstMatch(of: /^([ \t]+)([^ \t\n]|\n|$)/) else { zero = true; return }
                    if m.2 != "\n" { minimum = min(minimum, width(m.1)) }
                }
                switch item {
                case .text(let t):
                    // Every line start, a blank line's next line included.
                    var rest = t[...]
                    while let newline = rest.firstIndex(of: "\n") {
                        let after = rest[rest.index(after: newline)...]
                        let indent = after.prefix { $0 == " " || $0 == "\t" }
                        let next = after.dropFirst(indent.count).first
                        if indent.isEmpty {
                            if next != nil, next != "\n" { zero = true; return }
                        } else if next != "\n" {
                            minimum = min(minimum, width(indent))
                        }
                        rest = after
                    }
                case .object(let node, let children):
                    if node.kind == .lineBreak {
                        firstFlag = true
                    } else if [.bold, .italic, .underline, .strikeThrough, .link, .linkDescription, .superscript, .subscript].contains(node.kind) {
                        scan(children, &firstFlag)
                    }
                }
            }
        }
        var first = !ignoreFirst
        scan(items, &first)
        guard !zero, minimum != Int.max, minimum > 0 else { return items }
        func strip(_ items: [Inline], _ firstFlag: inout Bool) -> [Inline] {
            items.map { item in
                switch item {
                case .text(var t):
                    if firstFlag {
                        firstFlag = false
                        t = dedent(t, atStart: true, by: minimum)
                    } else {
                        t = dedent(t, atStart: false, by: minimum)
                    }
                    return .text(t)
                case .object(let node, let children):
                    if firstFlag { firstFlag = false }
                    if node.kind == .lineBreak { firstFlag = true; return item }
                    var flag = false
                    return .object(node, strip(children, &flag))
                }
            }
        }
        var flag = !ignoreFirst
        return strip(items, &flag)
    }

    static func width(_ s: Substring) -> Int { s.reduce(0) { $0 + ($1 == "\t" ? 8 : 1) } }

    /// Indentation after each newline (and at the start) less `by` columns; blank lines lose theirs.
    static func dedent(_ t: String, atStart: Bool, by: Int) -> String {
        var lines = t.components(separatedBy: "\n")
        for i in lines.indices where i > 0 || atStart {
            let indent = lines[i].prefix { $0 == " " || $0 == "\t" }
            guard !indent.isEmpty else { continue }
            let rest = lines[i].dropFirst(indent.count)
            if rest.isEmpty && i < lines.count - 1 {
                lines[i] = ""
            } else if rest.isEmpty {
                lines[i] = String(repeating: " ", count: max(0, width(indent) - by))
            } else {
                lines[i] = String(repeating: " ", count: max(0, width(indent) - by)) + rest
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line of Org text transcoded, for keywords and captions.
    func inlineString(_ text: String) throws -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return plainText(text) }
        let saved = exportSource
        exportSource = ExportSource(tree: tree, text: text)
        defer { exportSource = saved }
        return Self.trim(try transcode(try inlineItems(paragraph)))
    }

    /// `node`'s contents transcoded, as a heading's title is.
    private func inline(_ node: SyntaxNode, sectionTitle: Bool) throws -> String {
        let saved = inTitle
        inTitle = sectionTitle
        defer { inTitle = saved }
        return try transcode(try inlineItems(node))
    }

    private var inTitle = false

    /// `org-export-data` over objects: math objects merged (`org-latex--wrap-latex-math-block`),
    /// objects that export nothing taking their blanks with them unless they are needed.
    func transcode(_ items: [Inline]) throws -> String {
        var out = ""
        var index = 0
        var dropBlanks = false
        while index < items.count {
            let item = items[index]
            switch item {
            case .text(var t):
                if dropBlanks { t = String(t.drop { $0 == " " || $0 == "\t" }) }
                dropBlanks = false
                out += plainText(t)
                index += 1
            case .object(let node, let children):
                dropBlanks = false
                if let math = mathValue(node) {
                    var values = [math]
                    var next = index + 1
                    while next < items.count, case .object(let n, _) = items[next], let v = mathValue(n) {
                        values.append(v)
                        next += 1
                    }
                    let joined = Self.trim(values.joined(separator: " "))
                    if !joined.isEmpty { out += "\\(\(joined)\\)" }
                    index = next
                    continue
                }
                if var result = try object(node, children) {
                    // `org-timestamp-translate` keeps the blanks after the timestamp.
                    if node.kind == .timestamp, index + 1 < items.count, case .text(let t) = items[index + 1] {
                        result = result.dropLast() + String(t.prefix { $0 == " " || $0 == "\t" }) + "}"
                    }
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

    /// The LaTeX inside `\(…\)` for an object a math block takes, nil for others.
    private func mathValue(_ node: SyntaxNode) -> String? {
        switch node.kind {
        case .entity:
            let name = String(node.text.dropFirst()).replacingOccurrences(of: "{}", with: "")
            guard let (latex, math) = OrgEntities.latex[name], math else { return nil }
            return latex
        case .latexFragment:
            guard options.tex else { return nil }
            let value = node.text
            if value.hasPrefix("\\(") { return String(value.dropFirst(2).dropLast(2)) }
            if value.hasPrefix("$"), !value.hasPrefix("$$") { return String(value.dropFirst().dropLast()) }
            return nil
        default:
            return nil
        }
    }

    private func object(_ node: SyntaxNode, _ children: [Inline]) throws -> String? {
        switch node.kind {
        case .bold: return "\\textbf{\(try transcode(children))}"
        case .italic: return "\\emph{\(try transcode(children))}"
        case .underline: return inTitle ? "\\underline{\(try transcode(children))}" : "\\uline{\(try transcode(children))}"
        case .strikeThrough: return "\\sout{\(try transcode(children))}"
        case .verbatim, .code:
            return Self.texttt(String(node.text.dropFirst().dropLast()))
        case .link: return try link(node, children)
        case .linkDescription: return try transcode(children)
        case .timestamp: return try timestamp(node.text)
        case .footnoteReference: return try footnote(node)
        case .entity:
            let name = String(node.text.dropFirst()).replacingOccurrences(of: "{}", with: "")
            guard let (latex, _) = OrgEntities.latex[name] else { throw Unsupported(reason: "Unknown entity \(node.text)") }
            return latex
        case .superscript: return "\\textsuperscript{\(try transcode(children))}"
        case .subscript: return "\\textsubscript{\(try transcode(children))}"
        case .lineBreak: return "\\\\\n"
        case .latexFragment: return options.tex ? node.text : nil
        case .statisticsCookie: return node.text.replacingOccurrences(of: "%", with: "\\%")
        case .exportSnippet:
            let backend = node.tokens.first?.text.dropFirst(2).dropLast() ?? ""
            guard backend == "latex" else { return nil }
            return node.tokens.filter { $0.kind != .marker }.map(\.text).joined()
        case .target:
            let name = String(node.text.dropFirst(2).dropLast(2))
            return "\\label{\(reference("target:" + name))}"
        case .macro:
            guard case .some(let value) = exportSource.resultsMacro(node) else { return nil }
            return try value.map(inlineString)
        default:
            throw Unsupported(reason: "\(node.kind)")
        }
    }

    // MARK: Plain text

    /// `org-latex-plain-text`.
    func plainText(_ text: String) -> String {
        let special = options.specialStrings
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "%", "$", "#", "&", "{", "}", "_":
                out += "\\" + String(c)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\^{}"
            case "\\":
                if special {
                    if i + 1 < chars.count {
                        if chars[i + 1] == "-" {
                            out += "\\"
                        } else {
                            out += "$\\backslash$" + String(chars[i + 1])
                            i += 1
                        }
                    } else {
                        out += "$\\backslash$"
                    }
                } else {
                    out += "$\\backslash$"
                }
            default:
                out.append(c)
            }
            i += 1
        }
        out = Self.texLogos(out)
        if special { out = out.replacingOccurrences(of: "...", with: "\\ldots{}") }
        out = out.replacing(#/(?m)^(\s*)\[/#) { $0.1 + "{[}" }
        if inVerse {
            out = out.replacing(#/(?:[ \t]*\\\\)?[ \t]*\n/#, with: "\\\\\n")
            out = out.replacing(#/(\\\\\n)(?:(?m:^)[ \t]*\\\\\n)+/#, with: "\n\n")
            out = out.replacing(#/(?m)^[ \t]+/#) { "\\hspace*{\($0.output.count)\\fontdimen2\\font}" }
        }
        return out
    }

    /// `LaTeX` and `TeX` as words, as their commands.
    static func texLogos(_ s: String) -> String {
        guard s.contains("TeX") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        // Word constituents in Org's syntax table, the apostrophe among them.
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }
        outer: while i < chars.count {
            if i == 0 || !isWord(chars[i - 1]) {
                for word in ["LaTeX", "TeX"] {
                    let w = Array(word)
                    if i + w.count <= chars.count, Array(chars[i..<(i + w.count)]) == w, i + w.count == chars.count || !isWord(chars[i + w.count]) {
                        out += "\\" + word + "{}"
                        i += w.count
                        continue outer
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: Timestamps

    /// `org-latex-timestamp`: `org-element-timestamp-interpreter`'s text in `\textit`, with the
    /// blanks after the timestamp.
    private func timestamp(_ text: String) throws -> String? {
        guard let stamp = Timestamp.parse(text) else { throw Unsupported(reason: "Timestamp \(text)") }
        let open = stamp.active ? "<" : "["
        let close = stamp.active ? ">" : "]"
        func date(_ p: Timestamp.Point, time: Bool) -> String {
            var components = DateComponents(year: p.year, month: p.month, day: p.day)
            components.calendar = Calendar(identifier: .gregorian)
            let weekday = components.calendar!.date(from: components).map { components.calendar!.component(.weekday, from: $0) } ?? 1
            let name = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
            var s = String(format: "%04d-%02d-%02d ", p.year, p.month, p.day) + name
            if time, let h = p.hour, let m = p.minute { s += String(format: " %02d:%02d", h, m) }
            return s
        }
        var suffix = ""
        if let r = stamp.repeater {
            suffix += " " + r.kind.rawValue + "\(r.interval.value)\(r.interval.unit.rawValue)"
            if let d = r.habitDeadline { suffix += "/\(d.value)\(d.unit.rawValue)" }
        }
        if let w = stamp.warning { suffix += " " + (w.firstOccurrenceOnly ? "--" : "-") + "\(w.interval.value)\(w.interval.unit.rawValue)" }
        var out = open + date(stamp.start, time: true)
        let dateRange = text.contains(">--<") || text.contains("]--[")
        if let end = stamp.end {
            if dateRange {
                out += suffix + close + "--" + open + date(end, time: true) + suffix + close
            } else {
                if let h = end.hour, let m = end.minute, h != stamp.start.hour || m != stamp.start.minute {
                    out += String(format: "-%02d:%02d", h, m)
                }
                out += suffix + close
            }
        } else {
            out += suffix + close
        }
        guard options.items["<"] ?? "t" == "t" else { return nil }
        return "\\textit{\(plainText(out))}"
    }

    // MARK: Links

    private func linkTarget(_ node: SyntaxNode) -> (type: String, path: String) {
        var raw = node.tokens.first { $0.kind == .linkPath }?.text ?? node.text
        if node.tokens.first(where: { $0.kind == .linkPath }) == nil, raw.hasPrefix("<"), raw.hasSuffix(">") {
            raw = String(raw.dropFirst().dropLast())
        }
        if raw.hasPrefix("#") { return ("custom-id", String(raw.dropFirst())) }
        if raw.hasPrefix("(") && raw.hasSuffix(")") { return ("coderef", String(raw.dropFirst().dropLast())) }
        if raw.hasPrefix("./") || raw.hasPrefix("../") || raw.hasPrefix("/") || raw.hasPrefix("~") { return ("file", raw) }
        if let m = raw.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/), Self.linkTypes.contains(m.1.lowercased()) {
            let type = m.1.lowercased()
            var path = String(m.2)
            if type == "file", path.hasPrefix("//") == false, let range = path.range(of: "::") { path = String(path[..<range.lowerBound]) }
            return (type, path)
        }
        return ("fuzzy", raw)
    }

    /// `org-link-parameters` under `emacs -Q` with ox-latex loaded.
    static let linkTypes: Set<String> = ["attachment", "id", "file+sys", "file+emacs", "shell", "news", "mailto", "https", "http", "ftp", "shortdoc", "help", "file", "elisp"]

    private func isImage(_ node: SyntaxNode) -> Bool {
        guard node.kind == .link, node.firstChild(.linkDescription) == nil else { return false }
        let (type, path) = linkTarget(node)
        guard type == "file" || type == "https" else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        let image = type == "file" ? ["pdf", "jpeg", "jpg", "png", "ps", "eps", "tikz", "pgf", "svg"] : ["jpeg", "jpg", "png", "ps", "eps", "tikz", "pgf", "svg"]
        return image.contains(ext) && path.lowercased().hasSuffix("." + ext)
    }

    /// The image link of a paragraph holding only it and blanks.
    private func soleImage(_ items: [Inline]) -> SyntaxNode? {
        var image: SyntaxNode?
        for item in items {
            switch item {
            case .text(let t): if t.contains(where: { !$0.isWhitespace }) { return nil }
            case .object(let node, _):
                guard image == nil, isImage(node) else { return nil }
                image = node
            }
        }
        return image
    }

    private func link(_ node: SyntaxNode, _ children: [Inline]) throws -> String? {
        let (type, path) = linkTarget(node)
        var description: String? = node.firstChild(.linkDescription) == nil ? nil : try transcode(children)
        if description == "" { description = nil }
        if node.firstChild(.linkDescription)?.descendants().contains(where: { $0.kind == .link }) == true {
            throw Unsupported(reason: "Links in link descriptions")
        }
        if let d = node.firstChild(.linkDescription)?.text, d.firstMatch(of: /^(?:[A-Za-z]+:\S+|<[^>]+>)$/) != nil {
            throw Unsupported(reason: "Images as link descriptions")
        }
        if isImage(node) { return try inlineImage(node, affiliated: currentAffiliated ?? Affiliated(), alone: false) }
        switch type {
        case "custom-id", "fuzzy", "id":
            let label: String
            let numberedHeading: Bool
            var title: String?
            if type == "fuzzy", !path.hasPrefix("*"), let found = target(path).map({ reference("target:" + $0) }) ?? namedElement(path) {
                return description.map { "\\hyperref[\(found)]{\($0)}" } ?? "\\ref{\(found)}"
            }
            guard let heading = try resolveHeading(type: type, path: path) else {
                throw Unsupported(reason: "Unable to resolve link: \"\(type == "custom-id" ? "#" : type == "id" ? "id:" : "")\(path)\"")
            }
            label = "sec:" + reference("heading@\(heading.headingRange.lowerBound)")
            numberedHeading = numbered && (num.map { heading.level + levelOffset <= $0 } ?? true)
            if description == nil, numberedHeading { return "\\ref{\(label)}" }
            if description == nil {
                let node = tree.root.descendants().first { $0.kind == .heading && $0.range.lowerBound == heading.headingRange.lowerBound }
                title = try node?.firstChild(.title).map { try Self.trim(inline($0, sectionTitle: false)) } ?? ""
            }
            return "\\hyperref[\(label)]{\(description ?? title ?? "")}"
        case "coderef":
            guard let resolved = Coderef.resolve(path, in: tree) else { throw Unsupported(reason: "Unable to resolve code reference: \(path)") }
            // `org-export-get-coderef-format` on the transcoded description, then `format`.
            var format = description ?? "%s"
            if let range = format.range(of: "(\(path))") { format.replaceSubrange(range, with: "%s") }
            return format.replacingOccurrences(of: "%s", with: resolved).replacingOccurrences(of: "%%", with: "%")
        case "file":
            if path.hasPrefix("~") { throw Unsupported(reason: "File links under ~") }
            let uri = path.hasPrefix("//") ? "file:" + path : path.hasPrefix("/") ? "file://" + path : path
            let protected = Self.protect(uri)
            return description.map { "\\href{\(protected)}{\($0)}" } ?? "\\url{\(protected)}"
        case "http", "https", "ftp", "mailto", "news":
            let protected = Self.protect(type + ":" + path)
            return description.map { "\\href{\(protected)}{\($0)}" } ?? "\\url{\(protected)}"
        default:
            throw Unsupported(reason: "\(type): links")
        }
    }

    /// Words of a fuzzy link or a title, as `org-export-search-cells` compares them.
    static func words(_ s: String) -> [String] {
        s.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The `<<target>>` a fuzzy link names.
    private func target(_ path: String) -> String? {
        let search = Self.words(path)
        return tree.root.descendants().first { $0.kind == .target && Self.words(String($0.text.dropFirst(2).dropLast(2))) == search }
            .map { String($0.text.dropFirst(2).dropLast(2)) }
    }

    /// The label of the element whose `#+NAME` a fuzzy link names, as the element writes it.
    private func namedElement(_ path: String) -> String? {
        let search = path.split(whereSeparator: \.isWhitespace).map(String.init)
        for node in tree.root.descendants() where node.kind == .affiliatedKeyword {
            guard let m = node.text.firstMatch(of: /^[ \t]*#\+(?i:name):[ \t]*(.*?)[ \t]*\n?$/) else { continue }
            let name = String(m.1)
            let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words == search || words == search.map({ $0.uppercased() }), let parent = node.parent else { continue }
            let siblings = parent.children
            guard let index = siblings.firstIndex(where: { $0.range == node.range }) else { continue }
            let keywords = siblings[index...].prefix { $0.kind == .affiliatedKeyword }
            guard let element = siblings[index...].first(where: { $0.kind != .affiliatedKeyword }) else { continue }
            let captioned = keywords.contains { $0.text.firstMatch(of: /^[ \t]*#\+(?i:caption)/) != nil }
            let prefix: String
            switch element.kind {
            case .table: prefix = "tab:"
            case .block where blockType(element) == "src": prefix = "lst:"
            case .paragraph where captioned: prefix = "fig:"
            default: prefix = ""
            }
            return prefix + reference("name:" + name)
        }
        return nil
    }

    /// The heading a link goes to: by `CUSTOM_ID`, `ID` or title.
    private func resolveHeading(type: String, path: String) throws -> HeadingInfo? {
        switch type {
        case "custom-id":
            return model.headings.first { $0.properties.contains { $0.key.uppercased() == "CUSTOM_ID" && $0.value == path } }
        case "id":
            return model.headings.first { $0.properties.contains { $0.key.uppercased() == "ID" && $0.value == path } }
        default:
            let search = Self.words(path.hasPrefix("*") ? String(path.dropFirst()) : path)
            return model.headings.first { heading in
                let node = tree.root.descendants().first { $0.kind == .heading && $0.range.lowerBound == heading.headingRange.lowerBound }
                let raw = (node?.firstChild(.title)?.text ?? "").replacing(#/\[[0-9]*(?:%|/[0-9]*)\]/#, with: " ")
                return Self.words(raw) == search
            }
        }
    }

    /// `org-latex--inline-image`.
    private func inlineImage(_ node: SyntaxNode, affiliated: Affiliated, alone: Bool) throws -> String {
        let (type, path) = linkTarget(node)
        if type != "file" { throw Unsupported(reason: "Remote images") }
        if path.hasPrefix("~") || path.hasPrefix("/") { throw Unsupported(reason: "Images with absolute paths") }
        let ext = (path as NSString).pathExtension.lowercased()
        let caption = try captionLabel(affiliated, type: "figure", prefix: !affiliated.caption.isEmpty ? "fig:" : "")
        enum Float: Equatable { case none, nonfloat, figure, wrap, sideways, multicolumn, env(String) }
        var float: Float
        let attrFloat = affiliated.attribute("float")
        if !alone {
            float = .none
        } else {
            switch attrFloat {
            case .some(.some("wrap")): float = .wrap
            case .some(.some("sideways")): float = .sideways
            case .some(.some("multicolumn")): float = .multicolumn
            case .some(.some("t")): float = .figure
            case .some(nil): float = .nonfloat
            case .some(.some(let f)): float = .env(f)
            case .none: float = !affiliated.caption.isEmpty || affiliated.value("caption") != nil ? .figure : .nonfloat
            }
        }
        let placement: String
        if let p = affiliated.value("placement") {
            placement = p
        } else if float == .wrap {
            placement = "{l}{0.5\\textwidth}"
        } else if float == .figure {
            placement = "[htbp]"
        } else {
            placement = ""
        }
        let center = affiliated.has("center") ? affiliated.value("center") != nil : true
        let scale = float == .wrap ? "" : affiliated.value("scale") ?? ""
        let width: String = !scale.isEmpty ? "" : affiliated.value("width") ?? (affiliated.value("height") != nil ? "" : float == .wrap ? "0.48\\textwidth" : ".9\\linewidth")
        let height: String = !scale.isEmpty ? "" : affiliated.value("height") ?? ""
        var options = affiliated.value("options") ?? ""
        if let m = options.wholeMatch(of: /\[(.*)\]/) { options = String(m.1) }
        if ext == "tikz" || ext == "pgf" { throw Unsupported(reason: "TikZ images") }
        if affiliated.value("comment-include") != nil { throw Unsupported(reason: ":comment-include") }
        if !scale.isEmpty {
            options += ",scale=" + scale
        } else {
            if !width.isEmpty { options += ",width=" + width }
            if !height.isEmpty { options += ",height=" + height }
        }
        let optionString = options.isEmpty ? "" : options.hasPrefix(",") ? "[\(options.dropFirst())]" : "[\(options)]"
        var imagePath = path
        if ext == "svg", imagePath.contains(where: { !$0.isASCII }) { imagePath = "\\detokenize{\(imagePath)}" }
        var code = "\\includegraphics\(optionString){\(imagePath)}"
        if ext == "svg" {
            code = "\\includesvg" + code.dropFirst("\\includegraphics".count)
            code = code.replacingOccurrences(of: ".svg}", with: "}")
        }
        let above = false
        switch float {
        case .env(let env):
            return "\\begin{\(env)}\(placement)\n\(above ? caption : "")\(center ? "\\centering" : "")\n\(code)\n\(above ? "" : caption)\\end{\(env)}"
        case .wrap:
            return "\\begin{wrapfigure}\(placement)\n\(center ? "\\centering" : "")\n\(code)\n\(caption)\\end{wrapfigure}"
        case .sideways:
            return "\\begin{sidewaysfigure}\n\(center ? "\\centering" : "")\n\(code)\n\(caption)\\end{sidewaysfigure}"
        case .multicolumn:
            return "\\begin{figure*}\(placement)\n\(center ? "\\centering" : "")\n\(code)\n\(caption)\\end{figure*}"
        case .figure:
            return "\\begin{figure}\(placement)\n\(center ? "\\centering" : "")\n\(code)\n\(caption)\\end{figure}"
        case .none, .nonfloat:
            if center { return "\\begin{center}\n\(code)\n\(caption)\\end{center}" }
            return code
        }
    }

    // MARK: Footnotes

    private var footnoteReferences: [String: Int] = [:]
    private var footnotesSeen: Set<String> = []
    private var definitions: [String: String] = [:]
    private var anonymous = 0

    /// Footnote definitions, and how many references each label has.
    private func countFootnotes() throws {
        for node in tree.root.descendants() {
            if node.kind == .footnoteDefinition, let m = node.text.firstMatch(of: /^\[fn:([^\]]+)\][ \t]*/) {
                // A definition goes on to the next one, a heading or two blank lines.
                if let parent = node.parent, let index = parent.children.firstIndex(where: { $0.range == node.range }), index + 1 < parent.children.count {
                    let next = parent.children[index + 1]
                    if next.kind != .footnoteDefinition, next.kind != .section, blankLines(from: node.range.lowerBound, to: next.range.lowerBound) < 2 {
                        throw Unsupported(reason: "Footnote definitions of several paragraphs")
                    }
                }
                definitions[String(m.1)] = String(node.text[m.range.upperBound...])
            }
            if node.kind == .footnoteReference, let m = node.text.firstMatch(of: /^\[fn:([^:\]]+)/) {
                if node.parent.map({ Self.excluded($0, by: self) }) == true { continue }
                footnoteReferences[String(m.1), default: 0] += 1
            }
        }
    }

    /// Whether `node` is under a section the export leaves out.
    private static func excluded(_ node: SyntaxNode, by renderer: LaTeXRenderer) -> Bool {
        var current: SyntaxNode? = node
        while let n = current {
            if n.kind == .section, let heading = n.firstChild(.heading),
               HTMLRenderer.sectionExport(heading, options: renderer.options, selected: renderer.selected) != .all { return true }
            current = n.parent
        }
        return false
    }

    /// `org-latex-footnote-reference`.
    private func footnote(_ node: SyntaxNode) throws -> String {
        guard let m = node.text.firstMatch(of: /^\[fn:([^:\]]*)(?::(.*))?\]$/) else { throw Unsupported(reason: "Footnote \(node.text)") }
        let label = String(m.1)
        if inFootnote { throw Unsupported(reason: "Footnotes inside footnotes") }
        var separator = ""
        if let previous = previousSibling(node), previous.kind == .footnoteReference { separator = "\\textsuperscript{,}\\," }
        if let inline = m.2 {
            if !label.isEmpty {
                if footnotesSeen.contains(label) { return separator + "\\textsuperscript{\\ref{\(reference("fn:" + label))}}" }
                footnotesSeen.insert(label)
            }
            inFootnote = true
            defer { inFootnote = false }
            let content = try inlineString(String(inline))
            let labelText = !label.isEmpty && (footnoteReferences[label] ?? 0) > 1 ? "\\label{\(reference("fn:" + label))}" : ""
            return separator + "\\footnote{\(content)\(labelText)}"
        }
        guard !label.isEmpty, let definition = definitions[label] else { throw Unsupported(reason: "Definition not found for footnote \(label)") }
        if footnotesSeen.contains(label) {
            return separator + "\\textsuperscript{\\ref{\(reference("fn:" + label))}}"
        }
        footnotesSeen.insert(label)
        inFootnote = true
        defer { inFootnote = false }
        let content = Self.trim(try footnoteBody(definition))
        let labelText = (footnoteReferences[label] ?? 0) > 1 ? "\\label{\(reference("fn:" + label))}" : ""
        return separator + "\\footnote{\(content)\(labelText)}"
    }

    private var inFootnote = false

    /// A definition's text transcoded, its first paragraph's first line left as it is.
    private func footnoteBody(_ text: String) throws -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        let nodes = tree.root.children.flatMap { $0.kind == .zerothSection ? $0.children : [$0] }
        if nodes.count == 1, nodes[0].kind == .paragraph {
            return try paragraph(nodes[0], affiliated: Affiliated(), ignoreFirst: true)
        }
        return try blocks(text)
    }

    /// The object or text before `node` in its parent.
    private func previousSibling(_ node: SyntaxNode) -> SyntaxNode? {
        guard let parent = node.parent else { return nil }
        var previous: SyntaxNode.Element?
        for element in parent.elements {
            if case .node(let n) = element, n.range == node.range {
                if case .node(let p)? = previous { return p }
                return nil
            }
            previous = element
        }
        return nil
    }
}
