import Foundation

// Column view (`org-colview.el`, Org 9.8.7): the column format, values and summaries of each
// entry, and the `columnview` dynamic block that captures them.

public enum ColumnView {
    /// One column of `org-columns-compile-format`.
    public struct Spec: Sendable, Equatable {
        public let property: String
        public let title: String
        public let width: Int?
        public let summary: String?
        public let format: String?
    }

    public struct Row: Sendable, Equatable {
        public let level: Int
        /// Start of the heading line.
        public let start: Int
        public let values: [String]
    }

    public struct View: Sendable, Equatable {
        public let specs: [Spec]
        public let rows: [Row]
    }

    public static let defaultFormat = "%25ITEM %TODO %3PRIORITY %TAGS"

    /// `org-columns-compile-format`.
    public static func compile(_ format: String) -> [Spec] {
        format.matches(of: /%([0-9]+)?([A-Za-z0-9_-]+)(?:\(([^)]*)\))?(?:\{([^}]*)\})?\s*/).map { m in
            let property = String(m.2)
            let title = m.3.map(String.init).flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil } ?? property
            var summary = m.4.map(String.init).flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil }
            var fmt: String?
            if let s = summary, let semicolon = s.firstIndex(of: ";") {
                fmt = String(s[s.index(after: semicolon)...])
                summary = String(s[..<semicolon])
            }
            return Spec(property: property.uppercased(), title: title, width: m.1.flatMap { Int($0) }, summary: summary, format: fmt)
        }
    }

    // MARK: - Numbers and durations as Emacs Lisp has them

    /// A number from `string-to-number`: an integer unless the text has a fraction or exponent.
    enum Number {
        case int(Int)
        case float(Double)

        init(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let m = t.prefixMatch(of: /[-+]?[0-9]+(?![.eE0-9])/), let i = Int(m.0) { self = .int(i); return }
            if let m = t.prefixMatch(of: /[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?/), let d = Double(m.0) {
                self = m.0.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? .float(d) : .int(Int(d)); return
            }
            self = .int(0)
        }

        var double: Double {
            switch self {
            case .int(let i): Double(i)
            case .float(let d): d
            }
        }

        /// `format "%s"`.
        var lisp: String {
            switch self {
            case .int(let i): String(i)
            case .float(let d): d.isFinite && d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
            }
        }

        static func + (a: Number, b: Number) -> Number {
            if case .int(let x) = a, case .int(let y) = b { return .int(x + y) }
            return .float(a.double + b.double)
        }
    }

    /// `format FMT` with a number, for the formats summaries use.
    static func format(_ fmt: String?, _ n: Number) -> String {
        guard let fmt else { return n.lisp }
        if fmt.contains("%d") { return String(format: fmt.replacingOccurrences(of: "%d", with: "%ld"), Int(n.double)) }
        if fmt.contains("%s") { return fmt.replacingOccurrences(of: "%s", with: n.lisp) }
        return String(format: fmt, n.double)
    }

    static let unitMinutes: [(String, Double)] = [("min", 1), ("h", 60), ("d", 1440), ("w", 10080), ("m", 43200), ("y", 525960)]

    /// `org-duration-to-minutes`.
    public static func minutes(_ duration: String) -> Double? {
        let s = duration.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        if s.wholeMatch(of: /[0-9]+(?::[0-9]{2}){1,2}/) != nil {
            let parts = s.split(separator: ":").map { Double($0) ?? 0 }
            return parts[0] * 60 + parts[1] + (parts.count > 2 ? parts[2] / 60 : 0)
        }
        let unit = /([0-9]+(?:\.[0-9]*)?)[ \t]*(min|h|d|w|m|y)/
        if s.wholeMatch(of: /(?:[0-9]+(?:\.[0-9]*)?[ \t]*(?:min|h|d|w|m|y)[ \t]*)+/) != nil {
            var total = 0.0
            for m in s.matches(of: unit) {
                let name = String(m.2)
                total += (Double(m.1) ?? 0) * (unitMinutes.first { $0.0 == name }?.1 ?? 0)
            }
            return total
        }
        if let m = s.wholeMatch(of: /((?:[0-9]+(?:\.[0-9]*)?[ \t]*(?:min|h|d|w|m|y)[ \t]*)+)[ \t]*([0-9]+(?::[0-9]{2}){1,2})/) {
            return (minutes(String(m.1)) ?? 0) + (minutes(String(m.2)) ?? 0)
        }
        if s.wholeMatch(of: /[0-9]+(?:\.[0-9]*)?/) != nil { return Double(s) }
        return nil
    }

    /// `org-duration-from-minutes` with `h:mm`, or with nil the default format (days, then
    /// `H:MM`).
    static func duration(_ minutes: Double, hmmOnly: Bool) -> String {
        if minutes < 0 { return "-" + duration(-minutes, hmmOnly: hmmOnly) }
        func hmm(_ m: Double) -> String { String(format: "%d:%02d", Int(m / 60), Int(m.truncatingRemainder(dividingBy: 60))) }
        if hmmOnly || minutes < 1440 { return hmm(minutes) }
        let days = (minutes / 1440).rounded(.down)
        return "\(Int(days))d " + hmm(minutes - days * 1440)
    }

    /// `org-columns--age-to-minutes`: minutes since an active timestamp in `value`, or a duration.
    static func ageMinutes(_ value: String, now: Date, calendar: Calendar) throws -> Double {
        if let range = value.range(of: "<[0-9]{4}-[0-9]{2}-[0-9]{2}(?: .*?)?>", options: .regularExpression) {
            guard let stamp = EmacsBuffer.parseTimeString(String(value[range])), let date = calendar.date(from: stamp) else {
                throw EmacsBuffer.UserError(message: "Invalid age: \"\(value)\"")
            }
            return now.timeIntervalSince(date) / 60
        }
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty, let minutes = minutes(value) else {
            throw EmacsBuffer.UserError(message: "Invalid age: \"\(value)\"")
        }
        return minutes
    }

    /// `org-columns--format-age`: days, hours and minutes, those that aren't zero.
    static func age(_ minutes: Double) -> String {
        if minutes < 0 { return "-" + age(-minutes) }
        var left = minutes
        var parts: [String] = []
        for (unit, modifier) in [("d", 1440.0), ("h", 60.0), ("min", 1.0)] where modifier <= left {
            let value = (left / modifier).rounded(.down)
            left -= value * modifier
            parts.append("\(Int(value))\(unit)")
        }
        return parts.isEmpty ? "0min" : parts.joined(separator: " ")
    }

    /// `org-columns--summarize`: nil for an unknown operator.
    static func summarize(_ op: String, _ values: [String], fmt: String?, now: Date, calendar: Calendar = .current) throws -> String? {
        let numbers = values.map(Number.init)
        switch op {
        case "@min", "@max", "@mean":
            let ages = try values.map { try ageMinutes($0, now: now, calendar: calendar) }
            return age(op == "@min" ? ages.min()! : op == "@max" ? ages.max()! : ages.reduce(0, +) / Double(ages.count))
        case "+": return format(fmt, numbers.reduce(.int(0), +))
        case "$": return String(format: "%.2f", numbers.reduce(0) { $0 + $1.double })
        case "X":
            let done = values.filter { $0 == "[X]" }.count
            return done == values.count ? "[X]" : done > 0 ? "[-]" : "[ ]"
        case "X/":
            let done = values.filter { $0 == "[X]" || $0.firstMatch(of: /\[([1-9])\/\1\]/) != nil }.count
            return "[\(done)/\(values.count)]"
        case "X%":
            let done = values.filter { $0 == "[X]" || $0 == "[100%]" }.count
            return "[\(Int((100.0 * Double(done) / Double(values.count)).rounded()))%]"
        case "min", "max":
            var best = numbers[0]
            for n in numbers.dropFirst() where op == "min" ? n.double < best.double : n.double > best.double { best = n }
            return format(fmt, best)
        case "mean": return format(fmt, .float(numbers.reduce(0) { $0 + $1.double } / Double(numbers.count)))
        case ":", ":min", ":max", ":mean":
            let times = values.compactMap(minutes)
            guard !times.isEmpty else { return nil }
            let hmmOnly = values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).wholeMatch(of: /[0-9]+(?::[0-9]{2}){1,2}/) != nil }
            let result: Double = switch op {
            case ":": times.reduce(0, +)
            case ":min": times.min()!
            case ":max": times.max()!
            default: times.reduce(0, +) / Double(times.count)
            }
            return duration(result, hmmOnly: hmmOnly)
        case "est+":
            var mean = 0.0, variance = 0.0
            for e in values {
                let parts = e.split(separator: "-", omittingEmptySubsequences: false).map { Number(String($0)).double }
                if parts.count == 2 {
                    let m = (parts[0] + parts[1]) / 2
                    mean += m
                    variance += (parts[0] * parts[0] + parts[1] * parts[1]) / 2 - m * m
                } else if let v = parts.first {
                    mean += v
                }
            }
            let sd = variance.squareRoot()
            return String(format: "%.0f-%.0f", mean - sd, mean + sd)
        default: return nil
        }
    }

    // MARK: - Values

    static let specials: Set<String> = PropertyValues.special.union(["CATEGORY"])

    /// `org-entry-get` with `selective` inheritance, and the special properties column view
    /// shows.
    static func value(_ property: String, heading index: Int, model: DocumentModel, text: NSString, clocksum: [Int: Int]) -> String {
        let h = model.headings[index]
        switch property {
        case "ITEM": return h.title.replacingOccurrences(of: "\t", with: "        ")
        case "TODO": return h.todo ?? ""
        case "PRIORITY": return h.priority ?? model.orgSettings.priorities.default
        case "TAGS": return h.localTags.isEmpty ? "" : ":" + h.localTags.joined(separator: ":") + ":"
        case "ALLTAGS":
            let tags = model.ancestors(of: index).flatMap { model.headings[$0].localTags } + h.localTags
            var seen: Set<String> = []
            let all = (model.fileTags + tags).filter { seen.insert($0).inserted }
            return all.isEmpty ? "" : ":" + all.joined(separator: ":") + ":"
        case "DEADLINE", "SCHEDULED", "CLOSED":
            // From the planning line under the heading.
            let next = NSMaxRange(text.lineRange(for: NSRange(location: h.headingRange.lowerBound, length: 0)))
            guard next < text.length else { return "" }
            let line = text.substring(with: text.lineRange(for: NSRange(location: next, length: 0)))
            guard line.range(of: "^[ \\t]*(?:SCHEDULED|DEADLINE|CLOSED):", options: .regularExpression) != nil,
                  let m = line.range(of: property + ": *(<[^>\\n]+>|\\[[^\\]\\n]+\\])", options: .regularExpression) else { return "" }
            return String(line[m]).replacingOccurrences(of: "^" + property + ": *", with: "", options: .regularExpression)
        case "CLOCKSUM": return clocksum[index].map { ClockTable.duration($0) } ?? ""
        default:
            return model.property(property, of: index)?.value ?? ""
        }
    }

    /// `org-columns--displayed-value` without the stars on ITEM.
    static func displayed(_ spec: Spec, _ value: String) -> String {
        switch spec.property {
        case "ITEM": return value
        case "DEADLINE", "SCHEDULED", "TIMESTAMP": return value.replacingOccurrences(of: "<([^>]*)>", with: "[$1]", options: .regularExpression)
        default: return spec.format.map { format($0, Number(value)) } ?? value
        }
    }

    // MARK: - The view

    /// `org-columns` and `org-columns--capture-view` at `offset`: the format, the entries from the
    /// top level (the first ancestor with COLUMNS, else the entry; the file before the first
    /// heading or with `global`), their values with summaries. `updates` are the parents whose
    /// summarized property org rewrites.
    /// Throws for an age operator's value that is neither a timestamp nor a duration.
    public static func capture(text: String, tree: OrgTree, at offset: Int, global: Bool, format override: String? = nil,
                               maxLevel: Int? = nil, skipEmpty: Bool = false, excludeTags: [String] = [], now: Date = Date(),
                               calendar: Calendar = .current) throws
        -> (view: View, updates: [(start: Int, property: String, value: String)]) {
        let model = DocumentModel(tree: tree)
        let ns = text as NSString
        let headings = model.headings
        let here = global ? nil : headings.lastIndex { $0.headingRange.lowerBound <= offset }
        // The top level and the format.
        var top: Int?
        var format = override
        if let here {
            for h in [here] + model.ancestors(of: here).reversed() {
                if let columns = headings[h].properties.last(where: { $0.key.uppercased() == "COLUMNS" }) {
                    top = h
                    if format == nil { format = columns.value }
                    break
                }
            }
            if top == nil { top = here }
        }
        if format == nil, let keyword = (tree.settings.setupKeywords + text).firstMatch(of: #/(?mi)^[ \t]*#\+COLUMNS:[ \t]+(.+?)[ \t]*$/#) { format = String(keyword.1) }
        let specs = compile(format ?? defaultFormat)
        // The entries in scope, without archived or commented subtrees.
        var scope: [Int] = []
        let end: Int = top.map { t in headings[(t + 1)...].firstIndex { $0.level <= headings[t].level } ?? headings.count } ?? headings.count
        var skipBelow: Int?
        for i in (top ?? 0)..<end {
            if let level = skipBelow, headings[i].level > level { continue }
            skipBelow = nil
            let title = headings[i].title
            if headings[i].localTags.contains("ARCHIVE") || title == "COMMENT" || title.hasPrefix("COMMENT ") {
                skipBelow = headings[i].level
                continue
            }
            scope.append(i)
        }
        // Clocked minutes per subtree, as `org-clock-sum`.
        var clocksum: [Int: Int] = [:]
        if specs.contains(where: { $0.property == "CLOCKSUM" }) {
            for i in headings.indices {
                let own = headings[i].clocks.compactMap(\.minutes).reduce(0, +)
                guard own > 0 else { continue }
                for h in [i] + model.ancestors(of: i) { clocksum[h, default: 0] += own }
            }
        }
        // Summaries, bottom up through the whole top-level subtree.
        var summaries: [Int: [Int: String]] = [:]
        var updates: [(Int, String, String)] = []
        var seen: Set<String> = []
        for (column, spec) in specs.enumerated() {
            let first = seen.insert(spec.property).inserted
            guard let op = spec.summary, !PropertyValues.special.contains(spec.property) else { continue }
            var accumulators = [[String]](repeating: [], count: 31)
            var level = 0
            var lastLevel = 30
            for i in ((top ?? 0)..<end).reversed() {
                if level != 0 { lastLevel = level }
                level = min(30, headings[i].level)
                let own = headings[i].properties.last { $0.key.uppercased() == spec.property }?.value
                let set = own.map { $0.contains { !$0.isWhitespace } } ?? false
                if level < lastLevel {
                    let below = accumulators[(level + 1)...].flatMap { $0 }
                    let summary = below.isEmpty ? nil : try summarize(op, below, fmt: spec.format, now: now, calendar: calendar)
                    if let summary {
                        summaries[i, default: [:]][column] = summary
                        let trimmed = summary.trimmingCharacters(in: .whitespaces)
                        if first, let own, own != trimmed { updates.append((headings[i].headingRange.lowerBound, spec.property, trimmed)) }
                    }
                    if let value = summary ?? (set ? own : nil) { accumulators[level].append(value) }
                    for l in (level + 1)...30 { accumulators[l] = [] }
                } else if set, let own {
                    accumulators[level].append(own)
                }
            }
        }
        // Rows.
        var rows: [Row] = []
        for i in scope {
            let level = headings[i].level
            if let maxLevel, level > maxLevel { continue }
            let values = specs.enumerated().map { column, spec -> String in
                let raw = summaries[i]?[column] ?? value(spec.property, heading: i, model: model, text: ns, clocksum: clocksum)
                return displayed(spec, raw)
            }
            if skipEmpty {
                let others = Set(zip(specs, values).filter { $0.0.property != "ITEM" }.map(\.1)).subtracting([""])
                if others.isEmpty { continue }
            }
            if !excludeTags.isEmpty {
                let tags = model.ancestors(of: i).flatMap { headings[$0].localTags } + headings[i].localTags + model.fileTags
                if tags.contains(where: excludeTags.contains) { continue }
            }
            rows.append(Row(level: level, start: headings[i].headingRange.lowerBound, values: values))
        }
        return (View(specs: specs, rows: rows), updates)
    }

    /// `org-columns--clean-item`: no footnote references, targets, statistics cookies or inline
    /// source blocks, and `|` as `\vert`.
    static func cleanItem(_ item: String) -> String {
        var s = item
        s = s.replacingOccurrences(of: "\\[fn:[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<<<?([^<>]*)>>>?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[0-9]*(?:%|/[0-9]*)\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "src_[^\\s{\\[]+(?:\\[[^\\]]*\\])?\\{[^}]*\\}", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\vert")
    }

    /// `org-columns-dblock-write-default`'s rows, before alignment.
    static func dblockTable(_ view: View, hlines: Int?, hlinesAll: Bool, indent: Bool) -> [[String]?] {
        var table: [[String]?] = [view.specs.map(\.title), nil]
        let item = view.specs.firstIndex { $0.property == "ITEM" }
        for row in view.rows {
            if table.last! != nil, hlinesAll || hlines.map({ row.level <= $0 }) == true { table.append(nil) }
            var values = row.values
            if let item {
                let cleaned = cleanItem(values[item])
                values[item] = indent && row.level > 1 ? "\\_" + String(repeating: " ", count: 2 * (row.level - 1)) + cleaned : cleaned
            }
            table.append(values)
        }
        if view.specs.contains(where: { $0.width != nil }) {
            table.insert(view.specs.map { $0.width.map { "<\($0)>" } ?? "" }, at: 0)
        }
        return table
    }
}

