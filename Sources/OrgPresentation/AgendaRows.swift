import Foundation
import OrgCore

/// An event from the system Calendar, read-only (OrgApp's `CalendarEvents` reads them).
public struct AgendaEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let calendarID: String
    public let calendarTitle: String
    /// The calendar's color; nil uses the theme's `agenda-event`.
    public let color: RGBA?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?

    public init(
        id: String, title: String, calendarID: String, calendarTitle: String, color: RGBA?, start: Date, end: Date,
        isAllDay: Bool, location: String? = nil
    ) {
        self.id = id
        self.title = title
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.color = color
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }

    /// The days (as `Days` numbers them) the event covers; an end at midnight ends the day before.
    public func days(calendar: Calendar) -> ClosedRange<Int> {
        let first = Days.absolute(start, calendar: calendar)
        var last = Days.absolute(end, calendar: calendar)
        if end > start, calendar.startOfDay(for: end) == end { last -= 1 }
        return first...max(first, last)
    }
}

/// One line of the agenda: an Org entry or a calendar event.
///
/// The gutter holds the time (`08:00`, `13:50–14:30`) or, untimed, a short status:
/// deadlines `Due today`, `Due in 2d`, `3d late`, `Due` (on a day other than today);
/// scheduled `Scheduled`, `4d ago`; habits `Habit`; timestamps, diary sexps and
/// calendar events `All day`; ranges `Day 2/5`; log mode `Closed`, `Clocked`, `State`; TODO
/// and match lists nothing. Ages use `AgendaAge.compact`.
public struct AgendaRow: Sendable, Equatable, Identifiable {
    /// What the gutter's color says.
    public enum Status: String, Sendable {
        /// Not done, with a deadline or scheduled date before today.
        case overdue
        /// Not done, with a deadline today or within its warning period.
        case dueSoon = "due-soon"
        case normal
        /// A done TODO keyword.
        case done
    }

    public enum Icon: String, Sendable {
        case scheduled, deadline, habit, event, timestamp
    }

    /// Unique within a day group.
    public internal(set) var id: String
    public let gutter: String
    public let status: Status
    /// Nil for TODO and match list entries.
    public let icon: Icon?
    /// The category line above the title: the entry's category, or the event's calendar.
    public let category: String
    public let title: String
    public let tags: [String]
    public let todo: String?
    public let isDone: Bool
    public let priority: String?
    /// The statistics cookie: `1/3`, `50%`.
    public let progress: String?
    /// Log mode: the time clocked (`1:30`) or the state set (`DONE`).
    public let detail: String?
    /// `HHMM` of the start and the end, when timed.
    public let start: Int?
    public let end: Int?
    /// The deadline or scheduled day, as `Days` numbers it.
    public let planningDay: Int?
    /// The Org entry, for its actions.
    public let item: AgendaItem?
    public let event: AgendaEvent?

    public var isEvent: Bool { event != nil }
    /// The calendar's color for an event.
    public var color: RGBA? { event?.color }

    /// Nil for the time grid and the current-time line.
    public init?(item: AgendaItem, day: Int, today: Int) {
        if item.kind == .timeGrid || item.kind == .currentTime { return nil }
        let timed = item.timeOfDay.map { start in (start, Self.endTime(item.time)) }
        let planning = item.planningDay
        let late = planning.map { $0 < today } ?? false
        var icon: Icon?
        var status: Status = .normal
        var untimed = ""
        switch item.kind {
        case .deadline, .upcomingDeadline:
            icon = .deadline
            let due = planning ?? day
            if day == today {
                untimed = due == today ? "Due today" : due < today ? "\(AgendaAge.compact(today - due)) late" : "Due in \(AgendaAge.compact(due - today))"
            } else {
                untimed = "Due"
            }
            status = late ? .overdue : day == today ? .dueSoon : .normal
        case .scheduled, .pastScheduled:
            if item.habit != nil {
                icon = .habit
                untimed = "Habit"
            } else {
                icon = .scheduled
                let on = planning ?? day
                untimed = on < day ? "\(AgendaAge.compact(day - on)) ago" : "Scheduled"
            }
            status = late ? .overdue : .normal
        case .timestamp, .sexp:
            icon = .timestamp
            untimed = "All day"
        case .block:
            icon = .timestamp
            let ns = item.extra as NSString
            if let m = Self.rangeDay.firstMatch(in: item.extra, range: NSRange(location: 0, length: ns.length)) {
                untimed = "Day " + ns.substring(with: m.range(at: 1))
            } else {
                untimed = "All day"
            }
        case .closed: (icon, untimed) = (.timestamp, "Closed")
        case .clock: (icon, untimed) = (.timestamp, "Clocked")
        case .state: (icon, untimed) = (.timestamp, "State")
        case .todo, .tagsMatch, .search, .timeGrid, .currentTime: break
        }
        if item.isDone { status = .done }
        self.id = [item.path ?? "", "\(item.headingOffset ?? -1)", "\(item.markerOffset ?? -1)", item.kind.rawValue, item.text].joined(separator: "\u{1f}")
        self.gutter = timed.map { Self.timeText($0.0, $0.1) } ?? untimed
        self.status = status
        self.icon = icon
        self.category = item.category
        self.title = item.title
        self.tags = item.tags
        self.todo = item.todo
        self.isDone = item.isDone
        self.priority = item.priorityLetter
        self.progress = item.progress
        self.detail = item.kind == .clock || item.kind == .state ? Self.logDetail(item.extra) : nil
        self.start = timed?.0
        self.end = timed?.1
        self.planningDay = planning
        self.item = item
        self.event = nil
    }

