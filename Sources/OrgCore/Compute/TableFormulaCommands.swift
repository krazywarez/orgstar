import Foundation

/// C-c * and C-u C-c *: `org-table-recalculate`, and C-c C-c on a `#+TBLFM` line. Tables the
/// native evaluator can't do fail with `TableRecalculate.emacsMessage`, and the app
/// recalculates them in Emacs.
public struct TableRecalculate: OrgCommand {
    public let all: Bool
    public init(all: Bool) { self.all = all }
    public var id: String { all ? "org.table.recalc-all" : "org.table.recalc" }
    public var title: String { all ? "Recalculate Table" : "Recalculate Table Row" }

    public static let emacsMessage = "needs Emacs: "

    public func applies(in context: EditContext) -> Bool {
        KeyContext.holds("table", in: context) || Self.tblfmLine(in: context) != nil
    }

    static func tblfmLine(in context: EditContext) -> String? {
        let buffer = EmacsBuffer(context.text, point: context.caret)
        let line = buffer.substring(buffer.lineStart(buffer.point), buffer.lineEnd(buffer.point))
        guard line.range(of: EmacsBuffer.tblfmPattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return line
    }

    public func run(in context: EditContext) -> CommandStep {
        let step = commitBuffer(context) { buffer in
            do {
                if let line = Self.tblfmLine(in: context) {
                    // `org-table-calc-current-TBLFM`: that line's formulas, every row, with
                    // point at the end of the table.
                    let formulas = String(line[line.index(after: line.firstIndex(of: ":")!)...]).trimmingCharacters(in: .init(charactersIn: " "))
                    let saved = buffer.marker(buffer.point)
                    defer { buffer.release(saved) }
                    guard let tableEnd = buffer.saveExcursion({ () -> Int? in
                        while buffer.forwardLine(-1) == 0 {
                            if buffer.lookingAtLine("^[ \\t]*\\|") { return buffer.lineEnd(buffer.point) }
                        }
                        return nil
                    }) else { throw EmacsBuffer.UserError(message: "Not at a table") }
                    buffer.point = tableEnd
                    try buffer.tableRecalculate(all: true, tblfm: formulas)
                    buffer.point = saved.position
                } else {
                    try buffer.tableRecalculate(all: all)
                }
            } catch let error as Calc.Unsupported {
                throw EmacsBuffer.UserError(message: Self.emacsMessage + error.reason)
            }
        }
        let form = Self.tblfmLine(in: context) != nil ? "(org-table-calc-current-TBLFM)" : all ? "(org-table-recalculate t)" : "(org-table-recalculate nil)"
        return Self.inEmacs(step, form: form, in: context)
    }

    /// A step that failed with `emacsMessage` as a request to run `form` on the table in
    /// Emacs, whose text then replaces the table here; other steps unchanged.
    static func inEmacs(_ step: CommandStep, form: String, in context: EditContext) -> CommandStep {
        guard case .failed(let message) = step, message.hasPrefix(emacsMessage) else { return step }
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        let onTblfm = tblfmLine(in: context) != nil
        if onTblfm {
            while buffer.forwardLine(-1) == 0, !buffer.lookingAtLine("^[ \\t]*\\|") {}
        }
        let table = buffer.tableBegin()..<buffer.tableEnd()
        let tblfm = onTblfm ? tblfmLine(in: context) ?? "" : buffer.firstTblfm(after: table.upperBound) ?? ""
        return .external(.emacsTable(
            table: table, point: context.caret, form: form,
            reason: String(message.dropFirst(emacsMessage.count)), lisp: tblfm.contains("'(")
        ))
    }
}

/// C-u C-u C-c *: `org-table-iterate`, the whole table recalculated until it stops changing,
/// at most ten times.
public struct TableIterate: OrgCommand {
    public init() {}
    public var id: String { "org.table.iterate" }
    public var title: String { "Iterate Table Formulas" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }

