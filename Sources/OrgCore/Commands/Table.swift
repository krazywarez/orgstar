import Foundation

// Org tables (org-table.el, Org 9.8.7): alignment and the editing commands, with
// `org-table-automatic-realign` t, `org-table-tab-jumps-over-hlines` t, no shrunk columns,
// `org-table-fix-formulas-confirm` nil (formulas are fixed silently).

extension EmacsBuffer {
    static let numberPattern = "^([<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%:]*|[<>]?[-+]?0[xX][0-9a-fA-F.]+|[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+|nan|[-+u]?inf)$"

    /// `org-at-table-p`: an org table line outside blocks.
    var atTable: Bool {
        guard lookingAtLine("^[ \\t]*\\|") else { return false }
        // Dynamic blocks hold elements in Org; their tables count.
        let kind = element(at: lineStart(point))?.kind
        return kind == .table || kind == .tableRow || kind == .dynamicBlock
    }

    var atTableHline: Bool { lookingAtLine("^[ \\t]*\\|-") }

    func lookingAtLine(_ pattern: String) -> Bool {
        saveExcursion {
            beginningOfLine()
            return looking(pattern, caseInsensitive: false, setsMatch: false) != nil
        }
    }

    /// `org-table-begin`.
    func tableBegin() -> Int {
        saveExcursion {
            searchBackward("^[ \\t]*[^| \\t]", caseInsensitive: false).map { _ in lineEnd(point) + 1 } ?? 0
        }
    }

    /// `org-table-end`.
    func tableEnd() -> Int {
        saveExcursion {
            if let match = searchForward("^[ \\t]*[^| \\t]", caseInsensitive: false) { return match[0]!.lowerBound }
            point = length
            skipBackward(Self.blanks)
            return bolp ? point : lineEnd(point)
        }
    }

    /// `org-table-to-lisp`: rows of trimmed fields, nil for rules.
    func tableToLisp() -> [[String]?] {
        saveExcursion {
            point = tableBegin()
            var table: [[String]?] = []
            while true {
                skipForward(Self.blanks)
                guard character(at: point) == 124 else { break }
                point += 1
                if character(at: point) == 45 {
                    table.append(nil)
                } else {
                    var row: [String] = []
                    while true {
                        skipForward(Self.blanks)
                        if eolp { break }
                        let start = point
                        while let c = character(at: point), c != 124, c != 10 { point += 1 }
                        let next = eolp ? point : point + 1
                        skipBackward(Self.blanks, bound: start)
                        row.append(substring(start, point))
                        point = next
                    }
                    table.append(row)
                }
                if forwardLine(1) != 0 { break }
            }
            return table
        }
    }

    /// `org-string-width` of a cell as Emacs shows it.
    func cellWidth(_ cell: String) -> Int {
        VisibleLine(cell, options: options, settings: settings).width
    }

    /// `org-table--align-field`.
    func alignField(_ field: String, width: Int, alignment: Character, fieldWidth: Int) -> String {
        let spaces = width - fieldWidth
        let prefix: Int
        switch alignment {
        case "r": prefix = spaces
        case "c": prefix = spaces / 2
        default: prefix = 0
        }
        return " " + String(repeating: " ", count: prefix) + field + String(repeating: " ", count: spaces - prefix) + " "
    }

