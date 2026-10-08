import Foundation

// Table formulas (org-table.el, Org 9.8.7): `org-table-recalculate` and
// `org-table-eval-formula` with Calc and Lisp evaluated natively. Symbolic results, Calc
// features beyond `Calc`, Lisp beyond `Elisp`, remote tables found by ID and relative field
// targets throw `Calc.Unsupported`; the caller then recalculates the table in Emacs.

/// Where `remote()` finds tables by ID in other files.
public enum RemoteTables {
    /// The text of the file holding the entry with an ID; the app sets it, from its index.
    nonisolated(unsafe) public static var fileWithID: ((String) -> String?)?
}

extension EmacsBuffer {
    struct TableAnalysis {
        /// Table-relative line index of each data line, from 1 (index 0 unused).
        var dlines: [Int]
        /// Hline flag per line, with an extra hline after the last.
        var types: [Bool]
        var ncol: Int
        var begin: Int
        /// `org-table-column-names`: from the first `!` row.
        var columnNames: [(name: String, column: Int)] = []
        /// `org-table-local-parameters`, in the order org pushes them; the last match wins.
        var parameters: [(name: String, value: String)] = []
        /// `org-table-named-field-locations`: the table-relative line and the column.
        var namedFields: [(name: String, line: Int, column: Int)] = []
        /// A row marked for calculation (`org-table-calculate-mark-regexp`).
        var marked = false
    }

    static let tblfmPattern = "^[ \\t]*#\\+TBLFM: *(.*)"
    static let rangePattern = "@([-+]?I*[-+]?[0-9]*)(\\$[-+]?[0-9]+)?(\\.\\.@?([-+]?I*[-+]?[0-9]*)(\\$[-+]?[0-9]+)?)?"

    /// `org-table-analyze`.
    func tableAnalyze() throws -> TableAnalysis {
        let begin = tableBegin()
        let end = tableEnd()
        return try saveExcursion {
            point = begin
            var dlines = [0]
            var types: [Bool] = []
            var lines: [String] = []
            var line = 0
            while point < end || (point == end && false) {
                let content = substring(lineStart(point), lineEnd(point))
                guard content.range(of: "^[ \\t]*\\|", options: .regularExpression) != nil else { break }
                lines.append(content)
                let isHline = content.range(of: "^[ \\t]*\\|-", options: .regularExpression) != nil
                types.append(isHline)
                if !isHline { dlines.append(line) }
                line += 1
                if forwardLine(1) != 0 || point >= end { break }
            }
            types.append(true)
            guard dlines.count > 1 else { throw UserError(message: "No data lines in table") }
            point = begin
            forwardLine(dlines[1])
            let first = substring(lineStart(point), lineEnd(point))
            let ncol = Self.splitFields(first, separator: "[ \\t]*\\|[ \\t]*").count
            var analysis = TableAnalysis(dlines: dlines, types: types, ncol: ncol, begin: begin)
            Self.names(lines, into: &analysis)
            return analysis
        }
    }

    /// The names part of `org-table-analyze`.
    static func names(_ lines: [String], into analysis: inout TableAnalysis) {
        let identifier = "^[a-zA-Z][_a-zA-Z0-9]*$"
        func rest(_ line: String, _ pattern: String) -> String? {
            guard let m = try! NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
            return (line as NSString).substring(with: m.range(at: m.numberOfRanges - 1))
        }
        if let names = lines.lazy.compactMap({ rest($0, "^[ \\t]*\\| *! *(\\|.*)") }).first {
            for (i, name) in splitFields(names, separator: " *\\| *").enumerated() where name.range(of: identifier, options: .regularExpression) != nil {
                analysis.columnNames.append((name, i + 2))
            }
        }
        for line in lines {
            guard let fields = rest(line, "^[ \\t]*\\| *\\$ *(\\|.*)") else { continue }
            for field in splitFields(fields, separator: " *\\| *") {
                if let m = field.firstMatch(of: /^([a-zA-Z][_a-zA-Z0-9]*|%) *= *(.*)/) { analysis.parameters.append((String(m.1), String(m.2))) }
            }
        }
        for (k, line) in lines.enumerated() {
            guard let m = line.firstMatch(of: /^[ \t]*\| *([_^]) *(\|.*)/) else { continue }
            let target = m.1 == "_" ? k + 1 : k - 1
            guard lines.indices.contains(target), let values = rest(lines[target], "^[ \\t]*\\|[^|]*(\\|.*)") else { continue }
            for (i, (name, value)) in zip(splitFields(String(m.2), separator: " *\\| *"), splitFields(values, separator: " *\\| *")).enumerated()
            where name.range(of: identifier, options: .regularExpression) != nil {
                analysis.parameters.append((name, value))
                analysis.namedFields.append((name, target, i + 2))
            }
        }
        analysis.marked = lines.contains { $0.range(of: "^[ \\t]*\\| *[!$^_#*] *(\\||$)", options: .regularExpression) != nil }
    }

