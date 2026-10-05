import Foundation

public struct AgendaItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case deadline
        case upcomingDeadline = "upcoming-deadline"
        case scheduled
        case pastScheduled = "past-scheduled"
        case timestamp
        case block
        case timeGrid
        case currentTime
        case todo
        case tagsMatch = "tagsmatch"
    }

    public let kind: Kind
    public let path: String?
    /// Start of the entry's heading line.
    public let headingOffset: Int?
    /// The heading line as it was read, from its stars, to check the offsets still hold.
    public let headingLine: String?
    /// Where org's marker points: the timestamp, or the end of a range.
    public let markerOffset: Int?
    public let category: String
    /// `HHMM`, when the item has a time of day.
    public let timeOfDay: Int?
    /// `14:00-15:00`, ` 9:00......`, or empty.
    public let time: String
    /// The leader: `Deadline:  `, `Sched. 2x: `, `(1/3): `.
    public let extra: String
    /// The heading text as shown: TODO keyword, priority, title, without tags.
    public let text: String
    public let tags: [String]
    public let todo: String?
    public let isDone: Bool
    public let urgency: Int
    /// The line as org prints it, with one space before the tags.
    public let line: String
}

public struct AgendaDay: Sendable, Equatable {
    /// Emacs's absolute day number (`Days`).
    public let day: Int
    public let isToday: Bool
    /// `Monday      5 October 2026 W41`.
    public let header: String
    public let items: [AgendaItem]
}

public struct AgendaOptions: Sendable, Equatable {
    public var deadlineWarningDays = 14
    public var gridTimes = [800, 1000, 1200, 1400, 1600, 1800, 2000]
    public var gridTrailing = " ┄┄┄┄┄ "
    public var gridLine = "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
    public var currentTimeLine = "← now ───────────────────────────────────────────────"

    public init() {}

    /// What Emacs shows without a graphical display.
    public static let terminal: AgendaOptions = {
        var options = AgendaOptions()
        options.gridTrailing = "......"
        options.gridLine = "----------------"
        options.currentTimeLine = "now - - - - - - - - - - - - - - - - - - - - - - - - -"
        return options
    }()
}

/// `org-agenda-list`.
public enum Agenda {
    public static func list(
        _ sources: [AgendaSource], start: Int, days: Int, today: Int, now: (hour: Int, minute: Int),
        options: AgendaOptions = AgendaOptions()
    ) -> [AgendaDay] {
        (start..<(start + days)).map { day in
            var items: [AgendaItem] = []
            for source in sources { items += entries(source, day: day, today: today, options: options) }
            let isToday = day == today
            if (isToday || days == 1), items.contains(where: { $0.timeOfDay != nil }) {
                items = grid(day: day, isToday: isToday, now: now, options: options) + items
            }
            return AgendaDay(day: day, isToday: isToday, header: header(day), items: sort(items))
        }
    }

    /// `org-agenda-get-day-entries` with the default entry types.
    static func entries(_ source: AgendaSource, day: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let deadlines = self.deadlines(source, day: day, today: today, options: options)
        return deadlines + scheduled(source, day: day, today: today, options: options) + blocks(source, day: day, options: options)
            + timestamps(source, day: day, today: today, options: options)
    }

    // MARK: - Collectors

    static func deadlines(_ source: AgendaSource, day current: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let isToday = current == today
        var items: [AgendaItem] = []
        for heading in source.headings {
            guard !heading.skipped, let (s, offset) = heading.deadline, let deadline = Days.absolute(of: s) else { continue }
            let repeat_ = current <= today ? deadline : (Days.closest(s, to: current, prefer: .future) ?? deadline)
            let diff = deadline - current
            let warningDays = Days.warningDays(s, delay: false, defaultDays: options.deadlineWarningDays)
            if current != deadline, current != repeat_ {
                if !isToday { continue }
                if deadline > current {
                    if diff > warningDays { continue }
                } else if 10000 < -diff {
                    continue
                }
            }
            if heading.isDone, deadline != current { continue }
            let time: Dotime? = current != deadline && current != repeat_ ? nil : (timeIn(s).map { .string($0) } ?? .headline)
            let extra: String
            if isToday, deadline < today {
                extra = String(format: "%2d d. ago: ", -diff)
            } else if isToday, deadline > today {
                extra = String(format: "In %3d d.: ", diff)
            } else {
                extra = "Deadline:  "
            }
            let upcoming = isToday && deadline > today
            items.append(format(
                source, heading, kind: upcoming ? .upcomingDeadline : .deadline, marker: offset, extra: extra,
                dotime: time, removing: nil, trailing: options.gridTrailing, urgency: { (isToday ? -diff : 0) + $0 }
            ))
        }
        return items
    }

