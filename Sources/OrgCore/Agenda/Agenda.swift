import Foundation

public struct AgendaItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case deadline
        case upcomingDeadline = "upcoming-deadline"
        case scheduled
        case pastScheduled = "past-scheduled"
        case timestamp
        case block
        case sexp
        case timeGrid
        case currentTime
        case todo
        case tagsMatch = "tagsmatch"
        /// Log mode: a closed entry, a clock line, a state change.
        case closed, clock, state
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
    /// `APPT_WARNTIME`: minutes of warning before the entry's time.
    public let warntime: Int?
    /// The habit whose consistency graph goes on the line (scheduled habits).
    public let habit: Habit?
    /// The line as org prints it, with one space before the tags.
    public let line: String
    /// What `org-agenda-prefix-format` puts before the heading text.
    public var prefix = ""
    /// The entry's `Effort` property.
    public var effort: String?
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
    /// `org-agenda-prefix-format`, by view: `agenda`, `todo`, `tags`, `search`.
    public var prefixFormat = PrefixFormat.defaults
    /// Log mode (`l`): closed entries and clocked time on each day.
    public var logMode = false
    /// `org-agenda-log-mode-items`.
    public var logItems: Set<String> = ["closed", "clock"]

    public init() {}

    func prefix(_ view: String) -> PrefixFormat {
        PrefixFormat(prefixFormat[view] ?? PrefixFormat.defaults[view]!)
    }

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
        return (options.logMode ? progress(source, day: day, options: options) : []) + deadlines + scheduled(source, day: day, today: today, options: options) + blocks(source, day: day, options: options)
            + timestamps(source, day: day, today: today, options: options) + sexps(source, day: day, options: options)
    }

    /// `org-time-string-to-absolute` for a planning timestamp's text: a diary sexp counts on
    /// `current` when it applies then, and otherwise the entry is skipped.
    static func planningDay(_ s: String, current: Int) -> (day: Int, sexp: Bool)? {
        guard s.hasPrefix("%%(") else { return Days.absolute(of: s).map { ($0, false) } }
        guard let close = s.lastIndex(of: ")"), let (sexp, _) = try? LispReader.readFirst(String(s[s.index(s.startIndex, offsetBy: 2)...close])),
              DiarySexp.matches(sexp, day: current) else { return nil }
        return (current, true)
    }

    // MARK: - Collectors

    static func deadlines(_ source: AgendaSource, day current: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let isToday = current == today
        var items: [AgendaItem] = []
        for heading in source.headings {
            guard !heading.skipped, let (s, offset) = heading.deadline, let (deadline, sexp) = planningDay(s, current: current) else { continue }
            let repeat_ = sexp || current <= today ? deadline : (Days.closest(s, to: current, prefer: .future) ?? deadline)
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
                dotime: time, removing: nil, trailing: options.gridTrailing, prefix: options.prefix("agenda"), urgency: { (isToday ? -diff : 0) + $0 }
            ))
        }
        return items
    }

    static func scheduled(_ source: AgendaSource, day current: Int, today: Int, options: AgendaOptions) -> [AgendaItem] {
        let isToday = current == today
        var items: [AgendaItem] = []
        for heading in source.headings {
            guard !heading.skipped, let (s, offset) = heading.scheduled, let (schedule, sexp) = planningDay(s, current: current) else { continue }
            let repeat_ = sexp || current <= today ? schedule : (Days.closest(s, to: current, prefer: .future) ?? schedule)
            let diff = current - schedule
            let past = schedule < today
            let delay = Days.warningDays(s, delay: true, defaultDays: 0)
            if (delay > 0 && diff < delay) || diff > 10000 || schedule > current
                || (current != schedule && current != today && current != repeat_) {
                continue
            }
            if heading.isDone, schedule != current { continue }
            // org-habit: habits only on today's agenda, and not when done.
            if heading.isHabit, heading.isDone || !isToday { continue }
            let time: Dotime? = !heading.isHabit && current != schedule && current != repeat_ ? nil : (timeIn(s).map { .string($0) } ?? .headline)
            let extra = heading.isHabit ? "" : isToday && past ? String(format: "Sched.%2dx: ", diff) : "Scheduled: "
            let habit = heading.isHabit ? heading.habit : nil
            items.append(format(
                source, heading, kind: past ? .pastScheduled : .scheduled, marker: offset, extra: extra,
                dotime: time, removing: nil, trailing: options.gridTrailing, prefix: options.prefix("agenda"), habit: habit,
                urgency: { habit?.urgency(today: today) ?? 99 + diff + $0 }
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
            items.append(format(source, heading, kind: .block, marker: block.marker, extra: extra, dotime: dotime, removing: nil, trailing: options.gridTrailing, prefix: options.prefix("agenda"), urgency: { $0 }))
        }
        return items
    }

    /// `org-agenda-get-progress`.
    static func progress(_ source: AgendaSource, day current: Int, options: AgendaOptions) -> [AgendaItem] {
        let date = Days.date(current)
        let literal = String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
        var items: [AgendaItem] = []
        for entry in source.progress where entry.date == literal {
            let kind: AgendaItem.Kind
            let extra: String
            switch entry.kind {
            case .closed:
                guard options.logItems.contains("closed") else { continue }
                (kind, extra) = (.closed, "Closed:    ")
            case .clock:
                guard options.logItems.contains("clock") else { continue }
                (kind, extra) = (.clock, "Clocked:   (\(entry.clocked))")
            case .state:
                guard options.logItems.contains("state") else { continue }
                (kind, extra) = (.state, "State:     (\(entry.state ?? ""))")
            }
            let heading = source.headings[entry.heading]
            var head = heading.head
            if let note = entry.note {
                // Before the tags, as org adds it.
                if let tags = head.range(of: "([ \\t]+)(:[^ \\n\\t]*?:)[ \\t]*$", options: .regularExpression) {
                    let tagText = head[tags].trimmingCharacters(in: .whitespaces)
                    head = head[..<tags.lowerBound] + " - " + note + " " + tagText
                } else {
                    head += " - " + note
                }
            }
            items.append(format(
                source, heading, kind: kind, marker: entry.offset, extra: extra, dotime: .only(entry.timestamp), removing: nil,
                trailing: options.gridTrailing, prefix: options.prefix("agenda"), head: head, urgency: { _ in 100_000 }
            ))
        }
        return items
    }

    static let diaryStamp = try! NSRegularExpression(pattern: "^<%%(\\([^>\\n]+\\))([^\\n>]*)>")
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
            } else if let m = diaryStamp.firstMatch(in: stamp.rest, range: all) {
                guard let (sexp, _) = try? LispReader.readFirst(rest.substring(with: m.range(at: 1))), DiarySexp.matches(sexp, day: current) else { continue }
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
                dotime: .string(timestamp), removing: stampActive, trailing: options.gridTrailing, prefix: options.prefix("agenda"),
                urgency: { heading.isHabit ? heading.habit?.urgency(today: today) ?? $0 : $0 }
            ))
        }
        return items
    }

    /// `org-agenda-get-sexps`.
    static func sexps(_ source: AgendaSource, day current: Int, options: AgendaOptions) -> [AgendaItem] {
        var items: [AgendaItem] = []
        for line in source.sexps {
            guard let results = DiarySexp.entries(line.sexp, entry: line.entry, day: current) else { continue }
            let heading = source.headings[line.heading]
            for result in results {
                let txt = result.contains(where: { !$0.isWhitespace }) ? result : "SEXP entry returned empty string"
                items.append(format(
                    source, heading, kind: .sexp, marker: line.offset, extra: "", dotime: .headline, removing: nil,
                    trailing: options.gridTrailing, prefix: options.prefix("agenda"), head: txt, attached: false, urgency: { _ in 0 }
                ))
            }
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
        /// In the string only (`org-agenda-search-headline-for-time` nil).
        case only(String)
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
        extra: String, dotime: Dotime?, removing: NSRegularExpression?, trailing: String, prefix prefixFormat: PrefixFormat,
        head: String? = nil, habit: Habit? = nil, attached: Bool = true, urgency: (Int) -> Int
    ) -> AgendaItem {
        var txt = (head ?? heading.head).trimmingCharacters(in: .whitespaces)
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

        let timed = timeFields(&txt, tagString: tagString, dotime: dotime, trailing: trailing, removeTimes: prefixFormat.hasTime)
        if let removing {
            while let m = removing.firstMatch(in: txt, range: NSRange(location: 0, length: (txt as NSString).length)) {
                txt = (txt as NSString).replacingCharacters(in: m.range, with: "")
            }
        }
        let category = heading.category
        let prefix = prefixFormat.render([
            "c": category, "t": timed.time, "s": habit == nil ? extra : "", "l": String(repeating: " ", count: heading.level),
            "e": heading.properties["EFFORT"] ?? "", "b": breadcrumbs(source, heading), "T": tags.last?.name ?? "",
        ])
        txt = highlightTodo(txt, keywords: source.keywords)
        let priority = Self.priority(prefix + txt, source.priorities)
        return AgendaItem(
            kind: kind, path: source.path, headingOffset: attached ? heading.start : nil, headingLine: attached ? heading.line : nil, markerOffset: marker, category: category,
            timeOfDay: timed.timeOfDay, time: timed.time, extra: extra, text: txt, tags: tags.map(\.name),
            todo: heading.todo, isDone: heading.isDone, urgency: urgency(priority),
            warntime: heading.properties["APPT_WARNTIME"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }, habit: habit,
            line: prefix + txt + (tagString.isEmpty ? "" : " " + tagString), prefix: prefix, effort: heading.properties["EFFORT"]
        )
    }

    /// `%b`: the outline path above the heading, each title followed by `->`.
    static func breadcrumbs(_ source: AgendaSource, _ heading: AgendaSource.Heading) -> String {
        guard let index = source.headings.firstIndex(where: { $0.start == heading.start }) else { return "" }
        var path: [String] = []
        var level = heading.level
        for candidate in source.headings[..<index].reversed() where candidate.level < level {
            let title = candidate.title.replacingOccurrences(of: "\\[[0-9]+%\\]|\\[[0-9]+/[0-9]+\\]", with: "", options: .regularExpression)
            path.insert(Links.displayFormat(title).trimmingCharacters(in: .whitespaces), at: 0)
            level = candidate.level
            if level == 1 { break }
        }
        return path.isEmpty ? "" : path.joined(separator: "->") + "->"
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
        case .only(let s): containing = s
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
                time: timed.time, extra: "", text: txt, tags: [], todo: nil, isDone: false, urgency: 0, warntime: nil, habit: nil,
                line: options.prefix("agenda").render(["t": timed.time]) + txt, prefix: options.prefix("agenda").render(["t": timed.time])
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
            if (a.element.habit == nil) != (b.element.habit == nil) { return a.element.habit == nil }
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
