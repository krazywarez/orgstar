import Foundation

// Whole-table changes (org-table.el, Org 9.8.7): `org-table-sort-lines`,
// `org-table-transpose-table-at-point`, `org-table-convert-region`, `org-table-import`'s
// insertion and `org-table-export`'s TSV and CSV.

extension EmacsBuffer {
    /// `org-table-sort-lines` on the lines between the hlines around point. `kind` is one of
    /// `aAnNtT`.
    func tableSortLines(_ kind: Character, column requested: Int? = nil) throws {
        try saveExcursion {
            skipBackward([32, 9])
            if bolp { _ = searchForward("\\|", bound: lineEnd(point), caseInsensitive: false) }
            try checkInsideDataField()
        }
        let current = tableCurrentColumn()
        let column = current > 0 ? current : requested ?? 1
        guard "aAnNtT".contains(kind) else { throw UserError(message: "Invalid sorting type `\(kind)'") }
        let start = tableBegin()
        let end = tableEnd()
        let hline = "^[ \\t]*\\|-"
        let low = saveExcursion { () -> Int in
            guard searchBackward(hline, bound: start, caseInsensitive: false) != nil else { return start }
            forwardLine(1)
            return point
        }
        let high = saveExcursion { searchForward(hline, bound: end, caseInsensitive: false)?[0]?.lowerBound ?? end }
        let lineOffset = countLines(low, lineStart(point))
        let column0 = currentColumn
        // Records: each data line, without its newline.
        var records: [Range<Int>] = []
        point = low
        while point < high {
            if lookingAt("[ \\t]*\\|[^-]") != nil { records.append(point..<lineEnd(point)) }
            if forwardLine(1) != 0 { break }
        }
        let keys = records.map { record -> SortEntries.SortKey in
            let field = saveExcursion { () -> String in
                point = record.lowerBound
                let line = substring(record.lowerBound, record.upperBound).trimmingCharacters(in: .whitespaces)
                let fields = Self.splitFields(line, separator: " *\\| *")
                return column <= fields.count ? fields[column - 1] : ""
            }.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
            switch kind.lowercased() {
            case "n": return .number(Self.stringToNumber(field))
            case "a": return .text(SortEntries.removeInvisible(field).lowercased())
            default: return .number(Self.timeKey(field, now: now, calendar: calendar))
            }
        }
        let reverse = kind.isUppercase
        var order = Array(records.indices)
        if reverse { order.reverse() }
        order = order.enumerated().sorted { a, b in
            let less = keys[a.element] < keys[b.element]
            let greater = keys[b.element] < keys[a.element]
            return less != greater ? less : a.offset < b.offset
        }.map(\.element)
        if reverse { order.reverse() }
        let texts = records.map { substring($0.lowerBound, $0.upperBound) }
        for (record, source) in zip(records, order).reversed() {
            replace(record, with: texts[source])
        }
        point = low
        forwardLine(lineOffset)
        moveToColumn(column0)
    }

