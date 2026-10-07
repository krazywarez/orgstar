import Foundation

// `org-babel-tangle` (Org 9.8.7 ob-tangle.el): source blocks written to the files their
// `:tangle` names, with `:noweb`, `:padline`, `:shebang`, `:mkdirp`, `:tangle-mode`,
// `:prologue` and `:epilogue`, `:var` for shells, Python and Emacs Lisp, and `:comments` for
// languages whose comment syntax is known. Header values written as Lisp are evaluated with
// the file's name and folder; other Lisp is refused.

public enum Tangle {
    /// All blocks (C-c C-v t), the block at an offset (C-u C-c C-v t), or the blocks going to
    /// the same file as the block at an offset (C-u C-u C-c C-v t).
    public enum Scope: Sendable, Equatable {
        case all
        case block(Int)
        case target(Int)
    }

    public struct File: Sendable, Equatable {
        /// Absolute.
        public var path: String
        public var contents: String
        /// From `:tangle-mode`, or 0o755 for a file with a `:shebang`; nil leaves the mode alone.
        public var mode: Int?
        /// `:mkdirp`: the file's directory is made if missing.
        public var makeDirectories: Bool
    }

    public struct Output: Sendable, Equatable {
        public var files: [File]
        /// Blocks written, for "Tangled N code blocks".
        public var blocks: Int
    }

