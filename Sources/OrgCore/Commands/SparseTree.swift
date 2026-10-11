import Foundation

// Sparse trees (`org-sparse-tree`, C-c /, Org 9.8.7): `org-occur` and the trees built on it,
// and `org-match-sparse-tree`. Matches are shown as `org-fold-show-context` does with the
// default `ancestors` detail, after `org-cycle-overview`.

public enum SparseTree {
    /// Where each match leaves point (org shows the context there), and the text to highlight.
    public struct Matches: Sendable, Equatable {
        public var points: [Int] = []
        public var highlights: [Range<Int>] = []
    }

    /// `org-occur`: matches of `pattern` (ICU), each kept when `keep` says so.
    static func occur(_ buffer: EmacsBuffer, _ pattern: String, caseInsensitive: Bool, keep: ((EmacsBuffer, [Range<Int>?]) -> Bool)? = nil) -> Matches {
        var matches = Matches()
        buffer.point = 0
        while buffer.point <= buffer.length, let match = buffer.searchForward(pattern, caseInsensitive: caseInsensitive) {
            let whole = match[0]!
            buffer.point = whole.upperBound
            let kept = buffer.saveExcursion { keep?(buffer, match) ?? true }
            if kept {
                matches.points.append(whole.upperBound)
                matches.highlights.append(whole)
            }
            if whole.isEmpty {
                guard buffer.point < buffer.length else { break }
                buffer.point += 1
            }
        }
        return matches
    }

