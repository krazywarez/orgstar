import Foundation

// Clock tables (org-clock.el, Org 9.8.7): the `clocktable` dynamic block written by
// `org-clocktable-write-default` from `org-clock-get-table-data` and `org-clock-sum`, updated
// by `org-update-dblock` (C-c C-c on its #+BEGIN line, C-c C-x C-u) and inserted by
// `org-clock-report` (C-c C-x C-r), with `org-clocktable-defaults` and `org-duration-format`
// ((\"d\" . nil) (special . h:mm)). Scopes within the file (file, subtree, tree, treeN), the
// agenda files, archives and lists of files, `:match`, and `:step`. Other files are read from
// disk. `:formatter` and scopes given as functions aren't supported.

enum ClockTable {
    struct Params {
        var values: [String: Sexp] = [:]

        func symbol(_ key: String) -> String? { values[key]?.symbol ?? values[key]?.string }
        func flag(_ key: String) -> Bool { values[key].map { $0.symbol != "nil" } ?? false }
        func int(_ key: String) -> Int? { values[key]?.integer }

        /// `org-clocktable-defaults` under the block's own.
        static let defaults: [String: Sexp] = [
            ":maxlevel": .integer(2), ":scope": .symbol("file"), ":wstart": .integer(1), ":mstart": .integer(1),
            ":narrow": .symbol("40!"), ":indent": .symbol("t"), ":lang": .string("en"),
        ]

        init(_ line: String, defaults: [String: Sexp] = Self.defaults) throws {
            values = defaults
            let forms = try LispReader.read("(" + line + ")")
            let items = forms.first?.sexp.elements ?? []
            var i = 0
            while i + 1 < items.count {
                if let key = items[i].symbol, key.hasPrefix(":") { values[key] = items[i + 1] }
                i += 2
            }
        }
    }

    struct Row {
        let level: Int
        let headline: String
        let tags: [String]
        let minutes: Int
        let properties: [String: String]
    }

    /// `org-duration-from-minutes` with the default format: `H:MM`, days as `Nd ` before it.
    static func duration(_ minutes: Int) -> String {
        let days = minutes / 1440
        let rest = minutes % 1440
        let hm = String(format: "%d:%02d", rest / 60, rest % 60)
        return days > 0 ? "\(days)d " + hm : hm
    }

    /// `org-clock-special-range` for `:block`: the start and end in seconds, and the caption's
    /// text.
    static func range(_ block: String, now: Date, calendar: Calendar, wstart: Int, mstart: Int) throws -> (Double, Double, String) {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        var key = block
        var shift = 0
        var y = c.year!, month = c.month!, d = c.day!
        // `decode-time`'s day of week: Sunday 0.
        var dow = c.weekday! - 1
        if let m = block.wholeMatch(of: /([0-9]+)/) {
            y = Int(m.1)!; month = 1; d = 1; key = "year"
        } else if let m = block.wholeMatch(of: /([0-9]+)-([0-9]{1,2})/) {
            y = Int(m.1)!; month = Int(m.2)!; d = 1; key = "month"
        } else if let m = block.wholeMatch(of: /([0-9]+)-[wW]([0-9]{1,2})/) {
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let date = iso.date(from: DateComponents(weekday: 2, weekOfYear: Int(m.2)!, yearForWeekOfYear: Int(m.1)!))!
            let g = calendar.dateComponents([.year, .month, .day], from: date)
            y = g.year!; month = g.month!; d = g.day!; dow = 1; key = "week"
        } else if let m = block.wholeMatch(of: /([0-9]+)-([0-9]{1,2})-([0-9]{1,2})/) {
            y = Int(m.1)!; month = Int(m.2)!; d = Int(m.3)!; key = "day"
        } else if let m = block.firstMatch(of: /([-+][0-9]+)$/) {
            shift = Int(m.1.replacingOccurrences(of: "+", with: ""))!
            key = String(block[..<m.range.lowerBound])
        }
        if shift == 0 {
            switch key {
            case "yesterday": key = "today"; shift = -1
            case "lastweek": key = "week"; shift = -1
            case "lastmonth": key = "month"; shift = -1
            case "lastyear": key = "year"; shift = -1
            default: break
            }
        }
        var start = DateComponents(year: y, month: month, day: d, hour: 0, minute: 0)
        var end = start
        let text: String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        switch key {
        case "day", "today":
            start.day = d + shift
            end = start
            end.hour = 24
            formatter.dateFormat = "EEEE, MMMM dd, yyyy"
            text = formatter.string(from: calendar.date(from: start)!)
        case "week", "thisweek":
            let diff = -7 * shift + ((dow + 7 - wstart) % 7 + 7) % 7
            start.day = d - diff
            end = start
            end.day = start.day! + 7
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let s = calendar.date(from: start)!
            text = String(format: "week %04d-W%02d", iso.component(.yearForWeekOfYear, from: s), iso.component(.weekOfYear, from: s))
        case "month", "thismonth":
            start.day = mstart
            start.month = month + shift
            end = start
            end.month = start.month! + 1
            formatter.dateFormat = "MMMM yyyy"
            text = formatter.string(from: calendar.date(from: start)!)
        case "year", "thisyear":
            start.day = 1
            start.month = 1
            start.year = y + shift
            end = start
            end.year = start.year! + 1
            text = "the year \(start.year!)"
        default:
            throw EmacsBuffer.UserError(message: "No such time block \(block)")
        }
        return (calendar.date(from: start)!.timeIntervalSince1970, calendar.date(from: end)!.timeIntervalSince1970, text)
    }

