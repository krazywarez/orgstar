import Foundation

// Variables, `:prologue` and `:epilogue` for the interpreted languages (ob-ruby, ob-js, ob-R,
// ob-awk, Org 9.8.7), and how ob-ruby and ob-js return a block's value.

extension Babel {
    /// `org-babel-expand-body:generic`: the prologue, the variables, the body and the epilogue,
    /// a line apart.
    static func expandGeneric(_ body: String, _ lines: [String], _ params: Params) -> String {
        ((params.single[":prologue"].map { [$0] } ?? []) + lines + [body] + (params.single[":epilogue"].map { [$0] } ?? [])).joined(separator: "\n")
    }

    /// `org-babel-ruby-var-to-ruby`: lists in brackets, a rule `nil`, the rest as `prin1`.
    static func rubyLiteral(_ value: VarValue) -> String {
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): n
            case .text(let s): lispString(s)
            }
        }
        switch value {
        case .scalar(let s): return lispString(s)
        case .number(let n): return n
        case .list(let items): return "[" + items.map(cell).joined(separator: ", \n") + "]"
        case .table(let rows): return "[" + rows.map { $0.map { "[" + $0.map(cell).joined(separator: ", \n") + "]" } ?? "nil" }.joined(separator: ", \n") + "]"
        }
    }

    /// `org-babel-js-var-to-js`: lists in brackets, the rest as `prin1` with newlines as `\n`.
    static func jsLiteral(_ value: VarValue) -> String {
        func atom(_ printed: String) -> String { printed.replacingOccurrences(of: "\n", with: "\\n") }
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): n
            case .text(let s): atom(lispString(s))
            }
        }
        switch value {
        case .scalar(let s): return atom(lispString(s))
        case .number(let n): return n
        case .list(let items): return "[" + items.map(cell).joined(separator: ", ") + "]"
        case .table(let rows): return "[" + rows.map { $0.map { "[" + $0.map(cell).joined(separator: ", ") + "]" } ?? "hline" }.joined(separator: ", ") + "]"
        }
    }

    /// `org-babel-R-assign-elisp`: a table or list read from its TSV text, an integer with `L`,
    /// a float or a string as they print. `colnames` are the header row `:colnames` took off,
    /// which ob-R puts back.
    static func rAssignment(_ name: String, _ value: VarValue, colnames: [Cell]?, colnamesYes: Bool, rownamesYes: Bool) -> String {
        // `orgtbl-to-tsv` makes every field a string, which `org-babel-R-quote-tsv-field` quotes.
        func field(_ c: Cell) -> String { "\"" + cellText(c).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows: [[Cell]?]
        switch value {
        case .scalar(let s): return "\(name) <- \(lispString(s))"
        case .number(let n): return "\(name) <- " + (n.contains(where: { ".eE".contains($0) }) ? n : n + "L")
        case .list(let items): rows = items.map { [$0] }
        case .table(let table): rows = table
        }
        if let colnames { rows = [colnames, nil] + rows }
        let lengths = rows.compactMap { $0?.count }
        let tsv = rows.compactMap { $0.map { $0.map(field).joined(separator: "\t") } }.joined(separator: "\n")
        let header = (rows.count > 1 && rows[1] == nil) || colnamesYes ? "TRUE" : "FALSE"
        let rowNames = rownamesYes ? "1" : "NULL"
        let common = """
            \(name) <- local({
                 con <- textConnection(
                   \(lispString(tsv))
                 )
                 res <- utils::read.table(
                   con,
                   header    = \(header),
                   row.names = \(rowNames),
                   sep       = "\\t",
                   as.is     = TRUE
            """
        if lengths.max() == lengths.min() {
            return common + "\n     )\n     close(con)\n     res\n   })"
        }
        return common + ",\n       fill      = TRUE,\n       col.names = paste(\"V\", seq_len(\(lengths.max() ?? 0)), sep =\"\")\n     )\n     close(con)\n     res\n   })"
    }

    /// `org-babel-ruby-wrapper-method` and `org-babel-ruby-pp-wrapper-method`: the body's
    /// value written to the result file.
    static func rubyWrapper(_ body: String, pp: Bool) -> String {
        pp ? """

            require 'pp'
            results = (lambda do
            \(body)
            end).call
            File.open('\(resultFileToken)', 'w') do |f|
              $stdout = f
              pp results
            end

            """ : """

            results = (lambda do
            \(body)
            end).call
            File.open('\(resultFileToken)', 'w'){ |f| f.write((results.class == String) ? results : results.inspect) }

            """
    }

    /// `org-babel-js-function-wrapper`: the body's value printed with `util.inspect`.
    static func jsWrapper(_ body: String) -> String {
        "require('process').stdout.write(require('util').inspect(function(){\(body)\n}()));"
    }

    /// `org-babel-awk-command`'s command line: the program in a file, `:cmd-line`, a `-v` for
    /// each variable, and `:in-file`.
    static func awkCommand(_ vars: [(String, VarValue)], params: Params) -> String {
        var parts = ["awk", "-f", "\"$f\""]
        if let cmdline = params.single[":cmd-line"] { parts.append(cmdline) }
        parts += vars.map { "-v \($0.0)='\(shellString($0.1))'" }
        if let file = params.single[":in-file"] { parts.append(file) }
        return "f=$(mktemp); cat > \"$f\"; " + parts.joined(separator: " ") + " < /dev/null; s=$?; rm -f \"$f\"; exit $s"
    }
}

extension Babel {
    /// `org-babel-js-read`: an array read as a list once its quotes and commas are Lisp's;
    /// otherwise `org-babel-read`, which takes a quoted word as the symbol it names.
    static func jsValue(_ raw: String) -> Value {
        if raw.hasPrefix("["), raw.hasSuffix("]") { return pythonValue(raw, none: "\u{0}") }
        if raw.hasPrefix("'") {
            return .string(String(raw.dropFirst().prefix { !$0.isWhitespace && !"()\"';".contains($0) }))
        }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { return .string(String(raw.dropFirst().dropLast())) }
        return .string(raw)
    }
}
