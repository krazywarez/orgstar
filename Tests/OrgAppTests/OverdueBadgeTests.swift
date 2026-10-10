import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct OverdueBadgeTests {
    static let file = """
        * TODO Send forms
        DEADLINE: <2026-10-02 Fri>
        * TODO Water plants
        SCHEDULED: <2026-10-05 Mon>
        * DONE Took out bins
        SCHEDULED: <2026-10-05 Mon>
        * Standup
        SCHEDULED: <2026-10-05 Mon 08:00>
        * TODO Call the bank
        SCHEDULED: <2026-10-06 Tue 09:30> DEADLINE: <2026-10-08 Thu>
        * TODO Renew passport
        DEADLINE: <2026-10-09 Fri>
        * TODO Stretch
        SCHEDULED: <2026-10-05 Mon .+1d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        * Dentist <2026-10-06 Tue 13:50>
        """

    static let today = Days.absolute(year: 2026, month: 10, day: 5)

    static func groups(today: Int) -> [AgendaDayGroup] {
        let source = AgendaSource(path: "/notes/life.org", text: file, defaults: .default)
        return AgendaRows.groups(Agenda.list([source], start: today, days: 7, today: today, now: (10, 0)), today: today)
    }

    /// The entries in the agenda's own Overdue section on each later day; an entry past both its
    /// scheduled day and its deadline has two rows there.
    @Test func projectsWhatTheAgendaShowsOnLaterDays() {
        let counts = OverdueBadge.counts(Self.groups(today: Self.today), today: Self.today, days: 7)
        let actual = (0..<7).map { k in
            let day = Self.today + k
            let rows = Self.groups(today: day).first { $0.day == day }?.overdue.filter { !$0.isDone && $0.item?.habit == nil } ?? []
            return Set(rows.compactMap { $0.item?.headingOffset }).count
        }
        #expect(counts == actual)
        // Send forms; then Water plants and Standup; Call the bank; Renew passport after the 9th.
        #expect(counts == [1, 3, 4, 4, 4, 5, 5])
    }
}