    static let clockRange = try! NSRegularExpression(pattern:
        "^[ \\t]*CLOCK:[ \\t]*\\[([0-9]{4})-([0-9]{2})-([0-9]{2})[^\\]\\n]*? ([0-9]{1,2}):([0-9]{2})\\]-+\\[([0-9]{4})-([0-9]{2})-([0-9]{2})[^\\]\\n]*? ([0-9]{1,2}):([0-9]{2})\\]",
        options: .anchorsMatchLines)
    static let nakedClock = try! NSRegularExpression(pattern: "^[ \\t]*CLOCK:[ \\t]*=>[ \\t]+([0-9]+):([0-9]+)", options: .anchorsMatchLines)

    /// `org-clock-sum` over `region`: the minutes of each heading with its subtree's, and the
    /// total. With `include`, headings it rejects add none of their own time, though their
    /// ancestors still show the time of included descendants.
    static func sum(_ text: String, region: Range<Int>, tstart: Double?, tend: Double?, calendar: Calendar,
                    include: ((Int) -> Bool)? = nil) -> (rows: [(start: Int, level: Int, minutes: Int)], total: Int) {
        let ns = text as NSString
        let range = NSRange(region)
        func seconds(_ m: NSTextCheckingResult, _ first: Int) -> Double {
            let parts = (first..<(first + 5)).map { Int(ns.substring(with: m.range(at: $0)))! }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!.timeIntervalSince1970
        }
        // Clock lines and headings, scanned from the end as Org does.
        enum Mark { case heading(level: Int), clock(Int) }
        var marks: [(offset: Int, mark: Mark)] = []
        for m in headingLine.matches(in: text, range: range) { marks.append((m.range.location, .heading(level: m.range(at: 1).length))) }
        for m in clockRange.matches(in: text, range: range) {
            let ts = seconds(m, 1)
            let te = seconds(m, 6)
            let dt = (tend.map { min(te, $0) } ?? te) - (tstart.map { max(ts, $0) } ?? ts)
            marks.append((m.range.location, .clock(dt > 0 ? Int(floor(dt / 60)) : 0)))
        }
        for m in nakedClock.matches(in: text, range: range) {
            marks.append((m.range.location, .clock(Int(ns.substring(with: m.range(at: 1)))! * 60 + Int(ns.substring(with: m.range(at: 2)))!)))
        }
        marks.sort { $0.offset > $1.offset }
        var ltimes = [Int](repeating: 0, count: 30)
        var t1 = 0
        var forced: Set<Int> = []
        var rows: [(Int, Int, Int)] = []
        let ordered: [(start: Int, level: Int)] = marks.reversed().compactMap { mark in
            if case .heading(let level) = mark.mark { return (mark.offset, level) }
            return nil
        }
        for (offset, mark) in marks {
            switch mark {
            case .clock(let minutes): t1 += minutes
            case .heading(let level):
                while level >= ltimes.count { ltimes += [Int](repeating: 0, count: ltimes.count) }
                let included = include?(offset) ?? true
                if t1 > 0 || ltimes[level] > 0 {
                    if included || forced.contains(offset) {
                        if included { for l in 0...level { ltimes[l] += t1 } }
                        rows.append((offset, level, ltimes[level]))
                        if include != nil {
                            // `org-clock-force-headline-inclusion` on the ancestors.
                            var current = level
                            for heading in ordered.reversed() where heading.start < offset && heading.level < current {
                                forced.insert(heading.start)
                                current = heading.level
                            }
                        }
                    }
                    t1 = 0
                    for l in level..<ltimes.count { ltimes[l] = 0 }
                }
            }
        }
        return (rows.reversed().map { (start: $0.0, level: $0.1, minutes: $0.2) }, ltimes[0])
    }

