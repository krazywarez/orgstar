import CoreGraphics
import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct AgendaSettingsTests {
    @Test func agendaSettingsReadFromConfigToml() throws {
        let defaults = try #require(UserDefaults(suiteName: "orgstar-agenda-settings-\(UUID().uuidString)"))
        #expect(!OrgPreferences.agendaShowAllDates(defaults))
        #expect(!OrgPreferences.agendaSkipScheduledIfDone(defaults) && !OrgPreferences.agendaSkipDeadlineIfDone(defaults))
        #expect(!OrgPreferences.calendarEvents(defaults) && OrgPreferences.calendarEventCalendars(defaults).isEmpty)
        let problems = UserConfig.apply("""
            org-agenda-show-all-dates = true
            org-agenda-skip-scheduled-if-done = true
            org-agenda-skip-deadline-if-done = true
            [orgstar]
            calendar-events = true
            calendar-event-calendars = "Work, Family ,  ,ABC-123"
            """, to: defaults)
        #expect(problems.isEmpty, "\(problems)")
        #expect(OrgPreferences.agendaShowAllDates(defaults))
        #expect(OrgPreferences.calendarEvents(defaults))
        #expect(OrgPreferences.calendarEventCalendars(defaults) == ["Work", "Family", "ABC-123"])
        let options = OrgPreferences.agendaOptions(AgendaOptions(), defaults)
        #expect(options.skipScheduledIfDone && options.skipDeadlineIfDone)
        #expect(UserConfig.template(from: defaults).contains("org-agenda-show-all-dates = true"))
    }
}

struct CalendarEventsTests {
    struct Record: CalendarEventRecord {
        var recordID = "e1@0"
        var recordTitle = "Standup"
        var recordStart = Date(timeIntervalSince1970: 1_791_190_800)
        var recordEnd = Date(timeIntervalSince1970: 1_791_192_600)
        var recordIsAllDay = false
        var recordLocation: String? = "Room 4"
        var recordCalendarID = "cal-1"
        var recordCalendarTitle = "Work"
        var recordCalendarColor: CGColor? = CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
    }

    @Test func recordsBecomeAgendaEvents() {
        let event = CalendarEvents.event(Record())
        #expect(event.id == "e1@0" && event.title == "Standup" && event.calendarTitle == "Work" && event.calendarID == "cal-1")
        #expect(event.color?.hex == "#ff8000" && event.location == "Room 4" && !event.isAllDay)
        var noColor = Record()
        noColor.recordCalendarColor = nil
        #expect(CalendarEvents.event(noColor).color == nil)
    }

    @Test func eventsBecomeRows() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let event = CalendarEvents.event(Record())
        let day = Days.absolute(event.start, calendar: utc)
        let row = AgendaRow(event: event, day: day, calendar: utc)
        #expect(row.gutter == "09:00–09:30" && row.category == "Work" && row.title == "Standup" && row.isEvent && row.icon == .event)
        var allDay = Record()
        allDay.recordIsAllDay = true
        #expect(AgendaRow(event: CalendarEvents.event(allDay), day: day, calendar: utc).gutter == "All day")
    }

    @Test func entriesBecomeEventDrafts() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = Days.absolute(year: 2026, month: 10, day: 12)
        let midnight = utc.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let timed = EventDraft.entry("Standup", day: day, start: 930, end: 1015, calendar: utc)
        #expect(!timed.isAllDay && timed.title == "Standup")
        #expect(timed.start == midnight.addingTimeInterval(9.5 * 3600) && timed.end == midnight.addingTimeInterval(10.25 * 3600))
        let open = EventDraft.entry("Call", day: day, start: 1400, end: nil, calendar: utc)
        #expect(open.end.timeIntervalSince(open.start) == 3600)
        let backwards = EventDraft.entry("Odd", day: day, start: 1400, end: 1300, calendar: utc)
        #expect(backwards.end.timeIntervalSince(backwards.start) == 3600)
        let allDay = EventDraft.entry("Holiday", day: day, start: nil, end: nil, calendar: utc)
        #expect(allDay.isAllDay && allDay.start == midnight && allDay.end == midnight && allDay.calendarID.isEmpty)
        let event = CalendarEvents.event(Record())
        #expect(EventDraft(event) == EventDraft(title: "Standup", start: event.start, end: event.end, isAllDay: false, location: "Room 4", calendarID: "cal-1"))
    }

    @Test func calendarsChosenByTitleOrIdentifier() {
        #expect(CalendarEvents.chooses(id: "x", title: "Work", chosen: []))
        #expect(CalendarEvents.chooses(id: "x", title: "Work", chosen: ["Work"]))
        #expect(CalendarEvents.chooses(id: "x", title: "Work", chosen: ["x"]))
        #expect(!CalendarEvents.chooses(id: "x", title: "Work", chosen: ["Home"]))
    }
}
