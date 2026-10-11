import Foundation

extension Babel {
    // MARK: - Tables in variables

    /// Variables after `org-babel-disassemble-tables`, with the names taken off their tables.
    struct Tables {
        var vars: [(String, VarValue)] = []
        var colnames: [(name: String, names: [Cell])] = []
        var rownames: [(name: String, names: [Cell])] = []

        /// `org-babel-pick-name`: a Lisp list given as the header argument, or the last
        /// variable's names, unless the header argument is absent, whose `nil` selects none.
        func picked(_ names: [(name: String, names: [Cell])], _ key: String, _ params: Params) -> [String]? {
            if let list = params.evaluated[key].flatMap(Babel.lispNames) { return list }
            guard params.single[key] != nil, let last = names.last else { return nil }
            return last.names.map(Babel.cellText)
        }
    }

    /// A Lisp list of strings and numbers, as names.
    static func lispNames(_ value: Sexp) -> [String]? {
        guard case .list(let items) = value else { return nil }
        return try? items.map { item in
            if let s = item.string { return s }
            let printed = Elisp.printed(item)
            guard number(printed) == printed else { throw Failure.message(printed) }
            return printed
        }
    }

    static func cellText(_ c: Cell) -> String {
        switch c {
        case .number(let n): n
        case .text(let s): s
        }
    }

    /// `org-babel-disassemble-tables`: a table's header row comes off when `:colnames` asks, or
    /// by default when only its second row is a rule; its first column with `:rownames`; its
    /// rules unless `:hlines yes`.
    static func disassemble(_ vars: [(String, VarValue)], params: Params) throws -> Tables {
        for key in [":colnames", ":rownames"] where params.lisp.contains(key) && params.evaluated[key].flatMap(lispNames) == nil {
            throw Failure.message("\(key) \(params.single[key] ?? "") is Lisp that only Emacs can evaluate; nothing was run.")
        }
        let colnames = params.single[":colnames"]
        let rownames = params.single[":rownames"]
        let hlines = params.single[":hlines"] ?? "no"
        var tables = Tables()
        for (name, value) in vars {
            guard case .table(var rows) = value else {
                tables.vars.append((name, value))
                continue
            }
            let auto = rows.count > 1 && rows[0] != nil && rows[1] == nil && !rows.dropFirst(2).contains(where: { $0 == nil })
            if colnames != "no", colnames != nil || auto {
                while let first = rows.first, first == nil { rows.removeFirst() }
                if let header = rows.first ?? nil {
                    rows.removeFirst(rows.count > 1 && rows[1] == nil ? 2 : 1)
                    tables.colnames.append((name, header))
                }
            }
            if let rownames, rownames != "no" {
                let kept = rows.compactMap { $0 }
                tables.rownames.append((name, kept.map { $0.first ?? .text("") }))
                rows = kept.map { Array($0.dropFirst()) }
            }
            if hlines != "yes" { rows = rows.filter { $0 != nil } }
            tables.vars.append((name, .table(rows)))
        }
        return tables
    }

    /// `org-babel-reassemble-table` on a result.
    static func reassemble(_ value: Value, _ finish: BabelJob.Finish) -> Value {
        guard case .table(var rows) = value else { return value }
        if let names = finish.rownames, names.count == rows.count {
            var next = names.makeIterator()
            rows = rows.map { row in row.map { [next.next() ?? ""] + $0 } }
        }
        if let names = finish.colnames, let first = rows.first ?? nil, first.count == names.count {
            rows = [names, nil] + rows
        }
        return .table(rows)
    }

    /// A `:var` value that is Lisp (`org-babel-read`): evaluated, as a number, string, list or
    /// table.
    static func lispValue(_ value: String) throws -> VarValue {
        let refusal = Failure.message(":var value \(value) is Lisp that only Emacs can evaluate.")
        guard let form = try? LispReader.readFirst(value).sexp, let result = try? Elisp().eval(form) else { throw refusal }
        func cell(_ v: Sexp) throws -> Cell {
            if let s = v.string { return .text(s) }
            if let n = number(Elisp.printed(v)), Elisp.printed(v) == n { return .number(n) }
            throw refusal
        }
        if let s = result.string { return .scalar(s) }
        if case .list(let items) = result, !items.isEmpty {
            if items.allSatisfy({ if case .list = $0 { return true }; return $0 == .symbol("hline") }) {
                return .table(try items.map { item in
                    if item == .symbol("hline") { return nil }
                    guard case .list(let cells) = item else { throw refusal }
                    return try cells.map(cell)
                })
            }
            return .list(try items.map(cell))
        }
        if case .number(let n) = try? cell(result) { return .number(n) }
        throw refusal
    }

    // MARK: - Variables

    /// A referenced block's result as a `:var` value.
    static func varValue(_ finish: BabelJob.Finish, _ output: BabelOutput) -> VarValue {
        switch value(finish, output) {
        case .none: return .scalar("")
        case .string(let s): return number(s).map(VarValue.number) ?? .scalar(s)
        case .table(let rows): return .table(rows.map { $0?.map(cell) })
        }
    }