    static func scheduled(_ source: AgendaSource, day current: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let isToday = current == today
        var items: [AgendaItem] = []
        for heading in source.headings {
            guard !heading.skipped, let (s, offset) = heading.scheduled, let schedule = Days.absolute(of: s) else { continue }
            let repeat_ = current <= today ? schedule : (Days.closest(s, to: current, prefer: .future) ?? schedule)
            let diff = current - schedule
            let past = schedule < today
            let delay = Days.warningDays(s, delay: true, defaultDays: 0)
            if (delay > 0 && diff < delay) || diff > 10000 || schedule > current
                || (current != schedule && current != today && current != repeat_) {
                continue
            }
            if heading.isDone, schedule != current { continue }
            let time: Dotime? = current != schedule && current != repeat_ ? nil : (timeIn(s).map { .string($0) } ?? .headline)
            let extra = isToday && past ? String(format: "Sched.%2dx: ", diff) : "Scheduled: "
            items.append(format(
                source, heading, kind: past ? .pastScheduled : .scheduled, marker: offset, extra: extra,
                dotime: time, removing: nil, trailing: options.gridTrailing, urgency: { 99 + diff + $0 }
            ))
        }
        return items
    }

    static func blocks(_ source: AgendaSource, day current: Int, options: AgendaOptions) -> [AgendaItem] {
        var items: [AgendaItem] = []
        for block in source.blocks {
            guard let startDay = Days.absolute(of: block.start), let endDay = Days.absolute(of: block.end),
                  current >= startDay, endDay >= current else { continue }
            let heading = source.headings[block.heading]
            let extra = startDay == endDay ? "" : "(\(current - startDay + 1)/\(endDay - startDay + 1)): "
            let dotime: Dotime?
            if startDay == current, endDay == current {
                dotime = .string("<\(block.start)>--<\(block.end)>")
            } else if startDay == current {
                dotime = .string("<\(block.start)>")
            } else if endDay == current {
                dotime = .string("<\(block.end)>")
            } else {
                dotime = nil
            }
            items.append(format(source, heading, kind: .block, marker: block.marker, extra: extra, dotime: dotime, removing: nil, trailing: options.gridTrailing, urgency: { $0 }))
        }
        return items
    }

    static let repeating = try! NSRegularExpression(pattern: "^<[0-9]+-[0-9]+-[0-9]+[^>\\n]+?\\+[0-9]+[hdwmy]>")
    static let stampBoth = try! NSRegularExpression(pattern: "^[\\[<](\(AgendaSource.tsInternal))[\\]>]")
    static let stampActive = try! NSRegularExpression(pattern: "<(\(AgendaSource.tsInternal))>")
    static let stampAny = try! NSRegularExpression(pattern: "[\\[<](\(AgendaSource.tsInternal))[\\]>]")