    static let headingLine = try! NSRegularExpression(pattern: "^(\\*+)[ \\t]", options: .anchorsMatchLines)

    /// `org-shorten-string`.
    static func shorten(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let n = Swift.max(max - 4, 1)
        if let m = s.firstMatch(of: try! Regex("^(.{1,\(n)}[^ ])( |$)")) {
            return String(m.output[1].substring!) + "..."
        }
        return String(s.prefix(Swift.max(max - 3, 0))) + "..."
    }

    /// What `org-clock-get-table-data` gives for one file: its name, its total and its rows.
    struct FileTable {
        let path: String?
        let total: Int
        let rows: [Row]
    }

    /// `org-clock-get-table-data` over `region` of `buffer`, the file at `path`, between
    /// `tstart` and `tend` (seconds).
    static func tableData(_ buffer: EmacsBuffer, path: String?, params: Params, region: Range<Int>, tstart: Double?, tend: Double?) -> FileTable {
        let maxlevel = params.int(":maxlevel") ?? 3
        let link = params.flag(":link")
        let showTags = params.flag(":tags")
        let properties = params.values[":properties"]?.elements?.compactMap(\.string) ?? []
        let text = buffer.string
        // `:match`: a tags/property/TODO match each heading's own time must pass.
        var include: ((Int) -> Bool)?
        if let match = params.values[":match"]?.string {
            let matcher = TagsMatcher(match)
            let source = AgendaSource(path: path ?? "", text: text, defaults: buffer.settings, checksBlocking: false)
            let byStart = Dictionary(source.headings.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
            let now = buffer.now, calendar = buffer.calendar
            include = { start in byStart[start].map { matcher.matches($0, in: source, now: now, calendar: calendar) } ?? false }
        }
        let summed = sum(text, region: region, tstart: tstart, tend: tend, calendar: buffer.calendar, include: include)
        var rows: [Row] = []
        for entry in summed.rows where entry.minutes > 0 && entry.level <= maxlevel {
            buffer.point = entry.start
            guard let match = buffer.lookingAt(buffer.complexHeadingPattern) else { continue }
            var title = match[4].map { buffer.substring($0.lowerBound, $0.upperBound) } ?? ""
            if title == "COMMENT" { title = "" } else if title.hasPrefix("COMMENT ") { title = String(title.dropFirst(8)) }
            var headline = title
            if link {
                let search = "*" + Links.normalize(title, context: false)
                let description = Links.displayFormat(title.replacingOccurrences(of: "\\[[0-9]*(?:%|/[0-9]*)\\]", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespaces)
                headline = Links.makeString(path.map { "file:\($0)::" + search } ?? search, description)
            }
            // `org-get-tags`: inherited ones first.
            let own = buffer.tags()
            let tags = showTags ? own.inherited + own.local : []
            var props: [String: String] = [:]
            for name in properties {
                if let line = buffer.saveExcursion({ () -> [Range<Int>?]? in
                    let end = buffer.saveExcursion { () -> Int in Capture.nextHeading(buffer); return buffer.point }
                    return buffer.searchForward("^[ \\t]*:" + NSRegularExpression.escapedPattern(for: name) + ":[ \\t]+(.*?)[ \\t]*$", bound: end, caseInsensitive: true)
                }), let value = line[1] {
                    props[name] = buffer.substring(value.lowerBound, value.upperBound)
                }
            }
            rows.append(Row(level: entry.level, headline: headline, tags: tags, minutes: entry.minutes, properties: props))
        }
        return FileTable(path: path, total: summed.total, rows: rows)
    }

    /// The `:block`, or `:tstart` and `:tend`, as seconds, with the block's caption text.
    static func timeRange(_ params: Params, now: Date, calendar: Calendar) throws -> (start: Double?, end: Double?, text: String?) {
        if let block = params.symbol(":block") ?? params.values[":block"]?.integer.map(String.init), block != "nil" {
            let r = try range(block, now: now, calendar: calendar, wstart: params.int(":wstart") ?? 1, mstart: params.int(":mstart") ?? 1)
            return (r.0, r.1, r.2)
        }
        let start = params.values[":tstart"]?.string.map { TagsMatcher.matcherTime($0, now: now, calendar: calendar) }
        let end = params.values[":tend"]?.string.map { TagsMatcher.matcherTime($0, now: now, calendar: calendar) }
        return (start, end, nil)
    }

    /// The table `org-clocktable-write-default` writes for `tables`, without its final
    /// newline. `multifile` adds the File column and a row per file.
    static func write(_ buffer: EmacsBuffer, params: Params, tables: [FileTable], multifile: Bool, rangeText: String?, content: String) throws -> String {
        let maxlevel = params.int(":maxlevel") ?? 3
        let emph = params.flag(":emphasize")
        let link = params.flag(":link")
        let compact = params.flag(":compact")
        let showLevel = !compact && params.flag(":level")
        let showTags = params.flag(":tags")
        let indent = compact || params.flag(":indent")
        let percent = params.values[":formula"]?.symbol == "%"
        let properties = params.values[":properties"]?.elements?.compactMap(\.string) ?? []
        var narrow: Int?
        var narrowCut = false
        if let value = params.values[":narrow"] {
            if let n = value.integer { narrow = n }
            else if let s = value.symbol, let m = s.wholeMatch(of: /([0-9]+)!/) { narrow = Int(m.1); narrowCut = true }
            else if value.symbol != "nil" { throw EmacsBuffer.UserError(message: "Invalid value \(value.description) of :narrow property in clock table") }
        }
        if compact, narrow == nil { narrow = 40; narrowCut = true }
        if let n = narrow, !narrowCut, link { narrow = n; narrowCut = true }

        let total = tables.reduce(0) { $0 + $1.total }
        let levels = tables.filter { $0.total != 0 }.flatMap { $0.rows.map(\.level) }
        let columns = compact || maxlevel < 2 ? 1 : min(maxlevel, params.int(":tcolumns") ?? 100, levels.max() ?? 1)
        let file = multifile ? "|" : ""

        var out: String
        if let header = params.values[":header"]?.string {
            out = header
        } else {
            let stamp = buffer.formatTimestamp(buffer.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: buffer.now), withTime: true, inactive: true)
            out = "#+CAPTION: Clock summary at \(stamp)\(rangeText.map { ", for \($0)." } ?? "")\n"
        }
        if let narrow, !narrowCut {
            out += "|" + file + (showLevel ? "|" : "") + (showTags ? "|" : "") + String(repeating: "|", count: properties.count) + "<\(narrow)>| |\n"
        }
        out += "|" + (multifile ? "File|" : "") + (showLevel ? "L|" : "") + (showTags ? "Tags |" : "") + properties.map { $0 + "|" }.joined()
            + "Headline|Time|" + String(repeating: "|", count: max(0, columns - 1)) + (percent ? "%|\n" : "\n")
        out += "|-\n|" + (multifile ? "| ALL " : "") + (showLevel ? "|" : "") + (showTags ? "|" : "") + String(repeating: "|", count: properties.count)
            + "*Total time*| *\(duration(total))*|" + String(repeating: "|", count: max(0, columns - 1))
            + (percent ? (total == 0 ? "0.0|" : "100.0|") : "") + "\n"
        if total > 0 {
            for table in tables where table.total > 0 || !params.flag(":fileskip0") {
                out += "|-\n"
                if multifile {
                    let name = table.path.map { path in
                        (params.flag(":filetitle") ? Self.title(path) : nil) ?? (path as NSString).lastPathComponent
                    } ?? ""
                    out += "| \(name) " + (showLevel ? "| " : "") + "| " + (showTags ? "| " : "") + String(repeating: "|", count: properties.count)
                        + "*File time* | *\(duration(table.total))*|" + String(repeating: "|", count: max(0, columns - 1))
                        + (percent ? String(format: " %.1f |", 100 * Double(table.total) / Double(total)) : "") + "\n"
                }
                guard maxlevel > 0 else { continue }
                for row in table.rows {
                    var headline = row.headline
                    if narrowCut, let narrow {
                        if let m = headline.wholeMatch(of: /\[\[(.+?)\]\[(.+)\]\]/) {
                            headline = "[[\(m.1)][\(shorten(String(m.2), narrow))]]"
                        } else {
                            headline = shorten(headline, narrow)
                        }
                    }
                    func field(_ f: String) -> String {
                        guard emph else { return f + " |" }
                        return row.level == 1 ? "*\(f)* |" : row.level == 2 ? "/\(f)/ |" : f + " |"
                    }
                    out += "|" + file + (showLevel ? "\(row.level)|" : "") + (showTags ? row.tags.joined(separator: ", ") + "|" : "")
                        + properties.map { (row.properties[$0] ?? "") + "|" }.joined()
                        + (indent && row.level > 1 ? "\\_" + String(repeating: " ", count: 2 * (row.level - 1)) : "")
                        + field(headline) + String(repeating: "|", count: max(0, min(columns, row.level) - 1))
                        + field(duration(row.minutes)) + String(repeating: "|", count: max(0, columns - row.level))
                        + (percent ? String(format: "%.1f |", 100 * Double(row.minutes) / Double(total)) : "") + "\n"
                }
            }
        }
        out.removeLast()
        if !percent, params.values[":formula"].map({ $0.symbol != "nil" }) ?? false {
            if let formula = params.values[":formula"]?.string { out += "\n#+TBLFM: " + formula }
        } else if let tblfm = content.range(of: "(?m)^[ \\t]*#\\+tblfm:.*", options: [.regularExpression, .caseInsensitive]) {
            out += "\n" + content[tblfm]
        }
        return out
    }

    /// `org-get-title` of the file at `path`.
    static func title(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let titles = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "^#\\+(?i:title):[ \\t]*", options: .regularExpression) else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return titles.isEmpty ? nil : titles.joined(separator: " ")
    }
}