    /// `org-table-align`, keeping point in the same field.
    func tableAlign() {
        let begin = tableBegin()
        let end = marker(tableEnd())
        defer { release(end) }
        let line = marker(lineStart(point))
        defer { release(line) }
        let column = tableCurrentColumn()
        point = begin
        let table = tableToLisp()
        let rows = table.compactMap { $0 }
        var widths: [Int] = []
        var alignments: [Character] = []
        var widthCache: [String: Int] = [:]
        func width(_ cell: String) -> Int {
            if let cached = widthCache[cell] { return cached }
            let value = cellWidth(cell)
            widthCache[cell] = value
            return value
        }
        let numberRegex = Self.regex(Self.numberPattern, caseInsensitive: false)
        var columns = 1
        if rows.isEmpty {
            let lineEndOffset = lineEnd(point)
            columns += substring(point, lineEndOffset).filter { $0 == "+" }.count
            widths = Array(repeating: 1, count: columns)
            alignments = Array(repeating: "l", count: columns)
        } else {
            columns = rows.map(\.count).max() ?? 1
            for i in 0..<columns {
                var maxWidth = 1
                var fixed: Character?
                var numbers = 0, nonEmpty = 0
                for row in rows {
                    let cell = i < row.count ? row[i] : ""
                    maxWidth = max(maxWidth, width(cell))
                    if fixed != nil || cell.isEmpty { continue }
                    if let cookie = cell.firstMatch(of: /^<([lrc])[0-9]*>$/) {
                        fixed = cookie.1.first
                    } else {
                        nonEmpty += 1
                        if numberRegex.firstMatch(in: cell, range: NSRange(location: 0, length: (cell as NSString).length)) != nil { numbers += 1 }
                    }
                }
                widths.append(maxWidth)
                alignments.append(fixed ?? (Double(numbers) >= 0.5 * Double(nonEmpty) ? "r" : "l"))
            }
        }
        let rule = widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+")
        let indent = looking("[ \\t]*\\|", setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) } ?? "|"
        for row in table {
            let previous = substring(point, lineEnd(point))
            let new: String
            if let row {
                let fields = row + Array(repeating: "", count: max(0, columns - row.count))
                new = indent + zip(fields, zip(widths, alignments)).map { field, spec in
                    alignField(field, width: spec.0, alignment: spec.1, fieldWidth: width(field))
                }.joined(separator: "|") + "|"
            } else {
                new = indent + rule + "|"
            }
            if new == previous {
                forwardLine(1)
            } else {
                insert(new + "\n")
                deleteRegion(point, min(length, lineEnd(point) + 1))
            }
        }
        point = line.position
        tableGotoColumn(column)
    }

    /// `org-table-current-column`.
    func tableCurrentColumn() -> Int {
        saveExcursion {
            let pos = point
            beginningOfLine()
            let text = substring(point, pos)
            guard let first = text.firstIndex(of: "|") else { return 0 }
            let separators: Set<Character> = atTableHline ? ["+", "|"] : ["|"]
            return 1 + text[text.index(after: first)...].filter { separators.contains($0) }.count
        }
    }

    /// `org-table-goto-column`.
    func tableGotoColumn(_ n: Int, onDelim: Bool = false, force: Bool = false) {
        beginningOfLine()
        guard n > 0 else { return }
        var remaining = n
        while remaining > 0 {
            remaining -= 1
            if let match = searchForward("\\|", bound: lineEnd(point), caseInsensitive: false) {
                _ = match
            } else if force {
                endOfLine()
                skipBackwardNot([124])
                insert(" | ")
            } else {
                break
            }
        }
        if force, looking(".*\\|", caseInsensitive: false, setsMatch: false) == nil {
            saveExcursion {
                endOfLine()
                insert(" | ")
            }
        }
        if onDelim {
            point -= 1
        } else if character(at: point) == 32 {
            point += 1
        }
    }

    /// `skip-chars-backward "^|"`.
    func skipBackwardNot(_ set: Set<unichar>) {
        while point > lineStart(point), let c = character(at: point - 1), !set.contains(c) { point -= 1 }
    }

    /// `org-table-current-dline`.
    func tableCurrentDataLine() -> Int {
        saveExcursion {
            let pos = lineStart(point)
            point = tableBegin()
            var count = 0
            while point <= pos {
                if looking("^[ \\t]*\\|[^-]", caseInsensitive: false, setsMatch: false) != nil { count += 1 }
                if forwardLine(1) != 0 { break }
            }
            return count
        }
    }

    /// `org-table-clean-line`.
    func cleanTableLine(_ line: String) -> String {
        if line.range(of: "^[ \\t]*\\|-", options: .regularExpression) != nil {
            return String(line.map { $0 == "|" || $0 == "+" ? "|" : " " })
        }
        var result = line
        let regex = try! NSRegularExpression(pattern: "\\|([ \\t]*?[^ \\t\\r\\n|][^\\r\\n|]*)\\|")
        while let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: (result as NSString).length)) {
            let cell = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: "|" + String(repeating: " ", count: cellWidth(cell)) + "|")
        }
        return result
    }

    /// `org-table-insert-row`; `below` as with a prefix argument.
    func tableInsertRow(below: Bool) throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        if eobp { saveExcursion { insert("\n") } }
        if substring(lineStart(point), lineEnd(point)).range(of: "\\|[ \\t]*$", options: .regularExpression) == nil { tableAlign() }
        let line = substring(lineStart(point), lineEnd(point))
        var new = cleanTableLine(line)
        if let match = line.range(of: "^[ \\t]*\\| *[#*$] *\\|", options: .regularExpression), let target = new.range(of: "^[ \\t]*\\| *[#*$] *\\|", options: .regularExpression) ?? new.range(of: "^[ \\t]*\\|[^|]*\\|", options: .regularExpression) {
            new.replaceSubrange(target, with: line[match])
        }
        forwardLine(below ? 1 : 0)
        if !bolp { insert("\n") }
        insertBeforeMarkers(new + "\n")
        forwardLine(-1)
        searchForward("\\| ?", bound: lineEnd(point), caseInsensitive: false)
        // `org-table-may-need-update' is set by any edit to a table, so org realigns here.
        tableAlign()
        fixFormulas("@", replace: [:], limit: tableCurrentDataLine() - 1, delta: 1)
    }

    /// `org-table-insert-hline`; `above` as with a prefix argument.
    func tableInsertHline(above: Bool) throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        if eobp { saveExcursion { insert("\n") } }
        if substring(lineStart(point), lineEnd(point)).range(of: "\\|[ \\t]*$", options: .regularExpression) == nil { tableAlign() }
        var line = cleanTableLine(substring(lineStart(point), lineEnd(point)))
        let column = currentColumn
        let regex = try! NSRegularExpression(pattern: "\\|( +)\\|")
        while let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            line = (line as NSString).replacingCharacters(in: match.range, with: "+" + String(repeating: "-", count: match.range(at: 1).length) + "|")
        }
        if let plus = line.firstIndex(of: "+") { line.replaceSubrange(plus...plus, with: "|") }
        forwardLine(above ? 0 : 1)
        insert(line + "\n")
        forwardLine(above ? 0 : -2)
        moveToColumn(column)
    }

    /// What `org-table-maybe-eval-formula` does to point: `org-table-get-field` leaves it one
    /// character into the field.
    func moveIntoField() {
        skipBackwardNot([124, 10])
        if bolp || looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) != nil { return }
        let start = point
        point = min(lineEnd(point), start + 1)
    }

    /// `org-table-next-field`.
    func tableNextField() throws {
        try tableMaybeEvalFormula()
        moveIntoField()
        tableAlign()
        let end = tableEnd()
        if atTableHline { endOfLine() }
        func toNextBar() -> Bool { searchForward("\\|", bound: end, caseInsensitive: false) != nil }
        var ok = toNextBar()
        if ok, looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) != nil { ok = toNextBar() }
        guard ok else {
            try tableInsertRow(below: true)
            return
        }
        if looking("-", caseInsensitive: false, setsMatch: false) != nil, let match = searchForward("^[ \\t]*\\|([^-])", bound: end, caseInsensitive: false) {
            point = match[1]!.lowerBound
        }
        if looking("-", caseInsensitive: false, setsMatch: false) != nil {
            forwardLine(-1)
            try tableInsertRow(below: true)
        } else if character(at: point) == 32 {
            point += 1
        }
    }

    /// `org-table-previous-field`.
    func tablePreviousField() throws {
        tableAlign()
        if atTableHline { endOfLine() }
        let start = tableBegin()
        let origin = point
        func back() -> Bool {
            guard let match = searchBackward("\\|", bound: start, caseInsensitive: false) else { return false }
            point = match[0]!.lowerBound
            return true
        }
        var ok = back() && back()
        while ok, looking("\\|(?:-|[ \\t]*$)", caseInsensitive: false, setsMatch: false) != nil { ok = back() }
        guard ok else {
            point = origin
            throw UserError(message: "Cannot move to previous table field")
        }
        if let bar = looking("\\| ?", caseInsensitive: false, setsMatch: false) { point = bar[0]!.upperBound }
    }

    /// `org-table-next-row`.
    func tableNextRow() throws {
        try tableMaybeEvalFormula()
        moveIntoField()
        tableAlign()
        let column = tableCurrentColumn()
        forwardLine(1)
        if !bolp { insert("\n") }
        if !atTable || atTableHline {
            forwardLine(-1)
            try tableInsertRow(below: true)
        }
        tableGotoColumn(column)
        skipBackwardNot([124, 10, 13])
        if character(at: point) == 32 { point += 1 }
    }

    /// `org-table-move-row`.
    func tableMoveRow(up: Bool) throws {
        let column = currentColumn
        let pos = point
        let hline1 = atTableHline
        let dline1 = tableCurrentDataLine()
        let dline2 = dline1 + (up ? -1 : 1)
        if up, lineStart(point) == 0 { throw UserError(message: "Cannot move row further") }
        forwardLine(up ? -1 : 1)
        if (!up && eobp) || !atTable {
            point = pos
            throw UserError(message: "Cannot move row further")
        }
        let hline2 = atTableHline
        point = pos
        let rowStart = lineStart(point)
        let rowEnd = min(length, lineEnd(point) + 1)
        let row = substring(rowStart, rowEnd)
        deleteRegion(rowStart, rowEnd)
        forwardLine(up ? -1 : 1)
        if !bolp { insert("\n") }
        insert(row)
        if !bolp { insert("\n") }
        forwardLine(-1)
        moveToColumn(column)
        if !hline1, !hline2 {
            fixFormulas("@", replace: [String(dline1): String(dline2), String(dline2): String(dline1)])
        }
    }

    /// `org-table-move-column`.
    func tableMoveColumn(left: Bool) throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        try findDataLine()
        try checkInsideDataField()
        let column = tableCurrentColumn()
        let first = left ? column - 1 : column
        let target = left ? column - 1 : column + 1
        let begin = tableBegin()
        let end = marker(tableEnd())
        defer { release(end) }
        if left, column == 1 { throw UserError(message: "Cannot move column further left") }
        if !left, looking("[^|\\n]*\\|[^|\\n]*$", caseInsensitive: false, setsMatch: false) != nil { throw UserError(message: "Cannot move column further right") }
        let line = marker(lineStart(point))
        point = begin
        while point < end.position {
            if !atTableHline {
                tableGotoColumn(first, onDelim: true)
                if let match = looking("\\|([^|\\n]+)\\|([^|\\n]+)\\|", caseInsensitive: false, setsMatch: false) {
                    let a = substring(match[1]!.lowerBound, match[1]!.upperBound)
                    let b = substring(match[2]!.lowerBound, match[2]!.upperBound)
                    replace(match[1]!.lowerBound..<match[2]!.upperBound, with: b + "|" + a)
                }
            }
            if forwardLine(1) != 0 { break }
        }
        point = line.position
        release(line)
        tableGotoColumn(column)
        tableGotoColumn(target)
        tableAlign()
        fixFormulas("$", replace: [String(column): String(target), String(target): String(column)])
    }

    /// `org-table-insert-column`.
    func tableInsertColumn() throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        if eobp { saveExcursion { insert("\n") } }
        if substring(lineStart(point), lineEnd(point)).range(of: "\\|[ \\t]*$", options: .regularExpression) == nil { tableAlign() }
        try findDataLine()
        let column = max(1, tableCurrentColumn())
        let begin = tableBegin()
        let end = marker(tableEnd())
        defer { release(end) }
        saveExcursion {
            point = begin
            while point < end.position {
                if !atTableHline {
                    tableGotoColumn(column, onDelim: true)
                    insert("|")
                }
                if forwardLine(1) != 0 { break }
            }
        }
        tableGotoColumn(column)
        tableAlign()
        fixFormulas("$", replace: [:], limit: column - 1, delta: 1)
    }

    /// `org-table-delete-column`.
    func tableDeleteColumn() throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        try findDataLine()
        if saveExcursion({ () -> Bool in skipForward(Self.blanks); return eolp }) {
            if let match = searchBackward("\\|", caseInsensitive: false) { point = match[0]!.lowerBound }
        }
        try checkInsideDataField()
        let column = tableCurrentColumn()
        let begin = tableBegin()
        let end = marker(tableEnd())
        defer { release(end) }
        let line = marker(lineStart(point))
        point = begin
        while point < end.position {
            if !atTableHline {
                tableGotoColumn(column, onDelim: true)
                if let match = looking("\\|[^|\\n]+\\|", caseInsensitive: false, setsMatch: false) { replace(match[0]!, with: "|") }
            }
            if forwardLine(1) != 0 { break }
        }
        point = line.position
        release(line)
        tableGotoColumn(column)
        tableAlign()
        fixFormulas("$", replace: [String(column): "INVALID"], limit: column, delta: -1, remove: column)
    }

    /// `org-table-kill-row`.
    func tableKillRow() throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        let column = currentColumn
        let dline = atTableHline ? nil : tableCurrentDataLine()
        deleteRegion(lineStart(point), min(lineEnd(point) + 1, length))
        if !atTable { forwardLine(-1) }
        moveToColumn(column)
        if let dline { fixFormulas("@", replace: [String(dline): "INVALID"], limit: dline, delta: -1, remove: dline) }
    }

    /// `org-table-find-dataline`.
    func findDataLine() throws {
        guard atTableHline else { return }
        let column = currentColumn
        let end = tableEnd()
        forwardLine(1)
        while point < end, atTableHline { forwardLine(1) }
        if point >= end { throw UserError(message: "Cannot find data row for column operation") }
        moveToColumn(column)
    }

    /// `org-table-check-inside-data-field`.
    func checkInsideDataField() throws {
        let atLineStart = saveExcursion { () -> Bool in skipBackward(Self.blanks); return bolp }
        if atLineStart || atTableHline || looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) != nil {
            throw UserError(message: "Not in table data field")
        }
    }

    /// `org-table-fix-formulas`.
    func fixFormulas(_ key: String, replace replacements: [String: String], limit: Int? = nil, delta: Int = 0, remove: Int? = nil) {
        saveExcursion {
            point = tableEnd()
            while looking("[ \\t]*#\\+tblfm:", setsMatch: false) != nil {
                if let remove {
                    let pattern = key == "$" ? "(@[0-9]+)?\\$\(remove)=.*?(::|$)" : "@\(remove)\\$[0-9]+=.*?(::|$)"
                    saveExcursion {
                        while let match = searchForward(pattern, bound: lineEnd(point), caseInsensitive: false) {
                            replace(match[0]!, with: "")
                            point = match[0]!.lowerBound
                        }
                    }
                }
                let lineStartOffset = point
                let pattern = NSRegularExpression.escapedPattern(for: key) + "([0-9]+)"
                while let match = searchForward(pattern, bound: lineEnd(point), caseInsensitive: false) {
                    let number = substring(match[1]!.lowerBound, match[1]!.upperBound)
                    if let new = replacements[number] {
                        replace(match[0]!, with: key + new)
                    } else if let limit, let n = Int(number), n > limit {
                        replace(match[0]!, with: key + String(n + delta))
                    }
                }
                _ = lineStartOffset
                if forwardLine(1) != 0 { break }
            }
        }
    }

    /// `org-table-create` with a size like `3x2`.
    func tableCreate(_ size: String) throws {
        let parts = size.split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]) else { throw UserError(message: "Size must be like 5x2") }
        let pos = point
        let indent = String(repeating: " ", count: currentColumn)
        let line = indent + "|" + String(repeating: "  |", count: columns) + "\n"
        if substring(lineStart(point), point).allSatisfy({ $0 == " " || $0 == "\t" }) {
            beginningOfLine()
        } else {
            insert("\n")
        }
        for _ in 0..<rows { insert(line) }
        point = pos
        if rows > 1 {
            endOfLine()
            insert("\n|-")
            point = pos
        }
        tableAlign()
    }
}


