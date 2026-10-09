import Foundation
import OrgCore
import OrgPresentation

/// The next days of the agenda for widgets, which can't read the folders: the app writes it
/// as JSON into the app group's container, the widgets read it.
public struct AgendaSnapshot: Codable, Equatable, Sendable {
    /// Days from today the snapshot holds.
    public static let dayCount = 7

    /// A color in light and dark appearance, `#rrggbb` or `#rrggbbaa`.
    public struct Hex: Codable, Equatable, Sendable {
        public var light: String
        public var dark: String

        public init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }

        init?(_ color: (Bool) -> RGBA?) {
            guard let light = color(false) ?? color(true), let dark = color(true) ?? color(false) else { return nil }
            self.init(light: light.hex, dark: dark.hex)
        }
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// `AgendaRow.gutter`: the time or a short status.
        public var gutter: String
        /// `AgendaRow.Status`'s raw value.
        public var status: String
        public var title: String
        public var category: String
        public var todo: String?
        public var priority: String?
        public var isDone: Bool
        public var isEvent: Bool
        /// When a timed row starts and ends.
        public var start: Date?
        public var end: Date?
        /// The Org entry, for a link to it.
        public var path: String?
        public var offset: Int?
        public var statusColor: Hex?
        public var todoColor: Hex?
        public var priorityColor: Hex?
        public var categoryColor: Hex?

        public init(
            id: String, gutter: String, status: String, title: String, category: String, todo: String?, priority: String?, isDone: Bool,
            isEvent: Bool, start: Date?, end: Date?, path: String?, offset: Int?, statusColor: Hex?, todoColor: Hex?, priorityColor: Hex?,
            categoryColor: Hex?
        ) {
            self.id = id
            self.gutter = gutter
            self.status = status
            self.title = title
            self.category = category
            self.todo = todo
            self.priority = priority
            self.isDone = isDone
            self.isEvent = isEvent
            self.start = start
            self.end = end
            self.path = path
            self.offset = offset
            self.statusColor = statusColor
            self.todoColor = todoColor
            self.priorityColor = priorityColor
            self.categoryColor = categoryColor
        }

        public var link: AppLink? {
            guard let path, let offset else { return nil }
            return .entry(path: path, offset: offset)
        }

