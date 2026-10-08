import Foundation

// Timestamps and planning, ported from Org 9.8.7: `org-at-timestamp-p`, `org-timestamp`,
// `org-timestamp-change`, `org-modify-ts-extra`, `org-add-planning-info`,
// `org--deadline-or-schedule`. `org-time-stamp-rounding-minutes` (0 5), `org-adapt-indentation`
// nil, `org-log-reschedule` and `org-log-redeadline` nil.

extension EmacsBuffer {
    static let timestampCore = "(([0-9]{4})-([0-9]{2})-([0-9]{2})(?: *([^\\]+0-9>\\r\\n -]+))?( ([0-9]{1,2}):([0-9]{2}))?)"
    /// `org-ts-regexp3`: groups 2 year, 3 month, 4 day, 5 day name, 7 hour, 8 minute.
    static let timestampPattern = "[\\[<]" + timestampCore + "[^\\]>\\n]{0,16}[\\]>]"
    /// `org-ts-regexp0`, for time strings.
    static let timeStringPattern = "(([0-9]{4})-([0-9]{2})-([0-9]{2})( +[^\\]+0-9>\\r\\n -]+)?( +([0-9]{1,2}):([0-9]{2}))?)"

    /// `org-in-regexp` on the current line: the match that contains point.
    func inRegexp(_ pattern: String) -> [Range<Int>?]? {
        let regex = Self.regex(pattern, caseInsensitive: false)
        let lineRange = NSRange(lineStart(point)..<lineEnd(point))
        for match in regex.matches(in: string, options: Self.searchOptions, range: lineRange) {
            let range = match.range.location..<NSMaxRange(match.range)
            guard range.lowerBound <= point else { break }
            if range.upperBound >= point {
                let groups = (0..<match.numberOfRanges).map { i -> Range<Int>? in
                    let r = match.range(at: i)
                    return r.location == NSNotFound ? nil : r.location..<NSMaxRange(r)
                }
                lastMatch = groups
                return groups
            }
        }
        return nil
    }

    enum TimestampPart: Equatable {
        case bracket, after, year, month, hour, minute, day
        /// Characters past the minutes or day name, in the repeater or end time.
        case extra(Int)
    }

    /// `org-at-timestamp-p` with `lax`: where in a timestamp point is, and the match.
    func atTimestamp() -> (part: TimestampPart, match: [Range<Int>?])? {
        guard let match = inRegexp(Self.timestampPattern) else { return nil }
        let pos = point
        func inGroup(_ i: Int) -> Bool { match[i].map { $0.lowerBound <= pos && pos <= $0.upperBound } ?? false }
        let whole = match[0]!
        let part: TimestampPart
        if pos == whole.lowerBound || pos == whole.upperBound - 1 {
            part = .bracket
        } else if pos == whole.upperBound {
            part = .after
        } else if inGroup(2) {
            part = .year
        } else if inGroup(3) {
            part = .month
        } else if inGroup(7) {
            part = .hour
        } else if inGroup(8) {
            part = .minute
        } else if inGroup(4) || inGroup(5) {
            part = .day
        } else if let last = match[8]?.upperBound ?? match[5]?.upperBound, pos > last, pos < whole.upperBound {
            part = .extra(pos - last)
        } else {
            part = .day
        }
        return (part, match)
    }

    /// `org-at-date-range-p` with INACTIVE-OK: the range around point, groups 1 and 2 the insides
    /// of its two timestamps.
    func atDateRange() -> [Range<Int>?]? {
        let pattern = "[\\[<](" + AgendaSource.tsInternal + ")[\\]>]--?-?[\\[<](" + AgendaSource.tsInternal + ")[\\]>]"
        return saveExcursion {
            let pos = point
            for _ in 0..<2 {
                while let c = character(at: point - 1), ![91, 60, 13, 10].contains(c) { point -= 1 }
                skipBackward([60, 91])
                if let match = lookingAt(pattern), match[0]!.upperBound >= pos { return match }
            }
            return nil
        }
    }