    public func run(in context: EditContext) -> CommandStep {
        var message = ""
        var step = commitBuffer(context) { buffer in
            guard buffer.atTable else { throw EmacsBuffer.UserError(message: "Not at a table") }
            func table() -> String { buffer.substring(buffer.tableBegin(), buffer.tableEnd()) }
            var last = table()
            do {
                for iteration in 1...10 {
                    try buffer.tableRecalculate(all: true)
                    let this = table()
                    if this == last {
                        message = iteration > 1 ? "Convergence after \(iteration) iterations" : "Table was already stable"
                        return
                    }
                    last = this
                }
            } catch let error as Calc.Unsupported {
                throw EmacsBuffer.UserError(message: TableRecalculate.emacsMessage + error.reason)
            }
            // The recalculations stay, as Emacs leaves them before its error.
            message = "No convergence after 10 iterations"
        }
        if case .commit(let result) = step {
            step = .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection, effects: result.effects + [.message(message)]))
        }
        return TableRecalculate.inEmacs(step, form: "(org-table-iterate)", in: context)
    }
}

// Formulas typed in a field (`org-table-maybe-eval-formula`) and C-c = (`org-table-eval-formula`).
extension EmacsBuffer {
    /// `org-table-maybe-recalculate-line`: a row whose first field is `#` recalculated, as
    /// TAB, S-TAB and RET in a table do first.
    func tableMaybeRecalculateLine() throws {
        guard lookingAtLine("^[ \\t]*\\| *# *(\\||$)") else { return }
        try tableRecalculate(all: false)
    }

    /// `org-table-formula-make-cmp-string`.
    static func formulaSortKey(_ lhs: String, analysis: TableAnalysis) -> String? {
        var a = lhs
        if let arrow = a.firstMatch(of: /^\$([<>])/) {
            a = (try? handleFirstLast(a, analysis: analysis)) ?? a
            a = "$\(10000 + (arrow.1 == "<" ? -1000 : 0) + Int(stringToNumber(String(a.dropFirst()))))"
        }
        guard let m = a.firstMatch(of: /^(@([0-9]+))?(\$?([0-9]+))?(\$?[a-zA-Z0-9]+)?/) else { return nil }
        var key = ""
        if let row = m.2 { key += String(format: "@%05d", Int(row) ?? 0) }
        if let column = m.4 { key += String(format: "$%05d", Int(column) ?? 0) }
        if let name = m.5 { key += "@@" + name }
        return key
    }

    /// `sort` with `org-table-formula-less-p`.
    static func sortFormulas(_ formulas: [(lhs: String, rhs: String)], analysis: TableAnalysis) -> [(lhs: String, rhs: String)] {
        var sorted: [(formula: (lhs: String, rhs: String), key: String?)] = []
        // Stable insertion, as `sort` with a partial predicate.
        for formula in formulas {
            let key = formulaSortKey(formula.lhs, analysis: analysis)
            var index = sorted.count
            while index > 0, let a = key, let b = sorted[index - 1].key, a < b { index -= 1 }
            sorted.insert((formula, key), at: index)
        }
        return sorted.map(\.formula)
    }

    /// `org-table-store-formulas`, sorted by `org-table-formula-less-p`.
    func tableStoreFormulas(_ formulas: [(lhs: String, rhs: String)], analysis: TableAnalysis) {
        let sorted = Self.sortFormulas(formulas, analysis: analysis)
        saveExcursion {
            point = tableEnd()
            if let match = looking("([ \\t]*\\n)*[ \\t]*(#\\+TBLFM:)(.*\\n?)", caseInsensitive: true, setsMatch: false) {
                deleteRegion(match[3]!.lowerBound, match[0]!.upperBound)
                point = match[3]!.lowerBound
            } else {
                insert("#+TBLFM:")
            }
            insert(" " + sorted.map { $0.lhs + "=" + $0.rhs }.joined(separator: "::") + "\n")
        }
    }

