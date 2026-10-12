import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct AgendaRowsTests {
    static let file = """
        #+CATEGORY: life
        * TODO [#B] Pay rent [0/2] :home:
        SCHEDULED: <2026-10-01 Thu>
        * TODO Ancient chore
        SCHEDULED: <2025-05-24 Sat>
        * TODO Send forms
        DEADLINE: <2026-10-02 Fri>
        * TODO File taxes
        DEADLINE: <2026-10-05 Mon>
        * TODO Renew passport
        DEADLINE: <2026-10-09 Fri>
        * TODO Water plants
        SCHEDULED: <2026-10-05 Mon>
        * DONE Took out bins
        SCHEDULED: <2026-10-05 Mon>
        * Standup
        SCHEDULED: <2026-10-05 Mon 08:00>
        * Dentist <2026-10-05 Mon 13:50-14:30>
        * Birthday <2026-10-05 Mon>
        * Conference
        <2026-10-04 Sun>--<2026-10-06 Tue>
        * TODO Stretch
        SCHEDULED: <2026-10-04 Sun .+1d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        * Far off
        <2026-10-11 Sun>
        """

    static let today = Days.absolute(year: 2026, month: 10, day: 5)
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func days(start: Int = today, span: Int = 1) -> [AgendaDay] {
        let source = AgendaSource(path: "life.org", text: file, defaults: OrgSettings.default.withTodoKeywords("TODO | DONE")!)
        return Agenda.list([source], start: start, days: span, today: today, now: (10, 0))
    }

    static func rows(day: Int = today) -> [String: AgendaRow] {
        var rows: [String: AgendaRow] = [:]
        for item in days(start: day)[0].items {
            guard let row = AgendaRow(item: item, day: day, today: today) else { continue }
            rows[row.title] = rows[row.title] ?? row
        }
        return rows
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: Double((day - 719163) * 86400 + hour * 3600 + minute * 60))
    }

    @Test func guttersAndStatusesOnToday() {
        let rows = Self.rows()
        func check(_ title: String, _ gutter: String, _ status: AgendaRow.Status, _ icon: AgendaRow.Icon?, sourceLocation: SourceLocation = #_sourceLocation) {
            let row = rows[title]
            #expect(row?.gutter == gutter, "\(title)", sourceLocation: sourceLocation)
            #expect(row?.status == status, "\(title)", sourceLocation: sourceLocation)
            #expect(row?.icon == icon, "\(title)", sourceLocation: sourceLocation)
        }
        check("Pay rent", "4d ago", .overdue, .scheduled)
        check("Ancient chore", "1y 4mo ago", .overdue, .scheduled)
        check("Send forms", "3d late", .overdue, .deadline)
        check("File taxes", "Due today", .dueSoon, .deadline)
        check("Renew passport", "Due in 4d", .dueSoon, .deadline)
        check("Water plants", "Scheduled", .normal, .scheduled)
        check("Took out bins", "Scheduled", .done, .scheduled)
        check("Standup", "08:00", .normal, .scheduled)
        check("Dentist", "13:50–14:30", .normal, .timestamp)
        check("Birthday", "All day", .normal, .timestamp)
        check("Conference", "Day 2/3", .normal, .timestamp)
        check("Stretch", "Habit", .overdue, .habit)
        #expect(rows["Dentist"]?.start == 1350 && rows["Dentist"]?.end == 1430)
        let rent = rows["Pay rent"]!
        #expect(rent.category == "life" && rent.tags == ["home"] && rent.todo == "TODO" && rent.priority == "B" && rent.progress == "0/2")
        #expect(!rent.isEvent && rent.item != nil)
    }

    @Test func logRowsKeepTheDurationAndState() {
        let text = """
            * DONE Write report
            CLOSED: [2026-10-05 Mon 11:00]
            :LOGBOOK:
            - State "DONE"       from "TODO"       [2026-10-05 Mon 11:00]
            CLOCK: [2026-10-05 Mon 09:00]--[2026-10-05 Mon 10:30] =>  1:30
            :END:
            """
        var options = AgendaOptions()
        options.logMode = true
        options.logItems = ["closed", "clock", "state"]
        let source = AgendaSource(path: "w.org", text: text, defaults: OrgSettings.default.withTodoKeywords("TODO | DONE")!)
        let items = Agenda.list([source], start: Self.today, days: 1, today: Self.today, now: (12, 0), options: options)[0].items
        let rows = items.compactMap { AgendaRow(item: $0, day: Self.today, today: Self.today) }
        #expect(rows.first { $0.item?.kind == .clock }?.detail == "1:30")
        #expect(rows.first { $0.item?.kind == .state }?.detail == "DONE")
        #expect(rows.first { $0.item?.kind == .closed }?.detail == nil)
    }

    @Test func guttersOnOtherDays() {
        let later = Self.rows(day: Self.today + 4)
        #expect(later["Renew passport"]?.gutter == "Due" && later["Renew passport"]?.status == .normal)
        let earlier = Self.rows(day: Self.today - 3)
        #expect(earlier["Send forms"]?.gutter == "Due" && earlier["Send forms"]?.status == .overdue)
    }

    @Test func emptyDaysAreHiddenButTodayStays() {
        let days = Self.days(start: Self.today - 1, span: 8)
        let shown = AgendaRows.groups(days, today: Self.today).map(\.day)
        // Sunday has the conference and the habit's first day; Wednesday to Saturday only Friday's deadline.
        #expect(shown == [Self.today - 1, Self.today, Self.today + 1, Self.today + 4, Self.today + 6])
        #expect(AgendaRows.groups(days, today: Self.today, showAllDates: true).count == 8)
        let empty = AgendaRows.groups(days, today: Self.today, keep: { _ in false })
        #expect(empty.map(\.day) == [Self.today] && empty[0].isEmpty && empty[0].isToday)
    }

    @Test func overdueEntriesGroupAboveTodayOldestFirst() {
        let today = AgendaRows.groups(Self.days(), today: Self.today)[0]
        #expect(today.overdue.map(\.title) == ["Ancient chore", "Pay rent", "Send forms"])
        #expect(!today.rows.contains { $0.status == .overdue && $0.icon != .habit })
        #expect(today.rows.contains { $0.title == "Stretch" })
        #expect(Set(today.rows.map(\.id)).count == today.rows.count)
    }

    @Test func eventsMergeByTime() {
        let day = Self.today
        let events = [
            AgendaEvent(id: "a", title: "Coffee", calendarID: "c1", calendarTitle: "Work", color: RGBA(hex: "#ff0000"), start: Self.date(day, 9), end: Self.date(day, 9, 30), isAllDay: false),
            AgendaEvent(id: "b", title: "Holiday", calendarID: "c2", calendarTitle: "Home", color: nil, start: Self.date(day, 0), end: Self.date(day + 1, 0), isAllDay: true),
            AgendaEvent(id: "c", title: "Flight", calendarID: "c1", calendarTitle: "Work", color: nil, start: Self.date(day - 1, 22), end: Self.date(day + 1, 2), isAllDay: false),
            AgendaEvent(id: "d", title: "Lunch", calendarID: "c1", calendarTitle: "Work", color: nil, start: Self.date(day, 13, 50), end: Self.date(day, 14, 30), isAllDay: false),
        ]
        let groups = AgendaRows.groups(Self.days(start: day - 1, span: 3), events: events, today: day, calendar: Self.utc)
        let today = groups.first { $0.isToday }!
        #expect(today.rows.prefix(2).map(\.title) == ["Holiday", "Flight"])
        #expect(today.rows.map(\.gutter).prefix(6) == ["All day", "All day", "08:00", "09:00–09:30", "13:50–14:30", "13:50–14:30"])
        #expect(today.rows[4].title == "Dentist" && today.rows[5].title == "Lunch")
        #expect(today.rows[3].isEvent && today.rows[3].category == "Work" && today.rows[3].color == RGBA(hex: "#ff0000") && today.rows[3].icon == .event)
        let before = groups.first { $0.day == day - 1 }!
        #expect(before.rows.first { $0.title == "Flight" }?.gutter == "22:00")
        let after = groups.first { $0.day == day + 1 }!
        #expect(after.rows.first { $0.title == "Flight" }?.gutter == "Until 02:00")
        // The all-day event ends at midnight: one day only.
        #expect(!after.rows.contains { $0.title == "Holiday" })
    }

    @Test func nowLineGoesAmongTimedRows() {
        let today = AgendaRows.groups(Self.days(), today: Self.today)[0]
        let timed = today.rows.indices.filter { today.rows[$0].start != nil }
        #expect(today.nowIndex(now: 700) == timed[0])
        #expect(today.nowIndex(now: 800) == timed[1])
        #expect(today.nowIndex(now: 1000) == timed[1])
        #expect(today.nowIndex(now: 1500) == timed.last! + 1)
        #expect(AgendaRows.nowIndex([], now: 900) == nil)
        let later = AgendaRows.groups(Self.days(start: Self.today + 4), today: Self.today)[0]
        #expect(later.nowIndex(now: 900) == nil)
    }

    @Test func timedHabitsGoAmongTimedRows() {
        let file = """
            * TODO Lunch
            SCHEDULED: <2026-10-05 Mon 12:00>
            * TODO Medication
            SCHEDULED: <2026-10-05 Mon 20:00>
            * TODO Bathe
            SCHEDULED: <2026-10-05 Mon 18:30 .+1d>
            :PROPERTIES:
            :STYLE: habit
            :END:
            """
        let source = AgendaSource(path: "life.org", text: file, defaults: OrgSettings.default.withTodoKeywords("TODO | DONE")!)
        let days = Agenda.list([source], start: Self.today, days: 1, today: Self.today, now: (10, 0))
        let day = Self.today
        let events = [
            AgendaEvent(id: "a", title: "Call", calendarID: "c1", calendarTitle: "Work", color: nil, start: Self.date(day, 19), end: Self.date(day, 19, 30), isAllDay: false),
        ]
        let today = AgendaRows.groups(days, events: events, today: day, calendar: Self.utc)[0]
        #expect(today.rows.map(\.title) == ["Lunch", "Bathe", "Call", "Medication"])
        #expect(today.nowIndex(now: 1800) == 1)
        #expect(today.nowIndex(now: 1904) == 3)
        #expect(today.grid.first { $0.time == 1800 }?.before == 1)
    }

    @Test func gridLinesGoBeforeLaterRows() {
        let today = AgendaRows.groups(Self.days(), today: Self.today)[0]
        #expect(today.grid.map(\.time) == [800, 1000, 1200, 1400, 1600, 1800, 2000])
        let lines = today.lines(now: 1100)
        // Each grid line comes before the first timed row after its time, entries at the same
        // time first, as `time-up urgency-down` orders them; the rest after the last timed row.
        var last = -1
        for line in lines {
            switch line {
            case .row(let index):
                if let start = today.rows[index].start { #expect(start >= last) ; last = start }
            case .grid(let time): #expect(time >= last); last = time
            case .now: #expect(1100 >= last); last = 1100
            }
        }
        #expect(lines.filter { if case .row = $0 { return true } else { return false } }.count == today.rows.count)
        #expect(lines.contains(.now))
        var options = AgendaOptions()
        options.useTimeGrid = false
        let source = AgendaSource(path: "life.org", text: Self.file, defaults: OrgSettings.default.withTodoKeywords("TODO | DONE")!)
        let plain = AgendaRows.groups(Agenda.list([source], start: Self.today, days: 1, today: Self.today, now: (10, 0), options: options), today: Self.today)[0]
        #expect(plain.grid.isEmpty && plain.nowIndex(now: 1100) == nil)
    }
}