    /// `org-babel-tangle-lang-exts`.
    static let extensions = ["emacs-lisp": "el", "elisp": "el", "bibtex": "bib"]
    /// `org-babel-shell-names`, and `shell` itself.
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "csh", "ash", "dash", "ksh", "mksh", "posh", "shell"]

    /// The files tangling `text`, the contents of the Org file at `path`, writes.
    public static func run(text: String, path: String, scope: Scope = .all, tree: OrgTree? = nil) -> Result<Output, Babel.Failure> {
        let ns = text as NSString
        let model = DocumentModel(tree: tree ?? OrgParser.parse(text))
        do {
            var order: [String] = []
            var specs: [String: [(language: String?, body: String, params: Babel.Params)]] = [:]
            // `org-babel-tangle-collect-blocks`: blocks numbered from 1 under each heading.
            var counters: [Int: Int] = [:]
            var lastHeading: Int?? = .none
            var counter = 0
            for block in model.srcBlocks {
                if lastHeading == .some(block.heading) { counter += 1 } else { (counter, lastHeading) = (1, .some(block.heading)) }
                counters[block.range.lowerBound] = counter
            }
            func add(_ block: SrcBlockInfo, _ params: Babel.Params, counter: Int) throws {
                guard let file = try fileName(path: path, language: block.language, tangle: params.single[":tangle"] ?? "no") else { return }
                let parsed = tree ?? OrgParser.parse(text)
                let links = { (other: SrcBlockInfo, otherParams: Babel.Params) in
                    try Self.links(other, params: otherParams, counter: counters[other.range.lowerBound] ?? 1, path: path, model: model, tree: parsed, text: ns)
                }
                let body = try spec(block, body: try body(block, params: params, model: model, text: ns, links: links), params: params, counter: counter,
                                    path: path, model: model, tree: parsed, text: ns)
                if specs[file] == nil { order.append(file) }
                specs[file, default: []].append((block.language, body, params))
            }
            switch scope {
            case .block(let offset):
                guard let block = block(at: offset, in: model) else { throw Babel.Failure.message("Point is not in a source code block") }
                try add(block, try params(block, model: model, text: ns, path: path), counter: 1)
            case .all, .target:
                var target: String?
                if case .target(let offset) = scope {
                    guard let block = block(at: offset, in: model) else { throw Babel.Failure.message("Point is not in a source code block") }
                    target = try params(block, model: model, text: ns, path: path).single[":tangle"] ?? "no"
                }
                for block in model.srcBlocks where !excluded(block, model: model) {
                    let params = try params(block, model: model, text: ns, path: path)
                    let tangle = params.single[":tangle"] ?? "no"
                    if tangle == "no" || (block.language == nil && tangle == "yes") { continue }
                    if let target, target != tangle { continue }
                    try add(block, params, counter: counters[block.range.lowerBound] ?? 1)
                }
            }
            var files: [File] = []
            var blocks = 0
            for file in order {
                var contents = ""
                var mode: Int?
                var makeDirectories = false
                var sheBanged = false
                for spec in specs[file]! {
                    let shebang = spec.params.single[":shebang"].flatMap { $0.isEmpty ? nil : $0 }
                    var tangleMode = try spec.params.single[":tangle-mode"].map(fileMode)
                    if shebang != nil, tangleMode == nil { tangleMode = 0o755 }
                    // `add-to-list` then `mapc`: the first mode given is the one left.
                    if mode == nil { mode = tangleMode }
                    if let mkdirp = spec.params.single[":mkdirp"], mkdirp != "no" { makeDirectories = true }
                    if spec.params.single[":padline"] != "no", !contents.isEmpty { contents += "\n" }
                    if let shebang, !sheBanged {
                        contents += shebang + "\n"
                        sheBanged = true
                    }
                    contents += spec.body
                    blocks += 1
                }
                files.append(File(path: file, contents: contents, mode: mode, makeDirectories: makeDirectories))
            }
            return .success(Output(files: files, blocks: blocks))
        } catch let error as Babel.Failure {
            return .failure(error)
        } catch {
            return .failure(.message("\(error)"))
        }
    }

    /// `org-babel-where-is-src-block-head`.
    static func block(at offset: Int, in model: DocumentModel) -> SrcBlockInfo? {
        model.srcBlocks.first { $0.range.contains(offset) || $0.range.upperBound == offset }
    }

    /// `org-in-commented-heading-p` and `org-in-archived-heading-p`.
    static func excluded(_ block: SrcBlockInfo, model: DocumentModel) -> Bool {
        guard let heading = block.heading else { return false }
        return ([heading] + model.ancestors(of: heading)).contains { index in
            let h = model.headings[index]
            return AgendaSource.isCommented(h.title) || h.localTags.contains("ARCHIVE")
        }
    }

    static func params(_ block: SrcBlockInfo, model: DocumentModel, text: NSString, path: String) throws -> Babel.Params {
        var params = try Babel.Params(block: block, model: model, text: text)
        for (key, value) in params.single where value.hasPrefix("(") && key != ":tangle-mode" {
            params.single[key] = try evaluate(value, key: key, path: path)
        }
        return params
    }

    /// `org-babel-read` of a header value written as Lisp, with what a file's buffer knows:
    /// `buffer-file-name`, `default-directory` and `system-type`.
    static func evaluate(_ value: String, key: String, path: String) throws -> String {
        let refusal = Babel.Failure.message("\(key) \(value) is Lisp tangling can't evaluate yet; nothing was tangled.")
        let lisp = Elisp()
        let directory = (path as NSString).deletingLastPathComponent + "/"
        lisp.set("buffer-file-name", .string(path))
        lisp.set("default-directory", .string(directory))
        lisp.set("system-type", .symbol("darwin"))
        func string(_ args: [Sexp], _ i: Int) throws -> String { try Elisp.string(args[i]) }
        lisp.define("expand-file-name") { lisp, args in
            try Elisp.arity(args, 1...2, "expand-file-name")
            let base = args.count > 1 && !Elisp.isNil(args[1]) ? try string(args, 1) : (try Elisp.string(lisp.value("default-directory")))
            return .string(expand(try string(args, 0), in: (base as NSString).expandingTildeInPath))
        }
        lisp.define("file-name-directory") { _, args in
            try Elisp.arity(args, 1...1, "file-name-directory")
            let name = try string(args, 0)
            guard let slash = name.lastIndex(of: "/") else { return .nil }
            return .string(String(name[...slash]))
        }
        lisp.define("file-name-nondirectory") { _, args in
            try Elisp.arity(args, 1...1, "file-name-nondirectory")
            let name = try string(args, 0)
            return .string(name.lastIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name)
        }
        lisp.define("file-name-sans-extension") { _, args in
            try Elisp.arity(args, 1...1, "file-name-sans-extension")
            return .string((try string(args, 0) as NSString).deletingPathExtension)
        }
        lisp.define("file-name-as-directory") { _, args in
            try Elisp.arity(args, 1...1, "file-name-as-directory")
            let name = try string(args, 0)
            return .string(name.hasSuffix("/") ? name : name + "/")
        }
        guard let form = try? LispReader.readFirst(value).sexp, let result = try? lisp.eval(form), !Elisp.isNil(result) else { throw refusal }
        switch result {
        case .string(let s): return s
        case .symbol(let s): return s
        case .integer, .float: return Elisp.printed(result)
        default: throw refusal
        }
    }

    /// `org-babel-effective-tangled-filename`.
    static func fileName(path: String, language: String?, tangle: String) throws -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        let base: String
        switch tangle {
        case "no", "": return nil
        case "yes": base = (path as NSString).deletingPathExtension
        default: base = expand(tangle, in: directory)
        }
        guard tangle == "yes", let language else { return base }
        return base + "." + (extensions[language] ?? language)
    }

    /// `expand-file-name`.
    static func expand(_ name: String, in directory: String) -> String {
        let expanded = (name as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    /// `org-babel-tangle-single-block`'s body: noweb references expanded or stripped, the
    /// language's expansion with `:var`, `:prologue` and `:epilogue`, `-r` coderefs taken
    /// out, and indentation and surrounding blank space trimmed.
    static func body(_ block: SrcBlockInfo, params: Babel.Params, model: DocumentModel, text: NSString,
                     links: ((SrcBlockInfo, Babel.Params) throws -> (begin: String, end: String))? = nil) throws -> String {
        var body = Babel.normalizedBody(block)
        let noweb = params.single[":noweb"]
        if Babel.nowebTangles(noweb) {
            if noweb == "strip-tangle" {
                body = body.replacingOccurrences(of: "<<([^ \\t\\n](?:.*?[^ \\t\\n])?)>>", with: "", options: .regularExpression)
            } else {
                body = try Babel.expandNoweb(block, params: params, model: model, text: text, tangling: true, links: links)
            }
        }
        if params.single[":no-expand"] == nil {
            body = try expandBody(body, language: block.language ?? "", params: params, model: model, text: text)
        }
        // `(string-match "-r" extra)`.
        let switches = block.switches.joined(separator: " ")
        if switches.contains("-r") {
            // `org-src-coderef-regexp` of `-l "FORMAT"`, or of `org-coderef-label-format`.
            let format = switches.firstMatch(of: /-l +"([^"\n]+)"/).map { String($0.1) } ?? "(ref:%s)"
            let pattern = "[ \\t]*" + NSRegularExpression.escapedPattern(for: format)
                .replacingOccurrences(of: "%s", with: "[-a-zA-Z0-9_][-a-zA-Z0-9_ ]*") + "[ \\t]*$"
            body = body.components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
                .joined(separator: "\n")
        }
        let preserve = block.switches.contains("-i")
        if !preserve { body = removeIndentation(body) }
        body = body.replacingOccurrences(of: "[ \\t\\n\\r]+$", with: "", options: .regularExpression)
        return preserve
            ? body.replacingOccurrences(of: "^([ \\t]*\\n)+", with: "", options: .regularExpression)
            : body.replacingOccurrences(of: "^[ \\t\\n\\r]+", with: "", options: .regularExpression)
    }

    /// `org-babel-spec-to-string`: the block's text in the file, with its `:comments`.
    static func spec(_ block: SrcBlockInfo, body: String, params: Babel.Params, counter: Int, path: String, model: DocumentModel, tree: OrgTree, text: NSString) throws -> String {
        let comments = params.single[":comments"] ?? "no"
        guard comments != "no" else { return body + "\n" }
        let language = block.language ?? ""
        let linked = ["both", "link", "yes", "noweb"].contains(comments)
        var out = ""
        if comments == "org" || comments == "both" {
            let prose = orgComment(block, model: model, text: text)
            if prose.contains(where: { !$0.isWhitespace }) { out += try commentRegion(prose, language: language) + "\n" }
        }
        let link = linked ? try links(block, params: params, counter: counter, path: path, model: model, tree: tree, text: text) : nil
        if let link { out += try commentRegion(link.begin, language: language) + "\n" }
        out += body + "\n"
        if let link { out += try commentRegion(link.end, language: language) + "\n" }
        return out
    }

    /// `org-babel-tangle-comment-format-beg` and `-end` for a block: `[[LINK][NAME]]` and
    /// `NAME ends here`, the link relative to the tangled file's folder.
    static func links(_ block: SrcBlockInfo, params: Babel.Params, counter: Int, path: String, model: DocumentModel, tree: OrgTree, text: NSString) throws -> (begin: String, end: String) {
        let directory = (path as NSString).deletingLastPathComponent
        let tangle = params.single[":tangle"] ?? "no"
        let target = tangle.contains("/") ? (expand(tangle, in: directory) as NSString).deletingLastPathComponent : directory
        let start = beginLine(block, text: text)
        let context = EditContext(revision: 0, text: text as String, tree: tree, selection: [start..<start])
        let stored = Links.store(in: context, path: relativePath(path, from: target)).link
        let name = block.name ?? ((block.heading.map { model.headings[$0].title.trimmingCharacters(in: .whitespaces) } ?? "No heading") + ":\(counter)")
        return ("[[\(stored)][\(name)]]", "\(name) ends here")
    }

    /// `file-relative-name`.
    static func relativePath(_ path: String, from directory: String) -> String {
        let to = (path as NSString).standardizingPath.split(separator: "/")
        let from = (directory as NSString).standardizingPath.split(separator: "/")
        let common = zip(to, from).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - common) + to.dropFirst(common).map(String.init)).joined(separator: "/")
    }

    /// The start of the block's `#+begin_src` line.
    static func beginLine(_ block: SrcBlockInfo, text: NSString) -> Int {
        let regex = try! NSRegularExpression(pattern: "^[ \\t]*#\\+begin_src", options: [.anchorsMatchLines, .caseInsensitive])
        return regex.firstMatch(in: text as String, range: NSRange(block.range))?.range.location ?? block.range.lowerBound
    }

    /// The prose `:comments org` takes: from the heading's title, or the end of the block
    /// before, to the block, without its common indentation.
    static func orgComment(_ block: SrcBlockInfo, model: DocumentModel, text: NSString) -> String {
        let begin = beginLine(block, text: text)
        var start = 0
        if let heading = block.heading {
            let line = text.substring(with: NSRange(model.headings[heading].headingRange))
            start = model.headings[heading].headingRange.lowerBound + (line.firstMatch(of: #/^\*+ /#).map { $0.output.utf16.count } ?? 0)
        }
        let end = try! NSRegularExpression(pattern: "^[ \\t]*#\\+end_src", options: [.anchorsMatchLines, .caseInsensitive])
        for other in model.srcBlocks where other.range.lowerBound < begin {
            if let m = end.firstMatch(in: text as String, range: NSRange(other.range)), NSMaxRange(m.range) <= begin { start = max(start, NSMaxRange(m.range)) }
        }
        return removeIndentation(text.substring(with: NSRange(location: start, length: max(0, begin - start))))
    }

    /// Comment syntax of the language's major mode (`org-src-get-lang-mode`), as
    /// `comment-region` writes it.
    static let commentSyntax: [String: (start: String, end: String)] = {
        var table: [String: (String, String)] = [:]
        for language in ["emacs-lisp", "elisp", "lisp", "scheme"] { table[language] = (";; ", "") }
        for language in ["python", "ruby", "perl", "conf", "toml", "makefile", "awk", "tcl"] { table[language] = ("# ", "") }
        for language in shells.subtracting(["fish"]) { table[language] = ("# ", "") }
        for language in ["js", "java", "cpp", "C++"] { table[language] = ("// ", "") }
        for language in ["c", "C", "css"] { table[language] = ("/* ", " */") }
        for language in ["lua", "sql", "sqlite"] { table[language] = ("-- ", "") }
        for language in ["latex"] { table[language] = ("%% ", "") }
        return table
    }()

    /// `comment-region` over `text`: each line that isn't blank, commented.
    static func commentRegion(_ text: String, language: String) throws -> String {
        guard let syntax = commentSyntax[language] else {
            throw Babel.Failure.message(":comments needs the comment syntax of \(language.isEmpty ? "the block's language" : language), which isn't known yet; nothing was tangled.")
        }
        return text.components(separatedBy: "\n").map { line in
            line.contains(where: { !$0.isWhitespace }) ? syntax.start + line + syntax.end : line
        }.joined(separator: "\n")
    }

    /// `org-remove-indentation`.
    static func removeIndentation(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let indents = lines.filter { $0.contains { !$0.isWhitespace } }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        guard common > 0 else { return s }
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }.joined(separator: "\n")
    }

    /// `org-babel-expand-body:LANG`, or the generic expansion with the language's variable
    /// assignments.
    static func expandBody(_ body: String, language: String, params: Babel.Params, model: DocumentModel, text: NSString) throws -> String {
        let refs = Babel.References(resolved: [:], options: Babel.Options())
        let vars = try params.vars.map { variable in
            do {
                return (variable.name, try Babel.resolve(variable.value, model: model, text: text, refs: refs))
            } catch is Babel.Needed {
                throw Babel.Failure.message(":var \(variable.value) would run a block while tangling, which isn't supported yet; nothing was tangled.")
            }
        }
        let prologue = params.single[":prologue"]
        let epilogue = params.single[":epilogue"]
        if language == "emacs-lisp" || language == "elisp" {
            guard !vars.isEmpty else { return body + "\n" }
            let bindings = vars.map { "(\($0.0) '\(Babel.lispLiteral($0.1)))" }.joined(separator: "\n      ")
            return "(let (\(bindings))\n" + (prologue.map { $0 + "\n      " } ?? "") + body + (epilogue.map { "\n      " + $0 + "\n" } ?? "") + "\n)"
        }
        var lines: [String] = []
        if shells.contains(language) {
            lines = try vars.map { name, value in
                switch value {
                case .scalar(let s), .number(let s): return "\(name)='" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                default: throw Babel.Failure.message("Tables and lists in :var aren't supported for tangling \(language) yet; nothing was tangled.")
                }
            }
        } else if language == "python" {
            lines = vars.map { "\($0.0)=\(Babel.pythonLiteral($0.1))" }
        } else if !vars.isEmpty {
            throw Babel.Failure.message(":var isn't supported for tangling \(language) yet; nothing was tangled.")
        }
        return ((prologue.map { [$0] } ?? []) + lines + [body] + (epilogue.map { [$0] } ?? [])).joined(separator: "\n")
    }

    /// `org-babel-interpret-file-mode`, for `:tangle-mode`.
    static func fileMode(_ value: String) throws -> Int {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let m = v.wholeMatch(of: /\(identity\s+#o([0-7]{3})\)/) ?? v.wholeMatch(of: /#o([0-7]{3})/) ?? v.wholeMatch(of: /o0?([0-7]{3})/) {
            return Int(m.1, radix: 8)!
        }
        if v.wholeMatch(of: /[r-][w-][xs-][r-][w-][xs-][r-][w-][x-]/) != nil {
            let chars = Array(v)
            var mode = 0
            for (i, bit) in [0o400, 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1].enumerated() where chars[i] != "-" { mode |= bit }
            return mode
        }
        if v.wholeMatch(of: /[ugoa]*[+=-][rwx]*(,[ugoa]*[+=-][rwx]*)*/) != nil {
            var mode = 0o644
            for clause in v.split(separator: ",") {
                let who = clause.prefix { "ugoa".contains($0) }
                let rest = clause.dropFirst(who.count)
                let op = rest.first!
                let perms = rest.dropFirst()
                var mask = 0
                for w in (who.isEmpty ? "a" : String(who)) {
                    switch w {
                    case "u": mask |= 0o700
                    case "g": mask |= 0o070
                    case "o": mask |= 0o007
                    default: mask |= 0o777
                    }
                }
                var bits = 0
                for p in perms {
                    switch p {
                    case "r": bits |= 0o444
                    case "w": bits |= 0o222
                    default: bits |= 0o111
                    }
                }
                switch op {
                case "+": mode |= bits & mask
                case "-": mode &= ~(bits & mask)
                default: mode = (mode & ~mask) | (bits & mask)
                }
            }
            return mode
        }
        throw Babel.Failure.message("File mode \(value) isn't one tangling understands; nothing was tangled.")
    }
}

/// C-c C-v t (`org-babel-tangle`): the app writes the files.
public struct TangleCommand: OrgCommand {
    public let scope: Scope

    public enum Scope: Sendable { case all, block, target }

    public init(_ scope: Scope = .all) { self.scope = scope }

    public var id: String {
        switch scope {
        case .all: "org.babel.tangle"
        case .block: "org.babel.tangle-block"
        case .target: "org.babel.tangle-target"
        }
    }

    public var title: String {
        switch scope {
        case .all: "Tangle File"
        case .block: "Tangle Block"
        case .target: "Tangle Block's Target"
        }
    }

    public func applies(in context: EditContext) -> Bool {
        scope == .all ? !DocumentModel(tree: context.tree).srcBlocks.isEmpty : KeyContext.holds("src", in: context)
    }

    public func run(in context: EditContext) -> CommandStep {
        switch scope {
        case .all: .external(.tangle(.all))
        case .block: .external(.tangle(.block(context.caret)))
        case .target: .external(.tangle(.target(context.caret)))
        }
    }
}