extension EmacsBuffer {
    /// `org-dblock-write:columnview` and the default writer, at point (the line after #+BEGIN).
    func writeColumnView(_ params: ClockTable.Params, at begin: Int, content: String, tree: OrgTree) throws -> String {
        let id = params.values[":id"]
        var offset = begin
        var global = false
        if let id {
            switch id.symbol ?? id.string ?? "" {
            case "global": global = true
            case "local", "nil", "": break
            case let value:
                if value.hasPrefix("file:") { throw UserError(message: "Column views of other files aren't supported yet") }
                guard let match = searchForwardFromStart("^[ \\t]*:ID:[ \\t]+" + NSRegularExpression.escapedPattern(for: value) + "[ \\t]*$") else {
                    throw UserError(message: "Cannot find entry with :ID: \(value)")
                }
                offset = match
            }
        }
        let hlines = params.values[":hlines"]
        let excluded = params.values[":exclude-tags"]?.elements?.compactMap { $0.string ?? $0.symbol } ?? []
        let captured = try ColumnView.capture(text: string, tree: tree, at: offset, global: global, format: params.values[":format"]?.string,
                                              maxLevel: params.int(":maxlevel"), skipEmpty: params.flag(":skip-empty-rows"),
                                              excludeTags: excluded, now: now, calendar: calendar)
        for update in captured.updates.sorted(by: { $0.start > $1.start }) {
            point = update.start
            entryPut(update.property, update.value)
        }
        let table = ColumnView.dblockTable(captured.view, hlines: hlines?.integer, hlinesAll: hlines?.symbol == "t",
                                           indent: params.flag(":indent"))
        var lines = table.map { row in row.map { "|" + $0.joined(separator: "|") + "|" } ?? "|-|" }
        for line in content.split(separator: "\n") where line.range(of: "^[ \\t]*#\\+TBLFM:", options: [.regularExpression, .caseInsensitive]) != nil {
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\n")
    }

    private func searchForwardFromStart(_ pattern: String) -> Int? {
        saveExcursion {
            point = 0
            return searchForward(pattern, caseInsensitive: true)?[0]?.lowerBound
        }
    }
}