    /// `org-occur` with a regexp in Emacs syntax.
    public static func occur(_ regexp: String, in text: String) throws -> Matches {
        guard !regexp.isEmpty else { throw EmacsBuffer.UserError(message: "Regexp cannot be empty") }
        let pattern = EmacsRegex.translate(regexp)
        guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw EmacsBuffer.UserError(message: "Invalid regexp") }
        return occur(EmacsBuffer(text, point: 0), pattern, caseInsensitive: true)
    }

    /// `org-show-todo-tree`: headings with an unfinished keyword, or with `keywords`
    /// (`KWD1|KWD2`).
    public static func todo(_ keywords: String?, in text: String, settings: OrgSettings) -> Matches {
        let buffer = EmacsBuffer(text, point: 0, settings: settings)
        let words: [String]
        let after: String
        if let keywords {
            words = keywords.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            after = "(?:[ \\t]|$)"
        } else {
            words = buffer.keywordsInOrder.filter { !settings.isDone($0) }
            after = "\\b\\s"
        }
        guard !words.isEmpty else { return Matches() }
        let alternation = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "^\\*+ " + " *" + (keywords == nil ? "\\b(" + alternation + ")" : "(" + alternation + ")") + after
        return occur(buffer, pattern, caseInsensitive: false)
    }

    /// `org-match-sparse-tree`: headings matching a tags/property match, their stars
    /// highlighted.
    public static func match(_ match: String, in text: String, now: Date, calendar: Calendar) -> Matches {
        let source = AgendaSource(path: "", text: text)
        let matcher = TagsMatcher(match)
        var matches = Matches()
        for heading in source.headings where matcher.matches(heading, in: source, now: now, calendar: calendar) {
            let stars = (text as NSString).substring(from: heading.start).prefix { $0 == "*" }.utf16.count
            matches.points.append(heading.start)
            matches.highlights.append(heading.start..<(heading.start + stars))
        }
        return matches
    }

    /// The day of an Org time string, as days since the epoch in `calendar`.
    static func day(_ stamp: String, calendar: Calendar) -> Int? {
        guard let c = EmacsBuffer.parseTimeString(stamp), let date = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) else { return nil }
        return calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: date).day
    }

    /// `org-time-string-to-time`.
    static func time(_ stamp: String, calendar: Calendar) -> Date? {
        guard let c = EmacsBuffer.parseTimeString(stamp) else { return nil }
        return calendar.date(from: c)
    }

    /// `org-check-deadlines`: deadlines past due or due within `days`, in entries not done.
    public static func deadlines(within days: Int, in text: String, settings: OrgSettings, now: Date, calendar: Calendar) -> Matches {
        let buffer = EmacsBuffer(text, point: 0, settings: settings)
        let today = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: calendar.startOfDay(for: now)).day ?? 0
        return occur(buffer, "\\bDEADLINE: *<([^>]+)>", caseInsensitive: false) { buffer, match in
            let stamp = buffer.substring(match[1]!.lowerBound, match[1]!.upperBound)
            guard let day = day(stamp, calendar: calendar), day - today <= days else { return false }
            return !entryIsDone(buffer, settings: settings)
        }
    }

    /// `org-entry-is-done-p`.
    static func entryIsDone(_ buffer: EmacsBuffer, settings: OrgSettings) -> Bool {
        guard (try? buffer.backToHeading()) != nil, let m = buffer.lookingAt("\\*+ +(\\S+)") else { return false }
        return settings.isDone(buffer.substring(m[1]!.lowerBound, m[1]!.upperBound))
    }

    /// `org-check-before-date`, `org-check-after-date` and `org-check-dates-range` on
    /// SCHEDULED and DEADLINE: planning times `from` or later and before `to`.
    public static func planning(from: String?, to: String?, in text: String, calendar: Calendar) -> Matches {
        let buffer = EmacsBuffer(text, point: 0)
        let low = from.flatMap { time($0, calendar: calendar) }
        let high = to.flatMap { time($0, calendar: calendar) }
        return occur(buffer, "\\b(?:DEADLINE|SCHEDULED): *<([^>]+)>", caseInsensitive: false) { buffer, match in
            guard buffer.lookingAtLine("^[ \\t]*(?:SCHEDULED|DEADLINE|CLOSED):"),
                  let at = time(buffer.substring(match[1]!.lowerBound, match[1]!.upperBound), calendar: calendar) else { return false }
            if let low, at < low { return false }
            if let high, !(at < high) { return false }
            return true
        }
    }

    /// What stays hidden: `org-cycle-overview`, then each point's context shown (its heading
    /// line, or its entry, and its ancestors' heading lines), then archived subtrees folded.
    public static func hidden(_ points: [Int], in text: String, tree: OrgTree) -> [Range<Int>] {
        let ns = text as NSString
        var lineStarts: [Int] = []
        var offset = 0
        while offset < ns.length {
            lineStarts.append(offset)
            offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        }
        if lineStarts.isEmpty { return [] }
        func lineIndex(_ position: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= position { low = mid } else { high = mid - 1 }
            }
            return low
        }
        let model = DocumentModel(tree: tree)
        let headings = model.headings
        var visible = [Bool](repeating: false, count: lineStarts.count)
        let firstHeadingLine = headings.first.map { lineIndex($0.headingRange.lowerBound) } ?? lineStarts.count
        for i in 0..<firstHeadingLine { visible[i] = true }
        for heading in headings where heading.level == 1 { visible[lineIndex(heading.headingRange.lowerBound)] = true }
        let headingStarts = headings.map(\.headingRange.lowerBound)
        func headingIndex(at position: Int) -> Int? {
            headingStarts.lastIndex { $0 <= position }
        }
        for point in points {
            let line = lineIndex(min(point, ns.length))
            guard let h = headingIndex(at: lineStarts[line]) else { continue }
            if lineStarts[line] == headingStarts[h] {
                visible[line] = true
            } else {
                let bodyEnd = h + 1 < headings.count ? headingStarts[h + 1] : ns.length
                for i in lineIndex(headingStarts[h])..<lineStarts.count where lineStarts[i] < bodyEnd { visible[i] = true }
            }
            var parent = headings[h].parent
            while let p = parent {
                visible[lineIndex(headingStarts[p])] = true
                parent = headings[p].parent
            }
        }
        for (index, heading) in headings.enumerated() where heading.localTags.contains("ARCHIVE") {
            let end = headings[(index + 1)...].first { $0.level <= heading.level }?.headingRange.lowerBound ?? ns.length
            let first = lineIndex(heading.headingRange.lowerBound) + 1
            for i in first..<lineStarts.count where lineStarts[i] < end { visible[i] = false }
        }
        var ranges: [Range<Int>] = []
        var start: Int?
        for i in lineStarts.indices {
            if !visible[i], start == nil { start = lineStarts[i] }
            if visible[i], let s = start {
                ranges.append(s..<lineStarts[i])
                start = nil
            }
        }
        if let s = start { ranges.append(s..<ns.length) }
        return ranges
    }
}

/// C-c /: `org-sparse-tree`. The editor shows the result.
public struct SparseTreeCommand: OrgCommand {
    public init() {}
    public var id: String { "org.sparse-tree" }
    public var title: String { "Sparse Tree…" }
    public func applies(in context: EditContext) -> Bool { true }

    static let menu = FastSelection(items: [
        .option(key: "r", name: "regexp"), .option(key: "t", name: "todo"), .option(key: "T", name: "todo keyword"),
        .option(key: "m", name: "match"), .option(key: "p", name: "property"), .newline,
        .option(key: "d", name: "deadlines"), .option(key: "b", name: "before date"), .option(key: "a", name: "after date"),
        .option(key: "D", name: "dates range"),
    ], multiple: false)