extension EmacsBuffer {
    /// `org-dblock-start-re` on point's line.
    static let dblockStart = "^[ \\t]*#\\+(?:BEGIN|begin):[ \\t]+(\\S+)([ \\t]+(.*))?"

    /// The dynamic block whose lines hold point: its #+BEGIN line's start.
    func dynamicBlockStart() -> Int? {
        saveExcursion {
            let origin = point
            point = lineEnd(point)
            guard let begin = searchBackward(Self.dblockStart, caseInsensitive: false)?[0]?.lowerBound else { return nil }
            point = lineEnd(begin)
            guard let end = searchForward("^[ \\t]*#\\+(?:END|end):?", caseInsensitive: false)?[0] else { return nil }
            return origin <= lineEnd(end.lowerBound) ? begin : nil
        }
    }

    /// `org-update-dblock` for a clock table at `begin`.
    func updateDynamicBlock(at begin: Int) throws {
        point = begin
        guard let start = lookingAt(Self.dblockStart) else { throw UserError(message: "Not at a dynamic block") }
        let name = start[1].map { substring($0.lowerBound, $0.upperBound) } ?? ""
        let paramText = start[3].map { substring($0.lowerBound, $0.upperBound) } ?? ""
        let deleteFrom = start[0]!.upperBound + 1
        point = start[0]!.upperBound
        guard let end = searchForward("^[ \\t]*#\\+(?:END|end):?", caseInsensitive: false)?[0] else { throw UserError(message: "Dynamic block not terminated") }
        let content = substring(min(deleteFrom, end.lowerBound), end.lowerBound)
        if name == "columnview" {
            let params = try ClockTable.Params(paramText, defaults: [:])
            let mark = marker(begin)
            defer { release(mark) }
            let table = try writeColumnView(params, at: begin, content: content, tree: OrgParser.parse(string))
            try replaceDynamicBlockContent(at: mark.position, with: table, recalculate: table.range(of: "(?mi)^[ \\t]*#\\+TBLFM:", options: .regularExpression) != nil)
            return
        }
        guard name == "clocktable" else { throw UserError(message: "Dynamic blocks named \(name) aren't supported") }
        let params = try ClockTable.Params(paramText)
        let range = try ClockTable.timeRange(params, now: now, calendar: calendar)
        if let step = params.symbol(":step"), step != "nil" {
            let table = try clockTableSteps(step, params: params, begin: begin, range: range, content: content)
            try replaceDynamicBlockContent(at: begin, with: table, alignAll: true)
            return
        }
        let tables = try clockTables(params, begin: begin, tstart: range.start, tend: range.end)
        let table = try ClockTable.write(self, params: params, tables: tables.tables, multifile: tables.multifile, rangeText: range.text, content: content)
        try replaceDynamicBlockContent(at: begin, with: table)
    }

