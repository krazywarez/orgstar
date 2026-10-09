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
