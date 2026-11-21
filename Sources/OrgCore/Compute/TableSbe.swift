import Foundation

// `org-sbe` (ob-table.el, Org 9.8.7) in Lisp table formulas. The named block runs in `Elisp`,
// or for js through `TableBlocks.javaScript`, and named tables and lists are read from the
// file. Other languages, and references this can't follow, throw `Elisp.Unsupported`, so the
// table goes to Emacs.

/// How `org-sbe` runs js blocks.
public enum TableBlocks {
    /// Runs a js job to the end on the calling thread; nil when it can't. The app sets it.
    nonisolated(unsafe) public static var javaScript: ((BabelJob) throws -> BabelOutput?)?
    /// Whether `org-sbe` may run; the app ties it to running source blocks.
    nonisolated(unsafe) public static var allowed: () -> Bool = { true }
    /// The reason a table goes to the app when `allowed` is false.
    public static let lockedReason = "Lisp org-sbe with source blocks locked"
}

extension Babel {
    /// Defines `org-sbe` for formulas in the file whose text `text` gives.
    static func defineSbe(_ lisp: Elisp, text: @escaping () -> String) {
        lisp.defineForm("org-sbe") { _, args in
            guard TableBlocks.allowed() else { throw Elisp.Unsupported(what: "org-sbe with source blocks locked") }
            return .string(try sbe(args, text: text()))
        }
    }

    /// The macro's value: `(org-trim (format "%S" result))`, or the result when it is a string.
    static func sbe(_ args: [Sexp], text: String) throws -> String {
        guard let first = args.first else { throw Elisp.Signal(message: "Wrong number of arguments: org-sbe, 0") }
        let name: String
        switch first {
        case .string(let s): name = s
        case .symbol(let s): name = s
        default: throw Elisp.Unsupported(what: "org-sbe with a block name that isn't a symbol")
        }
        var variables = Array(args.dropFirst())
        var header = ""
        if case .string(let s)? = variables.first {
            header = s
            variables.removeFirst()
        }
        var specs: [String] = []
        for variable in variables {
            guard case .list(let items) = variable, case .symbol(let variableName)? = items.first else {
                throw Elisp.Unsupported(what: "org-sbe with an argument that isn't (NAME VALUE)")
            }
            // A value after `$` is written as Lisp, so a string stays a string.
            var quote = false
            var values: [Sexp] = []
            for item in items.dropFirst() {
                if item == .symbol("$") {
                    quote = true
                    continue
                }
                if quote {
                    values.append(.string(Elisp.printed(item, escape: true)))
                } else if !Elisp.isNil(item) {
                    values.append(item)
                }
                quote = false
            }
            if values.count > 1 {
                let read = try values.map { value -> Sexp in
                    guard case .string(let s) = value else { throw Elisp.Unsupported(what: "org-sbe with values that aren't text") }
                    do { return try LispReader.readFirst(s).sexp } catch { throw Elisp.Signal(message: "End of file during parsing") }
                }
                specs.append(variableName + "='" + Elisp.printed(.list(read), escape: true))
            } else {
                specs.append(variableName + "=" + (try Elisp.format([.string("%s"), values.first ?? .nil])))
            }
        }
        guard !name.isEmpty else { return "" }
        guard !name.contains(where: { "[]():\"".contains($0) }) else { throw Elisp.Unsupported(what: "org-sbe with the reference \(name)") }
        var value = try sbeReference(name, header: header, arguments: splitArguments(specs.joined(separator: ", ")), text: text)
        // `org-babel-ref-resolve` gives a symbol's name.
        if case .symbol(let s) = value, !Elisp.isNil(value) { value = .string(s) }
        // `:var results=` takes off a first row followed by a rule, as column names.
        if case .list(let rows) = value, rows.count > 1, rows[0] != .symbol("hline"), rows[1] == .symbol("hline"),
           !rows.dropFirst(2).contains(.symbol("hline")) {
            value = rows.count > 2 ? .list(Array(rows.dropFirst(2))) : .nil
        }
        let printed = value.string ?? Elisp.printed(value, escape: true)
        return printed.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
    }