    /// The event's row on `day`: its times on the day it starts (the end only when it ends that
    /// day too), `Until 10:00` on the day a longer event ends, `All day` otherwise.
    public init(event: AgendaEvent, day: Int, calendar: Calendar) {
        let days = event.days(calendar: calendar)
        func hhmm(_ date: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return (c.hour ?? 0) * 100 + (c.minute ?? 0)
        }
        var start: Int?
        var end: Int?
        let gutter: String
        if event.isAllDay || (day != days.lowerBound && day != days.upperBound) {
            gutter = "All day"
        } else if day == days.lowerBound {
            start = hhmm(event.start)
            if days.lowerBound == days.upperBound { end = hhmm(event.end) }
            gutter = Self.timeText(start!, end)
        } else {
            gutter = "Until " + Self.timeText(hhmm(event.end), nil)
        }
        self.id = "event\u{1f}" + event.id
        self.gutter = gutter
        self.status = .normal
        self.icon = .event
        self.category = event.calendarTitle
        self.title = event.title
        self.tags = []
        self.todo = nil
        self.isDone = false
        self.priority = nil
        self.progress = nil
        self.detail = nil
        self.start = start
        self.end = end
        self.planningDay = nil
        self.item = nil
        self.event = event
    }

    static let rangeDay = try! NSRegularExpression(pattern: "^\\(([0-9]+/[0-9]+)\\)")
    static let logParen = try! NSRegularExpression(pattern: "\\(([^)]+)\\)")
    static let rangeEnd = try! NSRegularExpression(pattern: "-\\+?([0-9]{1,2}):([0-9]{2})")