    static func timestamps(_ source: AgendaSource, day current: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let date = Days.date(current)
        let literal = String(format: "<%04d-%02d-%02d", date.year, date.month, date.day)
        var items: [AgendaItem] = []
        for stamp in source.stamps {
            let rest = stamp.rest as NSString
            let all = NSRange(location: 0, length: rest.length)
            let timestamp: String
            if stamp.rest.hasPrefix(literal) {
                guard let m = stampBoth.firstMatch(in: stamp.rest, range: all) else { continue }
                timestamp = rest.substring(with: m.range)
            } else if let m = repeating.firstMatch(in: stamp.rest, range: all) {
                let repeat_ = rest.substring(with: m.range)
                guard let past = Days.closest(repeat_, to: current > today ? today : current, prefer: .past) else { continue }
                let future = current <= today ? past : (Days.closest(repeat_, to: current, prefer: .future) ?? past)
                if current != past, current != future { continue }
                timestamp = repeat_
            } else {
                continue
            }
            let heading = source.headings[stamp.heading]
            items.append(format(
                source, heading, kind: .timestamp, marker: stamp.offset, extra: "",
                dotime: .string(timestamp), removing: stampActive, trailing: options.gridTrailing, urgency: { $0 }
            ))
        }
        return items
    }

    /// `" HH:MM"` in a planning timestamp: the time and everything after it.
    static func timeIn(_ s: String) -> String? {
        guard let r = s.range(of: " [012]?[0-9]:[0-9][0-9]", options: .regularExpression) else { return nil }
        return String(s[s.index(after: r.lowerBound)...]) + " "
    }

    // MARK: - Formatting

    enum Dotime {
        case string(String)
        /// Look for a time in the heading only.
        case headline
    }

