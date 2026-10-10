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

struct PropertyInheritanceTests {
    static let file = """
        #+PROPERTY: STYLE habit
        * TODO Stretch
        SCHEDULED: <2026-10-05 Mon .+1d>
        * Work
        :PROPERTIES:
        :TEAM: ops
        :END:
        ** TODO Deploy
        """

    static func source(_ inheritance: String) -> AgendaSource {
        var defaults = OrgSettings.default
        defaults.propertyInheritance = .init(inheritance)
        return AgendaSource(path: "/notes/habits.org", text: file, defaults: defaults)
    }

    /// `org-is-habit-p` reads STYLE with selective inheritance: a `#+PROPERTY` line counts only
    /// when `org-use-property-inheritance` covers STYLE, as Emacs 31 does.
    @Test func fileStyleMakesHabitsWhenStyleInherits() {
        #expect(Self.source("nil").habits.isEmpty)
        #expect(Self.source("STYLE").habits.map(\.title) == ["Stretch"])
        #expect(Self.source("t").habits.map(\.title) == ["Stretch"])
        #expect(Self.source("TEAM").habits.isEmpty)
    }

    @Test func matchesSeeInheritedProperties() {
        func titles(_ inheritance: String) -> [String] {
            Agenda.tagsMatch([Self.source(inheritance)], match: "TEAM=\"ops\"").map(\.text)
        }
        #expect(titles("nil").count == 1)
        #expect(titles("TEAM").count == 2)
    }

    @Test func readsTheConfigValue() {
        #expect(SemanticSettings.PropertyInheritance("") == .none)
        #expect(SemanticSettings.PropertyInheritance("nil") == .none)
        #expect(SemanticSettings.PropertyInheritance("t") == .all)
        #expect(SemanticSettings.PropertyInheritance("style  Team") == .only(["STYLE", "TEAM"]))
    }
}