    /// The text in parentheses of a log row's `extra`: `Clocked:   (1:30)`.
    static func logDetail(_ extra: String) -> String? {
        let ns = extra as NSString
        guard let m = logParen.firstMatch(in: extra, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The end of a `%t` time range (` 9:00-10:30`), as `HHMM`; past midnight (`+1:00`) adds 24 hours.
    static func endTime(_ time: String) -> Int? {
        let ns = time as NSString
        guard let m = rangeEnd.firstMatch(in: time, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let overtime = ns.substring(with: m.range).contains("+") ? 24 : 0
        return (Int(ns.substring(with: m.range(at: 1)))! + overtime) * 100 + Int(ns.substring(with: m.range(at: 2)))!
    }

    /// `08:00`, `13:50–14:30`; hours past midnight wrap.
    static func timeText(_ start: Int, _ end: Int?) -> String {
        func text(_ t: Int) -> String { String(format: "%02d:%02d", (t / 100) % 24, t % 100) }
        return end.map { text(start) + "–" + text($0) } ?? text(start)
    }
}

/// One day of the agenda: today's entries carried from earlier days in `overdue`, the rest
/// in `rows`.
public struct AgendaDayGroup: Sendable, Equatable, Identifiable {
    /// As `Days` numbers it.
    public let day: Int
    public let isToday: Bool
    /// Org's day header: `Thursday    8 October 2026`.
    public let header: String
    /// Today only: deadlines and scheduled entries from before today, oldest first.
    public let overdue: [AgendaRow]
    public let rows: [AgendaRow]

    public var id: Int { day }
    public var isEmpty: Bool { overdue.isEmpty && rows.isEmpty }

    /// `Today`, `Tomorrow`, `Yesterday`, or nil.
    public func relativeName(today: Int) -> String? {
        switch day - today {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: nil
        }
    }

    /// Midnight starting the day.
    public func date(calendar: Calendar) -> Date {
        let d = Days.date(day)
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day))!
    }

    /// Where the current-time line goes in `rows`: before the first timed row starting after
    /// `now` (`HHMM`), or after the last timed row when all have started. Nil on other days
    /// and when no row is timed, as Org adds the line only among timed entries.
    public func nowIndex(now: Int) -> Int? {
        guard isToday else { return nil }
        return AgendaRows.nowIndex(rows, now: now)
    }
}

public enum AgendaRows {
    /// The days of `Agenda.list` as rows, with `events` merged in.
    ///
    /// - Days with no rows are left out unless `showAllDates` (`org-agenda-show-all-dates`);
    ///   today always stays.
    /// - Today's past-scheduled entries and past deadlines (not habits) go in `overdue`,
    ///   oldest date first, Org's order among the same date.
    /// - Other rows keep Org's order (timed by time, then untimed by urgency, habits last).
    ///   All-day events come first, timed events go among the timed entries by start time,
    ///   after entries at the same time.
    /// - `keep` filters the Org entries (an `AgendaFilter`); events are not filtered.
    public static func groups(
        _ days: [AgendaDay], events: [AgendaEvent] = [], today: Int, showAllDates: Bool = false, calendar: Calendar = .current,
        keep: (AgendaItem) -> Bool = { _ in true }
    ) -> [AgendaDayGroup] {
        let eventDays = events.map { ($0, $0.days(calendar: calendar)) }
        var groups: [AgendaDayGroup] = []
        for day in days {
            var overdue: [AgendaRow] = []
            var rows: [AgendaRow] = []
            for item in day.items where keep(item) {
                guard let row = AgendaRow(item: item, day: day.day, today: today) else { continue }
                if day.day == today, item.habit == nil, let planning = row.planningDay, planning < today {
                    overdue.append(row)
                } else {
                    rows.append(row)
                }
            }
            overdue = overdue.enumerated().sorted { a, b in
                a.element.planningDay! != b.element.planningDay! ? a.element.planningDay! < b.element.planningDay! : a.offset < b.offset
            }.map(\.element)
            let dayEvents = eventDays.filter { $0.1.contains(day.day) }.map { AgendaRow(event: $0.0, day: day.day, calendar: calendar) }
            rows = merge(rows, events: dayEvents)
            let group = AgendaDayGroup(day: day.day, isToday: day.day == today, header: day.header, overdue: unique(overdue), rows: unique(rows))
            if group.isEmpty, !group.isToday, !showAllDates { continue }
            groups.append(group)
        }
        return groups
    }

    /// `org` (in Org's order) with event rows added: untimed events first, timed ones before
    /// the first untimed or habit entry, or the first timed entry starting later.
    static func merge(_ org: [AgendaRow], events: [AgendaRow]) -> [AgendaRow] {
        let allDay = events.filter { $0.start == nil }
        var result = org
        let timed = events.filter { $0.start != nil }.enumerated().sorted { a, b in
            a.element.start! != b.element.start! ? a.element.start! < b.element.start! : a.offset < b.offset
        }.map(\.element)
        for event in timed {
            let at = result.firstIndex { row in
                if row.isEvent { return row.start.map { $0 > event.start! } ?? false }
                guard let start = row.start, row.item?.habit == nil else { return true }
                return start > event.start!
            } ?? result.count
            result.insert(event, at: at)
        }
        return allDay + result
    }

    /// Ids made unique: a repeat gets `#2`, `#3`.
    static func unique(_ rows: [AgendaRow]) -> [AgendaRow] {
        var seen: [String: Int] = [:]
        return rows.map { row in
            var row = row
            let n = seen[row.id, default: 0] + 1
            seen[row.id] = n
            if n > 1 { row.id += "#\(n)" }
            return row
        }
    }

    /// See `AgendaDayGroup.nowIndex(now:)`.
    public static func nowIndex(_ rows: [AgendaRow], now: Int) -> Int? {
        let timed = rows.indices.filter { rows[$0].start != nil && rows[$0].item?.habit == nil }
        guard let last = timed.last else { return nil }
        return timed.first { rows[$0].start! > now } ?? last + 1
    }
}
