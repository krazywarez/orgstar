import Foundation

/// The `org-icalendar-*` variables (ox-icalendar.el, Org 9.8.7).
public struct ICalendarOptions: Sendable, Equatable {
    /// `org-icalendar-include-todo`.
    public enum IncludeTodo: Sendable, Equatable {
        case none
        /// `t`: entries not done.
        case unfinished
        case all
        /// Not done, and not blocked by children or an `ORDERED` parent.
        case unblocked
        case keywords([String])
    }

    /// `org-icalendar-include-body`.
    public enum Body: Sendable, Equatable {
        case none, all
        case characters(Int)
    }

    /// `org-icalendar-use-deadline`: `event-if-not-todo`, `event-if-todo`,
    /// `event-if-todo-not-done`, `todo-due`.
    public var useDeadline: [String] = ["event-if-not-todo", "todo-due"]
    /// `org-icalendar-use-scheduled`: as `useDeadline`, with `todo-start`.
    public var useScheduled: [String] = ["todo-start"]
    public var includeTodo = IncludeTodo.none
    /// `org-icalendar-exclude-tags`, unless the file has `#+ICALENDAR_EXCLUDE_TAGS`.
    public var excludeTags: [String] = []
    /// `org-icalendar-categories`: `category`, `todo-state`, `local-tags`, `all-tags`.
    public var categories = ["local-tags", "category"]
    /// `org-icalendar-with-timestamps`: `active`, `inactive`, `t`, `nil`, unless the file's
    /// `#+OPTIONS` has `<:`.
    public var withTimestamps = "active"
    public var includeBody = Body.all
    /// `org-icalendar-alarm-time`, minutes; 0 for none.
    public var alarmTime = 0
    public var forceAlarm = false
    public var scheduledSummaryPrefix = "S: "
    public var deadlineSummaryPrefix = "DL: "
    /// `org-icalendar-todo-unscheduled-start`: `recurring-deadline-warning`,
    /// `deadline-warning`, `current-datetime`, `nil`.
    public var todoUnscheduledStart = "recurring-deadline-warning"
    /// `org-icalendar-timezone`; nil or empty for the time zone's abbreviation.
    public var timezone: String?
    /// `org-icalendar-date-time-format`: `:%Y%m%dT%H%M%S`, or with `Z` for UTC.
    public var dateTimeFormat = ":%Y%m%dT%H%M%S"
    /// `org-icalendar-ttl`, unless the file has `#+ICAL-TTL`.
    public var ttl: String?
    public var combinedName = "OrgMode"
    public var combinedDescription = ""
    /// `org-agenda-default-appointment-duration`, minutes.
    public var appointmentDuration: Int?
    /// `user-full-name`: the owner when a file has no `#+AUTHOR`, and of a combined calendar.
    public var userFullName = ""

    public init() {}
}

/// iCalendar export (`org-icalendar-export-to-ics`, `org-icalendar-combine-agenda-files`):
/// VEVENTs from deadlines, scheduled dates and other timestamps, VTODOs from tasks, with
/// lines folded at 75 characters and CRLF line ends. Diary sexps are left out.
public enum ICalendarExport {
    /// The calendar for a file named `name` (its base name is the calendar's), or for the
    /// subtree at `subtree` alone.
    public static func calendar(
        _ text: String, name: String, settings: OrgSettings = .default, options: ICalendarOptions = ICalendarOptions(),
        subtree: Int? = nil, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let file = File(text, name: name, settings: settings, options: options, subtree: subtree, now: now, calendar: calendar)
        let author = file.keyword("AUTHOR") ?? options.userFullName
        return vcalendar(
            name: (name as NSString).deletingPathExtension, owner: file.export.author ? file.ascii.inlineString(author) : "",
            timezone: zone(options, calendar), description: file.title, ttl: file.keyword("ICAL-TTL") ?? options.ttl, contents: file.components()
        )
    }

    /// One calendar of every file's entries, named `combinedName`.
    public static func combined(
        _ files: [(name: String, text: String, settings: OrgSettings)], options: ICalendarOptions = ICalendarOptions(),
        now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let contents = files.map {
            File($0.text, name: $0.name, settings: $0.settings, options: options, subtree: nil, now: now, calendar: calendar).components()
        }.joined()
        return vcalendar(name: options.combinedName, owner: options.userFullName, timezone: zone(options, calendar),
                         description: options.combinedDescription, ttl: options.ttl, contents: contents)
    }