struct AgendaThemeTests {
    @Test func newKeysHaveDefaultsInBothAppearances() {
        for key in ["todo-next", "todo-waiting", "todo-cancelled", "priority-a", "priority-b", "priority-c", "agenda-overdue", "agenda-due-soon", "agenda-event", "agenda-today"] {
            #expect(ThemeSpec.default.light[key] != nil && ThemeSpec.default.dark[key] != nil, "\(key)")
        }
    }

    @Test func keywordClasses() {
        #expect(ThemeSpec.TodoClass.of("TODO", isDone: false) == .todo)
        #expect(ThemeSpec.TodoClass.of("STRT", isDone: false) == .next)
        #expect(ThemeSpec.TodoClass.of("NEXT", isDone: false) == .next)
        #expect(ThemeSpec.TodoClass.of("WAIT", isDone: false) == .waiting)
        #expect(ThemeSpec.TodoClass.of("HOLD", isDone: false) == .waiting)
        #expect(ThemeSpec.TodoClass.of("DONE", isDone: true) == .done)
        #expect(ThemeSpec.TodoClass.of("KILL", isDone: true) == .cancelled)
        #expect(ThemeSpec.TodoClass.of("SKIPPED", isDone: true) == .cancelled)
        // Only done keywords cancel.
        #expect(ThemeSpec.TodoClass.of("SKIPPED", isDone: false) == .todo)
    }

