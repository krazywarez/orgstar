import Foundation

// Clock tables (org-clock.el, Org 9.8.7): the `clocktable` dynamic block written by
// `org-clocktable-write-default` from `org-clock-sum`, updated by `org-update-dblock` (C-c C-c
// on its #+BEGIN line, C-c C-x C-u) and inserted by `org-clock-report` (C-c C-x C-r), with
// `org-clocktable-defaults` and `org-duration-format` ((\"d\" . nil) (special . h:mm)).
// Scopes within the file (file, subtree, tree, treeN); `:link` links within the file, as
// Emacs does in a buffer without a file. `:match`, `:step`, `:formatter` and scopes over
// other files aren't supported.

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

        init(_ line: String) throws {
            values = Self.defaults
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

    /// `org-clock-sum` over `region`: each heading's minutes with its subtree's, and the total.
    static func sum(_ text: String, region: Range<Int>, tstart: Double?, tend: Double?, calendar: Calendar) -> (rows: [(start: Int, level: Int, minutes: Int)], total: Int) {
        let ns = text as NSString
        let range = NSRange(region)
        var own: [Int: Int] = [:] // heading start → minutes
        let headings = (try! NSRegularExpression(pattern: "^(\\*+)[ \\t]", options: .anchorsMatchLines)).matches(in: text, range: range)
            .map { (start: $0.range.location, level: $0.range(at: 1).length) }
        func owner(_ offset: Int) -> Int? { headings.last { $0.start <= offset }?.start }
        func seconds(_ m: NSTextCheckingResult, _ first: Int) -> Double {
            let parts = (first..<(first + 5)).map { Int(ns.substring(with: m.range(at: $0)))! }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!.timeIntervalSince1970
        }
        for m in clockRange.matches(in: text, range: range) {
            guard let head = owner(m.range.location) else { continue }
            let ts = seconds(m, 1)
            let te = seconds(m, 6)
            let dt = (tend.map { min(te, $0) } ?? te) - (tstart.map { max(ts, $0) } ?? ts)
            if dt > 0 { own[head, default: 0] += Int(floor(dt / 60)) }
        }
        for m in nakedClock.matches(in: text, range: range) {
            guard let head = owner(m.range.location) else { continue }
            own[head, default: 0] += Int(ns.substring(with: m.range(at: 1)))! * 60 + Int(ns.substring(with: m.range(at: 2)))!
        }
        var rows: [(Int, Int, Int)] = []
        for (i, heading) in headings.enumerated() {
            var minutes = own[heading.start] ?? 0
            for later in headings[(i + 1)...] {
                if later.level <= heading.level { break }
                minutes += own[later.start] ?? 0
            }
            if minutes > 0 { rows.append((heading.start, heading.level, minutes)) }
        }
        let total = own.values.reduce(0, +)
        return (rows.map { (start: $0.0, level: $0.1, minutes: $0.2) }, total)
    }

    /// `org-shorten-string`.
    static func shorten(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let n = Swift.max(max - 4, 1)
        if let m = s.firstMatch(of: try! Regex("^(.{1,\(n)}[^ ])( |$)")) {
            return String(m.output[1].substring!) + "..."
        }
        return String(s.prefix(Swift.max(max - 3, 0))) + "..."
    }

    /// The table `org-clocktable-write-default` writes, without its final newline.
    static func write(_ buffer: EmacsBuffer, params: Params, region: Range<Int>, content: String) throws -> String {
        let maxlevel = params.int(":maxlevel") ?? 3
        let emph = params.flag(":emphasize")
        let link = params.flag(":link")
        let compact = params.flag(":compact")
        let showLevel = !compact && params.flag(":level")
        let showTags = params.flag(":tags")
        let indent = compact || params.flag(":indent")
        let percent = params.values[":formula"]?.symbol == "%"
        let properties = params.values[":properties"]?.elements?.compactMap(\.string) ?? []
        if params.values[":match"].map({ $0.symbol != "nil" }) ?? false { throw EmacsBuffer.UserError(message: "Clock tables with :match aren't supported yet") }
        if params.values[":step"].map({ $0.symbol != "nil" }) ?? false { throw EmacsBuffer.UserError(message: "Clock tables with :step aren't supported yet") }
        var narrow: Int?
        var narrowCut = false
        if let value = params.values[":narrow"] {
            if let n = value.integer { narrow = n }
            else if let s = value.symbol, let m = s.wholeMatch(of: /([0-9]+)!/) { narrow = Int(m.1); narrowCut = true }
            else if value.symbol != "nil" { throw EmacsBuffer.UserError(message: "Invalid value \(value.description) of :narrow property in clock table") }
        }
        if compact, narrow == nil { narrow = 40; narrowCut = true }
        if let n = narrow, !narrowCut, link { narrow = n; narrowCut = true }

        var tstart: Double?
        var tend: Double?
        var rangeText: String?
        if let block = params.symbol(":block") ?? params.values[":block"]?.integer.map(String.init), block != "nil" {
            let r = try range(block, now: buffer.now, calendar: buffer.calendar, wstart: params.int(":wstart") ?? 1, mstart: params.int(":mstart") ?? 1)
            (tstart, tend, rangeText) = (r.0, r.1, r.2)
        } else {
            if let s = params.values[":tstart"]?.string { tstart = TagsMatcher.matcherTime(s, now: buffer.now, calendar: buffer.calendar) }
            if let s = params.values[":tend"]?.string { tend = TagsMatcher.matcherTime(s, now: buffer.now, calendar: buffer.calendar) }
        }
        let text = buffer.string
        let summed = sum(text, region: region, tstart: tstart, tend: tend, calendar: buffer.calendar)
        var rows: [Row] = []
        for entry in summed.rows where entry.level <= maxlevel {
            buffer.point = entry.start
            guard let match = buffer.lookingAt(buffer.complexHeadingPattern) else { continue }
            var title = match[4].map { buffer.substring($0.lowerBound, $0.upperBound) } ?? ""
            if title == "COMMENT" { title = "" } else if title.hasPrefix("COMMENT ") { title = String(title.dropFirst(8)) }
            var headline = title
            if link {
                let search = "*" + Links.normalize(title, context: false)
                let description = Links.displayFormat(title.replacingOccurrences(of: "\\[[0-9]*(?:%|/[0-9]*)\\]", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespaces)
                headline = Links.makeString(search, description)
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
        let total = summed.total
        let columns = compact || maxlevel < 2 ? 1 : min(maxlevel, params.int(":tcolumns") ?? 100, rows.map(\.level).max() ?? 1)

        let stamp = buffer.formatTimestamp(buffer.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: buffer.now), withTime: true, inactive: true)
        var out = "#+CAPTION: Clock summary at \(stamp)\(rangeText.map { ", for \($0)." } ?? "")\n"
        if let narrow, !narrowCut {
            out += "|" + (showLevel ? "|" : "") + (showTags ? "|" : "") + String(repeating: "|", count: properties.count) + "<\(narrow)>| |\n"
        }
        out += "|" + (showLevel ? "L|" : "") + (showTags ? "Tags |" : "") + properties.map { $0 + "|" }.joined()
            + "Headline|Time|" + String(repeating: "|", count: max(0, columns - 1)) + (percent ? "%|\n" : "\n")
        out += "|-\n|" + (showLevel ? "|" : "") + (showTags ? "|" : "") + String(repeating: "|", count: properties.count)
            + "*Total time*| *\(duration(total))*|" + String(repeating: "|", count: max(0, columns - 1))
            + (percent ? (total == 0 ? "0.0|" : "100.0|") : "") + "\n"
        if total > 0 {
            if total > 0 || !params.flag(":fileskip0") { out += "|-\n" }
            if maxlevel > 0 {
                for row in rows {
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
                    out += "|" + (showLevel ? "\(row.level)|" : "") + (showTags ? row.tags.joined(separator: ", ") + "|" : "")
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
        guard name == "clocktable" else { throw UserError(message: "Dynamic blocks named \(name) aren't supported") }
        let paramText = start[3].map { substring($0.lowerBound, $0.upperBound) } ?? ""
        let params = try ClockTable.Params(paramText)
        let indentation = currentIndentation
        let deleteFrom = start[0]!.upperBound + 1
        point = start[0]!.upperBound
        guard let end = searchForward("^[ \\t]*#\\+(?:END|end):?", caseInsensitive: false)?[0] else { throw UserError(message: "Dynamic block not terminated") }
        let content = substring(min(deleteFrom, end.lowerBound), end.lowerBound)
        // The scope's text.
        point = begin
        let region: Range<Int>
        switch params.symbol(":scope") ?? "file" {
        case "nil", "file":
            region = 0..<length
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
        case let scope:
            throw UserError(message: "Clock tables over \(scope) aren't supported yet")
        }
        let table = try ClockTable.write(self, params: params, region: region, content: content)
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
        if let bar = searchForward("^[ \\t]*\\|", caseInsensitive: false) {
            point = bar[0]!.upperBound
            tableAlign()
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
            // `org-create-dblock`.
            if buffer.substring(buffer.lineStart(buffer.point), buffer.lineEnd(buffer.point)).contains(where: { !$0.isWhitespace }) {
                buffer.point = buffer.lineEnd(buffer.point)
                buffer.insert("\n")
            }
            let column = buffer.currentColumn
            let begin = buffer.lineStart(buffer.point)
            buffer.insert("#+BEGIN: clocktable :scope \(scope) :maxlevel 2\n\n" + String(repeating: " ", count: column) + "#+END:\n")
            try buffer.updateDynamicBlock(at: begin)
            buffer.point = begin
        }
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
