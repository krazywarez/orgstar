import CoreGraphics
import EventKit
import Foundation
import OrgCore
import OrgPresentation

/// What the agenda reads from a calendar event: `EKEvent`, or a value made in tests.
public protocol CalendarEventRecord {
    var recordID: String { get }
    var recordTitle: String { get }
    var recordStart: Date { get }
    var recordEnd: Date { get }
    var recordIsAllDay: Bool { get }
    var recordLocation: String? { get }
    var recordCalendarID: String { get }
    var recordCalendarTitle: String { get }
    var recordCalendarColor: CGColor? { get }
}

extension EKEvent: CalendarEventRecord {
    /// A repeating event's occurrences share an identifier; the start tells them apart.
    public var recordID: String { (eventIdentifier ?? calendarItemIdentifier) + "@" + String(Int(startDate.timeIntervalSince1970)) }
    public var recordTitle: String { title ?? "" }
    public var recordStart: Date { startDate }
    public var recordEnd: Date { endDate }
    public var recordIsAllDay: Bool { isAllDay }
    public var recordLocation: String? { location.flatMap { $0.isEmpty ? nil : $0 } }
    public var recordCalendarID: String { calendar?.calendarIdentifier ?? "" }
    public var recordCalendarTitle: String { calendar?.title ?? "" }
    public var recordCalendarColor: CGColor? { calendar?.cgColor }
}

/// Read-only events from the system Calendar for the agenda (`calendar-events` in
/// config.toml), from the calendars `calendar-event-calendars` names.
public final class CalendarEvents: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    /// Reading events needs full access; EventKit has no read-only level.
    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for access once; later calls answer with what the person chose.
    public func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The event calendars, for choosing among them.
    public func calendars() -> [(id: String, title: String, color: RGBA?)] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .event).map { ($0.calendarIdentifier, $0.title, $0.cgColor.flatMap(Self.rgba)) }
    }

    /// Events overlapping `start..<end` in the chosen calendars (all when `chosen` is empty),
    /// by start. None without access.
    public func events(from start: Date, to end: Date, chosen: [String]) -> [AgendaEvent] {
        guard Self.isAuthorized else { return [] }
        let calendars = store.calendars(for: .event).filter { Self.chooses(id: $0.calendarIdentifier, title: $0.title, chosen: chosen) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.event).sorted { $0.start < $1.start }
    }

    /// Whether a calendar is among those chosen by identifier or title; every calendar is when
    /// none are.
    public static func chooses(id: String, title: String, chosen: [String]) -> Bool {
        chosen.isEmpty || chosen.contains(id) || chosen.contains(title)
    }

    public static func event(_ record: some CalendarEventRecord) -> AgendaEvent {
        AgendaEvent(
            id: record.recordID, title: record.recordTitle, calendarID: record.recordCalendarID, calendarTitle: record.recordCalendarTitle,
            color: record.recordCalendarColor.flatMap(rgba), start: record.recordStart, end: record.recordEnd,
            isAllDay: record.recordIsAllDay, location: record.recordLocation
        )
    }

    /// A color in sRGB.
    static func rgba(_ color: CGColor) -> RGBA? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        return RGBA(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(converted.alpha))
    }
}

/// An event's fields while it is edited or made.
public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    /// The calendar it goes in; empty for the default calendar for new events.
    public var calendarID: String

    public init(title: String, start: Date, end: Date, isAllDay: Bool, location: String = "", calendarID: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendarID = calendarID
    }

    public init(_ event: AgendaEvent) {
        self.init(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                  location: event.location ?? "", calendarID: event.calendarID)
    }

    /// An agenda entry on `day` as an event: at its time (`start` and `end` as `hhmm`), an
    /// hour long when it has no end, or all day without a time. An all-day event's dates are
    /// its first and last day.
    public static func entry(_ title: String, day: Int, start: Int?, end: Int?, calendar: Calendar = .current) -> EventDraft {
        let d = Days.date(day)
        let midnight = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
        guard let start else {
            return EventDraft(title: title, start: midnight, end: midnight, isAllDay: true)
        }
        func at(_ hhmm: Int) -> Date { calendar.date(bySettingHour: hhmm / 100, minute: hhmm % 100, second: 0, of: midnight) ?? midnight }
        let from = at(start)
        var to = end.map(at) ?? from.addingTimeInterval(3600)
        if to <= from { to = from.addingTimeInterval(3600) }
        return EventDraft(title: title, start: from, end: to, isAllDay: false)
    }
}

extension CalendarEvents {
    /// The calendars events can be added to or changed in.
    public func writableCalendars() -> [(id: String, title: String, color: RGBA?)] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .map { ($0.calendarIdentifier, $0.title, $0.cgColor.flatMap(Self.rgba)) }
    }

    /// The calendar new events go in.
    public var defaultCalendarID: String { store.defaultCalendarForNewEvents?.calendarIdentifier ?? "" }

    public enum SaveError: Error, CustomStringConvertible {
        case noAccess, gone, noCalendar, failed(String)

        public var description: String {
            switch self {
            case .noAccess: "orgstar may not change your calendars."
            case .gone: "The event is no longer in Calendar."
            case .noCalendar: "Choose a calendar."
            case .failed(let message): message
            }
        }
    }

    /// Writes `draft` into the event `replacing` (only that occurrence of a repeating event), or
    /// as a new event. Returns the event's agenda identifier.
    @discardableResult
    public func save(_ draft: EventDraft, replacing event: AgendaEvent? = nil) throws -> String {
        guard Self.isAuthorized else { throw SaveError.noAccess }
        let target: EKEvent
        if let event {
            let predicate = store.predicateForEvents(withStart: event.start.addingTimeInterval(-1), end: event.end.addingTimeInterval(1), calendars: nil)
            guard let found = store.events(matching: predicate).first(where: { $0.recordID == event.id }) else { throw SaveError.gone }
            target = found
        } else {
            target = EKEvent(eventStore: store)
        }
        let calendarID = draft.calendarID.isEmpty ? defaultCalendarID : draft.calendarID
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw SaveError.noCalendar }
        target.calendar = calendar
        target.title = draft.title
        target.isAllDay = draft.isAllDay
        // EventKit takes an all-day event's days from the dates.
        target.startDate = draft.isAllDay ? Calendar.current.startOfDay(for: draft.start) : draft.start
        target.endDate = max(draft.isAllDay ? Calendar.current.startOfDay(for: draft.end) : draft.end, target.startDate)
        target.location = draft.location.isEmpty ? nil : draft.location
        do {
            try store.save(target, span: .thisEvent, commit: true)
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
        return target.recordID
    }
}

extension CalendarEvents {
    /// Whether the event repeats, so that a change applies to one occurrence.
    public func isRepeating(_ event: AgendaEvent) -> Bool {
        guard Self.isAuthorized else { return false }
        let predicate = store.predicateForEvents(withStart: event.start.addingTimeInterval(-1), end: event.end.addingTimeInterval(1), calendars: nil)
        return store.events(matching: predicate).first { $0.recordID == event.id }?.hasRecurrenceRules ?? false
    }
}
