import CoreGraphics
import EventKit
import Foundation
import OrgPresentation

/// What the agenda reads from a reminder: `EKReminder`, or a value made in tests.
public protocol ReminderRecord {
    var recordID: String { get }
    var recordTitle: String { get }
    var recordDue: DateComponents? { get }
    var recordListID: String { get }
    var recordListTitle: String { get }
    var recordListColor: CGColor? { get }
}

extension EKReminder: ReminderRecord {
    public var recordID: String { calendarItemIdentifier }
    public var recordTitle: String { title ?? "" }
    public var recordDue: DateComponents? { dueDateComponents }
    public var recordListID: String { calendar?.calendarIdentifier ?? "" }
    public var recordListTitle: String { calendar?.title ?? "" }
    public var recordListColor: CGColor? { calendar?.cgColor }
}

/// Read-only incomplete reminders with a due date from Reminders for the agenda
/// (`agenda-reminders` in config.toml), from the lists `agenda-reminder-lists` names.
public final class ReminderLists: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Asks for access once; later calls answer with what the person chose.
    public func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// The reminder lists, for choosing among them.
    public func lists() -> [(id: String, title: String, color: RGBA?)] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .reminder).map { ($0.calendarIdentifier, $0.title, $0.cgColor.flatMap(CalendarEvents.rgba)) }
    }

    /// Incomplete reminders due before `end` in the chosen lists (all when `chosen` is empty),
    /// by due date. Earlier ones are overdue and show today. None without access.
    public func reminders(before end: Date, chosen: [String], calendar: Calendar = .current) async -> [AgendaEvent] {
        guard Self.isAuthorized else { return [] }
        let lists = store.calendars(for: .reminder).filter { CalendarEvents.chooses(id: $0.calendarIdentifier, title: $0.title, chosen: chosen) }
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: lists)
        let store = store
        let found: [AgendaEvent] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { Self.event($0, calendar: calendar) })
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Nil without a due date.
    public static func event(_ record: some ReminderRecord, calendar: Calendar = .current) -> AgendaEvent? {
        guard let due = record.recordDue, due.year != nil, due.month != nil, due.day != nil else { return nil }
        let timed = due.hour != nil
        var parts = DateComponents(year: due.year, month: due.month, day: due.day, hour: due.hour ?? 0, minute: due.minute ?? 0)
        parts.timeZone = due.timeZone
        guard let date = (due.timeZone.map { zone -> Calendar in var c = calendar; c.timeZone = zone; return c } ?? calendar).date(from: parts)
        else { return nil }
        return AgendaEvent(
            id: record.recordID, title: record.recordTitle, calendarID: record.recordListID, calendarTitle: record.recordListTitle,
            color: record.recordListColor.flatMap(CalendarEvents.rgba), start: date, end: date, isAllDay: !timed, isReminder: true
        )
    }
}