    /// `org-split-string`: leading and trailing separators produce no empty strings.
    static func splitFields(_ s: String, separator: String) -> [String] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: separator)
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [s] }
        var results: [String] = []
        var i = 0
        for (k, m) in matches.enumerated() {
            if k == 0, m.range.location == 0 {
                i = NSMaxRange(m.range)
                continue
            }
            results.append(ns.substring(with: NSRange(location: i, length: m.range.location - i)))
            i = NSMaxRange(m.range)
        }
        if i != ns.length { results.append(ns.substring(from: i)) }
        return results
    }

    /// `org-table-get-stored-formulas` from the `#+TBLFM` text `line`.
    static func storedFormulas(_ line: String) throws -> [(lhs: String, rhs: String)] {
        var result: [(String, String)] = []
        var seen: Set<String> = []
        let regex = try! NSRegularExpression(pattern: "^(@[-+I<>0-9.$@]+|\\$([_a-zA-Z0-9]+|[<>]+)) *= *(.*[^ \\t])")
        for part in splitFields(line, separator: " *:: *") {
            let ns = part as NSString
            guard let m = regex.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)) else { continue }
            let whole = ns.substring(with: m.range(at: 1))
            var lhs = whole
            if m.range(at: 2).location != NSNotFound,
               whole.range(of: "^\\$([0-9]+|[<>]+)$", options: .regularExpression) == nil {
                lhs = ns.substring(with: m.range(at: 2))
            }
            guard seen.insert(lhs).inserted else { throw UserError(message: "Double definition `\(lhs)=' in TBLFM line, please fix by hand") }
            result.append((lhs, ns.substring(with: m.range(at: 3))))
        }
        return result
    }

    /// The first `#+TBLFM` line after the table, blank lines allowed between.
    func firstTblfm(after end: Int) -> String? {
        saveExcursion {
            point = end
            while !eobp {
                let line = substring(lineStart(point), lineEnd(point))
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if forwardLine(1) != 0 { return nil }
                    continue
                }
                guard let r = line.range(of: Self.tblfmPattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
                let text = String(line[r])
                return String(text[text.index(after: text.firstIndex(of: ":")!)...]).trimmingCharacters(in: .init(charactersIn: " "))
            }
            return nil
        }
    }

    /// `org-table-formula-handle-first/last-rc`.
    static func handleFirstLast(_ s: String, analysis: TableAnalysis) throws -> String {
        var result = s
        var start = 0
        let regex = try! NSRegularExpression(pattern: "([@$])(<+|>+)|(remote\\([^)]+\\))")
        while let m = regex.firstMatch(in: result, range: NSRange(location: start, length: (result as NSString).length - start)) {
            let ns = result as NSString
            if m.range(at: 3).location != NSNotFound {
                start = NSMaxRange(m.range(at: 3))
                continue
            }
            let kind = ns.substring(with: m.range(at: 1))
            let nmax = kind == "@" ? analysis.dlines.count - 1 : analysis.ncol
            let marks = ns.substring(with: m.range(at: 2))
            let n = marks.first == "<" ? marks.count : nmax - marks.count + 1
            if n < 1 || n > nmax { throw UserError(message: "Reference \"\(ns.substring(with: m.range))\" in expression \"\(result)\" points outside table") }
            start = m.range.location
            result = ns.replacingCharacters(in: m.range, with: kind + String(n))
        }
        return result
    }

    /// `org-table--row-type`.
    static func rowType(hline: Bool, _ n: Int, _ start: Int, backwards: Bool, relative: Bool, analysis: TableAnalysis, desc: String) throws -> Int {
        var i = start
        let l = analysis.types.count
        for _ in 0..<n {
            while true {
                i += backwards ? -1 : 1
                guard i >= 0, i < l, analysis.types[i] != hline else { break }
            }
        }
        if i < 0 || i >= l { throw UserError(message: "Row descriptor \(desc) leads outside table") }
        return i == l - 1 ? i - 1 : i
    }

    /// `org-table--descriptor-line`, with `org-table-get-range`'s fallback to the current
    /// line for `@0`, whose `org-table-dlines` entry is nil.
    static func descriptorLine(_ desc: String, _ cline: Int, analysis: TableAnalysis) throws -> Int {
        if let n = Int(desc), desc.allSatisfy(\.isNumber) {
            guard n < analysis.dlines.count else { throw Calc.Unsupported("row out of range") }
            return n == 0 ? cline : analysis.dlines[n]
        }
        let ns = desc as NSString
        let regex = try! NSRegularExpression(pattern: "^(([-+])?(I+))?(([-+])?([0-9]+))?")
        let m = regex.firstMatch(in: desc, range: NSRange(location: 0, length: ns.length))!
        func has(_ i: Int) -> Bool { m.range(at: i).location != NSNotFound }
        if (!has(3) && !has(6)) || (has(3) && has(6) && !has(5)) { throw UserError(message: "Invalid row descriptor `\(desc)'") }
        var hn = has(3) ? m.range(at: 3).length : nil
        var hdir = has(2) ? ns.substring(with: m.range(at: 2)) : nil
        let odir = has(5) ? ns.substring(with: m.range(at: 5)) : nil
        let on = has(6) ? Int(ns.substring(with: m.range(at: 6))) : nil
        let rel = has(6) && ((has(1) && !has(3)) || has(5))
        var cline = cline
        if hn != nil, hdir == nil {
            cline = 0
            hdir = "+"
            if analysis.types[0] { hn! -= 1 }
        }
        if hn == nil, on != nil, odir == nil { throw UserError(message: "Should never happen") }
        if let hn { cline = try rowType(hline: true, hn, cline, backwards: hdir == "-", relative: false, analysis: analysis, desc: desc) }
        if let on { cline = try rowType(hline: false, on, cline, backwards: odir == "-", relative: rel, analysis: analysis, desc: desc) }
        return cline
    }

    /// `org-table-get-field` on the line at point.
    func tableField(_ column: Int) -> String {
        saveExcursion {
            tableGotoColumn(column)
            skipBackwardNot([124, 10])
            if bolp || looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) != nil { return "" }
            let start = point
            while let c = character(at: point), c != 124, c != 10, c != 13 { point += 1 }
            return substring(start, point)
        }
    }

    func isDataLine() -> Bool {
        looking("^[ \\t]*\\|[^-]", caseInsensitive: false, setsMatch: false) != nil
            || substring(lineStart(point), lineEnd(point)).range(of: "^[ \\t]*\\|[^-]", options: .regularExpression) != nil
    }

    func gotoTableLine(_ line: Int, _ analysis: TableAnalysis) {
        point = analysis.begin
        forwardLine(line)
    }

    /// `org-table-get-range`: one field's text, or the fields of a rectangle.
    func tableRange(_ desc: String, thisline: Int, col: Int, analysis: TableAnalysis) throws -> TableRangeValue {
        var desc = desc
        if desc.range(of: "^\\$[0-9]+\\.\\.\\$[0-9]+$", options: .regularExpression) != nil {
            desc = desc.replacingOccurrences(of: "$", with: "@0$")
        }
        let ns = desc as NSString
        guard let m = try! NSRegularExpression(pattern: Self.rangePattern).firstMatch(in: desc, range: NSRange(location: 0, length: ns.length)) else {
            throw UserError(message: "Invalid table range specifier `\(desc)'")
        }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let isRange = group(3) != nil
        func row(_ r: String?) throws -> Int {
            guard let r, r.contains(where: { !$0.isWhitespace }) else { return thisline }
            return try Self.descriptorLine(r, thisline, analysis: analysis)
        }
        func column(_ c: String?) -> Int {
            guard let c else { return col }
            let body = String(c.dropFirst())
            let n = Int(body) ?? 0
            if n == 0 { return col }
            return n + (body.first == "-" || body.first == "+" ? col : 0)
        }
        let r1 = try row(group(1))
        let r2 = try row(group(4))
        let c1 = column(group(2))
        let c2 = column(group(5))
        return try saveExcursion {
            if !isRange || (r1 == r2 && c1 == c2) {
                gotoTableLine(r1, analysis)
                while !isDataLine() {
                    if forwardLine(1) != 0 { throw Calc.Unsupported("reference outside table") }
                }
                return .field(tableField(c1).trimmingCharacters(in: .whitespaces))
            }
            var firstRow = min(r1, r2)
            let lastRow = max(r1, r2)
            let firstColumn = min(c1, c2)
            let lastColumn = max(c1, c2)
            gotoTableLine(firstRow, analysis)
            while !isDataLine() {
                if forwardLine(1) != 0 { throw Calc.Unsupported("reference outside table") }
                firstRow += 1
            }
            let startLine = lineStart(point)
            forwardLine(lastRow - firstRow)
            while !isDataLine() { forwardLine(-1) }
            let endLine = lineStart(point)
            var fields: [String] = []
            point = startLine
            while point <= endLine {
                if !atTableHline {
                    for c in firstColumn...lastColumn { fields.append(tableField(c).trimmingCharacters(in: .whitespaces)) }
                }
                if forwardLine(1) != 0 { break }
            }
            return .list(fields)
        }
    }

    enum TableRangeValue {
        case field(String)
        case list([String])
    }

    static let calcNumber = "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$"
    /// `org-ts-regexp-both`.
    static let timestampBoth = "[\\[<]([0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^\\]>\\n]*)?)[\\]>]"

    /// How `org-table-make-reference` turns fields into formula text.
    struct ReferenceMode {
        enum Lisp { case none, lisp, literal }
        var keepEmpty = false
        var numbers = false
        var lisp = Lisp.none
    }

    /// `number-to-string` of `string-to-number`.
    static func numberText(_ s: String) -> String { Elisp.printed(Elisp.stringToNumber(s)) }

    /// `org-table-make-reference`. For Calc, a field that isn't a number, a date or `nan`
    /// would be a symbol, which isn't supported.
    static func makeReference(_ value: TableRangeValue, _ mode: ReferenceMode) throws -> String {
        func blank(_ s: String) -> Bool { !s.contains { !$0.isWhitespace } }
        func lisp(_ s: String) -> String {
            switch mode.lisp {
            case .literal: s
            default: mode.numbers ? numberText(s) : Elisp.printed(.string(s), escape: true)
            }
        }
        func calc(_ s: String) throws -> String {
            let text = mode.numbers ? numberText(s) : s
            guard text.range(of: calcNumber, options: .regularExpression) != nil || text == "nan"
                || text.range(of: "^" + timestampBoth + "$", options: .regularExpression) != nil else {
                throw Calc.Unsupported("non-numeric field \(text)")
            }
            return text
        }
        let empty = !mode.keepEmpty || mode.numbers ? "0" : "nan"
        switch value {
        case .field(let s):
            if mode.lisp != .none { return lisp(s) }
            return blank(s) ? (empty == "0" ? "(0)" : "nan") : "(" + (try calc(s)) + ")"
        case .list(var items):
            if !mode.keepEmpty { items = items.filter { !blank($0) } }
            if mode.lisp != .none { return items.map(lisp).joined(separator: " ") }
            return "[" + (try items.map { blank($0) ? empty : try calc($0) }).joined(separator: ",") + "]"
        }
    }

    /// A number written in a formula, small enough to work with.
    static func integer(_ s: String) throws -> Int {
        guard let n = Int(s.hasPrefix("+") ? String(s.dropFirst()) : s), (-999_999_999...999_999_999).contains(n) else { throw Calc.Unsupported("number size \(s)") }
        return n
    }

    /// `org-table-time-string-to-seconds`.
    static func timeStringToSeconds(_ s: String) throws -> String {
        guard !s.isEmpty else { return s }
        func seconds(_ sign: Substring, _ parts: [Substring]) throws -> String {
            var total = 0
            for (i, part) in parts.enumerated() {
                let (scaled, o1) = (Int(part) ?? Int.max).multipliedReportingOverflow(by: [3600, 60, 1][i])
                let (sum, o2) = total.addingReportingOverflow(scaled)
                if o1 || o2 || Int(part) == nil { throw Calc.Unsupported("duration size") }
                total = sum
            }
            return String(sign.isEmpty ? total : -total)
        }
        if let m = s.firstMatch(of: /(-?)([0-9]+):([0-9]+):([0-9]+)/) { return try seconds(m.1, [m.2, m.3, m.4]) }
        if s.range(of: timestampBoth, options: .regularExpression) == nil, let m = s.firstMatch(of: /(-?)([0-9]+):([0-9]+)/) {
            return try seconds(m.1, [m.2, m.3])
        }
        return numberText(s)
    }

    enum DurationFormat { case hms, hhmm, hours }

    /// `org-table-time-seconds-to-string`, with `org-table-duration-custom-format` `hours`
    /// and zero-padded hours.
    static func secondsToString(_ seconds: Sexp, _ format: DurationFormat) throws -> String {
        let value = (try? Elisp.number(seconds))?.double ?? 0
        let magnitude = abs(value)
        guard magnitude.isFinite, magnitude < 1e15 else { throw Calc.Unsupported("duration size") }
        let result: String
        switch format {
        case .hours:
            result = String(format: "%.2f", magnitude / 3600)
        case .hms, .hhmm:
            let total = Int(magnitude.rounded(.down))
            let hms = String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            result = format == .hhmm ? String(hms.dropLast(3)) : hms
        }
        return value < 0 ? "-" + result : result
    }

    /// `org-table-convert-refs-to-rc` for a remote reference: `B3` is `@3$2`.
    static func refsToRC(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_$@])([a-zA-Z]{1,2})([0-9]+)(?![A-Za-z0-9_])")
        var out = s
        while let m = regex.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
            let ns = out as NSString
            let column = ns.substring(with: m.range(at: 1)).uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
            out = ns.replacingCharacters(in: m.range, with: "@\(ns.substring(with: m.range(at: 2)))$\(column)")
        }
        return out
    }

    /// `org-table-get-constant`: a parameter or named field, a `#+CONSTANTS` value, or the
    /// entry's property for `PROP_name`.
    func tableConstant(_ name: String, analysis: TableAnalysis) -> String {
        if let parameter = analysis.parameters.last(where: { $0.name == name }) { return parameter.value }
        for m in (settings.setupKeywords + string).matches(of: #/(?mi)^[ \t]*#\+CONSTANTS:(.*)$/#) {
            for pair in m.1.split(whereSeparator: \.isWhitespace) {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == name { return String(parts[1]) }
            }
        }
        if name.hasPrefix("PROP_"), let value = inheritedProperty(String(name.dropFirst(5)))?.value { return value }
        return "#UNDEFINED_NAME"
    }

    /// `org-table-formula-substitute-names`: column names become `$N`; parameters, named
    /// fields and constants their values, in parentheses outside Lisp formulas.
    func substituteNames(_ formula: String, analysis: TableAnalysis) throws -> String {
        let parenthesize = !formula.hasPrefix("'")
        let duration = formula.range(of: ";.*[Tt].*$", options: .regularExpression) != nil
        var new = formula
        if !analysis.columnNames.isEmpty {
            let names = analysis.columnNames.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
            let regex = try! NSRegularExpression(pattern: "\\$(\(names))(?![[:alnum:]])")
            var start = 0
            while let m = regex.firstMatch(in: new, range: NSRange(location: start, length: (new as NSString).length - start)) {
                let ns = new as NSString
                let column = analysis.columnNames.first { $0.name == ns.substring(with: m.range(at: 1)) }!.column
                new = ns.replacingCharacters(in: m.range, with: "$\(column)")
                start = m.range.location + 1
            }
        }
        let regex = try! NSRegularExpression(pattern: "\\$([a-zA-Z][_a-zA-Z0-9]*)|(\\bremote\\([^)]*\\))")
        var start = 0
        var substitutions = 0
        while let m = regex.firstMatch(in: new, range: NSRange(location: start, length: (new as NSString).length - start)) {
            let ns = new as NSString
            // A constant whose value names itself would go on forever, as it does in Org.
            substitutions += 1
            if substitutions > 1000 { throw Calc.Unsupported("constants that refer to themselves") }
            if m.range(at: 2).location != NSNotFound {
                start = NSMaxRange(m.range(at: 2))
                continue
            }
            start = m.range.location + 1
            var value = tableConstant(ns.substring(with: m.range(at: 1)), analysis: analysis)
            if duration, value.contains(where: { !$0.isWhitespace }) { value = try Self.timeStringToSeconds(value) }
            new = ns.replacingCharacters(in: m.range, with: parenthesize ? "(" + value + ")" : value)
        }
        return new
    }

    /// `org-table-get-remote-range`: the table after `#+NAME: name` in this file, or the first
    /// table in the entry with that ID, in this file or another.
    func remoteRange(_ name: String, _ form: String) throws -> TableRangeValue {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let keyword = try! NSRegularExpression(pattern: "^[ \\t]*#\\+(tbl)?name:[ \\t]*" + escaped + "[ \\t]*$", options: [.anchorsMatchLines, .caseInsensitive])
        let idLine = try! NSRegularExpression(pattern: "^[ \\t]*:ID:[ \\t]+" + escaped + "[ \\t]*$", options: [.anchorsMatchLines, .caseInsensitive])
        func first(_ regex: NSRegularExpression, in text: String) -> Int? {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.location
        }
        // `org-id-find`: the entry's heading, here or in the file holding the ID.
        func heading(_ text: String, _ offset: Int) -> Int {
            let before = try! NSRegularExpression(pattern: "^\\*+ ", options: .anchorsMatchLines)
            return before.matches(in: text, range: NSRange(location: 0, length: offset)).last?.range.location ?? 0
        }
        var text = string
        let location: Int
        if let found = first(keyword, in: string) {
            location = found
        } else if let found = first(idLine, in: string) {
            location = heading(string, found)
        } else if let other = RemoteTables.fileWithID?(name), let found = first(idLine, in: other) {
            text = other
            location = heading(other, found)
        } else {
            throw UserError(message: "Can't find remote table \"\(name)\"")
        }
        let ns = text as NSString
        let after = min(ns.length, location + 1)
        let next = try! NSRegularExpression(pattern: "^(\\*+ )|^[ \\t]*\\|", options: .anchorsMatchLines)
        guard let m = next.firstMatch(in: text, range: NSRange(location: after, length: ns.length - after)),
              m.range(at: 1).location == NSNotFound else {
            throw UserError(message: "Cannot find a table at NAME or ID \(name)")
        }
        let remote = EmacsBuffer(text, point: m.range.location, settings: settings, options: options)
        let analysis = try remote.tableAnalyze()
        let resolved = try remote.substituteNames(try Self.handleFirstLast(Self.refsToRC(form), analysis: analysis), analysis: analysis)
        let range = try! NSRegularExpression(pattern: Self.rangePattern)
        let rns = resolved as NSString
        if let r = range.firstMatch(in: resolved, range: NSRange(location: 0, length: rns.length)), r.range.length > 1 {
            return try remote.tableRange(rns.substring(with: r.range), thisline: 0, col: 1, analysis: analysis)
        }
        return .field(resolved)
    }

    /// `org-table-eval-formula` with the equation given, at point. `substituted` when names
    /// and constants were already replaced, as `org-table-recalculate` does.
    func tableEvalFormula(_ formula: String, analysis: TableAnalysis, substituted: Bool = true) throws {
        var formula = formula
        var modes = Calc.Modes()
        var mode = ReferenceMode()
        var duration: DurationFormat?
        var literal = false
        var fmt: String?
        if let semicolon = formula.lastIndex(of: ";") {
            var flags = (analysis.parameters.last { $0.name == "%" }?.value ?? "") + formula[formula.index(after: semicolon)...]
            formula = String(formula[..<semicolon])
            let numeric = try! NSRegularExpression(pattern: "([pnfse])(-?[0-9]+)")
            while let m = numeric.firstMatch(in: flags, range: NSRange(location: 0, length: (flags as NSString).length)) {
                let ns = flags as NSString
                let n = try Self.integer(ns.substring(with: m.range(at: 2)))
                switch ns.substring(with: m.range(at: 1)) {
                case "p": modes.precision = n
                case "n": modes.format = .float(n)
                case "f": modes.format = .fix(n)
                case "s": modes.format = .sci(n)
                default: modes.format = .eng(n)
                }
                flags = ns.replacingCharacters(in: m.range, with: "")
            }
            let letters = try! NSRegularExpression(pattern: "[tTUNLEDRFSu]")
            while let m = letters.firstMatch(in: flags, range: NSRange(location: 0, length: (flags as NSString).length)) {
                let ns = flags as NSString
                switch ns.substring(with: m.range) {
                case "t": (duration, mode.numbers) = (.hours, true)
                case "T": (duration, mode.numbers) = (.hms, true)
                case "U": (duration, mode.numbers) = (.hhmm, true)
                case "N": mode.numbers = true
                case "L": literal = true
                case "E": mode.keepEmpty = true
                case "F": modes.preferFractions = true
                case "D": modes.degrees = true
                case "R": modes.degrees = false
                default: throw Calc.Unsupported("format flag \(ns.substring(with: m.range))")
                }
                flags = ns.replacingCharacters(in: m.range, with: "")
            }
            if flags.contains(where: { !$0.isWhitespace }) { fmt = flags }
        }
        if !substituted { formula = try Self.handleFirstLast(try substituteNames(formula, analysis: analysis), analysis: analysis) }
        var fields = Self.splitFields(substring(lineStart(point), lineEnd(point)).trimmingCharacters(in: .whitespaces), separator: " *\\| *")
        if duration != nil { fields = try fields.map(Self.timeStringToSeconds) }
        if mode.numbers { fields = fields.map { $0.contains(where: { !$0.isWhitespace }) ? Self.numberText($0) : $0 } }
        if formula.count > 2, formula.hasPrefix("'(") { mode.lisp = literal ? .literal : .lisp }
        func reference(_ value: TableRangeValue) throws -> String {
            guard duration != nil else { return try Self.makeReference(value, mode) }
            switch value {
            case .field(let s): return try Self.makeReference(.field(try Self.timeStringToSeconds(s)), mode)
            case .list(let items): return try Self.makeReference(.list(try items.map(Self.timeStringToSeconds)), mode)
            }
        }
        let n0 = tableCurrentColumn()
        let thisline = try saveExcursion { () -> Int in
            let here = lineStart(point)
            point = analysis.begin
            var count = 0
            while point < here {
                if forwardLine(1) != 0 { throw Calc.Unsupported("table position") }
                count += 1
            }
            return count
        }
        var form = formula
        form = form.replacingOccurrences(of: "@#", with: String(tableCurrentDataLine()))
        form = form.replacingOccurrences(of: "$#", with: String(n0))
        // `org-table-remote-reference-indirection`: `remote($1, …)` names the table in a field.
        let indirect = try! NSRegularExpression(pattern: "\\bremote\\([ \\t]*([@$][^ \\t,]+)[ \\t]*,[ \\t]*([^\\n)]+)\\)")
        var start = 0
        while let m = indirect.firstMatch(in: form, range: NSRange(location: start, length: (form as NSString).length - start)) {
            let ns = form as NSString
            var eq = try Self.handleFirstLast(ns.substring(with: m.range(at: 1)), analysis: analysis)
            if eq.range(of: "^\\$[0-9]+$", options: .regularExpression) != nil { eq = "@0" + eq }
            guard case .field(let name) = try tableRange(eq, thisline: thisline, col: n0, analysis: analysis) else {
                throw Calc.Unsupported("remote table name from a range")
            }
            form = ns.replacingCharacters(in: m.range(at: 1), with: name)
            start = m.range(at: 1).location + (name as NSString).length
        }
        let remote = try! NSRegularExpression(pattern: "\\bremote\\([ \\t]*([^,)]+)[ \\t]*,[ \\t]*([^\\n)]+)\\)")
        while let m = remote.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) {
            let ns = form as NSString
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let value = try remoteRange(name, ns.substring(with: m.range(at: 2)))
            form = ns.replacingCharacters(in: m.range, with: try reference(value))
        }
        let range = try! NSRegularExpression(pattern: Self.rangePattern)
        while let m = range.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)), m.range.length > 1 {
            let ns = form as NSString
            let replacement = try reference(try tableRange(ns.substring(with: m.range), thisline: thisline, col: n0, analysis: analysis))
            if replacement.contains(form) { throw UserError(message: "Spreadsheet error: invalid reference \"\(form)\"") }
            form = ns.replacingCharacters(in: m.range, with: replacement)
        }
        let rowRange = try! NSRegularExpression(pattern: "\\$(([-+])?[0-9]+)\\.\\.\\$(([-+])?[0-9]+)")
        while let m = rowRange.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) {
            let ns = form as NSString
            let a = try Self.integer(ns.substring(with: m.range(at: 1))) + (m.range(at: 2).location != NSNotFound ? n0 : 0)
            let b = try Self.integer(ns.substring(with: m.range(at: 3))) + (m.range(at: 4).location != NSNotFound ? n0 : 0)
            guard a >= 1, b <= fields.count, a - 1 <= b else { throw Calc.Unsupported("range outside row") }
            form = ns.replacingCharacters(in: m.range, with: try Self.makeReference(.list(Array(fields[(a - 1)..<b])), mode))
        }
        let single = try! NSRegularExpression(pattern: "\\$(([-+])?[0-9]+)")
        while let m = single.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) {
            let ns = form as NSString
            let n = try Self.integer(ns.substring(with: m.range(at: 1))) + (m.range(at: 2).location != NSNotFound ? n0 : 0)
            let index = (n == 0 ? n0 : max(n, 1)) - 1
            guard index < fields.count else { throw UserError(message: "Invalid field specifier \"\(ns.substring(with: m.range))\"") }
            let replacement = try Self.makeReference(.field(fields[index]), mode)
            if replacement.contains(formula) { throw UserError(message: "Invalid field specifier \"\(ns.substring(with: m.range))\"") }
            form = ns.replacingCharacters(in: m.range, with: replacement)
        }

        var result: String
        if mode.lisp != .none {
            result = try evalLisp(form, duration: duration)
        } else {
            form = form.replacingOccurrences(of: "\\[([0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^\\]>\\n]*)?)\\]", with: "<$1>", options: .regularExpression)
            form = Self.normalizeTimestamps(form)
            if duration != nil, form.range(of: "^[0-9]+:[0-9]+(:[0-9]+)?$", options: .regularExpression) != nil {
                result = form
            } else {
                do {
                    result = try Calc.evaluate(form, modes: modes, numeric: !mode.keepEmpty && mode.numbers)
                } catch is Calc.Failure {
                    (result, fmt) = ("#ERROR", nil)
                }
            }
            if let duration, !result.isEmpty, result != "#ERROR" {
                let seconds = result.range(of: "^[0-9]+:[0-9]+(:[0-9]+)?$", options: .regularExpression) != nil ? try Self.timeStringToSeconds(result) : result
                result = try Self.secondsToString(Elisp.stringToNumber(seconds), duration)
            }
        }
        if let fmt {
            do {
                result = try Elisp.format([.string(fmt), Elisp.stringToNumber(result)])
            } catch let error as Elisp.Signal {
                throw UserError(message: error.message)
            }
        } else {
            result = result.replacingOccurrences(of: "<([0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^\\]>\\n]*)?)>", with: "[$1]", options: .regularExpression)
        }
        tableSetField(result)
    }

    /// `(eval (eval (read form)))` for a Lisp formula; an error is `#ERROR`.
    func evalLisp(_ form: String, duration: DurationFormat?) throws -> String {
        let lisp = Elisp()
        Self.defineLookups(lisp)
        let value: Sexp
        do {
            value = try lisp.eval(try lisp.eval(try LispReader.readFirst(form).sexp))
        } catch let unsupported as Elisp.Unsupported {
            throw Calc.Unsupported("Lisp \(unsupported.what)")
        } catch {
            return "#ERROR"
        }
        var result = Elisp.printed(value)
        if let duration { result = try Self.secondsToString(Elisp.stringToNumber(result), duration) }
        return result
    }

    /// `org-lookup-first`, `org-lookup-last` and `org-lookup-all`.
    static func defineLookups(_ lisp: Elisp) {
        func matches(_ lisp: Elisp, _ args: [Sexp]) throws -> [Sexp] {
            try Elisp.arity(args, 3...4, "org-lookup")
            let keys = try Elisp.elements(args[1])
            let values = Elisp.isNil(args[2]) ? keys : try Elisp.elements(args[2])
            let predicate = args.count > 3 && !Elisp.isNil(args[3]) ? args[3] : .symbol("equal")
            var found: [Sexp] = []
            for (i, key) in keys.enumerated() where !Elisp.isNil(try lisp.call(predicate, [args[0], key])) {
                found.append(i < values.count ? values[i] : .nil)
            }
            return found
        }
        lisp.define("org-lookup-first") { lisp, args in try matches(lisp, args).first ?? .nil }
        lisp.define("org-lookup-last") { lisp, args in try matches(lisp, args).last ?? .nil }
        lisp.define("org-lookup-all") { lisp, args in
            let found = try matches(lisp, args)
            return found.isEmpty ? .nil : .list(found)
        }
    }

    /// Timestamps in a formula as Calc reads them: `<YYYY-MM-DD Www>`, with ` HH:MM` when
    /// the stamp has a time, as org formats them for Calc.
    static func normalizeTimestamps(_ form: String) -> String {
        let regex = try! NSRegularExpression(pattern: "<([0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^\\]>\\n]*)?)>")
        var out = form
        var start = 0
        while let m = regex.firstMatch(in: out, range: NSRange(location: start, length: (out as NSString).length - start)) {
            let ns = out as NSString
            let stamp = ns.substring(with: m.range(at: 1))
            let parts = stamp.firstMatch(of: /^([0-9]{4})-([0-9]{2})-([0-9]{2})/)!
            let day = Days.absolute(year: Int(parts.1)!, month: Int(parts.2)!, day: Int(parts.3)!)
            let date = Days.date(day)
            var text = String(format: "<%04d-%02d-%02d %@", date.year, date.month, date.day, Calc.weekdays[Days.weekday(day)])
            if let time = stamp.firstMatch(of: /([0-9]{1,2}):([0-9]{2})/) {
                text += String(format: " %02d:%02d", Int(time.1)!, Int(time.2)!)
            }
            text += ">"
            out = ns.replacingCharacters(in: m.range, with: text)
            start = m.range.location + (text as NSString).length
        }
        return out
    }

    /// `string-to-number`.
    static func stringToNumber(_ s: String) -> Double {
        guard let r = s.range(of: "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?", options: .regularExpression) else { return 0 }
        return Double(s[r]) ?? 0
    }

    /// `org-table-justify-field-maybe` while the table needs realigning: the field becomes
    /// ` NEW |`.
    func tableSetField(_ value: String) {
        let pos = point
        guard tableCurrentColumn() > 0 else { return }
        skipBackwardNot([124])
        let start = point
        var end = point
        while let c = character(at: end), c != 124, c != 10 { end += 1 }
        let closed = character(at: end) == 124
        replaceRange(start, closed ? end + 1 : end, with: " \(value) |")
        point = min(pos, length)
    }

    func replaceRange(_ start: Int, _ end: Int, with text: String) {
        let saved = point
        deleteRegion(start, end)
        point = start
        insert(text)
        point = saved
    }

    /// `org-table-recalculate`: `all` for every row, otherwise the line at point; `tblfm`
    /// replaces the stored formulas, as C-c C-c on a `#+TBLFM` line does.
    func tableRecalculate(all: Bool, tblfm: String? = nil) throws {
        guard atTable else { throw UserError(message: "Not at a table") }
        let analysis = try tableAnalyze()
        let end = tableEnd()
        guard let line = tblfm ?? firstTblfm(after: end) else { return }
        let stored = try Self.storedFormulas(line).sorted { $0.lhs < $1.lhs }
        guard !stored.isEmpty else { return }
        var columnEquations: [(Int, String)] = []
        var fieldEquations: [(String, String)] = []
        for (oldLHS, rawRHS) in stored {
            let rhs = try substituteNames(try Self.handleFirstLast(rawRHS, analysis: analysis), analysis: analysis)
            if oldLHS.range(of: "^@-?I+", options: .regularExpression) != nil { throw UserError(message: "Can't assign to hline relative reference") }
            let lhs = try Self.handleFirstLast(oldLHS, analysis: analysis)
            if lhs.range(of: "^\\$[0-9]+$", options: .regularExpression) != nil {
                columnEquations.append((try Self.integer(String(lhs.dropFirst())), rhs))
            } else {
                fieldEquations.append((lhs, rhs))
            }
        }
        // `org-table-expand-lhs-ranges`.
        var fields: [(row: Int, column: Int, rhs: String)] = []
        for (lhs, rhs) in fieldEquations {
            if let m = lhs.firstMatch(of: /^@([0-9]+)\$([0-9]+)$/) {
                fields.append((try Self.integer(String(m.1)), try Self.integer(String(m.2)), rhs))
            } else if lhs.range(of: "^[a-zA-Z][_a-zA-Z0-9]*$", options: .regularExpression) != nil {
                guard let location = analysis.namedFields.last(where: { $0.name == lhs }), let row = Self.lineToDline(location.line, analysis) else {
                    throw UserError(message: "Unknown field: \(lhs)")
                }
                fields.append((row, location.column, rhs))
            } else if lhs.range(of: "^@[-+0-9]+\\$-?[0-9]+$", options: .regularExpression) != nil {
                // `org-table-goto-field` knows only absolute fields and names.
                throw UserError(message: "Unknown field: \(lhs)")
            } else if let m = lhs.firstMatch(of: /^@([0-9]+)$/) {
                let row = try Self.integer(String(m.1))
                for c in 1...analysis.ncol { fields.append((row, c, rhs)) }
            } else {
                let corners = try rangeCorners(lhs, analysis: analysis)
                guard let r1 = Self.lineToDline(corners.r1, analysis), let r2 = Self.lineToDline(corners.r2, analysis, above: true), r1 <= r2 else {
                    throw Calc.Unsupported("formula range")
                }
                for r in r1...r2 { for c in corners.c1...corners.c2 { fields.append((r, c, rhs)) } }
            }
        }
        let savedLine = lineStart(point)
        let savedColumn = tableCurrentColumn()
        let lineMarker = marker(savedLine)
        defer { release(lineMarker) }

        let endMarker = marker(end)
        defer { release(endMarker) }
        var beg: Int
        var lineRegexp = "^[ \\t]*\\|[^-]"
        if all, analysis.marked {
            beg = analysis.begin
            lineRegexp = "^[ \\t]*\\| *[#*] *(\\||$)"
        } else if all {
            beg = analysis.begin
            point = beg
            if searchForward("^[ \\t]*\\|[^-]", bound: end, caseInsensitive: false) != nil,
               searchForward("^[ \\t]*\\|-", bound: end, caseInsensitive: false) != nil,
               let body = searchForward("^[ \\t]*\\|[^-]", bound: end, caseInsensitive: false) {
                beg = body[0]!.lowerBound
            }
        } else {
            beg = lineStart(point)
            endMarker.position = min(length, lineEnd(point) + 1)
        }

        let currentLine = savedLine - 0
        var seen: Set<String> = []
        var untouchable: Set<String> = []
        for field in fields {
            let reference = "@\(field.row)$\(field.column)"
            guard seen.insert(reference).inserted else { throw UserError(message: "Several field/range formulas try to set \(reference)") }
            guard field.row < analysis.dlines.count else { throw UserError(message: "Invalid row number in \(reference)") }
            let lineStartOffset = saveExcursion { () -> Int in
                gotoTableLine(analysis.dlines[field.row], analysis)
                return lineStart(point)
            }
            if all || lineStartOffset == currentLine { untouchable.insert(reference) }
        }

        point = beg
        let rowMarker = marker(beg)
        defer { release(rowMarker) }
        while let match = searchForward(lineRegexp, bound: endMarker.position, caseInsensitive: false) {
            _ = match
            let rowStart = lineStart(point)
            rowMarker.position = rowStart
            let first = saveExcursion { () -> String in
                point = rowStart
                return tableField(1)
            }
            if first.range(of: "^ *[_^!$/] *$", options: .regularExpression) == nil {
                let dline = saveExcursion { () -> Int in
                    point = rowStart
                    return tableCurrentDataLine()
                }
                for (column, rhs) in columnEquations {
                    point = rowMarker.position
                    tableGotoColumn(column, force: true)
                    if untouchable.contains("@\(dline)$\(column)") { continue }
                    try tableEvalFormula(rhs, analysis: analysis)
                }
            }
            point = rowMarker.position
            if forwardLine(1) != 0 || point >= endMarker.position { break }
        }
        for field in fields {
            gotoTableLine(analysis.dlines[field.row], analysis)
            let count = substring(lineStart(point), lineEnd(point)).filter { $0 == "|" }.count - 1
            if field.column > count { throw UserError(message: "Missing columns in the table.  Aborting") }
            tableGotoColumn(field.column)
            try tableEvalFormula(field.rhs, analysis: analysis)
        }
        tableAlign()
        point = lineMarker.position
        tableGotoColumn(savedColumn)
    }

    /// `org-table-get-range` with `corners-only`.
    func rangeCorners(_ desc: String, analysis: TableAnalysis) throws -> (r1: Int, c1: Int, r2: Int, c2: Int) {
        let ns = desc as NSString
        guard let m = try! NSRegularExpression(pattern: Self.rangePattern).firstMatch(in: desc, range: NSRange(location: 0, length: ns.length)) else {
            throw UserError(message: "Invalid table range specifier `\(desc)'")
        }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let thisline = 0
        func row(_ r: String?) throws -> Int {
            guard let r, !r.isEmpty else { return thisline }
            return try Self.descriptorLine(r, thisline, analysis: analysis)
        }
        func column(_ c: String?) -> Int {
            guard let c, let n = Int(c.dropFirst()), n != 0 else { return 1 }
            return n + (c.dropFirst().first == "-" || c.dropFirst().first == "+" ? 1 : 0)
        }
        let r1 = try row(group(1))
        let r2 = try row(group(4))
        let c1 = column(group(2))
        let c2 = column(group(5))
        return (min(r1, r2), min(c1, c2), max(r1, r2), max(c1, c2))
    }

    /// `org-table-line-to-dline`.
    static func lineToDline(_ line: Int, _ analysis: TableAnalysis, above: Bool = false) -> Int? {
        let dlines = analysis.dlines
        var low = 1
        var high = dlines.count - 1
        if dlines[low] > line || dlines[high] < line { return nil }
        if line == dlines[high] { return high }
        while high - low > 1 {
            let mean = (high + low) / 2
            if dlines[mean] == line { return mean }
            if dlines[mean] > line { high = mean } else { low = mean }
        }
        if line == dlines[high] { return high }
        if line == dlines[low] { return low }
        return above ? low : high
    }
}

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
        guard case .failed(let message) = step, message.hasPrefix(Self.emacsMessage) else { return step }
        // Emacs recalculates the table; its text replaces the table here.
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        let onTblfm = Self.tblfmLine(in: context) != nil
        if onTblfm {
            while buffer.forwardLine(-1) == 0, !buffer.lookingAtLine("^[ \\t]*\\|") {}
        }
        let table = buffer.tableBegin()..<buffer.tableEnd()
        let tblfm = onTblfm ? Self.tblfmLine(in: context) ?? "" : buffer.firstTblfm(after: table.upperBound) ?? ""
        let form = onTblfm ? "(org-table-calc-current-TBLFM)" : all ? "(org-table-recalculate t)" : "(org-table-recalculate nil)"
        return .external(.emacsTable(
            table: table, point: context.caret, form: form,
            reason: String(message.dropFirst(Self.emacsMessage.count)), lisp: tblfm.contains("'(")
        ))
    }
}