private func tableCommand(_ context: EditContext, _ body: (EmacsBuffer) throws -> Void) -> CommandStep {
    commitBuffer(context, body)
}

/// A table command that needs the caret in an org table.
public struct TableCommand: OrgCommand {
    public enum Action: String, Sendable, CaseIterable {
        case align, nextField, previousField, nextRow, moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
        case insertColumn, deleteColumn, killRow, insertRowAbove, insertHline
    }

    public let action: Action
    public init(_ action: Action) { self.action = action }

    public var id: String {
        switch action {
        case .align: "org.table.align"
        case .nextField: "org.table.next-field"
        case .previousField: "org.table.previous-field"
        case .nextRow: "org.table.next-row"
        case .moveRowUp: "org.table.row-up"
        case .moveRowDown: "org.table.row-down"
        case .moveColumnLeft: "org.table.column-left"
        case .moveColumnRight: "org.table.column-right"
        case .insertColumn: "org.table.insert-column"
        case .deleteColumn: "org.table.delete-column"
        case .killRow: "org.table.kill-row"
        case .insertRowAbove: "org.table.insert-row"
        case .insertHline: "org.table.insert-hline"
        }
    }

    public var title: String {
        switch action {
        case .align: "Align Table"
        case .nextField: "Next Table Field"
        case .previousField: "Previous Table Field"
        case .nextRow: "Next Table Row"
        case .moveRowUp: "Move Table Row Up"
        case .moveRowDown: "Move Table Row Down"
        case .moveColumnLeft: "Move Table Column Left"
        case .moveColumnRight: "Move Table Column Right"
        case .insertColumn: "Insert Table Column"
        case .deleteColumn: "Delete Table Column"
        case .killRow: "Delete Table Row"
        case .insertRowAbove: "Insert Table Row"
        case .insertHline: "Insert Table Rule"
        }
    }

    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }

    public func run(in context: EditContext) -> CommandStep {
        tableCommand(context) { buffer in
            guard buffer.atTable else { throw EmacsBuffer.UserError(message: "Not at a table") }
            switch action {
            case .align: buffer.tableAlign()
            case .nextField: try buffer.tableNextField()
            case .previousField: try buffer.tablePreviousField()
            case .nextRow: try buffer.tableNextRow()
            case .moveRowUp: try buffer.tableMoveRow(up: true)
            case .moveRowDown: try buffer.tableMoveRow(up: false)
            case .moveColumnLeft: try buffer.tableMoveColumn(left: true)
            case .moveColumnRight: try buffer.tableMoveColumn(left: false)
            case .insertColumn: try buffer.tableInsertColumn()
            case .deleteColumn: try buffer.tableDeleteColumn()
            case .killRow: try buffer.tableKillRow()
            case .insertRowAbove: try buffer.tableInsertRow(below: false)
            case .insertHline: try buffer.tableInsertHline(above: false)
            }
        }
    }
}

/// C-c |: `org-table-create` with a size prompt.
public struct CreateTable: OrgCommand {
    public init() {}
    public var id: String { "org.table.create" }
    public var title: String { "Create Table" }
    public func applies(in context: EditContext) -> Bool { !KeyContext.holds("table", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        if let converted = convert(context) { return converted }
        guard let size = context.answers["size"] else {
            return .prompt(Prompt(key: "size", message: "Table size Columns x Rows [e.g. 5x2]:", initial: ""))
        }
        return tableCommand(context) { try $0.tableCreate(size.isEmpty ? "5x2" : size) }
    }

    /// `org-table-create-or-convert-from-region`.
    private func convert(_ context: EditContext) -> CommandStep? {
        guard let region = context.selection.first, !region.isEmpty else { return nil }
        return commitBuffer(context) { $0.tableConvertRegion(region.lowerBound, region.upperBound) }
    }
}