    /// The files `:scope` names and each one's table data, and whether the table gets a File
    /// column, as `org-dblock-write:clocktable` works them out.
    func clockTables(_ params: ClockTable.Params, begin: Int, tstart: Double?, tend: Double?) throws -> (tables: [ClockTable.FileTable], multifile: Bool) {
        let path = options.filePath
        func read(_ file: String) -> String? {
            file == path ? string : (try? String(contentsOfFile: file, encoding: .utf8))
        }
        let files: [String]?
        let scopeValue = params.values[":scope"] ?? .symbol("file")
        let scope = scopeValue.symbol ?? scopeValue.string ?? ""
        if let list = scopeValue.elements, scopeValue.symbol == nil {
            // A list of files; folders give their org files, as agenda entries do.
            let base = path.map { ($0 as NSString).deletingLastPathComponent }
            var expanded: [String] = []
            for item in list {
                guard let name = item.string else { throw UserError(message: "Unknown scope: \(scopeValue.description)") }
                var file = (name as NSString).expandingTildeInPath
                if !file.hasPrefix("/"), let base { file = (base as NSString).appendingPathComponent(file) }
                file = (file as NSString).standardizingPath
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), isDirectory.boolValue {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: file)) ?? []
                    expanded += names.sorted().filter { !$0.hasPrefix(".") && $0.hasSuffix(".org") }.map { (file as NSString).appendingPathComponent($0) }
                } else {
                    expanded.append(file)
                }
            }
            files = expanded
        } else {
            switch scope {
            case "agenda": files = options.agendaFiles ?? []
            case "agenda-with-archives": files = Archive.addArchiveFiles(options.agendaFiles ?? [], options: options, read: read)
            case "file-with-archives": files = path.map { Archive.addArchiveFiles([$0], options: options, read: read) }
            case "nil", "file", "subtree", "tree": files = nil
            case let s where s.wholeMatch(of: /tree[0-9]+/) != nil: files = nil
            default: throw UserError(message: "Unknown scope: \(scopeValue.description)")
            }
        }
        if let files, scope != "file-with-archives" || path != nil {
            var tables: [ClockTable.FileTable] = []
            for file in files {
                guard let text = read(file) else { continue }
                let buffer = file == path ? self : EmacsBuffer(text, point: 0, settings: OrgParser.parse(text).settings, options: options)
                buffer.now = now
                buffer.calendar = calendar
                let saved = point
                tables.append(ClockTable.tableData(buffer, path: file, params: params, region: 0..<buffer.length, tstart: tstart, tend: tend))
                point = saved
            }
            // `file-with-archives` counts as one extended file.
            return (tables, !params.flag(":hidefiles") && scope != "file-with-archives")
        }
        // The scope's text in this buffer.
        point = begin
        let region: Range<Int>
        switch scope {
        case "subtree":
            guard !beforeFirstHeading, let r = try? subtreeRange() else { throw UserError(message: "Before first headline") }
            region = r
        case let scope where scope.hasPrefix("tree"):
            guard !beforeFirstHeading else { throw UserError(message: "Before first headline") }
            try backToHeading()
            let limit = Int(scope.dropFirst(4))
            while let level = currentLevel, level > (limit ?? 1), upHeadingSafe() != nil {
                if let limit, outlineLevel <= limit { break }
            }
            region = try subtreeRange()
        default:
            region = 0..<length
        }
        return ([ClockTable.tableData(self, path: path, params: params, region: region, tstart: tstart, tend: tend)], false)
    }

    /// `org-clocktable-steps`: a table per day, week, semimonth, month, quarter or year of the
    /// range, each after a line naming its start; with `:stepskip0`, only those with time.
    func clockTableSteps(_ step: String, params: ClockTable.Params, begin: Int, range: (start: Double?, end: Double?, text: String?), content: String) throws -> String {
        let headers = ["day": "Daily report: ", "week": "Weekly report starting on: ", "semimonth": "Semimonthly report starting on: ",
                       "month": "Monthly report starting on: ", "year": "Annual report starting on: ", "quarter": "Quarterly report starting on: "]
        guard let stepHeader = headers[step] else { throw UserError(message: "Unknown `:step' specification: \(step)") }
        guard let start = range.start, let end = range.end else {
            throw UserError(message: "Clocktable `:step' can only be used with `:block' or `:tstart', `:tend'")
        }
        let weekStart = params.int(":wstart") ?? 1
        let monthStart = params.int(":mstart") ?? 1
        var stepParams = params
        stepParams.values[":header"] = .string("")
        stepParams.values[":step"] = nil
        stepParams.values[":block"] = nil
        // The block's contents as `org-clocktable-steps` builds them after `org-prepare-dblock`'s
        // `open-line`, with point at `p`; `out` ends where the #+END line starts.
        var out = "\n"
        var p = 0
        var at = Date(timeIntervalSince1970: start)
        let stop = Date(timeIntervalSince1970: end)
        while at < stop {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: at)
            let (y, m, d, dow) = (c.year!, c.month!, c.day!, c.weekday! - 1)
            func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day))!
            }
            let next: Date = switch step {
            case "day": date(y, m, d + 1)
            case "week": date(y, m, d + (dow == weekStart ? 7 : ((weekStart - dow) % 7 + 7) % 7))
            case "semimonth": d < 16 ? date(y, m, 16) : date(y, m + 1, 1)
            case "month": date(y, m + 1, monthStart)
            case "quarter": date(y, m + 3, monthStart)
            default: date(y + 1, 1, 1)
            }
            let tables = try clockTables(stepParams, begin: begin, tstart: at.timeIntervalSince1970, tend: min(next, stop).timeIntervalSince1970)
            let total = tables.tables.reduce(0) { $0 + $1.total }
            let stamp = formatTimestamp(calendar.dateComponents([.year, .month, .day], from: at), withTime: false, inactive: true)
            let table = try ClockTable.write(self, params: stepParams, tables: tables.tables, multifile: tables.multifile, rangeText: nil, content: content)
            if p > 0, (out as NSString).character(at: p - 1) != 10 {
                out = (out as NSString).replacingCharacters(in: NSRange(location: p, length: 0), with: "\n")
                p += 1
            }
            let tableBegin = p + 1
            out = (out as NSString).replacingCharacters(in: NSRange(location: p, length: 0), with: "\n" + stepHeader + stamp + "\n" + table)
            // An empty table goes, from its header line to the #+END line.
            if params.flag(":stepskip0"), total == 0 {
                out = (out as NSString).substring(to: tableBegin)
            }
            // `(end-of-line 0)` from the #+END line.
            p = max(0, (out as NSString).length - 1)
            at = next
        }
        return String(out.dropLast())
    }

    /// Puts `table` between the #+BEGIN and #+END lines of the block at `begin`, indented like
    /// the #+BEGIN line as `org-update-dblock` does, and aligns it.
    func replaceDynamicBlockContent(at begin: Int, with table: String, recalculate: Bool = false, alignAll: Bool = false) throws {
        point = begin
        guard let start = lookingAt(Self.dblockStart) else { throw UserError(message: "Not at a dynamic block") }
        let indentation = currentIndentation
        let deleteFrom = start[0]!.upperBound + 1
        point = start[0]!.upperBound
        guard let end = searchForward("^[ \\t]*#\\+(?:END|end):?", caseInsensitive: false)?[0] else { throw UserError(message: "Dynamic block not terminated") }
        // Replace the old contents.
        let contentEnd = end.lowerBound
        deleteRegion(min(deleteFrom, contentEnd), contentEnd)
        point = min(deleteFrom, length)
        insert(table + "\n")
        // Indent like the #+BEGIN line, as `org-update-dblock` does.
        if indentation > 0 {
            let pad = String(repeating: " ", count: indentation)
            point = deleteFrom
            while lookingAt("^[ \\t]*#\\+(?:END|end):?") == nil {
                insert(pad)
                if forwardLine(1) != 0 { break }
            }
            if let blank = lookingAt("[ \\t]+") { deleteRegion(blank[0]!.lowerBound, blank[0]!.upperBound) }
            insert(pad)
        }
        point = deleteFrom
        let endMark = marker(deleteFrom + (table as NSString).length + 1)
        defer { release(endMark) }
        while let bar = searchForward("^[ \\t]*\\|", bound: endMark.position, caseInsensitive: false) {
            point = bar[0]!.upperBound
            // A table kept with formulas is recalculated, as the column view writer does.
            if recalculate {
                do {
                    try tableRecalculate(all: true)
                } catch let error as Calc.Unsupported {
                    throw UserError(message: TableRecalculate.emacsMessage + error.reason)
                }
            }
            tableAlign()
            // `:step` writes a table per step, each aligned.
            guard alignAll else { break }
            point = lineStart(point)
            while lookingAt("^[ \\t]*\\|") != nil, forwardLine(1) == 0 {}
        }
        point = begin
    }
}