    @Test func colorsResolveOverridesFirst() throws {
        let (spec, problems) = ThemeSpec.reading(try TOML.parse("""
            [theme.todo]
            WAIT = "#010203"
            [theme.category]
            work = "#0a0b0c"
            """))
        #expect(problems.isEmpty)
        #expect(spec.todoColor("WAIT", isDone: false, dark: true)?.hex == "#010203")
        #expect(spec.todoColor("HOLD", isDone: false, dark: true) == ThemeSpec.default.dark["todo-waiting"])
        #expect(spec.todoColor("KILL", isDone: true, dark: false) == ThemeSpec.default.light["todo-cancelled"])
        #expect(spec.categoryColor("work", dark: false).hex == "#0a0b0c" && spec.categoryColor("work", dark: true).hex == "#0a0b0c")
        #expect(spec.priorityColor("A", dark: false) == ThemeSpec.default.light["priority-a"])
        #expect(spec.priorityColor("D", dark: false) == ThemeSpec.default.light["priority"])
        #expect(spec.statusColor(.overdue, dark: true) == ThemeSpec.default.dark["agenda-overdue"])
        let event = AgendaEvent(id: "x", title: "", calendarID: "", calendarTitle: "", color: nil, start: Date(), end: Date(), isAllDay: true)
        #expect(spec.eventColor(event, dark: false) == ThemeSpec.default.light["agenda-event"])
    }

    @Test func categoryHuesAreStable() {
        #expect(ThemeSpec.categoryHue("work") == 264)
        #expect(ThemeSpec.categoryHue("home") == 206)
        #expect(ThemeSpec.default.categoryColor("home", dark: false) == ThemeSpec.default.categoryColor("home", dark: false))
        #expect(ThemeSpec.default.categoryColor("home", dark: false) != ThemeSpec.default.categoryColor("home", dark: true))
        #expect(RGBA(hue: 0, saturation: 1, lightness: 0.5).hex == "#ff0000")
        #expect(RGBA(hue: 240, saturation: 1, lightness: 0.5).hex == "#0000ff")
    }
}