    /// The timestamp `org-timestamp` takes its defaults from: in a date range the start before
    /// the dashes and the end from the second-to-last dash on, otherwise the one at point.
    func timestampForUpdate() -> String? {
        if let range = atDateRange() {
            let stamp = point < range[2]!.lowerBound - 2 ? range[1]! : range[2]!
            return substring(stamp.lowerBound, stamp.upperBound)
        }
        return atTimestamp().map { substring($0.match[0]!.lowerBound, $0.match[0]!.upperBound) }
    }

    /// `org-parse-time-string`: date and time of an Org time string, time 0:00 if absent.
    static func parseTimeString(_ text: String) -> DateComponents? {
        guard let match = text.firstMatch(of: try! Regex(timeStringPattern)) else { return nil }
        func group(_ i: Int) -> Int? { match.output[i].substring.flatMap { Int($0) } }
        return DateComponents(year: group(2), month: group(3), day: group(4), hour: group(7) ?? 0, minute: group(8) ?? 0)
    }

    /// `format-time-string` with Org's timestamp formats, plus `extra` before the closing bracket.
    func formatTimestamp(_ components: DateComponents, withTime: Bool, inactive: Bool, extra: String? = nil) -> String {
        let date = calendar.date(from: components)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = withTime ? "yyyy-MM-dd EEE HH:mm" : "yyyy-MM-dd EEE"
        return (inactive ? "[" : "<") + formatter.string(from: date) + (extra ?? "") + (inactive ? "]" : ">")
    }

    /// `org-insert-timestamp`: inserted before markers, as org does.
    @discardableResult
    func insertTimestamp(_ components: DateComponents, withTime: Bool, inactive: Bool, endTime: String? = nil, extra: String? = nil) -> String {
        var suffix = extra
        if let endTime, let match = endTime.firstMatch(of: /([0-9]+):([0-9]+)/) {
            suffix = String(format: "-%02d:%02d", Int(match.1)!, Int(match.2)!)
        }
        let stamp = formatTimestamp(components, withTime: withTime, inactive: inactive, extra: suffix)
        insertBeforeMarkers(stamp)
        lastInsertedTimestamp = stamp
        return stamp
    }