    /// `org-table-get-formula`: stores EQUATION for the current column, or with `named` the
    /// current field, and returns it; nil when a blank EQUATION removed the formula. `read`
    /// when EQUATION is the prompt's answer, which the stored formula never replaces.
    func tableGetFormula(_ equation: String, named: Bool, read: Bool = false, analysis: TableAnalysis) throws -> String? {
        var stored = try Self.storedFormulas(firstTblfm(after: tableEnd()) ?? "")
        let ref = "@\(tableCurrentDataLine())$\(tableCurrentColumn())"
        let scol = named ? ref : "$\(tableCurrentColumn())"
        let old = stored.first { $0.lhs == scol }?.rhs
        var eq = !read && old != nil && equation.range(of: "^ *=? *$", options: .regularExpression) != nil ? old! : equation
        guard eq.contains(where: { !$0.isWhitespace }) else {
            stored.removeAll { $0.lhs == scol }
            tableStoreFormulas(stored, analysis: analysis)
            // Org's user error, which keeps the stored formulas and stops the command.
            message = "Formula removed"
            return nil
        }
        eq = eq.replacingOccurrences(of: "^ *=?", with: "", options: .regularExpression)
        eq = eq.replacingOccurrences(of: " *$", with: "", options: .regularExpression)
        var mustSave = false
        if !named, let index = stored.firstIndex(where: { $0.lhs == ref }) {
            stored.remove(at: index)
            mustSave = true
        }
        if let index = stored.firstIndex(where: { $0.lhs == scol }) {
            stored[index].rhs = eq
        } else {
            stored.insert((scol, eq), at: 0)
        }
        if mustSave || old != eq { tableStoreFormulas(stored, analysis: analysis) }
        return eq
    }

    /// `org-table-eval-formula` for the current field with EQUATION, which is stored first.
    /// A formula only Emacs can evaluate stays stored, the field unchanged.
    func tableEvalFormula(equation: String, named: Bool, read: Bool = false) throws {
        try checkInsideDataField()
        let analysis = try tableAnalyze()
        guard let formula = try tableGetFormula(equation, named: named, read: read, analysis: analysis) else { return }
        do {
            try tableEvalFormula(formula, analysis: analysis, substituted: false)
        } catch let error as Calc.Unsupported {
            message = "The formula was stored; recalculating it needs Emacs: " + error.reason
        }
        tableAlign()
    }

    /// `org-table-maybe-eval-formula`.
    func tableMaybeEvalFormula() throws {
        skipBackwardNot([124, 10])
        guard !bolp, looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) == nil else { return }
        let start = point
        var end = point
        while let c = character(at: end), c != 124, c != 10, c != 13 { end += 1 }
        point = min(lineEnd(point), start + 1)
        let field = substring(start, end).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
        guard let m = field.firstMatch(of: /^:?=(.*[^=])$/) else { return }
        try tableEvalFormula(equation: String(m.1), named: field.hasPrefix(":"))
    }
}

/// C-c = and C-u C-c =: `org-table-eval-formula`, asking for the column's or the field's
/// formula, the stored one offered.
public struct TableEvalFormula: OrgCommand {
    let named: Bool
    public init(named: Bool) { self.named = named }
    public var id: String { named ? "org.table.field-formula" : "org.table.column-formula" }
    public var title: String { named ? "Set Field Formula" : "Set Column Formula" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        guard let answer = context.answers["formula"] else {
            let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
            guard buffer.atTable else { return .failed("Not at a table") }
            let column = buffer.tableCurrentColumn()
            let scol = named ? "@\(buffer.tableCurrentDataLine())$\(column)" : "$\(column)"
            let stored = (try? EmacsBuffer.storedFormulas(buffer.firstTblfm(after: buffer.tableEnd()) ?? ""))?.first { $0.lhs == scol }?.rhs
            return .prompt(Prompt(key: "formula", message: "\(named ? "Field" : "Column") formula \(scol)=", initial: stored ?? ""))
        }
        return commitBuffer(context) { try $0.tableEvalFormula(equation: answer, named: named, read: true) }
    }
}

