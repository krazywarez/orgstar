import Foundation

// Table formulas (org-table.el, Org 9.8.7): `org-table-recalculate` and
// `org-table-eval-formula` with Calc evaluated natively. Column names, constants, named
// fields, marked rows, `remote()`, Lisp formulas, durations and Calc features beyond `Calc`
// throw `Calc.Unsupported`; the caller then recalculates the table in Emacs.

extension EmacsBuffer {
    struct TableAnalysis {
        /// Table-relative line index of each data line, from 1 (index 0 unused).
        var dlines: [Int]
        /// Hline flag per line, with an extra hline after the last.
        var types: [Bool]
        var ncol: Int
        var begin: Int
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
            var line = 0
            while point < end || (point == end && false) {
                let content = substring(lineStart(point), lineEnd(point))
                guard content.range(of: "^[ \\t]*\\|", options: .regularExpression) != nil else { break }
                if content.range(of: "^[ \\t]*\\| *[!$_^] *(\\||$)", options: .regularExpression) != nil {
                    throw Calc.Unsupported("named columns, parameters or fields")
                }
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
            return TableAnalysis(dlines: dlines, types: types, ncol: ncol, begin: begin)
        }
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

    /// `org-table--descriptor-line`.
    static func descriptorLine(_ desc: String, _ cline: Int, analysis: TableAnalysis) throws -> Int {
        if let n = Int(desc), desc.allSatisfy(\.isNumber) {
            guard n < analysis.dlines.count else { throw Calc.Unsupported("row out of range") }
            return analysis.dlines[n]
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

    /// `org-table-make-reference` for Calc, refusing what isn't a number.
    static func reference(_ value: TableRangeValue) throws -> String {
        func number(_ s: String) throws -> String {
            guard s.range(of: calcNumber, options: .regularExpression) != nil else { throw Calc.Unsupported("non-numeric field \(s)") }
            return s
        }
        switch value {
        case .field(let s):
            return s.contains(where: { !$0.isWhitespace }) ? "(" + (try number(s)) + ")" : "(0)"
        case .list(let items):
            return "[" + (try items.filter { $0.contains(where: { !$0.isWhitespace }) }.map(number)).joined(separator: ",") + "]"
        }
    }

    /// `org-table-eval-formula` with the equation given, at point.
    func tableEvalFormula(_ formula: String, analysis: TableAnalysis) throws {
        var formula = formula
        var modes = Calc.Modes()
        var fmt: String?
        if let semicolon = formula.lastIndex(of: ";") {
            var flags = String(formula[formula.index(after: semicolon)...])
            formula = String(formula[..<semicolon])
            let numeric = try! NSRegularExpression(pattern: "([pnfse])(-?[0-9]+)")
            while let m = numeric.firstMatch(in: flags, range: NSRange(location: 0, length: (flags as NSString).length)) {
                let ns = flags as NSString
                let n = Int(ns.substring(with: m.range(at: 2)))!
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
                case "D": modes.degrees = true
                case "R": modes.degrees = false
                default: throw Calc.Unsupported("format flag \(ns.substring(with: m.range))")
                }
                flags = ns.replacingCharacters(in: m.range, with: "")
            }
            if flags.contains(where: { !$0.isWhitespace }) {
                guard flags.range(of: "^%[-+ #0]*[0-9]*(\\.[0-9]+)?[fgeE]$", options: .regularExpression) != nil else {
                    throw Calc.Unsupported("format \(flags)")
                }
                fmt = flags
            }
        }
        if formula.hasPrefix("'(") { throw Calc.Unsupported("Lisp formula") }
        if formula.range(of: "\\$[a-zA-Z_]", options: .regularExpression) != nil || formula.contains("remote(")
            || formula.range(of: "[<\\[][0-9]{4}-", options: .regularExpression) != nil || formula.contains("&") {
            throw Calc.Unsupported("names, constants, remote references or dates")
        }
        let line = substring(lineStart(point), lineEnd(point)).trimmingCharacters(in: .whitespaces)
        let fields = Self.splitFields(line, separator: " *\\| *")
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
        let range = try! NSRegularExpression(pattern: Self.rangePattern)
        while let m = range.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)), m.range.length > 1 {
            let ns = form as NSString
            let replacement = try Self.reference(try tableRange(ns.substring(with: m.range), thisline: thisline, col: n0, analysis: analysis))
            form = ns.replacingCharacters(in: m.range, with: replacement)
        }
        let rowRange = try! NSRegularExpression(pattern: "\\$(([-+])?[0-9]+)\\.\\.\\$(([-+])?[0-9]+)")
        while let m = rowRange.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) {
            let ns = form as NSString
            let a = Int(ns.substring(with: m.range(at: 1)))! + (m.range(at: 2).location != NSNotFound ? n0 : 0)
            let b = Int(ns.substring(with: m.range(at: 3)))! + (m.range(at: 4).location != NSNotFound ? n0 : 0)
            guard a >= 1, b <= fields.count, a - 1 <= b else { throw Calc.Unsupported("range outside row") }
            form = ns.replacingCharacters(in: m.range, with: try Self.reference(.list(Array(fields[(a - 1)..<b]))))
        }
        let single = try! NSRegularExpression(pattern: "\\$(([-+])?[0-9]+)")
        while let m = single.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) {
            let ns = form as NSString
            let n = Int(ns.substring(with: m.range(at: 1)))! + (m.range(at: 2).location != NSNotFound ? n0 : 0)
            let index = (n == 0 ? n0 : max(n, 1)) - 1
            guard index < fields.count else { throw UserError(message: "Invalid field specifier \"\(ns.substring(with: m.range))\"") }
            form = ns.replacingCharacters(in: m.range, with: try Self.reference(.field(fields[index])))
        }
        var result = try Calc.evaluate(form, modes: modes)
        if let fmt {
            result = String(format: fmt, Self.stringToNumber(result))
        }
        tableSetField(result)
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
            let rhs = try Self.handleFirstLast(rawRHS, analysis: analysis)
            if oldLHS.range(of: "^@-?I+", options: .regularExpression) != nil { throw UserError(message: "Can't assign to hline relative reference") }
            let lhs = try Self.handleFirstLast(oldLHS, analysis: analysis)
            if lhs.range(of: "^\\$[0-9]+$", options: .regularExpression) != nil {
                columnEquations.append((Int(lhs.dropFirst())!, rhs))
            } else {
                fieldEquations.append((lhs, rhs))
            }
        }
        // `org-table-expand-lhs-ranges`.
        var fields: [(row: Int, column: Int, rhs: String)] = []
        for (lhs, rhs) in fieldEquations {
            if let m = lhs.firstMatch(of: /^@([0-9]+)\$([0-9]+)$/) {
                fields.append((Int(m.1)!, Int(m.2)!, rhs))
            } else if lhs.range(of: "^@[-+0-9]+\\$-?[0-9]+$", options: .regularExpression) != nil || lhs.range(of: "^[a-zA-Z]", options: .regularExpression) != nil {
                throw Calc.Unsupported("relative or named field formula")
            } else if let m = lhs.firstMatch(of: /^@([0-9]+)$/) {
                for c in 1...analysis.ncol { fields.append((Int(m.1)!, c, rhs)) }
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
        if all {
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
        while let match = searchForward("^[ \\t]*\\|[^-]", bound: endMarker.position, caseInsensitive: false) {
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