    static let tagGroup = try! NSRegularExpression(pattern: "[ \\t]+(:([\\p{L}\\p{N}_@#%:]+):)[ \\t]*$")
    static let stampTime = try! NSRegularExpression(
        pattern: "<([0-9]{4}-[0-9]{2}-[0-9]{2} +[\\p{L}\\p{N}_]+ +)([012][0-9]:[0-5][0-9])(-([012][0-9]:[0-5][0-9]))?[^\\n\\r>]*?>(--?<\\1([012][0-9]:[0-5][0-9])>)?"
    )
    static let plainTimePart = "((?<![\\p{L}\\p{N}_])[012]?[0-9]((:([0-5][0-9]([AaPp][Mm])?))|([AaPp][Mm]))(?![\\p{L}\\p{N}_]))"
    static let plainTime = try! NSRegularExpression(pattern: "\(plainTimePart)(--?\(plainTimePart))?")
    static let timeOfDay = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_])([012]?[0-9])(?::([0-5][0-9])(am|pm)?|(am|pm))(?![\\p{L}\\p{N}_])",
        options: .caseInsensitive
    )

    /// `org-agenda-format-item` with the default agenda prefix ` %i %-12:c%?-12t% s`, then
    /// `org-agenda-highlight-todo`.
    static func format(
        _ source: AgendaSource, _ heading: AgendaSource.Heading, kind: AgendaItem.Kind, marker: Int,
        extra: String, dotime: Dotime?, removing: NSRegularExpression?, trailing: String, hasTime: Bool = true,
        urgency: (Int) -> Int
    ) -> AgendaItem {
        var txt = heading.head.trimmingCharacters(in: .whitespaces)
        // `org-agenda-fix-displayed-tags`: the heading's tags are replaced by the full list.
        let tags = heading.tags
        if let m = tagGroup.firstMatch(in: txt, range: NSRange(location: 0, length: (txt as NSString).length)) {
            txt = (txt as NSString).substring(to: m.range.location)
        }
        var tagString = ""
        if !tags.isEmpty {
            var haveInherited = tags[0].inherited
            var parts: [String] = []
            for tag in tags {
                if haveInherited, !tag.inherited {
                    haveInherited = false
                    parts.append(":" + tag.name)
                } else {
                    parts.append(tag.name)
                }
            }
            tagString = ":" + parts.joined(separator: ":") + (haveInherited ? "::" : ":")
        }

        let timed = timeFields(&txt, tagString: tagString, dotime: dotime, trailing: trailing, removeTimes: hasTime)
        if let removing {
            while let m = removing.firstMatch(in: txt, range: NSRange(location: 0, length: (txt as NSString).length)) {
                txt = (txt as NSString).replacingCharacters(in: m.range, with: "")
            }
        }
        let category = heading.category
        // ` %i %-12:c%?-12t% s` in the agenda, ` %i %-12:c` in TODO and tags lists.
        let prefix = "  " + pad(category.isEmpty ? "" : category + ":", 12)
            + (hasTime ? (timed.time.isEmpty ? "" : pad(timed.time, 12)) + (extra.isEmpty ? "" : extra + " ") : "")
        txt = highlightTodo(txt, keywords: source.keywords)
        let priority = Self.priority(prefix + txt, source.priorities)
        return AgendaItem(
            kind: kind, path: source.path, headingOffset: heading.start, headingLine: heading.line, markerOffset: marker, category: category,
            timeOfDay: timed.timeOfDay, time: timed.time, extra: extra, text: txt, tags: tags.map(\.name),
            todo: heading.todo, isDone: heading.isDone, urgency: urgency(priority),
            line: prefix + txt + (tagString.isEmpty ? "" : " " + tagString)
        )
    }

    /// The time-of-day part of `org-agenda-format-item`: finds the time, removes it from the
    /// text, and formats the `%t` field.
    static func timeFields(_ txt: inout String, tagString: String, dotime: Dotime?, trailing: String, removeTimes: Bool = true) -> (timeOfDay: Int?, time: String) {
        guard let dotime else { return (nil, "") }
        let full = tagString.isEmpty ? txt : txt + " " + tagString
        let withoutStamps = stampAny.stringByReplacingMatches(in: full, range: NSRange(location: 0, length: (full as NSString).length), withTemplate: "")
        let containing: String
        switch dotime {
        case .string(let s): containing = s + withoutStamps
        case .headline: containing = withoutStamps
        }
        guard let timeOfDay = time(of: containing) else { return (nil, "") }
        let ns = containing as NSString
        let all = NSRange(location: 0, length: ns.length)
        var start: String?
        var end: String?
        if let m = stampTime.firstMatch(in: containing, range: all) {
            start = ns.substring(with: m.range(at: 2))
            let endGroup = m.range(at: 3).location != NSNotFound ? 4 : 6
            if m.range(at: endGroup).location != NSNotFound { end = ns.substring(with: m.range(at: endGroup)) }
            if removeTimes { removeTime(ns.substring(with: m.range), from: &txt) }
        } else if let m = plainTime.firstMatch(in: containing, range: all) {
            start = ns.substring(with: m.range(at: 1))
            if m.range(at: 8).location != NSNotFound { end = ns.substring(with: m.range(at: 8)) }
            if removeTimes { removeTime(ns.substring(with: m.range), from: &txt) }
        }
        let startText = start.flatMap(formattedTime).map { String(repeating: " ", count: max(0, 5 - $0.count)) + $0 }
        let endText = end.flatMap(formattedTime)
        let time: String
        if let startText, let endText {
            time = startText + "-" + endText
        } else if let startText {
            time = startText + trailing
        } else {
            time = ""
        }
        return (timeOfDay, time)
    }

    /// `org-agenda-remove-times-when-in-prefix`.
    static func removeTime(_ timeString: String, from txt: inout String) {
        let ns = txt as NSString
        let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: timeString) + " *")
        guard let m = regex.firstMatch(in: txt, range: NSRange(location: 0, length: ns.length)) else { return }
        if NSMaxRange(m.range) < ns.length, ns.character(at: NSMaxRange(m.range)) == 93 { return }
        txt = ns.replacingCharacters(in: m.range, with: "")
    }

    /// `org-get-time-of-day` as a number.
    static func time(of s: String) -> Int? {
        let ns = s as NSString
        guard let m = timeOfDay.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var hours = Int(ns.substring(with: m.range(at: 1)))!
        let minutes = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2)))! : 0
        let ampmRange = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 4)
        if ampmRange.location != NSNotFound {
            let am = ns.substring(with: ampmRange).lowercased() == "am"
            hours = hours == 12 ? (am ? 0 : 12) : hours + (am ? 0 : 12)
        }
        return hours * 100 + minutes
    }

    /// `org-get-time-of-day` with `overtime`: `H:MM`, or `+H:MM` past midnight.
    static func formattedTime(_ s: String) -> String? {
        guard let value = time(of: s) else { return nil }
        let hours = value / 100
        let minutes = value % 100
        if hours > 24 || (hours == 24 && minutes > 0) { return String(format: "+%d:%02d", hours - 24, minutes) }
        return String(format: "%d:%02d", hours, minutes)
    }

    /// `format "%-Ns"`: pads to a display width.
    static func pad(_ s: String, _ width: Int) -> String {
        s + String(repeating: " ", count: max(0, width - displayWidth(s)))
    }

    /// `org-agenda-highlight-todo` with `org-agenda-todo-keyword-format` `%-1s`: the spaces
    /// after a leading TODO keyword become one.
    static func highlightTodo(_ txt: String, keywords: [String]) -> String {
        let dots = txt.prefix { $0 == "." }
        let rest = txt.dropFirst(dots.count)
        for keyword in keywords.sorted(by: { $0.count > $1.count }) where rest.hasPrefix(keyword) {
            let after = rest.dropFirst(keyword.count)
            guard after.first == " " else { continue }
            return dots + keyword + " " + after.drop { $0 == " " }
        }
        return txt
    }

    /// `org-get-priority`.
    static func priority(_ s: String, _ priorities: Priorities) -> Int {
        func value(_ p: String) -> Int {
            p.allSatisfy(\.isNumber) ? Int(p)! : Int(p.unicodeScalars.first!.value)
        }
        let lowest = value(priorities.lowest)
        if let r = s.range(of: "\\[#([A-Z]|[0-9]|[1-5][0-9]|6[0-4])\\]", options: .regularExpression) {
            return 1000 * (lowest - value(String(s[r].dropFirst(2).dropLast())))
        }
        return 1000 * (lowest - value(priorities.default))
    }

    // MARK: - Grid, sorting, headers

    /// `org-agenda-add-time-grid-maybe`.
    static func grid(day: Int, isToday: Bool, now: (hour: Int, minute: Int), options: AgendaOptions) -> [AgendaItem] {
        func item(_ kind: AgendaItem.Kind, _ text: String, _ dotime: String) -> AgendaItem {
            var txt = text
            let timed = timeFields(&txt, tagString: "", dotime: .string(dotime), trailing: options.gridTrailing)
            return AgendaItem(
                kind: kind, path: nil, headingOffset: nil, headingLine: nil, markerOffset: nil, category: "", timeOfDay: timed.timeOfDay,
                time: timed.time, extra: "", text: txt, tags: [], todo: nil, isDone: false, urgency: 0,
                line: "  " + pad("", 12) + pad(timed.time, 12) + txt
            )
        }
        var new = options.gridTimes.reversed().map { t in
            item(.timeGrid, options.gridLine, String(format: "%02d:%02d", t / 100, t % 100))
        }
        if isToday {
            new.insert(item(.currentTime, options.currentTimeLine, String(format: "%02d:%02d ", now.hour, now.minute)), at: 0)
        }
        return new
    }

    /// `org-entries-lessp` with `(habit-down time-up urgency-down category-keep)`, stably.
    static func sort(_ items: [AgendaItem]) -> [AgendaItem] {
        items.enumerated().sorted { a, b in
            let ta = a.element.timeOfDay ?? 9901
            let tb = b.element.timeOfDay ?? 9901
            if ta != tb { return ta < tb }
            if a.element.urgency != b.element.urgency { return a.element.urgency > b.element.urgency }
            return a.offset < b.offset
        }.map(\.element)
    }

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// `org-agenda-format-date-aligned`.
    public static func header(_ day: Int) -> String {
        let date = Days.date(day)
        let weekday = Days.weekday(day)
        let week = weekday == 1 ? String(format: " W%02d", Days.isoWeek(day)) : ""
        return pad(dayNames[weekday], 10) + String(format: " %2d ", date.day) + monthNames[date.month - 1] + String(format: " %4d", date.year) + week
    }
}