    /// The `t` sort key: a timestamp's time, else a duration's minutes, else 0.
    static func timeKey(_ field: String, now: Date, calendar: Calendar) -> Double {
        if let stamp = field.firstMatch(of: /[\[<][0-9]{4}-[0-9]{2}-[0-9]{2}[^\]>\n]*[\]>]/) {
            return TagsMatcher.seconds(String(stamp.0), now: now, calendar: calendar)
        }
        if let minutes = durationMinutes(field.trimmingCharacters(in: .whitespaces)) { return minutes }
        if let clock = field.firstMatch(of: /\b([0-9]+):([0-9]{2})\b/) { return Double(clock.1)! * 60 + Double(clock.2)! }
        return 0
    }

    /// `org-duration-to-minutes` for strings `org-duration-p` accepts.
    static func durationMinutes(_ s: String) -> Double? {
        if let m = s.wholeMatch(of: /([0-9]+):([0-9]{2})(?::([0-9]{2}))?/) {
            return Double(m.1)! * 60 + Double(m.2)! + (m.3.map { Double($0)! / 60 } ?? 0)
        }
        let units: [String: Double] = ["min": 1, "h": 60, "d": 1440, "w": 10080, "m": 43200, "y": 525960]
        let parts = s.split(separator: " ")
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for part in parts {
            guard let m = part.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)(min|h|d|w|m|y)/) else { return nil }
            total += Double(m.1)! * units[String(m.2)]!
        }
        return total
    }

    /// `org-table-current-line`: the index of the data line at point, from 1.
    func tableCurrentLine() -> Int {
        let position = point
        let end = tableEnd()
        return saveExcursion {
            point = tableBegin()
            var count = 0
            while let match = searchForward("^[ \\t]*\\|[^-]", bound: end, caseInsensitive: false) {
                count += 1
                point = match[0]!.upperBound
                if lineEnd(point) >= position { break }
            }
            return count
        }
    }

    /// `org-table-goto-line`.
    func tableGotoLine(_ n: Int) {
        let end = tableEnd()
        point = tableBegin()
        var count = 0
        while count < n, let match = searchForward("^[ \\t]*\\|[^-]", bound: end, caseInsensitive: false) {
            count += 1
            point = count == n ? match[0]!.lowerBound : match[0]!.upperBound
        }
    }

    /// `org-table-transpose-table-at-point`.
    func tableTranspose() {
        let table = tableToLisp().compactMap { $0 }
        let dline = tableCurrentLine()
        let column = tableCurrentColumn()
        let width = table.first?.count ?? 0
        let contents = (0..<width).map { c in table.map { c < $0.count ? $0[c] : "" } }
        point = tableBegin()
        _ = searchForward("\\|", caseInsensitive: false)
        point -= 1
        deleteRegion(point, tableEnd())
        insert(contents.map { "| " + $0.joined(separator: " | ") + "  |\n" }.joined())
        tableGotoLine(column)
        tableGotoColumn(dline)
        tableAlign()
    }

    /// `org-table-convert-region` with the separator guessed: tabs when every line has one,
    /// commas (CSV) when every line has one, else runs of spaces.
    func tableConvertRegion(_ start: Int, _ end: Int) {
        point = min(start, end)
        point = lineStart(point)
        let begin = marker(point)
        point = max(start, end)
        if bolp, point > 0 { point -= 1 } else { endOfLine() }
        let stop = marker(point)
        defer {
            release(begin)
            release(stop)
        }
        point = begin.position
        let tabs = saveExcursion { searchForward("^[^\\n\\t]+$", bound: stop.position, caseInsensitive: false) == nil }
        let commas = saveExcursion { searchForward("^[^\\n,]+$", bound: stop.position, caseInsensitive: false) == nil }
        if !tabs, commas {
            while point < stop.position {
                if bolp {
                    insert("| ")
                } else if let m = lookingAt("[ \\t]*$") {
                    replace(m[0]!, with: " |")
                    point = m[0]!.lowerBound + 2
                    forwardLine(1)
                } else if let m = lookingAt("[ \\t]*\"([^\"]*)\"") {
                    let value = substring(m[1]!.lowerBound, m[1]!.upperBound).replacingOccurrences(of: "\n", with: " ")
                    replace(m[0]!, with: value)
                    point = m[0]!.lowerBound + value.utf16.count
                    if character(at: point) == 34 { insert("\"") }
                } else if let m = lookingAt("[^,\\n]+") {
                    point = m[0]!.upperBound
                } else if let m = lookingAt("[ \\t]*,") {
                    replace(m[0]!, with: " | ")
                    point = m[0]!.lowerBound + 3
                } else {
                    forwardLine(1)
                }
            }
        } else {
            let pattern = tabs ? "^|\\t" : "^ *| *\\t *| {1,}"
            while point < stop.position, let m = searchForward(pattern, bound: stop.position, caseInsensitive: false) {
                replace(m[0]!, with: "| ")
                point = m[0]!.lowerBound + 2
            }
        }
        point = begin.position
        tableAlign()
    }

    /// `orgtbl-to-tsv` and `orgtbl-to-csv` of the table at point, rules left out.
    func tableExportText(csv: Bool) -> String {
        tableToLisp().compactMap { $0 }.map { row in
            row.map { field in
                guard csv, field.contains(where: { $0 == "\"" || $0 == "," }) else { return field }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: csv ? "," : "\t")
        }.joined(separator: "\n")
    }
}

/// C-c ^ in a table: `org-table-sort-lines`.
public struct SortTableLines: OrgCommand {
    public init() {}
    public var id: String { "org.table.sort" }
    public var title: String { "Sort Table Lines" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }

    static let selection = FastSelection(items: [
        .option(key: "a", name: "alphabetic"), .option(key: "n", name: "numeric"), .option(key: "t", name: "time"), .newline,
        .option(key: "A", name: "alphabetic (reversed)"), .option(key: "N", name: "numeric (reversed)"), .option(key: "T", name: "time (reversed)"),
    ], multiple: false)

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret)
        if buffer.tableCurrentColumn() == 0, context.answers["column"] == nil {
            return .prompt(Prompt(key: "column", message: "Use column N for sorting:"))
        }
        guard let key = context.answers["sort"]?.first else {
            return .prompt(Prompt(key: "sort", message: "Sort Table: [a]lphabetic, [n]umeric, [t]ime.  A/N/T means reversed:", fast: Self.selection))
        }
        let column = context.answers["column"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return commitBuffer(context) { try $0.tableSortLines(key, column: column) }
    }
}

/// `org-table-transpose-table-at-point`.
public struct TransposeTable: OrgCommand {
    public init() {}
    public var id: String { "org.table.transpose" }
    public var title: String { "Transpose Table" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("table", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            guard buffer.atTable else { throw EmacsBuffer.UserError(message: "Not at a table") }
            buffer.tableTranspose()
        }
    }
}

/// `org-table-import` with a file's text: inserted at point, then made a table.
public struct ImportTable: OrgCommand {
    let contents: String
    public init(contents: String) { self.contents = contents }
    public var id: String { "internal.table.import" }
    public var title: String { "Import Table" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            if !buffer.bolp { buffer.insert("\n") }
            let start = buffer.point
            buffer.insert(contents)
            buffer.tableConvertRegion(start, buffer.point)
        }
    }

    /// `org-table-export`'s text for the table at `offset`: CSV for a `.csv` file, else TSV.
    public static func exportText(_ text: String, at offset: Int, path: String) -> String? {
        let buffer = EmacsBuffer(text, point: offset)
        guard buffer.atTable else { return nil }
        buffer.tableAlign()
        return buffer.tableExportText(csv: path.lowercased().hasSuffix(".csv")) + "\n"
    }
}
