import CoreGraphics
import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct ReminderListsTests {
    struct Record: ReminderRecord {
        var recordID = "r1"
        var recordTitle = "Call the bank"
        var recordDue: DateComponents? = DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30)
        var recordListID = "list-1"
        var recordListTitle = "Errands"
        var recordListColor: CGColor? = CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func recordsBecomeAgendaEvents() throws {
        let event = try #require(ReminderLists.event(Record(), calendar: Self.utc))
        #expect(event.isReminder && !event.isAllDay && event.title == "Call the bank" && event.calendarTitle == "Errands")
        #expect(event.start == event.end && Self.utc.dateComponents([.hour, .minute], from: event.start) == DateComponents(hour: 15, minute: 30))
        var untimed = Record()
        untimed.recordDue = DateComponents(year: 2026, month: 10, day: 12)
        #expect(ReminderLists.event(untimed, calendar: Self.utc)?.isAllDay == true)
        var none = Record()
        none.recordDue = nil
        #expect(ReminderLists.event(none, calendar: Self.utc) == nil)
    }

    @Test func remindersGoOnTheirDayAndOverdueOnesToday() throws {
        let calendar = Self.utc
        let timed = try #require(ReminderLists.event(Record(), calendar: calendar))
        var untimedRecord = Record()
        untimedRecord.recordID = "r2"
        untimedRecord.recordDue = DateComponents(year: 2026, month: 10, day: 13)
        let untimed = try #require(ReminderLists.event(untimedRecord, calendar: calendar))
        var lateRecord = Record()
        lateRecord.recordID = "r3"
        lateRecord.recordDue = DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 0)
        let late = try #require(ReminderLists.event(lateRecord, calendar: calendar))
        let today = Days.absolute(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!, calendar: calendar)
        let days = Agenda.list([], start: today, days: 4, today: today, now: (8, 0), options: AgendaOptions())
        let groups = AgendaRows.groups(days, events: [timed, untimed, late], today: today, calendar: calendar)
        let todayGroup = try #require(groups.first { $0.day == today })
        #expect(todayGroup.overdue.map(\.gutter) == ["2d late"])
        #expect(todayGroup.overdue.first?.status == .overdue && todayGroup.overdue.first?.icon == .reminder)
        let monday = try #require(groups.first { $0.day == today + 1 })
        #expect(monday.rows.map(\.gutter) == ["15:30"] && monday.rows[0].category == "Errands" && monday.rows[0].isEvent)
        let tuesday = try #require(groups.first { $0.day == today + 2 })
        #expect(tuesday.rows.map(\.gutter) == ["Reminder"])
        // The late reminder isn't repeated on the days after today.
        #expect(!groups.contains { $0.day != today && ($0.rows + $0.overdue).contains { $0.title == "Call the bank" && $0.gutter.hasSuffix("late") } })
    }
}
