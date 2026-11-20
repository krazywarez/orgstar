import Foundation

/// What an export includes, from `#+OPTIONS` and the export keywords (ox.el, Org 9.8.7).
public struct ExportOptions: Sendable, Equatable {
    public enum Scripts: Sendable, Equatable {
        case on
        /// `^:{}`: only `_{…}` and `^{…}`.
        case braces
        case off
    }

    /// `toc`: the table of contents' depth, nil for none.
    public var toc: Int?
    /// `num`: section numbers to this depth, nil for none.
    public var num: Int?
    public var tags = true
    /// `tags:not-in-toc`.
    public var tagsInTOC = true
    public var todo = true
    public var priority = false
    public var scripts = Scripts.on
    /// `H`: the deepest heading level the TOC and numbering count.
    public var headlineLevels = 3
    public var tex = true
    public var author = true
    public var date = true
    public var title = true
    /// `-`: `--`, `---`, `...` and `\-` as special strings.
    public var specialStrings = true
    /// `<`, as written: nil, t, active, inactive; nil when not given.
    public var timestamps: String?
    public var excludeTags = ["noexport"]
    public var selectTags = ["export"]
    /// `#+HTML_HEAD` and `#+HTML_HEAD_EXTRA` lines, in order.
    public var htmlHead: [String] = []
    /// `#+LATEX_CLASS`, the last one.
    public var latexClass: String?
    /// `#+LATEX_CLASS_OPTIONS`, the last one.
    public var latexClassOptions: String?
    /// `#+LATEX_HEADER` lines, in order.
    public var latexHeader: [String] = []
    /// `#+LATEX_HEADER_EXTRA` lines, in order.
    public var latexHeaderExtra: [String] = []
    /// `#+LATEX_COMPILER`, the first one.
    public var latexCompiler: String?
    /// Every `#+OPTIONS` item as written, the last value of each.
    public var items: [String: String] = [:]

    /// `org-export-with-*` defaults.
    public static let org = ExportOptions(toc: 3, num: 3)

    /// The shape the conformance corpus holds: no table of contents or numbers, priorities
    /// shown.
    public static let orgo: ExportOptions = {
        var options = ExportOptions(toc: nil, num: nil)
        options.priority = true
        return options
    }()

    /// `defaults` with the document's `#+OPTIONS`, `#+EXCLUDE_TAGS`, `#+SELECT_TAGS`,
    /// `#+HTML_HEAD` and `#+LATEX_*` applied.
    public static func parse(_ text: String, defaults: ExportOptions = .org) -> ExportOptions {
        var options = defaults
        var tocSet: String?
        var numSet: String?
        for m in text.matches(of: #/(?mi)^[ \t]*#\+(OPTIONS|EXCLUDE_TAGS|SELECT_TAGS|HTML_HEAD|HTML_HEAD_EXTRA|LATEX_CLASS|LATEX_CLASS_OPTIONS|LATEX_HEADER|LATEX_HEADER_EXTRA|LATEX_COMPILER):[ \t]*(.*?)[ \t]*$/#) {
            let value = String(m.2)
            switch m.1.uppercased() {
            case "EXCLUDE_TAGS": options.excludeTags = value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "SELECT_TAGS": options.selectTags = value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "HTML_HEAD", "HTML_HEAD_EXTRA": options.htmlHead.append(value)
            case "LATEX_CLASS": options.latexClass = value
            case "LATEX_CLASS_OPTIONS": options.latexClassOptions = value
            case "LATEX_HEADER": options.latexHeader.append(value)
            case "LATEX_HEADER_EXTRA": options.latexHeaderExtra.append(value)
            case "LATEX_COMPILER": if options.latexCompiler == nil { options.latexCompiler = value }
            default:
                for item in value.matches(of: /(\S+?):(\S+)/) {
                    let key = String(item.1)
                    let v = String(item.2)
                    options.items[key] = v
                    let on = v != "nil"
                    switch key {
                    case "toc": tocSet = v
                    case "num": numSet = v
                    case "tags":
                        options.tags = on
                        options.tagsInTOC = v != "not-in-toc"
                    case "todo": options.todo = on
                    case "pri": options.priority = on
                    case "^": options.scripts = v == "{}" ? .braces : on ? .on : .off
                    case "H": if let n = Int(v) { options.headlineLevels = n }
                    case "tex": options.tex = on
                    case "author": options.author = on
                    case "date": options.date = on
                    case "title": options.title = on
                    case "-": options.specialStrings = on
                    case "<": options.timestamps = v
                    default: break
                    }
                }
            }
        }
        // `toc` and `num` as t (to H), nil or a depth.
        func depth(_ v: String?, _ current: Int?) -> Int? {
            guard let v else { return current.map { _ in options.headlineLevels } }
            if v == "nil" { return nil }
            return Int(v).map { min($0, options.headlineLevels) } ?? options.headlineLevels
        }
        options.toc = depth(tocSet, options.toc)
        options.num = depth(numSet, options.num)
        return options
    }
}

