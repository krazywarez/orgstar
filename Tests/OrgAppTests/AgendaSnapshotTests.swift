import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct AgendaSnapshotTests {
    static let file = """
        #+CATEGORY: life
        * TODO [#A] Send forms
        DEADLINE: <2026-10-02 Fri>
        * TODO Water plants
        SCHEDULED: <2026-10-05 Mon>
        * DONE Took out bins
        SCHEDULED: <2026-10-05 Mon>
        * Standup
        SCHEDULED: <2026-10-05 Mon 08:00>
        * Dentist <2026-10-05 Mon 13:50-14:30>
        * NEXT Call the bank
        SCHEDULED: <2026-10-06 Tue 09:30>
        * Yesterday's note <2026-10-04 Sun>
        * Far off <2026-10-20 Tue>
        """

    static let today = Days.absolute(year: 2026, month: 10, day: 5)
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: Double((day - 719163) * 86400 + hour * 3600 + minute * 60))
    }

    /// The agenda from three days before today for three weeks, as the app's view may be.
    static func snapshot() -> AgendaSnapshot {
        let source = AgendaSource(path: "/notes/life.org", text: file, defaults: OrgSettings.default.withTodoKeywords("TODO NEXT | DONE")!)
        let days = Agenda.list([source], start: today - 3, days: 21, today: today, now: (10, 0))
        let event = AgendaEvent(
            id: "e1", title: "Lunch", calendarID: "c", calendarTitle: "Home", color: RGBA(hex: "#336699"),
            start: date(today, 12), end: date(today, 13), isAllDay: false
        )
        let groups = AgendaRows.groups(days, events: [event], today: today, calendar: utc)
        return AgendaSnapshot(groups: groups, today: today, theme: .default, generated: date(today, 10), calendar: utc)
    }

    @Test func holdsTodayAndTheNextDaysOnly() {
        let snapshot = Self.snapshot()
        #expect(snapshot.days.map(\.day) == [Self.today, Self.today + 1])
        let today = snapshot.days[0]
        #expect(today.date == Self.date(Self.today, 0))
        #expect(today.overdue.map(\.title) == ["Send forms"])
        #expect(today.rows.map(\.title) == ["Standup", "Lunch", "Dentist", "Water plants", "Took out bins"])
        #expect(snapshot.days[1].rows.map(\.title) == ["Call the bank"])
    }

    @Test func rowsCarryTimesLinksAndColors() throws {
        let snapshot = Self.snapshot()
        let rows = snapshot.days[0].rows + snapshot.days[0].overdue
        let dentist = try #require(rows.first { $0.title == "Dentist" })
        #expect(dentist.gutter == "13:50–14:30")
        #expect(dentist.start == Self.date(Self.today, 13, 50))
        #expect(dentist.end == Self.date(Self.today, 14, 30))
        #expect(dentist.path == "/notes/life.org")
        #expect(dentist.link == .entry(path: "/notes/life.org", offset: dentist.offset!))
        let forms = try #require(rows.first { $0.title == "Send forms" })
        #expect(forms.status == "overdue")
        #expect(forms.todo == "TODO")
        #expect(forms.priority == "A")
        #expect(forms.todoColor == .init(light: "#d70015", dark: "#ff6961"))
        #expect(forms.priorityColor == .init(light: "#d70015", dark: "#ff6961"))
        #expect(forms.statusColor == .init(light: "#d70015", dark: "#ff6961"))
        let lunch = try #require(rows.first { $0.title == "Lunch" })
        #expect(lunch.isEvent && lunch.link == nil)
        #expect(lunch.categoryColor == .init(light: "#336699", dark: "#336699"))
        #expect(snapshot.colors["agenda-today"] == .init(light: "#007aff", dark: "#0a84ff"))
        #expect(snapshot.colors["agenda-background"] == nil)
    }

    @Test func encodesAndDecodes() throws {
        let snapshot = Self.snapshot()
        let data = try AgendaSnapshot.encoder.encode(snapshot)
        #expect(try AgendaSnapshot.decoder.decode(AgendaSnapshot.self, from: data) == snapshot)
    }

    @Test func writesOnlyWhatChanged() throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("Widgets/agenda.json")
        var snapshot = Self.snapshot()
        #expect(try snapshot.write(to: file))
        #expect(AgendaSnapshot.read(from: file) == snapshot)
        snapshot.generated = snapshot.generated.addingTimeInterval(60)
        #expect(try !snapshot.write(to: file))
        snapshot.days.removeLast()
        #expect(try snapshot.write(to: file))
        #expect(AgendaSnapshot.read(from: file)?.days.count == 1)
    }

    @Test func whatIsLeftOfToday() {
        let snapshot = Self.snapshot()
        let morning = Self.date(Self.today, 7)
        #expect(snapshot.upcoming(at: morning, calendar: Self.utc).map(\.title) == ["Standup", "Lunch", "Dentist", "Water plants", "Send forms"])
        #expect(snapshot.upcoming(at: Self.date(Self.today, 14), calendar: Self.utc).map(\.title) == ["Dentist", "Water plants", "Send forms"])
        #expect(snapshot.openCount(at: morning, calendar: Self.utc) == 4)
        #expect(snapshot.overdueCount(at: morning, calendar: Self.utc) == 1)
        #expect(snapshot.day(after: morning, calendar: Self.utc)?.day == Self.today + 1)
        #expect(snapshot.upcoming(at: Self.date(Self.today + 3, 9), calendar: Self.utc) == [])
        #expect(snapshot.changes(after: Self.date(Self.today, 12, 30), calendar: Self.utc) == [
            Self.date(Self.today, 13, 1), Self.date(Self.today, 14, 31), Self.date(Self.today + 1, 0),
        ])
    }

    @Test func linksRoundTrip() {
        for link in [AppLink.agenda, .clock, .entry(path: "/notes/a b&c+d/ünï.org", offset: 42)] {
            #expect(AppLink(url: link.url) == link)
        }
        #expect(AppLink.agenda.url.absoluteString == "orgstar://agenda")
        #expect(AppLink(url: URL(string: "org-protocol://capture?body=x")!) == nil)
        #expect(AppLink(url: URL(string: "orgstar://entry?path=/a.org")!) == nil)
    }
}