/// C-c C-x C-u, and C-c C-c on a dynamic block's #+BEGIN line: `org-update-dblock` (clock
/// tables).
public struct UpdateDynamicBlock: OrgCommand {
    public init() {}
    public var id: String { "org.dblock.update" }
    public var title: String { "Update Dynamic Block" }
    public func applies(in context: EditContext) -> Bool {
        EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).dynamicBlockStart() != nil
    }
    public func run(in context: EditContext) -> CommandStep {
        guard let begin = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).dynamicBlockStart() else {
            return .failed("Not at a dynamic block")
        }
        return commitBuffer(context) { buffer in
            try buffer.updateDynamicBlock(at: begin)
            buffer.point = begin
        }
    }
}

/// C-c C-x C-r: `org-clock-report`. Updates the clock table at point, or inserts one for the
/// subtree (the file before the first heading).
public struct ClockReportTable: OrgCommand {
    public init() {}
    public var id: String { "org.clock.report" }
    public var title: String { "Insert or Update Clock Table" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            if let begin = buffer.dynamicBlockStart(), buffer.saveExcursion({ buffer.point = begin; return buffer.lookingAt("^[ \\t]*#\\+(?:BEGIN|begin):[ \\t]+clocktable") != nil }) {
                try buffer.updateDynamicBlock(at: begin)
                buffer.point = begin
                return
            }
            let scope = buffer.beforeFirstHeading ? "file" : "subtree"
            let begin = buffer.createDynamicBlock("clocktable :scope \(scope) :maxlevel 2")
            try buffer.updateDynamicBlock(at: begin)
            buffer.point = begin
        }
    }
}