        /// Not done and not a calendar event.
        public var isOpen: Bool { !isDone && !isEvent }
    }

    public struct Day: Codable, Equatable, Sendable, Identifiable {
        /// As `Days` numbers it.
        public var day: Int
        /// Midnight starting the day.
        public var date: Date
        public var header: String
        /// Today only: deadlines and scheduled entries from before today.
        public var overdue: [Row]
        public var rows: [Row]

        public var id: Int { day }

        public init(day: Int, date: Date, header: String, overdue: [Row], rows: [Row]) {
            self.day = day
            self.date = date
            self.header = header
            self.overdue = overdue
            self.rows = rows
        }
    }

    public var generated: Date
    public var days: [Day]
    /// The agenda's colors the widgets use: `agenda-today`, `agenda-time`, `agenda-date`,
    /// `foreground`, and `agenda-background` when the theme sets one.
    public var colors: [String: Hex]

    public init(generated: Date, days: [Day], colors: [String: Hex]) {
        self.generated = generated
        self.days = days
        self.colors = colors
    }

    /// The groups from `today` through `dayCount - 1` days later, colored by `theme`.
    public init(
        groups: [AgendaDayGroup], today: Int, dayCount: Int = AgendaSnapshot.dayCount, theme: ThemeSpec, generated: Date,
        calendar: Calendar = .current
    ) {
        func row(_ row: AgendaRow, midnight: Date) -> Row {
            func at(_ hhmm: Int?) -> Date? {
                hhmm.flatMap { calendar.date(byAdding: .minute, value: ($0 / 100) * 60 + $0 % 100, to: midnight) }
            }
            let item = row.item
            return Row(
                id: row.id, gutter: row.gutter, status: row.status.rawValue, title: row.title, category: row.category, todo: row.todo,
                priority: row.priority, isDone: row.isDone, isEvent: row.isEvent, start: at(row.start), end: at(row.end),
                path: item?.path, offset: item.flatMap { $0.headingOffset ?? $0.markerOffset },
                statusColor: Hex { theme.statusColor(row.status, dark: $0) },
                todoColor: row.todo.flatMap { todo in Hex { theme.todoColor(todo, isDone: row.isDone, dark: $0) } },
                priorityColor: row.priority.flatMap { priority in Hex { theme.priorityColor(priority, dark: $0) } },
                categoryColor: Hex { dark -> RGBA? in
                    if let event = row.event { return theme.eventColor(event, dark: dark) }
                    return theme.categoryColor(row.category, dark: dark)
                }
            )
        }
        days = groups.filter { $0.day >= today && $0.day < today + dayCount }.map { group in
            let midnight = group.date(calendar: calendar)
            return Day(
                day: group.day, date: midnight, header: group.header,
                overdue: group.overdue.map { row($0, midnight: midnight) }, rows: group.rows.map { row($0, midnight: midnight) }
            )
        }
        var colors: [String: Hex] = [:]
        for key in ["agenda-today", "agenda-time", "agenda-date", "foreground", "agenda-background"] {
            colors[key] = Hex { theme.color(key, dark: $0) }
        }
        self.colors = colors
        self.generated = generated
    }

    // MARK: - What the widgets show

    /// The snapshot's day that `now` falls on.
    public func day(at now: Date, calendar: Calendar = .current) -> Day? {
        days.first { calendar.isDate($0.date, inSameDayAs: now) }
    }

    /// The day after `now`'s.
    public func day(after now: Date, calendar: Calendar = .current) -> Day? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return day(at: next, calendar: calendar)
    }

    /// What's left of `now`'s day: its rows not done, without timed rows that have ended
    /// (or, with no end, started) before `now`, then the overdue entries.
    public func upcoming(at now: Date, calendar: Calendar = .current) -> [Row] {
        guard let day = day(at: now, calendar: calendar) else { return [] }
        return (day.rows + day.overdue).filter { row in
            guard !row.isDone else { return false }
            guard let time = row.end ?? row.start else { return true }
            return time >= now
        }
    }

    /// Entries of `now`'s day not done, overdue ones included; calendar events don't count.
    public func openCount(at now: Date, calendar: Calendar = .current) -> Int {
        guard let day = day(at: now, calendar: calendar) else { return 0 }
        return (day.rows + day.overdue).filter(\.isOpen).count
    }

    public func overdueCount(at now: Date, calendar: Calendar = .current) -> Int {
        day(at: now, calendar: calendar)?.overdue.filter(\.isOpen).count ?? 0
    }

    /// When what `upcoming` shows changes after `now`: a minute after each timed row of the
    /// day ends (or starts), and the next midnight.
    public func changes(after now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = Set<Date>()
        for row in day(at: now, calendar: calendar).map({ $0.rows + $0.overdue }) ?? [] {
            if let time = row.end ?? row.start, time.addingTimeInterval(60) > now { dates.insert(time.addingTimeInterval(60)) }
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) { dates.insert(midnight) }
        return dates.sorted()
    }

    // MARK: - The file

    /// `Widgets/agenda.json` in the app group's container; nil without the group.
    public static func file(group: String = CaptureInbox.group) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widgets").appendingPathComponent("agenda.json")
    }

    public static func read(from file: URL) -> AgendaSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(AgendaSnapshot.self, from: data)
    }

    /// Writes the snapshot unless the file holds the same days and colors; true when it wrote.
    @discardableResult
    public func write(to file: URL) throws -> Bool {
        if let old = Self.read(from: file), old.days == days, old.colors == colors { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: file, options: .atomic)
        return true
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The app's own links, `orgstar://`, which widgets and the Live Activity open.
public enum AppLink: Equatable, Sendable {
    case agenda
    /// An Org entry: its file and an offset in it.
    case entry(path: String, offset: Int)
    /// The entry of the running clock.
    case clock

    public static let scheme = "orgstar"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .agenda:
            components.host = "agenda"
        case .clock:
            components.host = "clock"
        case .entry(let path, let offset):
            components.host = "entry"
            components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "offset", value: String(offset))]
        }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func query(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        switch components.host {
        case "agenda": self = .agenda
        case "clock": self = .clock
        case "entry":
            guard let path = query("path"), let offset = query("offset").flatMap(Int.init) else { return nil }
            self = .entry(path: path, offset: offset)
        default: return nil
        }
    }
}