// The formula editor (`org-table-edit-formulas`, C-c ' in a table), in the block editor.
extension BlockEdit {
    static let formulasKind = "formulas"

    /// The formulas of the table at `offset`, or of the `#+TBLFM` line there, one per line as
    /// org's editor lists them. The range runs from the table (or that line) to the formulas.
    public static func formulas(at offset: Int, text: String) -> BlockEdit? {
        let buffer = EmacsBuffer(text, point: offset)
        let line = buffer.substring(buffer.lineStart(offset), buffer.lineEnd(offset))
        let atTblfm = line.range(of: EmacsBuffer.tblfmPattern, options: [.regularExpression, .caseInsensitive]) != nil
        guard atTblfm || buffer.atTable else { return nil }
        let start: Int
        let end: Int
        let formulas: [(lhs: String, rhs: String)]
        if atTblfm {
            start = buffer.lineStart(offset)
            end = min(buffer.length, buffer.lineEnd(offset) + 1)
            let tblfm = String(line[line.range(of: ":")!.upperBound...]).trimmingCharacters(in: .init(charactersIn: " "))
            formulas = (try? EmacsBuffer.storedFormulas(tblfm)) ?? []
            guard buffer.searchBackward("^[ \\t]*\\|", caseInsensitive: false) != nil else { return nil }
        } else {
            start = buffer.tableBegin()
            let tableEnd = buffer.tableEnd()
            end = buffer.saveExcursion {
                buffer.point = tableEnd
                return buffer.looking("([ \\t]*\\n)*[ \\t]*#\\+TBLFM:.*\\n?", caseInsensitive: true, setsMatch: false)?[0]?.upperBound ?? tableEnd
            }
            formulas = (try? EmacsBuffer.storedFormulas(buffer.firstTblfm(after: tableEnd) ?? "")) ?? []
        }
        guard let analysis = try? buffer.tableAnalyze() else { return nil }
        var content = ""
        var titles: [(type: String, title: String)] = [("column", "# Column Formulas\n"), ("field", "# Field and Range Formulas\n"), ("named", "# Named Field Formulas\n")]
        for (lhs, rhs) in EmacsBuffer.sortFormulas(formulas, analysis: analysis) {
            let type = lhs.range(of: "^\\$([0-9]+|[<>]+)$", options: .regularExpression) != nil ? "column" : lhs.hasPrefix("@") ? "field" : "named"
            if let index = titles.firstIndex(where: { $0.type == type }) {
                if !content.isEmpty { content += "\n" }
                content += titles[index].title
                titles.remove(at: index)
            }
            content += (lhs.hasPrefix("@") || lhs.hasPrefix("$") ? "" : "$") + lhs + " = " + rhs + "\n"
        }
        let ns = text as NSString
        return BlockEdit(range: start..<end, original: ns.substring(with: NSRange(location: start, length: end - start)), content: content, language: nil, kind: formulasKind)
    }