    public func run(in context: EditContext) -> CommandStep {
        guard let kind = context.answers["sparse"] else {
            return .prompt(Prompt(key: "sparse", message: "Sparse tree: [r]egexp [t]odo [T]odo-kwd [m]atch [p]roperty [d]eadlines [b]efore-date [a]fter-date [D]ates range", fast: Self.menu))
        }
        let text = context.text
        let settings = context.tree.settings
        func ask(_ key: String, _ message: String, choices: [String] = [], date: Bool = false) -> CommandStep? {
            context.answers[key] == nil ? .prompt(Prompt(key: key, message: message, choices: choices, requireMatch: false, date: date ? .init(defaultDate: nil) : nil)) : nil
        }
        func dateString(_ answer: String) -> String {
            let read = ReadDate.read(answer, default: nil, now: context.now, calendar: context.calendar)
            let base = String(format: "%04d-%02d-%02d", read.year, read.month, read.day)
            return read.timeGiven ? base + String(format: " %02d:%02d", read.hour, read.minute) : base
        }
        let matches: SparseTree.Matches
        let message: String?
        switch kind {
        case "r", "R", "/":
            if let step = ask("regexp", "Regexp:") { return step }
            do {
                matches = try SparseTree.occur(context.answers["regexp"]!, in: text)
            } catch let error as EmacsBuffer.UserError {
                return .failed(error.message)
            } catch {
                return .failed("\(error)")
            }
            message = "\(matches.points.count) match(es) for regexp \(context.answers["regexp"]!)"
        case "t":
            matches = SparseTree.todo(nil, in: text, settings: settings)
            message = "\(matches.points.count) TODO entries found"
        case "T":
            let buffer = EmacsBuffer(text, point: 0, settings: settings)
            if let step = ask("keyword", "Keyword (or KWD1|KWD2|...):", choices: buffer.keywordsInOrder) { return step }
            matches = SparseTree.todo(context.answers["keyword"]!, in: text, settings: settings)
            message = "\(matches.points.count) TODO entries found"
        case "m":
            if let step = ask("match", "Match:") { return step }
            matches = SparseTree.match(context.answers["match"]!, in: text, now: context.now, calendar: context.calendar)
            message = nil
        case "p", "P":
            if let step = ask("property", "Property:", choices: SortEntries.propertyKeys(text)) { return step }
            let name = context.answers["property"]!
            let values = SparseTreeCommand.propertyValues(name, in: text)
            if let step = ask("value", "Value:", choices: values) { return step }
            var value = context.answers["value"]!
            if value.range(of: "^\\{.*\\}$", options: .regularExpression) == nil { value = "\"" + value + "\"" }
            matches = SparseTree.match(name.replacingOccurrences(of: "-", with: "\\-") + "=" + value, in: text, now: context.now, calendar: context.calendar)
            message = nil
        case "d":
            matches = SparseTree.deadlines(within: settings.deadlineWarningDays, in: text, settings: settings, now: context.now, calendar: context.calendar)
            message = "\(matches.points.count) deadlines past-due or due within \(settings.deadlineWarningDays) days"
        case "b", "a":
            if let step = ask("date", "Date:", date: true) { return step }
            let date = dateString(context.answers["date"]!)
            matches = kind == "b" ? SparseTree.planning(from: nil, to: date, in: text, calendar: context.calendar)
                : SparseTree.planning(from: date, to: nil, in: text, calendar: context.calendar)
            message = "\(matches.points.count) entries \(kind == "b" ? "before" : "after") \(date)"
        case "D":
            if let step = ask("start", "Range starts:", date: true) { return step }
            if let step = ask("end", "Range end:", date: true) { return step }
            let start = dateString(context.answers["start"]!)
            let end = dateString(context.answers["end"]!)
            matches = SparseTree.planning(from: start, to: end, in: text, calendar: context.calendar)
            message = "\(matches.points.count) entries between \(start) and \(end)"
        default:
            return .failed("No such sparse tree command \"\(kind)\"")
        }
        let effects: [Effect] = [.sparseTree(show: matches.points, highlights: matches.highlights)] + (message.map { [.message($0)] } ?? [])
        return .commit(EditResult(baseRevision: context.revision, edits: [], effects: effects))
    }

    /// `org-property-values`: the values `name` has in the text.
    static func propertyValues(_ name: String, in text: String) -> [String] {
        let pattern = "(?mi)^[ \\t]*:" + NSRegularExpression.escapedPattern(for: name) + ":[ \\t]+(.*?)[ \\t]*$"
        var values: [String] = []
        for m in (try! NSRegularExpression(pattern: pattern)).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let value = (text as NSString).substring(with: m.range(at: 1))
            if !values.contains(value) { values.append(value) }
        }
        return values
    }
}