    enum VarValue: Equatable, Sendable {
        case scalar(String)
        case number(String)
        /// Rows; nil is a rule (`hline`).
        case table([[Cell]?])
        case list([Cell])
    }

    enum Cell: Equatable, Sendable {
        case text(String)
        case number(String)
    }

    /// `org-babel--string-to-number`, keeping Emacs's printed form.
    static func number(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), t.range(of: "^[0-9e.+ -]+$", options: .regularExpression) != nil else { return nil }
        if t.range(of: "^[-+]?[0-9]+\\.?$", options: .regularExpression) != nil {
            var digits = t.hasSuffix(".") ? String(t.dropLast()) : t
            let negative = digits.hasPrefix("-")
            if digits.hasPrefix("-") || digits.hasPrefix("+") { digits.removeFirst() }
            digits = String(digits.drop { $0 == "0" })
            if digits.isEmpty { return "0" }
            return (negative ? "-" : "") + digits
        }
        guard t.range(of: "^[-+]?([0-9]+\\.[0-9]+|[0-9]*\\.[0-9]+|[0-9]+(\\.[0-9]*)?e[-+]?[0-9]+|[0-9]*\\.[0-9]+e[-+]?[0-9]+)$", options: .regularExpression) != nil,
              let d = Double(t) else { return nil }
        return emacsFloat(d)
    }

    /// How Emacs prints a float.
    static func emacsFloat(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    static func cell(_ s: String) -> Cell {
        var t = s
        if let m = s.firstMatch(of: /^\s*"(.+)"\s*$/) { t = String(m.1) }
        return number(t).map(Cell.number) ?? .text(t)
    }

    /// `name` or `name(args)` naming a src block in the file: the block and its call arguments.
    static func referencedBlock(_ value: String, model: DocumentModel) -> (block: SrcBlockInfo, arguments: String?)? {
        guard let m = value.firstMatch(of: /^([^\s()\[\]"]+)(?:\((.*)\))?$/),
              let block = model.srcBlocks.first(where: { $0.name == String(m.1) }) else { return nil }
        return (block, m.2.map(String.init))
    }

    /// The blocks `params`' references run, directly or through theirs.
    static func referencedBlocks(_ params: Params, model: DocumentModel, text: NSString, seen: Set<String>) -> [SrcBlockInfo] {
        var found: [SrcBlockInfo] = []
        var seen = seen
        for value in params.vars.map(\.value) + [params.single[":stdin"]].compactMap({ $0 }) {
            guard let (block, arguments) = referencedBlock(value, model: model), let name = block.name, seen.insert(name).inserted else { continue }
            found.append(block)
            let extra = arguments.map { [splitArguments($0).map { (":var", $0) }] } ?? []
            if let inner = try? Params(block: block, model: model, text: text, extra: extra) {
                found += referencedBlocks(inner, model: model, text: text, seen: seen)
            }
        }
        return found
    }

    /// `org-babel-ref-resolve` for literals, named tables and lists in the file, and named src
    /// blocks, which run first (`Needed`) and give their result.
    static func resolve(_ value: String, model: DocumentModel, text: NSString, refs: References) throws -> VarValue {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { return .scalar(Params.unescape(String(value.dropFirst().dropLast()))) }
        if let n = number(value) { return .number(n) }
        if let first = value.first, "('`[".contains(first) { return try lispValue(value) }
        if let known = refs.resolved[value] { return known }
        if let (block, arguments) = referencedBlock(value, model: model), let name = block.name {
            guard !refs.visiting.contains(name) else { throw Failure.message("\(name) refers to itself through :var") }
            let extra = arguments.map { [splitArguments($0).map { (":var", $0) }] } ?? []
            var inner = refs
            inner.visiting.insert(name)
            var params = try Params(block: block, model: model, text: text, extra: extra)
            params.evaluateLisp(file: refs.options.file)
            // A cached block gives its result without running, as `org-babel-execute-src-block` does.
            var useCache = true
            if params.single[":cache"] == "yes", let language = block.language {
                let tables = try disassemble(params.vars.map { ($0.name, try resolve($0.value, model: model, text: text, refs: inner)) }, params: params)
                let body = nowebEvaluates(params.single[":noweb"]) ? try expandNoweb(block, params: params, model: model, text: text) : normalizedBody(block)
                let state = try cacheState(language: language, params: params, tables: tables, body: body, location: block.range, name: name, call: false, text: text, options: refs.options, model: model)
                if state.current {
                    if let value = state.value { return value }
                    useCache = false
                }
            }
            switch plan(block, params: params, model: model, text: text,
                        options: refs.options, location: block.range, name: name, refs: inner, useCache: useCache) {
            case .failure(let failure): throw failure
            case .success(let job):
                throw Needed(need: job.needs.first ?? BabelJob.Need(reference: value, job: job))
            }
        }
        if value.contains("(") || value.contains("[") { throw Failure.message("References like \(value) aren't supported yet.") }
        // A named element: `#+NAME: value` above a table or list.
        let pattern = "(?im)^[ \\t]*#\\+name:[ \\t]*" + NSRegularExpression.escapedPattern(for: value) + "[ \\t]*$"
        guard let r = (text as String).range(of: pattern, options: .regularExpression) else {
            throw Failure.message("Can't find \(value) for :var.")
        }
        let start = NSMaxRange(text.lineRange(for: NSRange(r, in: text as String)))
        var location = start
        var rows: [[Cell]?] = []
        var items: [Cell] = []
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                if trimmed.hasPrefix("|-") {
                    rows.append(nil)
                    location = NSMaxRange(lineRange)
                    continue
                }
                let cells = trimmed.dropFirst().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                rows.append((trimmed.hasSuffix("|") ? Array(cells.dropLast()) : cells).map(cell))
            } else if let m = trimmed.firstMatch(of: /^[-+*] (.*)$/), rows.isEmpty {
                items.append(cell(String(m.1)))
            } else if trimmed.hasPrefix("#+") || (!rows.isEmpty || !items.isEmpty) {
                if rows.isEmpty, items.isEmpty, trimmed.lowercased().hasPrefix("#+begin_src") {
                    throw Failure.message("Using a src block's result in :var isn't supported yet.")
                }
                break
            } else {
                break
            }
            location = NSMaxRange(lineRange)
        }
        if !rows.isEmpty { return .table(rows) }
        if !items.isEmpty { return .list(items) }
        throw Failure.message("\(value) isn't a table or list.")
    }

    /// `org-babel-sh-var-to-string`: a table's rows as tab-separated lines, a list's items as
    /// lines.
    static func shellString(_ value: VarValue, separator: String? = nil, hline: String? = nil) -> String {
        switch value {
        case .scalar(let s), .number(let s): return s
        case .list(let items): return items.map(cellText).joined(separator: "\n")
        case .table(let rows): return rows.compactMap { $0?.map(cellText).joined(separator: separator ?? "\t") ?? hline }.joined(separator: "\n")
        }
    }

    /// `org-babel-variable-assignments:shell`, by the shell's name: for bash, an array for a
    /// list and an associative array for a table of two or more columns; `set` for fish; a
    /// quoted string otherwise.
    static func shellAssignments(_ vars: [(String, VarValue)], shell: String, params: Params) -> [String] {
        let separator = params.single[":separator"]
        let hline = params.single[":hlines"] == "yes" ? params.single[":hline-string"] ?? "hline" : nil
        func quoted(_ value: VarValue) -> String {
            "'" + shellString(value, separator: separator, hline: hline).replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        return vars.map { name, value in
            if shell.hasSuffix("bash") {
                switch value {
                case .table(let rows) where (rows.first ?? nil).map({ $0.count >= 2 }) ?? false:
                    let entries = rows.compactMap { $0 }.map { row in
                        "\(name)[\(quoted(.scalar(cellText(row[0]))))]=\(quoted(.list(Array(row.dropFirst()))))"
                    }
                    return (["unset \(name)", "declare -A \(name)"] + entries).joined(separator: "\n")
                case .table(let rows):
                    let items = rows.map { $0.map { quoted(.list($0)) } ?? quoted(.scalar("hline")) }
                    return "unset \(name)\ndeclare -a \(name)=( \(items.joined(separator: " ")) )"
                case .list(let items):
                    return "unset \(name)\ndeclare -a \(name)=( \(items.map { quoted(.scalar(cellText($0))) }.joined(separator: " ")) )"
                case .scalar, .number:
                    break
                }
            }
            return (shell.hasSuffix("fish") ? "set \(name) " : "\(name)=") + quoted(value)
        }
    }

    /// `org-babel-python-var-to-python`.
    static func pythonLiteral(_ value: VarValue) -> String {
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): return n
            case .text(let s): return lispString(s, triple: s.contains("\n") || s.contains("\r"))
            }
        }
        switch value {
        case .scalar(let s): return lispString(s, triple: s.contains("\n") || s.contains("\r"))
        case .number(let n): return n
        case .list(let items): return "[" + items.map(cell).joined(separator: ", ") + "]"
        case .table(let rows): return "[" + rows.map { $0.map { "[" + $0.map(cell).joined(separator: ", ") + "]" } ?? "None" }.joined(separator: ", ") + "]"
        }
    }

    /// `prin1` of a string.
    static func lispString(_ s: String, triple: Bool = false) -> String {
        let quoted = "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return triple ? "\"\"" + quoted + "\"\"" : quoted
    }

    static func lispLiteral(_ value: VarValue) -> String {
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): return n
            case .text(let s): return lispString(s)
            }
        }
        switch value {
        case .scalar(let s): return lispString(s)
        case .number(let n): return n
        case .list(let items): return "(" + items.map(cell).joined(separator: " ") + ")"
        case .table(let rows): return "(" + rows.map { $0.map { "(" + $0.map(cell).joined(separator: " ") + ")" } ?? "hline" }.joined(separator: " ") + ")"
        }
    }
}