    /// `org-table-fedit-finish`'s reading of the editor's text.
    static func parseFormulas(_ content: String) throws -> [(lhs: String, rhs: String)] {
        let regex = try! NSRegularExpression(pattern: "^(@[-+I<>0-9.$@]+|@?[0-9]+|\\$([a-zA-Z0-9]+|[<>]+)) *= *(.*(\\n[ \\t]+.*$)*)", options: .anchorsMatchLines)
        let ns = content as NSString
        var result: [(lhs: String, rhs: String)] = []
        for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let lhs = ns.substring(with: m.range(at: 1))
            var rhs = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
            guard !rhs.isEmpty else { continue }
            rhs = rhs.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: " ", options: .regularExpression)
            if result.contains(where: { $0.lhs == lhs }) { throw EmacsBuffer.UserError(message: "Double formulas for \(lhs)") }
            result.insert((lhs, rhs), at: 0)
        }
        return result
    }

    /// Installs edited formulas, as `org-table-fedit-finish` without a prefix argument.
    func installFormulas(_ content: String, in context: EditContext) -> CommandStep {
        let step = commitBuffer(context) { buffer in
            let formulas = try Self.parseFormulas(content)
            buffer.point = range.lowerBound
            let analysis = try buffer.saveExcursion { () throws -> EmacsBuffer.TableAnalysis in
                if !buffer.atTable { _ = buffer.searchBackward("^[ \\t]*\\|", caseInsensitive: false) }
                return try buffer.tableAnalyze()
            }
            buffer.tableStoreFormulas(formulas, analysis: analysis)
        }
        guard case .commit(let result) = step else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection,
                                  effects: result.effects + [.message("New formulas installed - Recalculate Table (C-c C-c on the #+TBLFM line) applies them.")]))
    }
}

// `org-table-edit-field` (C-c `): a field's text edited apart, then put back.
extension BlockEdit {
    static let fieldKind = "field"

    /// The data field at `offset`, trimmed. The range is its line, to check it's unchanged.
    public static func field(at offset: Int, text: String) -> BlockEdit? {
        let buffer = EmacsBuffer(text, point: offset)
        guard buffer.insideDataField else { return nil }
        let coordinate = "@\(buffer.tableCurrentDataLine())$\(buffer.tableCurrentColumn())"
        let field = buffer.saveExcursion { () -> String in
            buffer.skipBackwardNot([124, 10])
            return buffer.substring(buffer.point, buffer.looking("[^|\\r\\n]*", caseInsensitive: false, setsMatch: false)![0]!.upperBound)
        }
        let start = buffer.lineStart(offset)
        let end = buffer.lineEnd(offset)
        return BlockEdit(range: start..<end, original: buffer.substring(start, end), content: field.trimmingCharacters(in: .whitespacesAndNewlines),
                         language: nil, kind: fieldKind, point: offset, coordinate: coordinate)
    }

    /// `org-table-finish-edit-field`: comment lines go, line breaks become spaces, and the
    /// table is aligned.
    func installField(_ content: String, in context: EditContext) -> CommandStep {
        var text = content.replacingOccurrences(of: "(?m)^#.*\n?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \t]*\n[ \t\n]*", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return commitBuffer(context) { buffer in
            buffer.point = point ?? range.lowerBound
            guard buffer.insideDataField else { throw EmacsBuffer.UserError(message: "Not in table data field") }
            buffer.skipBackwardNot([124, 10])
            let end = buffer.looking("[^|\\r\\n]*", caseInsensitive: false, setsMatch: false)![0]!.upperBound
            buffer.replaceRange(buffer.point, end, with: text.isEmpty ? " " : text)
            buffer.point = min(buffer.lineEnd(buffer.point), buffer.point + 1)
            buffer.tableAlign()
        }
    }
}

extension EmacsBuffer {
    /// `org-table-check-inside-data-field` with NOERROR.
    var insideDataField: Bool {
        atTable && !atTableHline
            && !saveExcursion { () -> Bool in
                while let c = character(at: point - 1), c == 32 || c == 9 { point -= 1 }
                return bolp
            }
            && looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) == nil
    }
}

/// C-c `: `org-table-edit-field`, in the block editor.
public struct TableEditField: OrgCommand {
    public init() {}
    public var id: String { "org.table.edit-field" }
    public var title: String { "Edit Table Field" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        guard let edit = BlockEdit.field(at: context.caret, text: context.text) else {
            return .failed(EmacsBuffer(context.text, point: context.caret).atTable ? "Not in table data field" : "Not at a table")
        }
        return .external(.editBlock(edit))
    }
}
