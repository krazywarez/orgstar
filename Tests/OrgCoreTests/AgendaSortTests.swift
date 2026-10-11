import Foundation
import Testing
@testable import OrgCore

/// `org-agenda-sorting-strategy` against Emacs.
struct AgendaSortTests {
    static let today = Days.absolute(year: 2026, month: 10, day: 5)

    static let files = [
        ("a.org", """
        #+CATEGORY: alpha
        * TODO [#B] write report :work:
        SCHEDULED: <2026-10-05 Mon 14:00>
        :PROPERTIES:
        :Effort: 1:30
        :END:
        * WAIT [#A] Call Bob :phone:
        DEADLINE: <2026-10-07 Wed>
        * TODO Buy milk :home:errand:
        SCHEDULED: <2026-10-03 Sat>
        :PROPERTIES:
        :Effort: 0:10
        :END:
        * HOLD zebra notes
        <2026-10-05 Mon 09:00>
        [2026-09-01 Tue]
        * TODO [#C] apples
        DEADLINE: <2026-10-05 Mon 11:00>
        :PROPERTIES:
        :Effort: 2:00
        :END:

        """),
        ("b.org", """
        #+CATEGORY: beta
        * IDEA Mango :work:
        SCHEDULED: <2026-10-05 Mon>
        * TODO [#A] banana
        <2026-10-06 Tue 08:00>
        [2026-08-15 Sat]
        * STRT Kiwi :home:
        DEADLINE: <2026-10-04 Sun>
        :PROPERTIES:
        :Effort: 0:45
        :END:
        * DONE cherry
        SCHEDULED: <2026-10-05 Mon 10:00>

        """),
    ]

