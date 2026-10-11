import Foundation

/// `#+PLOT` (org-plot.el, Org 9.8.7): the options above a table, the table as org-plot reads
/// it, the data file and the gnuplot script `org-plot/gnuplot` writes, and the values a chart
/// of its own draws.
public enum TablePlot {
    /// A value as `read-from-string` reads an option.
    public enum Value: Sendable, Equatable, CustomStringConvertible {
        case number(Double)
        case symbol(String)
        case string(String)
        case list([Value])

        public var description: String {
            switch self {
            case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
            case .symbol(let s), .string(let s): s
            case .list(let l): "(" + l.map(\.description).joined(separator: " ") + ")"
            }
        }

        var int: Int? { if case .number(let n) = self { Int(n) } else { nil } }
        public var truthy: Bool { if case .symbol(let s) = self { s != "nil" } else { true } }
    }

    /// The plist org-plot builds, by key without the colon.
    public struct Options: Sendable, Equatable {
        public var values: [String: Value] = [:]
        /// `:set` and `:line`, latest first, as `cons` leaves them.
        public var sets: [String] = []
        public var lines: [String] = []

        public subscript(key: String) -> Value? { values[key] }
        public var type: String { values["plot-type"]?.description ?? "2d" }
        public var with: String { values["with"]?.description ?? "lines" }
        public var ind: Int { values["ind"]?.int ?? 0 }
        public var deps: [Int]? {
            guard case .list(let l)? = values["deps"] else { return nil }
            return l.compactMap(\.int)
        }
        public var labels: [String]? {
            guard case .list(let l)? = values["labels"] else { return nil }
            return l.map(\.description)
        }
        public var file: String? { values["file"]?.description }
        public var title: String? { values["title"]?.description }
    }

    static let keys: [(name: String, key: String)] = [
        ("type", "plot-type"), ("script", "script"), ("line", "line"), ("set", "set"), ("title", "title"), ("ind", "ind"),
        ("deps", "deps"), ("with", "with"), ("file", "file"), ("labels", "labels"), ("map", "map"), ("timeind", "timeind"),
        ("timefmt", "timefmt"), ("min", "ymin"), ("ymin", "ymin"), ("max", "ymax"), ("ymax", "ymax"), ("xmin", "xmin"),
        ("xmax", "xmax"), ("ticks", "ticks"), ("trans", "transpose"), ("transpose", "transpose"),
    ]

    /// `org-plot/add-options-to-plist`, with its quirks: a key also matches inside a longer
    /// word (`timeind:` sets `ind`), and an unquoted value ends at `.`, `,` or `;`.
    static func add(_ text: String, to options: inout Options) {
        let value = #":("[^"]+?"|\([^)]+?\)|[^ \t\n\r;,.]*)"#
        var start = text.startIndex
        for (name, key) in keys {
            let pattern = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: name) + value)
            if name == "set" || name == "line" {
                while let m = pattern.firstMatch(in: text, range: NSRange(start..<text.endIndex, in: text)) {
                    start = Range(m.range, in: text)!.upperBound
                    let read = Self.read(String(text[Range(m.range(at: 1), in: text)!]))
                    if name == "set" { options.sets.insert(read.description, at: 0) } else { options.lines.insert(read.description, at: 0) }
                }
            } else if let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                options.values[key] = Self.read(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
    }

