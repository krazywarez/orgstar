import Foundation
import Testing
@testable import OrgCore

struct AgendaItemTextTests {
    static let file = """
        * TODO [#A] Write the report [1/3] :work:urgent:
        SCHEDULED: <2026-10-01 Thu>
        * WAIT Call [[https://example.com][the bank]] about <2026-10-05 Mon> fees [50%]
        DEADLINE: <2026-10-05 Mon>
        * Plain heading with no keyword :home:
        SCHEDULED: <2026-10-05 Mon 08:00-09:30>
        * DONE [#C]   Spaced    out   title
        SCHEDULED: <2026-10-05 Mon>
        * TODO Renew passport
        DEADLINE: <2026-10-09 Fri>
        * TODO Weekly review
        SCHEDULED: <2026-09-28 Mon +1w>
        """

    static let today = Days.absolute(year: 2026, month: 10, day: 5)

    static func items(on day: Int = today) -> [AgendaItem] {
        let source = AgendaSource(path: "t.org", text: file, defaults: OrgSettings.default.withTodoKeywords("TODO WAIT | DONE KILL")!)
        return Agenda.list([source], start: day, days: 1, today: today, now: (9, 0)).flatMap(\.items).filter { $0.path != nil }
    }

    static func item(_ title: String, on day: Int = today) -> AgendaItem {
        items(on: day).first { $0.title == title && $0.kind != .timestamp }!
    }

    @Test func titlesLeaveOutKeywordPriorityCookiesTimestampsAndTags() {
        let titles = Set(Self.items().map(\.title))
        #expect(titles == ["Write the report", "Call the bank about fees", "Plain heading with no keyword", "Spaced out title", "Renew passport", "Weekly review"])
        let report = Self.item("Write the report")
        #expect(report.extra.hasPrefix("Sched."))
        #expect(report.priorityLetter == "A" && report.progress == "1/3" && report.tags == ["work", "urgent"] && report.todo == "TODO")
        let call = Self.item("Call the bank about fees")
        #expect(call.priorityLetter == nil && call.progress == "50%" && call.todo == "WAIT")
        let done = Self.item("Spaced out title")
        #expect(done.isDone && done.priorityLetter == "C")
        #expect(Self.item("Plain heading with no keyword").todo == nil)
    }

    @Test func planningDaysAreTheTimestampsDays() {
        #expect(Self.item("Write the report").planningDay == Self.today - 4)
        #expect(Self.item("Call the bank about fees").planningDay == Self.today)
        #expect(Self.item("Renew passport").planningDay == Self.today + 4)
        // A repeater's occurrence on a later day.
        #expect(Self.item("Weekly review", on: Self.today + 7).planningDay == Self.today + 7)
        #expect(Self.items().filter { $0.kind == .timestamp }.allSatisfy { $0.planningDay == nil })
    }

    @Test func skipIfDoneLeavesDoneEntriesOutOnTheirDay() {
        let source = AgendaSource(path: "t.org", text: Self.file, defaults: OrgSettings.default.withTodoKeywords("TODO WAIT | DONE KILL")!)
        var options = AgendaOptions()
        #expect(Agenda.list([source], start: Self.today, days: 1, today: Self.today, now: (9, 0), options: options)[0].items.contains { $0.isDone })
        options.skipScheduledIfDone = true
        #expect(!Agenda.list([source], start: Self.today, days: 1, today: Self.today, now: (9, 0), options: options)[0].items.contains { $0.isDone })
    }

    @Test(arguments: [
        (0, "0d"), (3, "3d"), (13, "13d"), (14, "2w"), (59, "8w"), (60, "2mo"), (120, "4mo"), (364, "11mo"),
        (365, "1y"), (499, "1y 4mo"), (730, "2y"), (729, "1y 11mo"), (-3, "3d"),
    ])
    func compactAges(days: Int, text: String) {
        #expect(AgendaAge.compact(days) == text)
    }
}