/// What happens to the text before it's parsed for export: `#+INCLUDE` (ox.el's
/// `org-export-expand-include-keyword`) and macros (`org-macro-replace-all`).
public enum ExportPreprocess {
    /// `#+INCLUDE: "file" [example|export FORMAT|src LANG] [:lines "A-B"] [:minlevel N]`, with
    /// `file::*Heading` or `file::#custom-id` for one subtree. Relative to `directory`.
    /// `includer` is the exported file's directory, `directory` at the top.
    public static func includes(_ text: String, directory: URL?, depth: Int = 0, includer: URL? = nil) -> String {
        let includer = depth == 0 ? directory : includer
        guard depth < 8, text.containsIgnoringASCIICase("#+INCLUDE:") else { return text }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let m = line.firstMatch(of: #/(?i)^[ \t]*#\+INCLUDE:[ \t]+"([^"]+)"(.*)$/#) else {
                lines.append(line)
                continue
            }
            let spec = String(m.1)
            let rest = String(m.2)
            var file = spec
            var target: String?
            if let r = spec.range(of: "::") {
                file = String(spec[..<r.lowerBound])
                target = String(spec[r.upperBound...])
            }
            let url = includeURL(file, directory: directory)
            guard var included = try? String(contentsOf: url, encoding: .utf8) else {
                lines.append("")
                continue
            }
            if let target { included = subtree(included, target) ?? "" }
            if let range = rest.firstMatch(of: /:lines[ \t]+"([0-9]*)-([0-9]*)"/) {
                let all = included.components(separatedBy: "\n")
                let low = max(1, Int(range.1) ?? 1)
                let high = min(all.count, (Int(range.2).map { $0 - 1 }) ?? all.count)
                included = low <= high ? all[(low - 1)..<high].joined(separator: "\n") : ""
            }
            let words = rest.replacingOccurrences(of: ":[a-z-]+[ \\t]+(\"[^\"]*\"|\\S+)", with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if let kind = words.first?.lowercased(), ["src", "example", "export", "quote", "verse", "center", "comment"].contains(kind) {
                // The words after the kind, as written, up to the first option.
                var parameter = rest.drop { $0 == " " || $0 == "\t" }.dropFirst(kind.count).drop { $0 == " " || $0 == "\t" }
                if let option = parameter.firstIndex(of: ":") { parameter = parameter[..<option] }
                let body = included.hasSuffix("\n") ? String(included.dropLast()) : included
                let escaped = kind == "src" || kind == "example" ? BlockEdit.escape(body) : body
                lines.append("#+BEGIN_\(kind)" + (parameter.isEmpty ? "" : " " + parameter))
                lines.append(escaped)
                lines.append("#+END_\(kind)")
                continue
            }
            if let includer { included = rebasingLinks(included, from: url.deletingLastPathComponent(), to: includer) }
            if let minLevel = rest.firstMatch(of: /:minlevel[ \t]+([0-9]+)/).flatMap({ Int($0.1) }) {
                included = shift(included, to: minLevel)
            }
            let expanded = includes(included, directory: url.deletingLastPathComponent(), depth: depth + 1, includer: includer)
            lines.append(expanded.hasSuffix("\n") ? String(expanded.dropLast()) : expanded)
        }
        return lines.joined(separator: "\n")
    }