extension EmacsBuffer {
    /// `org-create-dblock`: an empty block named by `header` on a line of its own at point.
    func createDynamicBlock(_ header: String) -> Int {
        if substring(lineStart(point), lineEnd(point)).contains(where: { !$0.isWhitespace }) {
            point = lineEnd(point)
            insert("\n")
        }
        let column = currentColumn
        let begin = lineStart(point)
        insert("#+BEGIN: \(header)\n\n" + String(repeating: " ", count: column) + "#+END:\n")
        return begin
    }
}

/// C-c C-x i: `org-columns-insert-dblock`, asking what to capture (this subtree, the file, or an
/// entry by ID).
public struct InsertColumnView: OrgCommand {
    public init() {}
    public var id: String { "org.columns.insert-dblock" }
    public var title: String { "Insert Column View Table" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        guard let answer = context.answers["capture"] else {
            let ids = SparseTreeCommand.propertyValues("ID", in: context.text)
            return .prompt(Prompt(key: "capture", message: "Capture columns (local, global, entry with :ID: property) [local]:",
                                  choices: ["global", "local"] + ids, requireMatch: false))
        }
        let id = answer.isEmpty || answer == "local" ? "local" : answer == "global" ? "global" : answer
        return commitBuffer(context) { buffer in
            let begin = buffer.createDynamicBlock("columnview :hlines 1 :id \(id)")
            try buffer.updateDynamicBlock(at: begin)
            buffer.point = begin
        }
    }
}