    /// `read-from-string` of an option's value.
    static func read(_ s: String) -> Value {
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { return .string(String(s.dropFirst().dropLast())) }
        if s.hasPrefix("("), s.hasSuffix(")") {
            let inner = s.dropFirst().dropLast()
            var items: [Value] = []
            for m in inner.matches(of: /"[^"]*"|[^\s"]+/) { items.append(read(String(m.0))) }
            return .list(items)
        }
        if let n = Double(s), s.range(of: "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)(e[-+]?[0-9]+)?$", options: .regularExpression) != nil { return .number(n) }
        return .symbol(s)
    }

    // MARK: - The table

    /// What `org-plot/gnuplot` reads: the options, the header row as labels, and the rows.
    public struct Plot: Sendable, Equatable {
        public var options: Options
        /// Rows of fields; nil for a rule left in the table.
        public var rows: [[String]?]
        public var columns: Int
        /// The ind column holds timestamps (`:timeind`) or text (`:textind`).
        public var timeInd = false
        public var textInd = false
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The plot for the table at `offset`, or the first table after it, with the `#+PLOT`
    /// lines above it.
    public static func plot(_ text: String, at offset: Int) throws -> Plot {
        let buffer = EmacsBuffer(text, point: offset)
        // `org-plot/goto-nearest-table`.
        buffer.point = buffer.lineStart(buffer.point)
        while !buffer.atTable, buffer.forwardLine(1) == 0 {}
        guard buffer.atTable else { throw Failure(description: "No table at point") }
        let begin = buffer.tableBegin()
        var options = Options()
        options.values = ["plot-type": .symbol("2d"), "with": .symbol("lines"), "ind": .number(0)]
        func collect() {
            buffer.point = begin
            while buffer.forwardLine(-1) == 0, buffer.looking("[ \\t]*#\\+", caseInsensitive: false, setsMatch: false) != nil {
                let line = buffer.substring(buffer.point, buffer.lineEnd(buffer.point))
                if let m = line.firstMatch(of: /#\+PLOT: +(.*)$/) { add(String(m.1), to: &options) }
            }
        }
        collect()
        buffer.point = begin
        var table = buffer.tableToLisp()
        if let t = options["transpose"]?.description, ["y", "yes", "t"].contains(t) {
            let rows = table.compactMap { $0 }
            let width = rows.map(\.count).min() ?? 0
            var transposed: [[String]?] = (0..<width).map { c in rows.map { $0[c] } }
            if table.contains(where: { $0 == nil }), !transposed.isEmpty { transposed.insert(nil, at: 1) }
            table = transposed
        }
        let first = table.first.flatMap { $0 } ?? (table.count > 1 ? table[1] : nil)
        let columns = first?.count ?? 0
        guard ["2d", "3d", "grid"].contains(options.type) else {
            throw Failure(description: options.type == "radar" ? "Radar plots need gnuplot" : "Org-plot type `\(options.type)' is undefined")
        }
        if table.count > 1, table[1] == nil, let header = table[0] {
            options.values["labels"] = .list(header.map { .string($0) })
            table = table.dropFirst().filter { $0 != nil }
        }
        collect()
        var plot = Plot(options: options, rows: table, columns: columns)
        if options.type == "2d" {
            let ind = options.ind - 1
            if ind >= 0 {
                let column = table.compactMap { $0 }.map { ind < $0.count ? $0[ind] : "" }
                if column.allSatisfy({ $0.range(of: EmacsBuffer.timestampPattern, options: .regularExpression) != nil }) {
                    plot.timeInd = true
                } else if options.with == "hist" || !column.allSatisfy(isNumber) {
                    plot.textInd = true
                }
            }
        }
        return plot
    }

    /// `org-table-number-regexp`.
    static let numberPattern = "^([<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%:]*|[<>]?[-+]?0[xX][0-9a-fA-F.]+|[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+|nan|[-+u]?inf)$"
    static func isNumber(_ s: String) -> Bool { s.range(of: numberPattern, options: .regularExpression) != nil }

    // MARK: - gnuplot

    /// `org-plot/gnuplot-to-data`: tab-separated fields, numbers as they are, timestamps in
    /// `timefmt`, other text quoted.
    public static func data(_ plot: Plot, calendar: Calendar = .current) -> String {
        let format = plot.options["timefmt"]?.description ?? "%Y-%m-%d-%H:%M:%S"
        return plot.rows.compactMap { $0 }.map { row in
            row.map { field -> String in
                if isNumber(field) { return field }
                if let m = field.firstMatch(of: try! Regex(EmacsBuffer.timestampPattern)),
                   let stamp = Timestamp.parse(String(field[m.range])) {
                    return strftime(format, stamp.start, calendar: calendar)
                }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// `format-time-string` for the escapes timestamps use.
    static func strftime(_ format: String, _ p: Timestamp.Point, calendar: Calendar) -> String {
        var out = ""
        var chars = Array(format)
        var i = 0
        chars.append(" ")
        while i < chars.count - 1 {
            if chars[i] == "%" {
                switch chars[i + 1] {
                case "Y": out += String(format: "%04d", p.year)
                case "m": out += String(format: "%02d", p.month)
                case "d": out += String(format: "%02d", p.day)
                case "H": out += String(format: "%02d", p.hour ?? 0)
                case "M": out += String(format: "%02d", p.minute ?? 0)
                case "S": out += "00"
                case "%": out += "%"
                default: out += "%" + String(chars[i + 1])
                }
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// `org-plot/gnuplot-to-grid-data`: each cell as the four corners gnuplot's `pm3d`
    /// draws, and the ind column's values as y labels.
    public static func gridData(_ plot: Plot) -> (data: String, yLabels: [(Int, String)]) {
        let ind = plot.options.ind - 1
        var rows = plot.rows.compactMap { $0 }
        var labels: [(Int, String)] = []
        if ind >= 0 { labels = rows.enumerated().map { ($0.offset + 1, ind < $0.element.count ? $0.element[ind] : "") } }
        var deps = plot.options.deps.map { $0.map { $0 - 1 } } ?? Array((0..<(rows.first?.count ?? 0)).reversed())
        if ind >= 0 || !deps.isEmpty {
            deps.removeAll { $0 == ind }
            rows = rows.map { row in row.indices.filter(deps.contains).map { row[$0] } }
        }
        var out = ""
        let columns = rows.first?.count ?? 0
        func corners(_ col: Int, _ row: Int, _ value: Double) -> String {
            String(format: "%f  %f  %f\n%f  %f  %f\n", Double(col + 1), Double(row + 1) - 0.5, value, Double(col + 1), Double(row + 1) + 0.5, value)
        }
        for col in 0..<columns {
            var back = "", front = ""
            for (r, row) in rows.enumerated() {
                let value = col < row.count ? stringToNumber(row[col]) : 0
                back += corners(col - 1, r, value)
                front += corners(col, r, value)
            }
            out += back + "\n" + front + "\n"
        }
        return (out, labels)
    }

    /// `string-to-number`: the leading number, else 0.
    static func stringToNumber(_ s: String) -> Double {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard let m = trimmed.firstMatch(of: /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?/) else { return 0 }
        return Double(m.0) ?? 0
    }

    /// `org-plot/gnuplot-script`, with `org-plot/gnuplot-term-extra` and the preamble empty.
    /// `output` is where `file:` goes, expanded. A `preface` leaves out the plot command, for
    /// a `script:` file to follow.
    public static func script(_ plot: Plot, dataFile: String, output: String?, yLabels: [(Int, String)] = [], preface: Bool = false) -> String {
        let o = plot.options
        var script = "reset"
        func add(_ line: String?) { if let line { script += "\n" + line } }
        add("set term \(o.file.map { ($0 as NSString).pathExtension } ?? "GNUTERM") ")
        if let output { add("set output '\(output)'") }
        switch o.type {
        case "3d": if o["map"]?.truthy == true { add("set map") }
        case "grid": add(o["map"]?.truthy == true ? "set pm3d map" : "set map")
        default: break
        }
        add("")
        if let title = o.title { add("set title '\(title)'") }
        for line in o.lines { add(line) }
        for set in o.sets { add("set \(set)") }
        if script.range(of: "(?m)^set datafile separator", options: .regularExpression) == nil { add("set datafile separator \"\\t\"") }
        if !yLabels.isEmpty { add("set ytics (" + yLabels.map { "\"\($0.1)\" \($0.0)" }.joined(separator: ", ") + ")") }
        if o["timeind"]?.truthy == true || plot.timeInd {
            add("set xdata time")
            add("set timefmt \"" + (o["timefmt"]?.description ?? "%Y-%m-%d-%H:%M:%S") + "\"")
        }
        if preface { return script }
        var plotLines: [String] = []
        let with = o.type == "grid" ? "pm3d" : o.with
        switch o.type {
        case "2d":
            let ind = o.ind
            let textInd = plot.textInd || o.with == "histograms"
            for col in 0..<plot.columns {
                if ind == col + 1 || (o.deps.map { !$0.contains(col + 1) } ?? false) { continue }
                let using = ind > 0 && !textInd ? "\(ind):" : ""
                let tic = textInd ? ":xticlabel(\(ind))" : ""
                let label = o.labels.flatMap { col < $0.count ? $0[col] : nil } ?? "\(col + 1)"
                plotLines.append("'\(dataFile)' using \(using)\(col + 1)\(tic) with \(with) title '\(label)'")
            }
            add("plot " + plotLines.joined(separator: ",\\\n    "))
        case "3d":
            add("splot '\(dataFile)' matrix with \(with) title ''")
        default:
            add("splot '\(dataFile)' with \(with) title ''")
        }
        return script
    }

    // MARK: - Values for a chart

    /// A dependent column's points: x as a number, a date or a label, and y.
    public struct Series: Sendable, Equatable {
        public enum X: Sendable, Equatable {
            case number(Double)
            case date(Date)
            case label(String)
        }
        public var label: String
        public var points: [(x: X, y: Double)]
        public static func == (a: Series, b: Series) -> Bool {
            a.label == b.label && a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    /// The 2d plot's series, as the script plots them: one per column but the ind column (or
    /// the deps), against the ind column or the row number.
    public static func series(_ plot: Plot, calendar: Calendar = .current) -> [Series] {
        let o = plot.options
        let rows = plot.rows.compactMap { $0 }
        let ind = o.ind
        var out: [Series] = []
        for col in 0..<plot.columns {
            if ind == col + 1 || (o.deps.map { !$0.contains(col + 1) } ?? false) { continue }
            let label = o.labels.flatMap { col < $0.count ? $0[col] : nil } ?? "\(col + 1)"
            var points: [(Series.X, Double)] = []
            for (r, row) in rows.enumerated() {
                guard col < row.count, isNumber(row[col]), let y = Double(row[col].filter { "0123456789.-+eE".contains($0) }) else { continue }
                let x: Series.X
                if ind > 0, ind - 1 < row.count {
                    let field = row[ind - 1]
                    if plot.timeInd, let m = field.firstMatch(of: try! Regex(EmacsBuffer.timestampPattern)), let stamp = Timestamp.parse(String(field[m.range])) {
                        let p = stamp.start
                        x = .date(calendar.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: p.hour ?? 0, minute: p.minute ?? 0)) ?? Date())
                    } else if plot.textInd || o.with == "histograms" {
                        x = .label(field)
                    } else {
                        x = .number(stringToNumber(field))
                    }
                } else {
                    x = .number(Double(r + 1))
                }
                points.append((x, y))
            }
            out.append(Series(label: label, points: points))
        }
        return out
    }

    /// The 3d and grid plots' matrix: rows of numbers, without the ind column, and the
    /// ind column's values for the rows.
    public static func matrix(_ plot: Plot) -> (values: [[Double]], rowLabels: [String]) {
        let rows = plot.rows.compactMap { $0 }
        if plot.options.type == "3d" { return (rows.map { $0.map(stringToNumber) }, []) }
        let ind = plot.options.ind - 1
        var deps = plot.options.deps.map { $0.map { $0 - 1 } } ?? Array(0..<(rows.first?.count ?? 0))
        deps.removeAll { $0 == ind }
        let values = rows.map { row in row.indices.filter(deps.contains).map { stringToNumber(row[$0]) } }
        return (values, ind >= 0 ? rows.map { ind < $0.count ? $0[ind] : "" } : [])
    }
}