    /// `org-babel-ref-resolve` for `name[header](arguments)`: a src block's value, or a named
    /// table or list.
    static func sbeReference(_ name: String, header: String, arguments: [String], text: String) throws -> Sexp {
        let ns = text as NSString
        let model = DocumentModel(tree: OrgParser.parse(text))
        let options = Options()
        // The first `#+NAME:` line with the name outside COMMENTed headings that names an
        // element: a src block's, or another element's.
        let pattern = "(?im)^[ \\t]*#\\+name:[ \\t]*" + NSRegularExpression.escapedPattern(for: name) + "[ \\t]*$"
        let matches = try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let headingStarts = model.headings.map(\.headingRange.lowerBound)
        func commented(_ location: Int) -> Bool {
            guard let h = headingStarts.lastIndex(where: { $0 <= location }) else { return false }
            return ([h] + model.ancestors(of: h)).contains { model.headings[$0].title == "COMMENT" || model.headings[$0].title.hasPrefix("COMMENT ") }
        }
        // A keyword followed by a blank line, after any other affiliated keywords, names nothing.
        func orphaned(_ match: NSRange) -> Bool {
            var location = NSMaxRange(ns.lineRange(for: match))
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let content = ns.substring(with: line)
                if content.range(of: "(?i)^[ \\t]*#\\+(name|caption|header|plot|results|attr_[-\\w]+)(\\[.*\\])?:", options: .regularExpression) == nil {
                    return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                location = NSMaxRange(line)
            }
            return true
        }
        guard let named = matches.first(where: { !commented($0.location) && !orphaned($0) }) else { throw notFound(name, text: text) }
        let start = named.location
        let block = model.srcBlocks.first { block in
            guard block.name == name, block.range.lowerBound > start else { return false }
            let between = ns.substring(with: NSRange(location: start, length: block.range.lowerBound - start))
            return between.split(separator: "\n").allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#+") }
        }
        guard let block else {
            // `resolve` reads the first element with the name, and runs a src block before it.
            guard named == matches.first, !model.srcBlocks.contains(where: { $0.name == name }) else {
                throw Elisp.Unsupported(what: "org-sbe with a name used more than once")
            }
            do {
                return try sbeSexp(resolve(name, model: model, text: ns, refs: References(resolved: [:], options: options)))
            } catch let failure as Failure {
                throw sbeError(failure, text: text)
            }
        }
        let params: Params
        do {
            params = try Params(block: block, model: model, text: ns, extra: [Params.parse(header) + arguments.map { (":var", $0) }])
        } catch let failure as Failure {
            throw sbeError(failure, text: text)
        }
        if params.single[":cache"] == "yes" { throw Elisp.Unsupported(what: "org-sbe with :cache") }
        var refs = References(resolved: [:], options: options)
        refs.visiting = [name]
        // The blocks its `:var`s refer to run first, as `DocumentSession.runBabel` runs them.
        while true {
            switch plan(block, params: params, model: model, text: ns, options: options, location: block.range, name: name, refs: refs, useCache: false) {
            case .failure(let failure):
                throw sbeError(failure, text: text)
            case .success(let job):
                if job.needsFile { throw Elisp.Unsupported(what: "org-sbe with Lisp that needs the file's name") }
                if let need = job.needs.first {
                    refs.resolved[need.reference] = varValue(need.job.finish, try sbeRun(need.job))
                    continue
                }
                // `org-babel-emacs-lisp-lexical`: "yes" and "t" are lexical; other Lisp is read.
                let lexical: Bool
                switch params.single[":lexical"] {
                case "yes", "t": lexical = true
                case nil, "no", "nil": lexical = false
                default: throw Elisp.Unsupported(what: "org-sbe with this :lexical")
                }
                return try sbeValue(job, lexical: lexical)
            }
        }
    }

    /// A block a reference needs, run as `Babel.evaluateNatively` or in JavaScriptCore.
    static func sbeRun(_ job: BabelJob) throws -> BabelOutput {
        if job.lispForm != nil {
            do {
                guard let output = try evaluateNatively(job) else { throw Elisp.Unsupported(what: "org-sbe with Lisp only Emacs runs") }
                return output
            } catch let Failure.message(message) {
                // An error in the block.
                throw Elisp.Signal(message: message)
            }
        }
        guard job.language == "js" || job.language == "javascript" else { throw Elisp.Unsupported(what: "org-sbe with \(job.language) blocks") }
        guard let output = try? TableBlocks.javaScript?(job), output.status == 0 else { throw Elisp.Unsupported(what: "org-sbe with js blocks") }
        return output
    }