/// C-c C-x C-c: `org-columns`, shown read-only: the entries from the column view's top level
/// with their values and summaries.
public struct ShowColumnView: OrgCommand {
    let global: Bool
    public init(global: Bool = false) { self.global = global }
    public var id: String { global ? "org.columns.global" : "org.columns" }
    public var title: String { global ? "Column View of File" : "Column View" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        var view: ColumnView.View
        do {
            view = try ColumnView.capture(text: context.text, tree: context.tree, at: context.caret, global: global, now: context.now, calendar: context.calendar).view
            view.global = global
        } catch let error as EmacsBuffer.UserError {
            return .failed(error.message)
        } catch {
            return .failed("\(error)")
        }
        guard !view.rows.isEmpty else { return .failed("No entries for column view") }
        return .external(.columnView(view))
    }
}

/// C-c C-x e: `org-set-effort`. Offers the entry's `Effort_ALL` values; sets `Effort`.
public struct SetEffort: OrgCommand {
    public init() {}
    public var id: String { "org.effort.set" }
    public var title: String { "Set Effort" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard let answer = context.answers["effort"] else {
            let current = buffer.saveExcursion { () -> String in
                _ = try? buffer.backToHeading()
                let end = buffer.saveExcursion { () -> Int in Capture.nextHeading(buffer); return buffer.point }
                guard let line = buffer.searchForward("^[ \\t]*:Effort:[ \\t]+(.*?)[ \\t]*$", bound: end, caseInsensitive: true), let value = line[1] else { return "" }
                return buffer.substring(value.lowerBound, value.upperBound)
            }
            let allowed = (buffer.inheritedProperty("Effort_ALL")?.value ?? Self.fileProperty(context.text, "Effort_ALL") ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            return .prompt(Prompt(key: "effort", message: "Effort:", initial: current, choices: allowed, requireMatch: false))
        }
        let value = answer.trimmingCharacters(in: .whitespaces)
        return commitBuffer(context) { buffer in
            buffer.saveExcursion {
                _ = try? buffer.backToHeading()
                buffer.entryPut("Effort", value)
            }
        }
    }

    /// `#+PROPERTY: NAME value`.
    static func fileProperty(_ text: String, _ name: String) -> String? {
        text.firstMatch(of: try! Regex("(?im)^[ \\t]*#\\+PROPERTY:[ \\t]+" + NSRegularExpression.escapedPattern(for: name) + "[ \\t]+(.*?)[ \\t]*$"))
            .map { String($0.output[1].substring!) }
    }
}