// Formulas typed in a field (`org-table-maybe-eval-formula`) and C-c = (`org-table-eval-formula`).
extension EmacsBuffer {
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

    /// `org-table-get-formula` with EQUATION given: stores it for the current column, or with
    /// `named` the current field, and returns it.
    func tableGetFormula(_ equation: String, named: Bool, analysis: TableAnalysis) throws -> String {
        var stored = try Self.storedFormulas(firstTblfm(after: tableEnd()) ?? "")
        let ref = "@\(tableCurrentDataLine())$\(tableCurrentColumn())"
        let scol = named ? ref : "$\(tableCurrentColumn())"
        let old = stored.first { $0.lhs == scol }?.rhs
        var eq = old != nil && equation.range(of: "^ *=? *$", options: .regularExpression) != nil ? old! : equation
        guard eq.contains(where: { !$0.isWhitespace }) else {
            stored.removeAll { $0.lhs == scol }
            tableStoreFormulas(stored, analysis: analysis)
            throw UserError(message: "Formula removed")
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
    func tableEvalFormula(equation: String, named: Bool) throws {
        try checkInsideDataField()
        let analysis = try tableAnalyze()
        let formula = try tableGetFormula(equation, named: named, analysis: analysis)
        do {
            try tableEvalFormula(formula, analysis: analysis, substituted: false)
        } catch let error as Calc.Unsupported {
            throw UserError(message: "The formula was stored; recalculating it needs Emacs: " + error.reason)
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
        return commitBuffer(context) { try $0.tableEvalFormula(equation: answer, named: named) }
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
                                  effects: result.effects + [.message("New formulas installed - press C-u C-c C-c to apply.")]))
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
