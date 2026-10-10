import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct WidgetDataTests {
    static let file = """
        * TODO Stretch
        SCHEDULED: <2026-10-05 Mon .+1d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        :LOGBOOK:
        - State "DONE"       from "TODO"       [2026-10-04 Sun 08:00]
        :END:
        * TODO Water plants
        SCHEDULED: <2026-10-05 Mon>
        * DONE Old habit
        SCHEDULED: <2026-10-05 Mon .+1d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        """

    @Test func habitsOfTheFilesWithTheirGraphsAndColors() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        let source = AgendaSource(path: "/notes/life.org", text: Self.file, defaults: .default)
        let habits = source.habits.map { HabitSnapshot.Entry(title: $0.title, path: source.path, offset: $0.offset, habit: $0.habit) }
        let snapshot = HabitSnapshot(habits: habits, theme: .default)
        #expect(snapshot.habits.map(\.title) == ["Stretch"])
        let habit = try #require(snapshot.habits.first)
        #expect(habit.link == .entry(path: "/notes/life.org", offset: 0))
        #expect(habit.habit.graph(today: today).contains { $0.glyph == "*" })
        #expect(Set(snapshot.colors.keys) == ["habit-clear", "habit-ready", "habit-alert", "habit-overdue"])
    }

    @Test func writesOnlyWhatChanged() throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("Widgets/clock.json")
        var clock = ClockSnapshot(running: "Write", startedAt: Date(timeIntervalSince1970: 1_000_000), last: "Read")
        #expect(try clock.write(to: file))
        #expect(ClockSnapshot.read(from: file) == clock)
        #expect(try !clock.write(to: file))
        clock.running = nil
        #expect(try clock.write(to: file))
        #expect(ClockSnapshot.read(from: file)?.running == nil)
    }
}