    /// `org-modify-ts-extra`.
    static func modifyTimestampExtra(_ extra: String, _ position: Int, _ increments: Int, _ step: Int) -> String {
        let regex = try! NSRegularExpression(pattern: "(-([012][0-9]):([0-5][0-9]))?( +\\+([0-9]+)([dmwy]))?( +-([0-9]+)([dmwy]))?")
        let ns = extra as NSString
        guard let match = regex.firstMatch(in: extra, range: NSRange(location: 0, length: ns.length)) else { return extra }
        func range(_ i: Int) -> Range<Int>? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : r.location..<NSMaxRange(r)
        }
        func inGroup(_ i: Int) -> Bool { range(i).map { $0.lowerBound <= position && position <= $0.upperBound } ?? false }
        func text(_ i: Int) -> String { ns.substring(with: match.range(at: i)) }
        let order: [(String, Int)] = [("d", 0), ("w", 1), ("m", 2), ("y", 3), ("d", -1), ("y", 4)]
        func shifted(_ unit: String) -> String? {
            let index = order.first { $0.0 == unit }!.1 + increments
            return order.first { $0.1 == index }?.0
        }
        var group: Int?
        var new = ""
        if inGroup(2) || inGroup(3) {
            var minute = Int(text(3))!, hour = Int(text(2))!
            if inGroup(2) {
                hour += increments
            } else {
                let n = step * increments
                let rem = minute % step
                if rem != 0 { minute += n > 0 ? -rem : step - rem }
                minute += n
            }
            if minute < 0 { minute += 60; hour -= 1 }
            if minute > 59 { minute -= 60; hour += 1 }
            hour = ((hour % 24) + 24) % 24
            group = 1
            new = String(format: "-%02d:%02d", hour, minute)
        } else if inGroup(6) {
            group = 6
            new = shifted(text(6)) ?? ""
        } else if inGroup(5) {
            group = 5
            new = String(max(1, increments + Int(text(5))!))
        } else if inGroup(9) {
            group = 9
            new = shifted(text(9)) ?? ""
        } else if inGroup(8) {
            group = 8
            new = String(max(0, increments + Int(text(8))!))
        }
        guard let group, let target = range(group) else { return extra }
        return ns.replacingCharacters(in: NSRange(target), with: new)
    }

    enum TimestampUnit { case minute, hour, day, month, year }

    /// `org-timestamp-change`. `what` nil changes the part at point. On a CLOCK line the
    /// duration is then updated, unless `updateClock` is false.
    func changeTimestamp(_ n: Int, what: TimestampUnit? = nil, updown: Bool = false, suppressDelay: Bool = false, updateClock: Bool = true) throws {
        let origin = point
        guard let (category, match) = atTimestamp() else { throw UserError(message: "Not at a timestamp") }
        if what == nil, category == .bracket {
            toggleTimestampType(match[0]!)
            return
        }
        let target: TimestampPart = what.map { unit in
            switch unit {
            case .minute: .minute
            case .hour: .hour
            case .day: .day
            case .month: .month
            case .year: .year
            }
        } ?? category
        let whole = match[0]!
        let inactive = character(at: whole.lowerBound) == 91
        let stamp = substring(whole.lowerBound, whole.upperBound)
        replace(whole, with: "")
        var extra: String?
        if let found = stamp.firstMatch(of: try! Regex("((-[012][0-9]:[0-5][0-9])?( +[.+]?-?[-+][0-9]+[hdwmy](/[0-9]+[hdwmy])?)*)[\\]>]")) {
            extra = found.output[1].substring.map(String.init)
            if suppressDelay, let value = extra { extra = value.replacingOccurrences(of: " --[0-9]+[hdwmy]", with: "", options: .regularExpression) }
        }
        let withTime = stamp.range(of: "^.{10}.*?[0-9]+:[0-9][0-9]", options: .regularExpression) != nil
        var time = Self.parseTimeString(stamp)!
        var step = 5
        var increment = n
        if updown, target == .minute {
            increment = step * n.signum()
            let rem = time.minute! % step
            if rem != 0 { time.minute! += n > 0 ? -rem : step - rem }
        } else {
            step = 1
        }
        switch target {
        case .minute: time.minute! += increment
        case .hour: time.hour! += increment
        case .day: time.day! += increment
        case .month: time.month! += increment
        case .year: time.year! += increment
        default: break
        }
        let normalized = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: calendar.date(from: time)!)
        if target == .hour || target == .minute, let value = extra, value.range(of: "-([012][0-9]):([0-5][0-9])", options: .regularExpression) != nil {
            extra = Self.modifyTimestampExtra(value, target == .hour ? 2 : 5, n, step)
        }
        if case .extra(let position) = target, let value = extra {
            extra = Self.modifyTimestampExtra(value, position, n, step)
        }
        let insertion = point
        insertTimestamp(normalized, withTime: withTime, inactive: inactive, extra: extra)
        point = insertion
        let after = looking(Self.timestampPattern, caseInsensitive: false)!
        switch category {
        case .day:
            let end = after[5].map { $0.upperBound - 1 } ?? after[7]?.lowerBound ?? after[1]!.upperBound - 1
            point = min(end, origin)
        case .hour: point = min(after[7]!.upperBound, origin)
        case .minute: point = min(after[8]!.upperBound - 1, origin)
        case .extra: point = min(after[0]!.upperBound - 1, origin)
        case .after: point = after[0]!.upperBound
        default: point = origin
        }
        if updateClock {
            let before = point
            clockUpdateTime()
            if point >= before { point = before }
        }
    }

    /// `org-toggle-timestamp-type`.
    func toggleTimestampType(_ range: Range<Int>) {
        saveExcursion {
            for offset in range {
                let swapped: String? = switch character(at: offset) {
                case 91: "<"
                case 93: ">"
                case 60: "["
                case 62: "]"
                default: nil
                }
                if let swapped { replace(offset..<(offset + 1), with: swapped) }
            }
        }
    }

    /// `org-get-compact-tod`: the time of day in a timestamp, as the date prompt shows it.
    static func compactTimeOfDay(_ stamp: String) -> String? {
        guard let match = stamp.firstMatch(of: /(([012]?[0-9]):([0-5][0-9]))(-(([012]?[0-9]):([0-5][0-9])))?/) else { return nil }
        let t1 = String(match.1)
        guard let t2h = match.6, let t2m = match.7 else { return t1 }
        var dh = Int(t2h)! - Int(match.2)!
        var dm = Int(t2m)! - Int(match.3)!
        if dm < 0 { dm += 60; dh -= 1 }
        return t1 + "+" + String(dh) + (dm != 0 ? String(format: ":%02d", dm) : "")
    }

    // MARK: - Planning

    static let planningLinePattern = "^[ \\t]*(CLOSED|DEADLINE|SCHEDULED):"
    static let keywordTimeNotClock = "\\b(CLOSED|DEADLINE|SCHEDULED):[ \\t]*[\\[<]([^\\]>]+)[\\]>]"

    enum PlanningKind {
        case closed, deadline, scheduled

        var keyword: String {
            switch self {
            case .closed: "CLOSED:"
            case .deadline: "DEADLINE:"
            case .scheduled: "SCHEDULED:"
            }
        }

        var pattern: String {
            switch self {
            case .closed: "\\bCLOSED: *\\[([^\\]]+)\\]"
            case .deadline: "\\bDEADLINE: *<([^>]+)>"
            case .scheduled: "\\bSCHEDULED: *<([^>]+)>"
            }
        }
    }

    /// The time string of the entry's planning `kind`, as `org-entry-get`.
    func planningValue(_ kind: PlanningKind) -> String? {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return nil }
            forwardLine(1)
            guard lookingAt(Self.planningLinePattern) != nil,
                  let match = searchForward(kind.pattern, bound: lineEnd(point), caseInsensitive: false) else { return nil }
            return substring(match[1]!.lowerBound, match[1]!.upperBound)
        }
    }

    /// `org-add-planning-info` with a resolved time.
    func addPlanningInfo(_ what: PlanningKind?, time: DateComponents?, withTime: Bool, endTime: String?, remove: [PlanningKind]) throws {
        try saveExcursion {
            try backToHeading()
            let planning = saveExcursion { () -> Bool in
                forwardLine(1)
                return lookingAt(Self.planningLinePattern) != nil
            }
            if planning {
                forwardLine(1)
                skipForward(Self.blanks)
                for type in (what.map { [$0] } ?? []) + remove {
                    saveExcursion {
                        guard let match = searchForward(type.pattern, bound: lineEnd(point), caseInsensitive: false) else { return }
                        let start = match[0]!.lowerBound
                        let end = searchForward(Self.keywordTimeNotClock, bound: lineEnd(point), caseInsensitive: false)?[0]!.lowerBound ?? lineEnd(point)
                        deleteRegion(start, end)
                    }
                }
                if lookingAt("[ \\t]*$") != nil, what == nil {
                    deleteRegion(lineStart(point) - 1, lineEnd(point))
                } else {
                    let p = point
                    saveExcursion {
                        endOfLine()
                        let end = point
                        while point > p, let c = character(at: point - 1), c == 32 || c == 9 { point -= 1 }
                        if point < end { deleteRegion(point, end) }
                    }
                }
            } else if what != nil {
                endOfLine()
                insert("\n")
            }
            if let what, let time {
                insert(what.keyword + " ")
                insertTimestamp(time, withTime: withTime || what == .closed, inactive: what == .closed, endTime: endTime)
                if !eolp { insert(" ") }
            }
        }
    }
}