    /// The block's value as `org-babel-execute-src-block` returns it.
    static func sbeValue(_ job: BabelJob, lexical: Bool) throws -> Sexp {
        let params = job.finish.params
        if params.contains("file") || job.finish.colnames != nil || job.finish.rownames != nil {
            throw Elisp.Unsupported(what: "org-sbe with this block's results")
        }
        let scalar = params.contains("scalar") || params.contains("verbatim") || params.contains("html") || params.contains("code")
            || params.contains("pp") || ((params.contains("output") || params.contains("raw") || params.contains("org")) && !params.contains("table"))
        var result: Sexp
        if let form = job.lispForm {
            // `org-babel-execute:emacs-lisp`: dynamic binding unless `:lexical` is yes or t.
            let lisp = Elisp()
            lisp.lexical = lexical
            lisp.syntax = .emacsLisp
            lisp.standardTime()
            result = try lisp.eval(try LispReader.readFirst(form).sexp)
            if Elisp.containsFunction(result) { throw Elisp.Unsupported(what: "org-sbe with a function value") }
            if scalar {
                result = .string(params.contains("scalar") || params.contains("verbatim") ? Elisp.printed(result, escape: true) : try Elisp.format([.string("%s"), result]))
            }
        } else {
            // `org-babel-js-read`: a number, a string, or the symbol a quoted word reads as.
            let raw = rawResult(job.finish, try sbeRun(job))
            if scalar {
                result = .string(raw)
            } else if raw.hasPrefix("(") || raw.hasPrefix("[") || raw.hasPrefix("`") || raw.contains("\\") {
                throw Elisp.Unsupported(what: "org-sbe with this js value")
            } else if raw.hasPrefix("'") {
                guard let m = raw.firstMatch(of: /^'([A-Za-z0-9_-]+)(?:'|\s)/) else { throw Elisp.Unsupported(what: "org-sbe with this js value") }
                result = try number(String(m.1)).map { try LispReader.readFirst($0).sexp } ?? .symbol(String(m.1))
            } else if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                result = .string(String(raw.dropFirst().dropLast()))
            } else {
                result = try number(raw).map { try LispReader.readFirst($0).sexp } ?? .string(raw)
            }
        }
        if params.contains("discard") { return .nil }
        if !job.finish.output, params.contains("vector") || params.contains("table") {
            if case .list = result {} else if !Elisp.isNil(result) { result = .list([.list([result])]) }
        }
        return result
    }

    /// A named table or list as `org-babel-read-element` reads it.
    static func sbeSexp(_ value: VarValue) throws -> Sexp {
        func cell(_ c: Cell) throws -> Sexp {
            switch c {
            case .text(let s): return .string(s)
            case .number(let n): return try LispReader.readFirst(n).sexp
            }
        }
        switch value {
        case .scalar(let s): return .string(s)
        case .number(let n): return try LispReader.readFirst(n).sexp
        case .list(let items): return .list(try items.map(cell))
        case .table(let rows): return .list(try rows.map { row in try row.map { .list(try $0.map(cell)) } ?? .symbol("hline") })
        }
    }

    /// A reference to nothing is an error; to an ID, which only Emacs looks up, unsupported.
    static func notFound(_ name: String, text: String) -> Error {
        let pattern = "(?im)^[ \\t]*:(custom_)?id:[ \\t]*" + NSRegularExpression.escapedPattern(for: name) + "[ \\t]*$"
        if text.range(of: pattern, options: .regularExpression) != nil { return Elisp.Unsupported(what: "org-sbe with an ID reference") }
        return Elisp.Signal(message: "Reference ‘\(name)’ not found in this buffer")
    }

    /// What a planning failure is in Emacs: a reference to nothing is an error, the rest
    /// unsupported here.
    static func sbeError(_ failure: Failure, text: String) -> Error {
        guard case .message(let message) = failure, let m = message.firstMatch(of: /^Can't find (.+) for :var\.$/) else {
            return Elisp.Unsupported(what: "org-sbe with a block orgstar can't run")
        }
        return notFound(String(m.1), text: text)
    }
}