    static func lisp(_ strategy: [String]) -> String { "(" + strategy.joined(separator: " ") + ")" }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func agendaSortsLikeOrg() throws {
        let strategies: [[String]] = [
            ["time-down", "priority-up", "category-keep"], ["category-up", "alpha-up"], ["category-down", "alpha-down"],
            ["effort-up", "tag-up"], ["effort-down", "tag-down"], ["todo-state-up", "alpha-up"], ["todo-state-down", "alpha-up"],
            ["deadline-up", "scheduled-down", "alpha-up"], ["timestamp-up", "alpha-up"], ["ts-down", "urgency-up"],
            ["category-keep", "alpha-up"], ["habit-up", "priority-down"],
        ]
        for strategy in strategies {
            for late in [true, false] {
                let form = "(let ((org-agenda-sorting-strategy '((agenda . \(Self.lisp(strategy))))) (org-agenda-sort-notime-is-late \(late ? "t" : "nil")) (org-agenda-sort-noeffort-is-high \(late ? "t" : "nil"))) (org-agenda-list nil \"2026-10-04\" 3))"
                let emacs = try AgendaOracle.run(files: Self.files, form: form, today: Self.today, hour: 9, minute: 30)
                let defaults = OrgSettings.default.withTodoKeywords(AgendaOracle.keywords)!
                let sources = Self.files.map { AgendaSource(path: $0.0, text: $0.1, defaults: defaults) }
                var options = AgendaOptions.terminal
                options.sortingStrategy["agenda"] = strategy
                options.sortNotimeIsLate = late
                options.sortNoeffortIsHigh = late
                let ours = Agenda.list(sources, start: Self.today - 1, days: 3, today: Self.today, now: (9, 30), options: options)
                #expect(ours.count == emacs.count)
                for (o, e) in zip(ours, emacs) {
                    #expect(AgendaOracle.describe(o.items, today: Self.today) == AgendaOracle.describe(e.items), "\(strategy) \(late) \(e.header)")
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listsSortLikeOrg() throws {
        let strategies: [[String]] = [
            ["priority-down", "alpha-up"], ["scheduled-up", "alpha-up"], ["deadline-down", "alpha-up"], ["timestamp-up", "alpha-up"],
            ["tsia-up", "alpha-down"], ["ts-up", "alpha-up"], ["todo-state-down", "effort-up"], ["category-keep", "alpha-up"],
            ["tag-down", "category-down"], ["effort-down", "alpha-up"],
        ]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double((Self.today - 719163) * 86400 + 9 * 3600 + 30 * 60))
        for strategy in strategies {
            var options = AgendaOptions()
            for view in ["todo", "tags", "search"] { options.sortingStrategy[view] = strategy }
            let alist = "'((todo . \(Self.lisp(strategy))) (tags . \(Self.lisp(strategy))) (search . \(Self.lisp(strategy))))"
            try AgendaOracle.compareList(files: Self.files, form: "(let ((org-agenda-sorting-strategy \(alist))) (org-todo-list nil))", today: Self.today) {
                Agenda.todoList($0, options: options, today: Self.today)
            }
            try AgendaOracle.compareList(files: Self.files, form: "(let ((org-agenda-sorting-strategy \(alist))) (org-tags-view nil \"work|home\"))", today: Self.today) {
                Agenda.tagsMatch($0, match: "work|home", now: now, calendar: utc, options: options)
            }
            try AgendaOracle.compareList(files: Self.files, form: "(let ((org-agenda-sorting-strategy \(alist))) (org-search-view nil \"a\"))", today: Self.today) {
                Agenda.textSearch($0, string: "a", options: options)
            }
        }
    }
}

/// `org-agenda-time-grid` and `org-agenda-use-time-grid` against Emacs.
struct AgendaTimeGridTests {
    static let file = """
    * Breakfast
    <2026-10-05 Mon 09:00>
    * Lunch
    <2026-10-05 Mon 14:00>
    * Untimed today
    SCHEDULED: <2026-10-05 Mon>
    * Tomorrow untimed
    SCHEDULED: <2026-10-06 Tue>
    * Yesterday timed
    <2026-10-04 Sun 10:30>

    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func gridsLikeOrg() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        let cases: [(use: Bool, when: [String], times: [Int], now: Bool, span: Int, start: Int)] = [
            (true, ["daily", "today", "require-timed"], [800, 1000, 1200, 1400, 1600, 1800, 2000], true, 3, -1),
            (false, ["daily", "today", "require-timed"], [800, 1000], true, 3, -1),
            (true, ["weekly", "require-timed"], [900, 1200], true, 3, -1),
            (true, ["weekly"], [900, 1200], false, 3, -1),
            (true, ["daily", "today", "remove-match"], [900, 1000, 1100, 1400], true, 3, -1),
            (true, ["daily"], [800, 1300], true, 1, 1),
            (true, ["daily", "require-timed"], [800, 1300], true, 1, 1),
            (true, ["today"], [800, 1300], true, 1, 0),
        ]
        for c in cases {
            let date = Days.date(today + c.start)
            let grid = "'((\(c.when.joined(separator: " "))) (\(c.times.map(String.init).joined(separator: " "))) \"......\" \"----------------\")"
            let form = "(let ((org-agenda-use-time-grid \(c.use ? "t" : "nil")) (org-agenda-time-grid \(grid)) (org-agenda-show-current-time-in-grid \(c.now ? "t" : "nil"))) (org-agenda-list nil \"\(String(format: "%04d-%02d-%02d", date.year, date.month, date.day))\" \(c.span)))"
            let emacs = try AgendaOracle.run(files: [("g.org", Self.file)], form: form, today: today, hour: 9, minute: 30)
            let defaults = OrgSettings.default.withTodoKeywords(AgendaOracle.keywords)!
            var options = AgendaOptions.terminal
            options.useTimeGrid = c.use
            options.gridWhen = Set(c.when)
            options.gridTimes = c.times
            options.showCurrentTimeInGrid = c.now
            let ours = Agenda.list([AgendaSource(path: "g.org", text: Self.file, defaults: defaults)], start: today + c.start, days: c.span,
                                   today: today, now: (9, 30), options: options)
            #expect(ours.count == emacs.count)
            for (o, e) in zip(ours, emacs) {
                #expect(AgendaOracle.describe(o.items, today: today) == AgendaOracle.describe(e.items), "\(form) \(e.header)")
            }
        }
    }
}