    /// The files `#+INCLUDE` names in `text`, and in the files they include, that can't be read.
    public static func unreadableIncludes(_ text: String, directory: URL?, depth: Int = 0) -> [String] {
        guard depth < 8, text.containsIgnoringASCIICase("#+INCLUDE:") else { return [] }
        var unreadable: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let m = line.firstMatch(of: #/(?i)^[ \t]*#\+INCLUDE:[ \t]+"([^"]+)"/#) else { continue }
            let spec = String(m.1)
            let url = includeURL(spec.range(of: "::").map { String(spec[..<$0.lowerBound]) } ?? spec, directory: directory)
            guard let included = try? String(contentsOf: url, encoding: .utf8) else {
                if !unreadable.contains(url.path) { unreadable.append(url.path) }
                continue
            }
            for path in unreadableIncludes(included, directory: url.deletingLastPathComponent(), depth: depth + 1) where !unreadable.contains(path) {
                unreadable.append(path)
            }
        }
        return unreadable
    }

    /// `org-export--update-included-link`: the relative `file` links of a file in `directory`,
    /// relative to `includer` instead. Links in descriptions too; `plain` for those, which
    /// can only be plain or angle links.
    static func rebasingLinks(_ text: String, from directory: URL, to includer: URL, plain: Bool = false) -> String {
        guard plain || directory.resolvingSymlinksInPath().path != includer.resolvingSymlinksInPath().path else { return text }
        let ns = text as NSString
        var edits: [(range: Range<Int>, text: String)] = []
        for node in OrgParser.parse(text).root.descendants() where node.kind == .link {
            let whole = node.text
            if whole.hasPrefix("[[") {
                guard !plain else { continue }
                if let description = node.firstChild(.linkDescription) {
                    let rebased = rebasingLinks(description.text, from: directory, to: includer, plain: true)
                    if rebased != description.text { edits.append((description.range, rebased)) }
                }
                if let path = node.tokens.first(where: { $0.kind == .linkPath }), let rebased = rebasedPath(path.text, from: directory, to: includer, bracket: true) {
                    edits.append((path.range, rebased))
                }
            } else if whole.hasPrefix("<"), whole.hasSuffix(">") {
                if let rebased = rebasedPath(String(whole.dropFirst().dropLast()), from: directory, to: includer, bracket: false) {
                    edits.append((node.range, "<" + rebased + ">"))
                }
            } else if let rebased = rebasedPath(whole, from: directory, to: includer, bracket: false) {
                edits.append((node.range, rebased))
            }
        }
        guard !edits.isEmpty else { return text }
        let out = NSMutableString(string: ns)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceCharacters(in: NSRange(location: edit.range.lowerBound, length: edit.range.count), with: edit.text)
        }
        return out as String
    }

    /// A link's path rewritten as `org-element-link-interpreter` writes it back: the type only
    /// when it was written. Nil when it isn't a relative file link.
    static func rebasedPath(_ raw: String, from directory: URL, to includer: URL, bracket: Bool) -> String? {
        var type = ""
        var rest = raw
        if let m = raw.firstMatch(of: /^(file(?:\+[^:]+)?|[^:\/]+\+file):/) {
            type = String(m.0)
            rest = String(raw[m.0.endIndex...])
        } else if !(bracket && ["/", "./", "../", "~"].contains(where: raw.hasPrefix)) {
            return nil
        }
        var path = rest
        var search = ""
        if let r = rest.range(of: "::") {
            path = String(rest[..<r.lowerBound])
            search = String(rest[r.lowerBound...])
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        // `file-relative-name` of `expand-file-name`.
        func components(_ path: String) -> [String] {
            var out: [String] = []
            for part in path.split(separator: "/", omittingEmptySubsequences: true) {
                if part == "." { continue }
                if part == ".." { if !out.isEmpty { out.removeLast() } } else { out.append(String(part)) }
            }
            return out
        }
        let target = components(directory.path + "/" + path)
        let base = components(includer.path)
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        let relative = (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
        return type + (relative.isEmpty ? "." : relative) + search
    }

    /// An include's file, relative to `directory`.
    static func includeURL(_ file: String, directory: URL?) -> URL {
        (file as NSString).isAbsolutePath || directory == nil
            ? URL(fileURLWithPath: OrgPaths.expandingTilde(file))
            : directory!.appendingPathComponent(file)
    }

    /// The subtree of `text` at `*Heading` or `#custom-id`.
    static func subtree(_ text: String, _ target: String) -> String? {
        let tree = OrgParser.parse(text)
        let model = DocumentModel(tree: tree)
        let found: Int?
        if target.hasPrefix("#") {
            let id = String(target.dropFirst())
            found = model.headings.firstIndex { $0.properties.contains { $0.key.uppercased() == "CUSTOM_ID" && $0.value == id } }
        } else {
            let title = target.hasPrefix("*") ? String(target.dropFirst()) : target
            found = model.headings.firstIndex { Links.displayFormat($0.title).trimmingCharacters(in: .whitespaces) == title || $0.title == title }
        }
        guard let index = found else { return nil }
        let start = model.headings[index].headingRange.lowerBound
        let end = model.headings[(index + 1)...].first { $0.level <= model.headings[index].level }?.headingRange.lowerBound ?? (text as NSString).length
        return (text as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    /// Headings moved so the shallowest is at `level`.
    static func shift(_ text: String, to level: Int) -> String {
        let levels = text.matches(of: #/(?m)^(\*+) /#).map { $0.1.count }
        guard let shallowest = levels.min() else { return text }
        let delta = level - shallowest
        guard delta != 0 else { return text }
        return text.components(separatedBy: "\n").map { line in
            guard let m = line.firstMatch(of: #/^(\*+) /#) else { return line }
            return String(repeating: "*", count: max(1, m.1.count + delta)) + line[m.1.endIndex...]
        }.joined(separator: "\n")
    }

    /// `{{{name(arg, …)}}}` replaced: `#+MACRO` definitions with `$1`… and the built-in title,
    /// author, date, email, input-file, keyword, property, n and time macros. Others become
    /// empty, as Lisp ones do here.
    /// `setup` is the setup files' keyword lines, whose definitions count too.
    public static func macros(_ text: String, path: String?, now: Date = Date(), setup: String = "") -> String {
        guard text.contains("{{{") else { return text }
        var definitions: [String: String] = [:]
        var keywords: [String: String] = [:]
        for m in (setup + text).matches(of: #/(?mi)^[ \t]*#\+([A-Z_]+):[ \t]*(.*?)[ \t]*$/#) {
            let key = m.1.uppercased()
            let value = String(m.2)
            if key == "MACRO", let d = value.firstMatch(of: /^(\S+)[ \t]*(.*)$/) {
                definitions[d.1.lowercased()] = String(d.2)
            } else if keywords[key] == nil {
                keywords[key] = value
            }
        }
        var counters: [String: Int] = [:]
        var model: DocumentModel?
        /// `org-entry-get` with `selective` inheritance at the heading holding `location`, or
        /// at the entry `search` finds (`*Title`, `#custom-id` or a title).
        func property(_ name: String, _ search: String?, at location: Int) -> String {
            if model == nil { model = DocumentModel(tree: OrgParser.parse(text)) }
            let headings = model!.headings
            let index: Int?
            if let search, !search.isEmpty {
                if search.hasPrefix("#") {
                    let id = String(search.dropFirst())
                    index = headings.firstIndex { $0.properties.contains { $0.key.uppercased() == "CUSTOM_ID" && $0.value == id } }
                } else {
                    let title = search.hasPrefix("*") ? String(search.dropFirst()) : search
                    index = headings.firstIndex { Links.displayFormat($0.title).trimmingCharacters(in: .whitespaces) == title || $0.title == title }
                }
            } else {
                index = headings.lastIndex { $0.headingRange.lowerBound <= location }
            }
            guard let index else { return "" }
            if name.uppercased() == "ITEM" { return headings[index].title }
            return model!.property(name, of: index)?.value ?? ""
        }
        let regex = try! NSRegularExpression(pattern: "\\{\\{\\{([-A-Za-z0-9_]+)(?:\\((.*?)\\))?\\}\\}\\}")
        var out = ""
        var at = 0
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = NSMaxRange(m.range)
            // Not on #+MACRO lines themselves.
            let lineStart = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
            if ns.substring(from: lineStart).range(of: "^[ \\t]*#\\+MACRO:", options: [.regularExpression, .caseInsensitive]) != nil {
                out += ns.substring(with: m.range)
                continue
            }
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            // Inline results stay for the exporter, which shows them as `:exports` says.
            if name == "results", definitions[name] == nil {
                out += ns.substring(with: m.range)
                continue
            }
            let args = m.range(at: 2).location == NSNotFound ? [] : arguments(ns.substring(with: m.range(at: 2)))
            let location = m.range.location
            out += expand(name, args, definitions: definitions, keywords: keywords, counters: &counters, path: path, now: now) {
                property($0, $1, at: location)
            }
        }
        out += ns.substring(from: at)
        return out
    }

    /// Macro arguments: split on commas, `\,` for a literal one, blanks around trimmed.
    static func arguments(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var escaped = false
        for c in s {
            if escaped {
                current.append(c == "," ? "," : "\\")
                if c != "," { current.append(c) }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "," {
                args.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        args.append(current)
        return args.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func expand(_ name: String, _ args: [String], definitions: [String: String], keywords: [String: String],
                       counters: inout [String: Int], path: String?, now: Date, property: (String, String?) -> String) -> String {
        if let template = definitions[name] {
            guard !template.hasPrefix("(eval") else { return "" }
            var result = template
            for (i, arg) in args.enumerated().reversed() { result = result.replacingOccurrences(of: "$\(i + 1)", with: arg) }
            return result.replacingOccurrences(of: "\\$[0-9]+", with: "", options: .regularExpression)
        }
        switch name {
        case "title", "author", "date", "email": return keywords[name.uppercased()] ?? ""
        case "keyword": return args.first.flatMap { keywords[$0.uppercased()] } ?? ""
        case "input-file": return path.map { ($0 as NSString).lastPathComponent } ?? ""
        case "property": return args.first.map { property($0, args.count > 1 ? args[1] : nil) } ?? ""
        case "n":
            let counter = args.first ?? ""
            let action = args.count > 1 ? args[1] : ""
            if action == "-" { return String(counters[counter] ?? 0) }
            let value = Int(action) ?? ((counters[counter] ?? 0) + 1)
            counters[counter] = value
            return String(value)
        case "time":
            guard let format = args.first else { return "" }
            return strftime(format, now)
        default: return ""
        }
    }

    /// `format-time-string` for the common directives.
    static func strftime(_ format: String, _ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tm = tm()
        localtime_r(&t, &tm)
        var buffer = [Int8](repeating: 0, count: 256)
        let count = Foundation.strftime(&buffer, buffer.count, format, &tm)
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