    static func zone(_ options: ICalendarOptions, _ calendar: Calendar) -> String {
        if let tz = options.timezone, !tz.isEmpty { return tz }
        return calendar.timeZone.abbreviation() ?? calendar.timeZone.identifier
    }

    /// `org-icalendar--vcalendar`, folded, with CRLF line ends.
    static func vcalendar(name: String, owner: String, timezone: String, description: String, ttl: String?, contents: String) -> String {
        var out = "BEGIN:VCALENDAR\nVERSION:2.0\nX-WR-CALNAME:\(cleanup(name))\nPRODID:-//\(cleanup(owner))//Emacs with Org mode//EN\n"
            + "X-WR-TIMEZONE:\(cleanup(timezone))\nX-WR-CALDESC:\(cleanup(description))\n"
        if let ttl { out += "X-PUBLISHED-TTL:\(cleanup(ttl))\n" }
        out += "CALSCALE:GREGORIAN\n" + contents + "END:VCALENDAR\n"
        return fold(out).replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// `org-icalendar-cleanup-string`: `\`, `,` and `;` escaped, newlines as `\n`.
    static func cleanup(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "\\" || c == "," || c == ";" { out.append("\\") }
            out.append(c)
        }
        return out.replacing(#/[ \t]*\n/#, with: "\\n")
    }

    /// `org-icalendar-fold-string`: lines over 75 characters continue on lines starting with a
    /// space.
    static func fold(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.map { line -> String in
            let scalars = Array(line.unicodeScalars)
            guard scalars.count > 75 else { return line }
            var parts = [String(String.UnicodeScalarView(scalars[0..<75]))]
            var start = 75
            while start < scalars.count {
                let end = min(start + 74, scalars.count)
                parts.append(" " + String(String.UnicodeScalarView(scalars[start..<end])))
                start = end
            }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    /// `org-export--skip-timestamp-p` for a timestamp written `text`.
    static func skipsTimestamp(_ text: String, with: String) -> Bool {
        let diary = text.hasPrefix("<%%")
        let active = text.hasPrefix("<")
        switch with {
        case "nil": return true
        case "active": return !active
        case "active-exclude-diary": return !active || diary
        case "inactive": return active
        default: return false
        }
    }

    // MARK: - A file's entries

    struct File {
        let text: String
        let source: NSString
        let tree: OrgTree
        let model: DocumentModel
        let options: ICalendarOptions
        var export: ExportOptions
        let ascii: ASCIIText
        let name: String
        let subtree: Int?
        let now: Date
        let calendar: Calendar
        let selected: Set<Int>?
        let headingIndex: [Int: Int]
        let settings: OrgSettings

        init(_ text: String, name: String, settings: OrgSettings, options: ICalendarOptions, subtree: Int?, now: Date, calendar: Calendar) {
            let text = ExportPreprocess.macros(text, path: name, now: now, setup: settings.setupKeywords)
            self.text = text
            source = text as NSString
            tree = OrgParser.parse(text, defaults: settings)
            model = DocumentModel(tree: tree)
            self.options = options
            self.settings = settings
            var export = ExportOptions.parse(settings.setupKeywords + "\n" + text)
            export.excludeTags = Self.keyword("ICALENDAR_EXCLUDE_TAGS", tree: tree, settings: settings)
                .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? options.excludeTags
            if export.timestamps == nil { export.timestamps = options.withTimestamps }
            self.export = export
            var ascii = ASCIIText(options: export)
            var numbers = Array(repeating: 0, count: max(1, export.headlineLevels))
            for heading in model.headings where heading.level <= export.headlineLevels {
                numbers[heading.level - 1] += 1
                for deeper in heading.level..<numbers.count { numbers[deeper] = 0 }
                let plain = Links.displayFormat(heading.title).trimmingCharacters(in: .whitespaces)
                if ascii.headingNumbers[plain] == nil { ascii.headingNumbers[plain] = numbers.prefix(heading.level).map(String.init).joined(separator: ".") }
            }
            self.ascii = ascii
            self.name = name
            self.subtree = subtree
            self.now = now
            self.calendar = calendar
            selected = HTMLRenderer.selection(tree, tags: export.selectTags)
            headingIndex = Dictionary(model.headings.enumerated().map { ($1.headingRange.lowerBound, $0) }, uniquingKeysWith: { a, _ in a })
        }

        static func keyword(_ key: String, tree: OrgTree, settings: OrgSettings) -> String? {
            var value: String?
            let lines = settings.setupKeywords.split(separator: "\n").map(String.init)
                + tree.root.descendants().filter { $0.kind == .keyword }.map(\.text)
            for line in lines {
                if let m = line.firstMatch(of: #/(?i)^[ \t]*#\+([^:\s]+):[ \t]*(.*?)[ \t]*\n?$/#), m.1.uppercased() == key { value = String(m.2) }
            }
            return value
        }

        func keyword(_ key: String) -> String? { Self.keyword(key, tree: tree, settings: settings) }

        /// The heading whose subtree is exported.
        var subtreeHeading: Int? { subtree.flatMap { offset in model.headings.lastIndex { $0.headingRange.lowerBound <= offset } } }

        /// `#+TITLE`; for a subtree, its `EXPORT_TITLE` or title.
        var title: String {
            if let index = subtreeHeading {
                return ascii.inlineString(property("EXPORT_TITLE", index) ?? Links.displayFormat(model.headings[index].title).trimmingCharacters(in: .whitespaces))
            }
            return keyword("TITLE").map { ascii.inlineString($0) } ?? ""
        }

        /// The components of every entry, in order.
        func components() -> String {
            var out = ""
            for node in tree.root.children where node.kind == .section { out += section(node) }
            return out
        }

        func section(_ node: SyntaxNode) -> String {
            guard let heading = node.firstChild(.heading), let index = headingIndex[heading.range.lowerBound] else { return "" }
            let info = model.headings[index]
            if subtree != nil, let target = subtreeHeading {
                // Only the subtree at `subtree`, as Org narrows to it.
                if model.ancestors(of: target).contains(index) { return node.children.filter { $0.kind == .section }.map(section).joined() }
                if index != target, !model.ancestors(of: index).contains(target) { return "" }
            }
            let what = HTMLRenderer.sectionExport(heading, options: export, selected: selected)
            if what == .nothing { return "" }
            let title = Links.displayFormat(info.title).trimmingCharacters(in: .whitespaces)
            if title == "Footnotes" { return "" }
            let body = what == .all ? node.children.filter { ![.heading, .section, .planning, .propertyDrawer].contains($0.kind) } : []
            var out = entry(index, heading: heading, body: body, end: node.children.first { $0.kind == .section }?.range.lowerBound ?? node.range.upperBound)
            if what == .all { for child in node.children where child.kind == .section { out += section(child) } }
            return out
        }

        // MARK: Entries

        func property(_ key: String, _ index: Int) -> String? { model.property(key, of: index)?.value }

        func entry(_ index: Int, heading: SyntaxNode, body: [SyntaxNode], end: Int) -> String {
            let info = model.headings[index]
            let todoType: String? = info.todo == nil ? nil : info.isDone ? "done" : "todo"
            let uid = info.id ?? UUID().uuidString
            let titleNode = heading.firstChild(.title)
            let summary = cleanup(model.headings[index].properties.contains { $0.key.uppercased() == "SUMMARY" } || model.inherits("SUMMARY")
                ? property("SUMMARY", index) ?? titleNode.map { ascii.inline($0) }?.trimmingCharacters(in: .whitespaces) ?? ""
                : titleNode.map { ascii.inline($0) }?.trimmingCharacters(in: .whitespaces) ?? "")
            let location = property("LOCATION", index).map(cleanup)
            let klass = property("CLASS", index).map(cleanup)
            var description: String?
            if let own = property("DESCRIPTION", index) {
                description = own
            } else {
                let contents = ascii.elements(body, end: end, source: source, width: ascii.width(level: info.level))
                if contents.contains(where: { !$0.isWhitespace }) {
                    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch options.includeBody {
                    case .none: description = nil
                    case .all: description = trimmed
                    case .characters(let n): description = String(trimmed.unicodeScalars.prefix(n))
                    }
                }
            }
            description = description.map(cleanup)
            let categories = self.categories(index)
            let timezone = property("TIMEZONE", index)
            var out = ""
            func wants(_ list: [String]) -> Bool {
                switch todoType {
                case "todo": list.contains("event-if-todo-not-done") || list.contains("event-if-todo")
                case "done": list.contains("event-if-todo")
                default: list.contains("event-if-not-todo")
                }
            }
            let entry = Entry(uid: uid, summary: summary, location: location, description: description, categories: categories, timezone: timezone, klass: klass, warnTime: info.properties.last { $0.key.uppercased() == "APPT_WARNTIME" }.flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) })
            if let deadline = info.deadline, wants(options.useDeadline) {
                out += vevent(entry, deadline, uid: "DL-" + uid, summary: cleanup(options.deadlineSummaryPrefix) + summary)
            }
            if let scheduled = info.scheduled, wants(options.useScheduled) {
                out += vevent(entry, scheduled, uid: "SC-" + uid, summary: cleanup(options.scheduledSummaryPrefix) + summary)
            }
            var counter = 0
            for text in timestamps(titleNode) + body.flatMap(timestamps) where !skipsTimestamp(text, with: export.timestamps ?? "active") {
                guard !text.hasPrefix("<%%"), let stamp = Timestamp.parse(text) else { continue }
                counter += 1
                out += vevent(entry, stamp, uid: "TS\(counter)-" + uid, summary: summary)
            }
            if let todoType, includesTodo(index, todoType: todoType) {
                out += vtodo(entry, index, todoType: todoType)
            }
            return out
        }

        struct Entry {
            let uid: String
            let summary: String
            let location: String?
            let description: String?
            let categories: String
            let timezone: String?
            let klass: String?
            let warnTime: Int?
        }

        /// The timestamps `org-element-map` finds, leaving out what the export ignores.
        func timestamps(_ node: SyntaxNode?) -> [String] {
            guard let node else { return [] }
            switch node.kind {
            case .timestamp: return [node.text]
            case .planning, .propertyDrawer, .clock, .comment, .keyword, .block, .inlineTask, .fixedWidth, .heading, .section: return []
            case .drawer:
                if node.text.firstMatch(of: /^[ \t]*:LOGBOOK:/) != nil { return [] }
            default: break
            }
            return node.children.flatMap(timestamps)
        }

        func categories(_ index: Int) -> String {
            let info = model.headings[index]
            var out: [String] = []
            func tags(_ list: [String]) -> [String] { list.filter { !export.selectTags.contains($0) && !export.excludeTags.contains($0) } }
            for kind in options.categories {
                switch kind {
                case "category":
                    out.append(property("CATEGORY", index) ?? keyword("CATEGORY") ?? (name as NSString).deletingPathExtension)
                case "todo-state": if let todo = info.todo { out.append(todo) }
                case "local-tags": out += tags(info.localTags)
                case "all-tags": out += tags(model.tags(of: index).map(\.value))
                default: break
                }
            }
            var seen: Set<String> = []
            return out.filter { seen.insert($0).inserted }.joined(separator: ",")
        }

        func includesTodo(_ index: Int, todoType: String) -> Bool {
            switch options.includeTodo {
            case .none: return false
            case .all: return true
            case .unfinished: return todoType == "todo"
            case .keywords(let list): return model.headings[index].todo.map(list.contains) ?? false
            case .unblocked: return !blocked(index)
            }
        }

        /// `org-icalendar-blocked-headline-p`.
        func blocked(_ index: Int) -> Bool {
            let level = model.headings[index].level
            for child in model.headings[(index + 1)...].prefix(while: { $0.level > level }) where child.todo != nil && !child.isDone { return true }
            var current = index
            for parent in model.ancestors(of: index).reversed() {
                guard model.headings[parent].todo != nil else { return false }
                let ordered = model.headings[parent].properties.last { $0.key.uppercased() == "ORDERED" }?.value
                if let ordered, !ordered.isEmpty, ordered != "nil" {
                    let siblings = model.headings.indices.filter { model.headings[$0].parent == parent && $0 < current }
                    if siblings.contains(where: { model.headings[$0].todo != nil && !model.headings[$0].isDone }) { return true }
                } else {
                    current = parent
                }
            }
            return false
        }

        // MARK: Components

        func vevent(_ entry: Entry, _ stamp: Timestamp, uid: String, summary: String) -> String {
            var out = "BEGIN:VEVENT\n" + dtstamp + "\nUID:" + uid + "\n"
            out += convert(stamp, "DTSTART", end: false, tz: entry.timezone) + "\n"
            out += convert(stamp, "DTEND", end: true, tz: entry.timezone) + "\n"
            if let r = stamp.repeater { out += rrule(r.interval) + "\n" }
            out += "SUMMARY:" + summary + "\n"
            if let l = entry.location, l.contains(where: { !$0.isWhitespace }) { out += "LOCATION:\(l)\n" }
            if let c = entry.klass, c.contains(where: { !$0.isWhitespace }) { out += "CLASS:\(c)\n" }
            if let d = entry.description, d.contains(where: { !$0.isWhitespace }) { out += "DESCRIPTION:\(d)\n" }
            out += "CATEGORIES:" + entry.categories + "\n"
            out += valarm(entry, stamp, summary: summary)
            return out + "END:VEVENT\n"
        }

        var dtstamp: String {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return "DTSTAMP:" + format(now, "%Y%m%dT%H%M%SZ", utc)
        }

        func rrule(_ interval: Timestamp.Interval) -> String {
            let freq = ["h": "HOURLY", "d": "DAILY", "w": "WEEKLY", "m": "MONTHLY", "y": "YEARLY"][String(interval.unit.rawValue)]!
            return "RRULE:FREQ=\(freq);INTERVAL=\(interval.value)"
        }

        func valarm(_ entry: Entry, _ stamp: Timestamp, summary: String) -> String {
            let alarm = entry.warnTime
            guard (alarm.map { $0 > 0 } ?? false) || options.alarmTime > 0 || options.forceAlarm, stamp.start.hour != nil else { return "" }
            let minutes: Int
            if let alarm, options.forceAlarm { minutes = alarm } else if let alarm, alarm != 0 { minutes = alarm } else { minutes = options.alarmTime }
            return "BEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:\(summary)\nTRIGGER:-P0DT0H\(minutes)M0S\nEND:VALARM\n"
        }

        /// `org-icalendar--repeater-type`: only `+` repeaters repeat a VTODO.
        static func repeats(_ stamp: Timestamp?) -> Bool {
            guard let r = stamp?.repeater, r.interval.value > 0 else { return false }
            return r.kind == .cumulate
        }

        func vtodo(_ entry: Entry, _ index: Int, todoType: String) -> String {
            let info = model.headings[index]
            let sc = options.useScheduled.contains("todo-start") ? info.scheduled : nil
            let dl = options.useDeadline.contains("todo-due") ? info.deadline : nil
            let scRepeats = Self.repeats(sc)
            let dlRepeats = Self.repeats(dl)
            let repeatInterval = sc?.repeater?.interval ?? dl?.repeater?.interval
            let until = scRepeats && !dlRepeats ? dl : nil
            var start: Timestamp? = sc
            if start == nil {
                switch options.todoUnscheduledStart {
                case "current-datetime":
                    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
                    start = Timestamp(active: true, start: .init(year: c.year!, month: c.month!, day: c.day!, hour: c.hour, minute: c.minute), end: nil, repeater: nil, warning: nil)
                case "deadline-warning" where dl != nil, "recurring-deadline-warning" where dlRepeats:
                    start = shifted(dl!, days: -warningDays(dl!))
                default: break
                }
            }
            var out = "BEGIN:VTODO\nUID:TODO-" + entry.uid + "\n" + dtstamp + "\n"
            if let start { out += convert(start, "DTSTART", end: false, tz: entry.timezone) + "\n" }
            if let dl, until == nil { out += convert(dl, "DUE", end: false, tz: entry.timezone) + "\n" }
            if dlRepeats, repeatInterval != dl?.repeater?.interval {
                // Different repeaters on SCHEDULED and DEADLINE: no RRULE, as Org warns.
            } else if dlRepeats, sc != nil, !scRepeats {
                // A repeater on DEADLINE but not SCHEDULED: no RRULE either.
            } else if scRepeats || dlRepeats, let repeatInterval {
                out += rrule(repeatInterval)
                if let until {
                    let local = entry.timezone == nil && options.dateTimeFormat == ":%Y%m%dT%H%M%S"
                    let date = self.date(until.start.year, until.start.month, until.start.day, until.start.hour ?? 0, until.start.minute ?? 0)
                    var utc = Calendar(identifier: .gregorian)
                    utc.timeZone = TimeZone(identifier: "UTC")!
                    out += ";UNTIL=" + (start?.start.minute == nil ? format(date, "%Y%m%d", calendar)
                        : local ? format(date, "%Y%m%dT%H%M%S", calendar) : format(date, "%Y%m%dT%H%M%SZ", utc))
                }
                out += "\n"
            }
            out += "SUMMARY:" + entry.summary + "\n"
            if let l = entry.location, l.contains(where: { !$0.isWhitespace }) { out += "LOCATION:\(l)\n" }
            if let c = entry.klass, c.contains(where: { !$0.isWhitespace }) { out += "CLASS:\(c)\n" }
            if let d = entry.description, d.contains(where: { !$0.isWhitespace }) { out += "DESCRIPTION:\(d)\n" }
            out += "CATEGORIES:" + entry.categories + "\n" + "SEQUENCE:1\n"
            out += "PRIORITY:\(priority(info.priority))\n"
            out += "STATUS:" + (todoType == "todo" ? "NEEDS-ACTION" : "COMPLETED") + "\n"
            return out + "END:VTODO\n"
        }

        func priority(_ cookie: String?) -> Int {
            func code(_ s: String) -> Int { Int(s) ?? Int(s.unicodeScalars.first?.value ?? 66) }
            let p = settings.priorities
            let highest = code(p.highest), lowest = code(p.lowest)
            let value = code(cookie ?? p.default)
            guard lowest != highest else { return 5 }
            return Int((9 - 8 * (Double(lowest - value) / Double(lowest - highest))).rounded(.down))
        }

        /// `org-get-wdays`: the deadline's warning period in days.
        func warningDays(_ stamp: Timestamp) -> Int {
            guard let w = stamp.warning else { return settings.deadlineWarningDays }
            let n = Double(w.interval.value)
            switch w.interval.unit {
            case .hour: return Int((n / 24).rounded(.down))
            case .day: return Int(n)
            case .week: return Int(n * 7)
            case .month: return Int((n * 30.4).rounded(.down))
            case .year: return Int((n * 365.25).rounded(.down))
            }
        }

        func shifted(_ stamp: Timestamp, days: Int) -> Timestamp {
            var copy = stamp
            let absolute = Days.absolute(year: stamp.start.year, month: stamp.start.month, day: stamp.start.day) + days
            let d = Days.date(absolute)
            (copy.start.year, copy.start.month, copy.start.day) = (d.year, d.month, d.day)
            copy.end = nil
            return copy
        }

        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: 0)) ?? now
        }

