import Foundation

// Repeating entries (`org-auto-repeat-maybe`, Org 9.8.7) and where state notes go
// (`org-log-beginning`), with `org-todo-repeat-to-state` nil.

extension EmacsBuffer {
    static let repeatPattern = "<[0-9]{4}-[0-9][0-9]-[0-9][0-9] [^>\\n]*?([.+]?\\+[0-9]+[hdwmy](/[0-9]+[hdwmy])?)"

    /// `org-entry-end-position`: the next heading, or the end of the buffer.
    var entryEnd: Int {
        saveExcursion {
            _ = try? backToHeading()
            outlineNextHeading()
            return point
        }
    }

    /// `org-get-repeat`.
    func repeatCookie() -> String? {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return nil }
            let end = entryEnd
            return searchForward(Self.repeatPattern, bound: end, caseInsensitive: false).map { substring($0[1]!.lowerBound, $0[1]!.upperBound) }
        }
    }

    /// The TODO keyword of the heading at point, if any.
    var todoKeyword: String? {
        saveExcursion {
            guard (try? backToHeading()) != nil, let match = lookingAt(todoLinePattern), let keyword = match[2] else { return nil }
            return substring(keyword.lowerBound, keyword.upperBound)
        }
    }

    /// The keyword change `org-todo` makes, with its tag alignment and statistics update.
    func setTodoKeyword(_ keyword: String?) {
        saveExcursion {
            guard (try? backToHeading()) != nil, let stars = lookingAt("\\*+ ") else { return }
            point = stars[0]!.upperBound - 1
            let names = keywordsInOrder.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let match = lookingAt(" +(" + names + ")( +|[ \\t]*$)") ?? lookingAt("(?: *|[ \\t]*$)")!
            replace(match[0]!, with: "")
            point = match[0]!.lowerBound
            insertBeforeMarkers(keyword.map { " " + $0 + " " } ?? " ")
            alignTags(onLineAt: point)
            updateParentTodoStatistics()
        }
    }

    /// `org-auto-repeat-maybe` after `doneWord` replaced `previous`. Returns the state note the
    /// repeat logs, if any.
    func autoRepeat(doneWord: String, previous: String?, log: LogSettings) throws -> LogSetup? {
        guard let cookie = repeatCookie(), (Int(cookie.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0) != 0 else { return nil }
        let end = marker(entryEnd)
        defer { release(end) }
        let sequence = settings.todoSequences.first { ($0.active + $0.done).contains { $0.name == previous } }
        let head = sequence.flatMap { ($0.active + $0.done).first?.name }
        let propertyState = inheritedProperty("REPEAT_TO_STATE")?.value
        let toState = propertyState.flatMap { keywordsInOrder.contains($0) ? $0 : nil }
            ?? (sequence?.kind == .type ? previous : head)
        setTodoKeyword(toState)
        try backToHeading()
        try addPlanningInfo(nil, time: nil, withTime: false, endTime: nil, remove: [.closed])
        let stamp = formatTimestamp(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now), withTime: true, inactive: true)
        if log.repeatHow != nil { entryPut("LAST_REPEAT", stamp) }
        if let scheduled = planningValue(.scheduled), ("<" + scheduled + ">").range(of: Self.repeatPattern, options: .regularExpression) == nil {
            saveExcursion { removePlanning(.scheduled) }
        }
        let units: [String: TimestampUnit] = ["h": .hour, "d": .day, "m": .month, "y": .year]
        let today = calendar.startOfDay(for: now)
        while let match = searchForward(Self.repeatPattern, bound: end.position, caseInsensitive: false) {
            let stamp = substring(match[0]!.lowerBound, match[0]!.upperBound)
            guard let parts = stamp.firstMatch(of: /([.+])?(\+[0-9]+)([hdwmy])/) else { continue }
            var n = Int(parts.2.dropFirst())!
            var what = String(parts.3)
            if what == "w" { n *= 7; what = "d" }
            guard let unit = units[what] else { continue }
            if what == "h", stamp.range(of: "[0-9]{1,2}:[0-9]{2}", options: .regularExpression) == nil {
                throw UserError(message: "Cannot repeat in \(n) hour(s) because no hour has been set")
            }
            if let kind = parts.1 {
                let time = Self.parseTimeString(stamp).map(date)!
                if kind == "." {
                    if what != "h" {
                        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: time), to: today).day!
                        try changeTimestamp(days, what: .day)
                    }
                } else {
                    var shifts = 0
                    var current = time
                    while shifts == 0 || (what == "h" ? current <= now : calendar.startOfDay(for: current) <= today) {
                        shifts += 1
                        if shifts > 100_000 { break }
                        try changeTimestamp(n, what: unit)
                        let found = inRegexp(Self.timestampPattern)!
                        current = Self.parseTimeString(substring(found[1]!.lowerBound, found[1]!.upperBound)).map(date)!
                    }
                    try changeTimestamp(-n, what: unit)
                }
            }
            try saveExcursion { try changeTimestamp(n, what: unit, suppressDelay: true) }
        }
        return log.repeatHow.map { LogSetup(purpose: .state, state: doneWord, previous: previous, how: $0, drawer: log.drawer) }
    }

    /// `org-end-of-meta-data` without FULL.
    func endOfMetaData() {
        _ = try? backToHeading()
        forwardLine(1)
        if lookingAt(Self.planningLinePattern) != nil { forwardLine(1) }
        if let drawer = looking(Self.propertyDrawerPattern) {
            point = drawer[0]!.upperBound
            forwardLine(1)
        }
    }

    /// `org-log-beginning` with `org-log-states-order-reversed` t: the newest note comes first.
    /// With `drawer`, notes go at the top of that drawer, which `create` adds when missing.
    func logBeginning(drawer: String? = nil, create: Bool = false) -> Int {
        saveExcursion {
            if let drawer { return drawerLogBeginning(drawer, create: create) }
            endOfMetaData()
            let endpos = point
            skipForward([32, 9, 10])
            forwardLine(0)
            if point < endpos { point = endpos }
            if bolp { return point }
            let end = lineEnd(point)
            return end < length ? end + 1 : length
        }
    }

    private func drawerLogBeginning(_ drawer: String, create: Bool) -> Int {
        endOfMetaData()
        let start = point
        let end = atHeading ? point : saveExcursion { outlineNextHeading(); return point }
        let name = NSRegularExpression.escapedPattern(for: drawer)
        while let match = searchForward("^[ \\t]*:" + name + ":[ \\t]*$", bound: end, caseInsensitive: true) {
            let closed = saveExcursion { searchForward("^[ \\t]*:END:[ \\t]*$", bound: end, caseInsensitive: true) != nil }
            if closed {
                point = match[0]!.upperBound
                return bolp ? point : lineEnd(point) < length ? lineEnd(point) + 1 : length
            }
        }
        point = start
        guard create else { return bolp ? point : lineEnd(point) < length ? lineEnd(point) + 1 : length }
        if !eobp, atHeading { point -= 1 }
        let atBlankLine = lookingAt("^[ \\t]*$") != nil
        let atNonBlankLineStart = bolp && !eolp
        if !bolp { insert("\n") }
        insert(":" + drawer + ":")
        insert("\n:END:")
        if atBlankLine || atNonBlankLineStart {
            insert("\n")
            point -= 1
        }
        point = lineStart(point) - 1
        return lineStart(point) == point ? point : lineEnd(point) + 1
    }
}
