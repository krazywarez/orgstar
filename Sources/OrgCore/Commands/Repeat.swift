import Foundation

// Repeating entries (`org-auto-repeat-maybe`, Org 9.8.7) and the state note org logs for them
// (`org-add-log-setup`, `org-store-log-note`, `org-log-beginning`), with `org-log-repeat`
// `time`, `org-log-into-drawer` nil, `org-todo-repeat-to-state` nil.

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

    /// `org-auto-repeat-maybe` after `doneWord` replaced `previous`. Returns the note to log, if
    /// any, with the marker it belongs at.
    func autoRepeat(doneWord: String, previous: String?) throws -> (Marker, String)? {
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
        if options.logRepeat { entryPut("LAST_REPEAT", stamp) }
        let note = marker(point)
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
        guard options.logRepeat else {
            release(note)
            return nil
        }
        func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "" }
        let line = "State " + quoted(doneWord).padding(toLength: max(12, quoted(doneWord).count), withPad: " ", startingAt: 0)
            + " from " + quoted(previous).padding(toLength: max(12, quoted(previous).count), withPad: " ", startingAt: 0)
            + " " + stamp
        return (note, line)
    }

    /// `org-store-log-note` for a one-line note at `marker`.
    func storeNote(_ marker: Marker, _ text: String) {
        saveExcursion {
            point = marker.position
            release(marker)
            point = logBeginning()
            if !bolp {
                insert("\n")
            } else if lookingAt("[ \\t]*\\S") != nil {
                saveExcursion { insert("\n") }
            }
            if let item = inItem() {
                let structure = saveExcursion { point = item; return listStruct() }
                indentLineTo(structure.ind(structure.top))
            } else {
                indentLineTo(0)
            }
            insert("- " + text)
        }
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

    /// `org-log-beginning` without a log drawer, with `org-log-states-order-reversed` t: the
    /// newest note comes first.
    func logBeginning() -> Int {
        saveExcursion {
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
}