        /// `org-icalendar-convert-timestamp`.
        func convert(_ stamp: Timestamp, _ keyword: String, end: Bool, tz: String?) -> String {
            let s = stamp.start
            let e = stamp.end ?? stamp.start
            let timed = s.minute != nil || s.hour != nil
            let equal = stamp.end == nil || (s.year, s.month, s.day, s.hour, s.minute) == (e.year, e.month, e.day, e.hour, e.minute)
            let mi = !timed ? 0 : !end ? (s.minute ?? 0) : (options.appointmentDuration != nil && equal) ? (e.minute ?? 0) + options.appointmentDuration! : (e.minute ?? 0)
            let h = !timed ? 0 : !end ? (s.hour ?? 0) : (!equal || options.appointmentDuration != nil) ? (e.hour ?? 0) : (e.hour ?? 0) + 2
            let d = !end ? s.day : !timed ? e.day + 1 : e.day
            let m = end ? e.month : s.month
            let y = end ? e.year : s.year
            let date = self.date(y, m, d, h, mi)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            if tz == "UTC" { return keyword + format(date, ":%Y%m%dT%H%M%SZ", utc) }
            if !timed { return keyword + format(date, ";VALUE=DATE:%Y%m%d", calendar) }
            if let tz { return keyword + ";TZID=" + tz + format(date, ":%Y%m%dT%H%M%S", calendar) }
            let pattern = options.dateTimeFormat.replacingOccurrences(of: "%Z", with: options.timezone ?? "")
            return keyword + format(date, pattern, options.dateTimeFormat.hasSuffix("Z") ? utc : calendar)
        }

        /// `format-time-string` for `%Y %m %d %H %M %S`.
        func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            var out = ""
            var i = pattern.startIndex
            while i < pattern.endIndex {
                let ch = pattern[i]
                let next = pattern.index(after: i)
                if ch == "%", next < pattern.endIndex {
                    switch pattern[next] {
                    case "Y": out += String(format: "%04d", c.year!)
                    case "m": out += String(format: "%02d", c.month!)
                    case "d": out += String(format: "%02d", c.day!)
                    case "H": out += String(format: "%02d", c.hour!)
                    case "M": out += String(format: "%02d", c.minute!)
                    case "S": out += String(format: "%02d", c.second!)
                    case "%": out += "%"
                    default: out += String(pattern[i...next])
                    }
                    i = pattern.index(after: next)
                } else {
                    out.append(ch)
                    i = next
                }
            }
            return out
        }
    }
}

extension ASCIIText {
    /// A line of Org text's objects, as a title is exported.
    func inlineString(_ text: String) -> String {
        let tree = OrgParser.parse(text)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return text }
        return inline(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
