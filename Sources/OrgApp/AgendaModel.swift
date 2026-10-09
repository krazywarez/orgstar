import Foundation
import Observation
import OrgCore
import OrgIndex
import OrgPresentation

/// The day/week agenda over the workspace's agenda files. Sources are read from disk and
/// cached by modification date and size; the open file's come from its buffer, so the agenda
/// shows unsaved edits.
@MainActor
@Observable
public final class AgendaModel {
    public private(set) var days: [AgendaDay] = []
    /// The entries of a TODO list, match or search view.
    public private(set) var list: [AgendaItem] = []
    public var mode: AgendaMode = .agenda(span: nil, startOffset: nil)
    /// The first day shown, as `Days` numbers it; nil follows today.
    public var start: Int?
    public var span = 10
    /// Where the view starts relative to today, as Doom's `org-agenda-start-day "-3d"`.
    public var startOffset = -3
    /// Files below the top level of each folder are agenda files too.
    public var includeSubfolders = false
    public var options = AgendaOptions()
    public private(set) var isComputing = false
    /// Calendar events over the days shown, from `calendarEvents` (nil reads none) and the
    /// calendars in `calendarNames` (all when empty).
    public private(set) var events: [AgendaEvent] = []
    public var calendarEvents: CalendarEvents?
    public var calendarNames: [String] = []
    /// Today and the calendar of the last refresh.
    public private(set) var today = Days.absolute(Date(), calendar: .current)
    @ObservationIgnored private var calendar = Calendar.current

    private let workspace: WorkspaceModel
    @ObservationIgnored private var cache: [String: (mtime: Date, size: Int, source: AgendaSource)] = [:]
    @ObservationIgnored private var generation = 0

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    /// Org files directly in each folder (or below it, with `includeSubfolders`), by path, as
    /// Emacs lists a directory in `org-agenda-files`.
    public var files: [String] {
        workspace.files
            // Dotfiles stay out, as `org-agenda-file-regexp` leaves them out.
            .filter { $0.kind == .org && !$0.name.hasPrefix(".") && (includeSubfolders || !$0.relativePath.contains("/")) }
            .map(\.path)
            .sorted()
    }

    /// Recomputes the days. `open` is the open buffers' text by path.
    public func refresh(open: [String: String], now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let id = generation
        isComputing = true
        let today = Days.absolute(now, calendar: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        var span = self.span
        var startOffset = self.startOffset
        if case .agenda(let viewSpan, let viewStart) = mode {
            span = viewSpan ?? span
            startOffset = viewStart ?? startOffset
        }
        let first = start ?? today + startOffset
        let options = self.options
        let mode = self.mode
        let provider = calendarEvents
        let names = calendarNames
        let all = await sources(open: open)
        let result = await Task.detached {
            var days: [AgendaDay] = []
            var list: [AgendaItem] = []
            var events: [AgendaEvent] = []
            switch mode {
            case .agenda:
                days = Agenda.list(all, start: first, days: span, today: today, now: (clock.hour ?? 0, clock.minute ?? 0), options: options)
                if let provider {
                    let from = Self.date(first, calendar: calendar)
                    events = provider.events(from: from, to: Self.date(first + span, calendar: calendar), chosen: names)
                }
            case .todo(let keywords):
                list = Agenda.todoList(all, keywords: keywords, options: options)
            case .match(let match, let todoOnly):
                list = Agenda.tagsMatch(all, match: match, todoOnly: todoOnly, now: now, calendar: calendar, options: options)
            case .search(let string, let todoOnly):
                list = Agenda.textSearch(all, string: string, todoOnly: todoOnly, options: options)
            }
            return (days, list, events)
        }.value
        guard id == generation else { return }
        days = result.0
        list = result.1
        events = result.2
        self.today = today
        self.calendar = calendar
        isComputing = false
    }

    /// Reminders for the timed entries of the next `days` days.
    public func reminders(open: [String: String], now: Date = Date(), calendar: Calendar = .current, days: Int = 7, lead: Int = 12) async -> [Reminder] {
        let all = await sources(open: open)
        return await Task.detached { Reminders.upcoming(all, now: now, calendar: calendar, days: days, lead: lead) }.value
    }

    /// Entries for the table and kanban views, and the keywords their files use.
    public func board(open: [String: String], match: String) async -> (entries: [BoardEntry], keywords: [String]) {
        let all = await sources(open: open)
        return await Task.detached { (Board.entries(all, match: match), Board.keywords(all)) }.value
    }

    /// The agenda files' sources: the open file's from its text, the others from the cache
    /// while their modification date and size are unchanged.
    private func sources(open: [String: String]) async -> [AgendaSource] {
        let defaults = workspace.settings.org
        let blocking = options.dimBlockedTasks != .off && (options.enforceTodoDependencies || options.enforceTodoCheckboxDependencies)
        var reads: [(path: String, cached: AgendaSource?, mtime: Date, size: Int, text: String?)] = []
        for path in files {
            if let text = open[path] {
                reads.append((path, nil, .distantPast, -1, text))
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = attributes?[.modificationDate] as? Date ?? .distantPast
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            // A file reading setup files is read again: they may have changed.
            let cached = cache[path].flatMap { $0.mtime == mtime && $0.size == size && !$0.source.readsSetupFiles && $0.source.checksBlocking == blocking ? $0.source : nil }
            reads.append((path, cached, mtime, size, nil))
        }
        let loaded = await Task.detached {
            var sources: [(path: String, mtime: Date, size: Int, source: AgendaSource, fromDisk: Bool)] = []
            for read in reads {
                if let cached = read.cached {
                    sources.append((read.path, read.mtime, read.size, cached, true))
                } else if let text = read.text {
                    sources.append((read.path, read.mtime, read.size, AgendaSource(path: read.path, text: text, defaults: defaults.resolvingSetupFiles(in: text, path: read.path, read: OrgSettings.readFile), checksBlocking: blocking), false))
                } else if let data = FileManager.default.contents(atPath: read.path) {
                    let text = SourceText(bytes: [UInt8](data)).text
                    sources.append((read.path, read.mtime, read.size, AgendaSource(path: read.path, text: text, defaults: defaults.resolvingSetupFiles(in: text, path: read.path, read: OrgSettings.readFile), checksBlocking: blocking), true))
                }
            }
            return sources
        }.value
        for source in loaded where source.fromDisk {
            cache[source.path] = (source.mtime, source.size, source.source)
        }
        return loaded.map(\.source)
    }

    /// The days as rows with the events, empty days hidden unless `showAllDates`; see
    /// `AgendaRows.groups`.
    public func groups(showAllDates: Bool = false, keep: (AgendaItem) -> Bool = { _ in true }) -> [AgendaDayGroup] {
        AgendaRows.groups(days, events: events, today: today, showAllDates: showAllDates, calendar: calendar, keep: keep)
    }

    nonisolated static func date(_ day: Int, calendar: Calendar) -> Date {
        let d = Days.date(day)
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }

    public func showToday() { start = nil }

    /// Moves the view by a whole span, forward or back.
    public func shift(forward: Bool, now: Date = Date(), calendar: Calendar = .current) {
        var span = self.span
        var startOffset = self.startOffset
        if case .agenda(let viewSpan, let viewStart) = mode {
            span = viewSpan ?? span
            startOffset = viewStart ?? startOffset
        }
        let current = start ?? Days.absolute(now, calendar: calendar) + startOffset
        start = current + (forward ? span : -span)
    }
}
