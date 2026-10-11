import Foundation
import Testing
@testable import OrgCore

/// `org-agenda-skip-entry-if` and `org-agenda-skip-subtree-if` against Emacs.
struct AgendaSkipTests {
    static let today = Days.absolute(year: 2026, month: 10, day: 5)
    static let file = """
    * TODO Parent :work:
    SCHEDULED: <2026-10-05 Mon>
    ** TODO Child one
    DEADLINE: <2026-10-06 Tue>
    ** WAIT Child two
    <2026-10-05 Mon 10:00>
    Mentions IGNORE here.
    *** NEXT Grandchild
    SCHEDULED: <2026-10-04 Sun>
    * DONE Finished
    CLOSED: [2026-10-05 Mon 09:00]
    <2026-10-05 Mon 12:00>
    * HOLD Plain :home:
    Some text with a <2026-10-07 Wed> timestamp.
    * IDEA Range
    <2026-10-04 Sun>--<2026-10-06 Tue>
    * TODO Waiting for IGNORE
    DEADLINE: <2026-10-05 Mon>
    ** TODO Under ignore
    SCHEDULED: <2026-10-05 Mon 15:00>
    * Sexp
    <%%(diary-float t 1 1)>

    """

    static let conditions = [
        "'scheduled", "'notscheduled", "'deadline", "'notdeadline", "'timestamp", "'nottimestamp",
        "'regexp \"IGNORE\"", "'notregexp \"IGNORE\"", "'todo '(\"WAIT\" \"NEXT\")", "'nottodo '(\"TODO\")",
        "'todo 'done", "'nottodo 'todo", "'todo 'any", "'todo '(\"*\")", "'scheduled 'deadline",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func skipsLikeOrg() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double((Self.today - 719163) * 86400 + 9 * 3600 + 30 * 60))
        let defaults = OrgSettings.default.withTodoKeywords(AgendaOracle.keywords)!
        let files = [("s.org", Self.file)]
        for subtree in [false, true] {
            for condition in Self.conditions {
                let skip = try AgendaSkip.parse(condition, subtree: subtree).get()
                let fn = "'(org-agenda-skip-\(subtree ? "subtree" : "entry")-if \(condition))"
                var options = AgendaOptions()
                options.skip = skip
                for (form, ours) in [
                    ("(org-todo-list nil)", { (s: [AgendaSource]) in Agenda.todoList(s, options: options, today: Self.today) }),
                    ("(org-tags-view nil \"LEVEL>0\")", { Agenda.tagsMatch($0, match: "LEVEL>0", now: now, calendar: utc, options: options) }),
                    ("(org-search-view nil \"e\")", { Agenda.textSearch($0, string: "e", options: options) }),
                ] {
                    try AgendaOracle.compareList(files: files, form: "(let ((org-agenda-skip-function \(fn))) \(form))", today: Self.today, ours)
                }
                let form = "(let ((org-agenda-skip-function \(fn)) (org-agenda-start-with-log-mode t)) (org-agenda-list nil \"2026-10-04\" 3))"
                let emacs = try AgendaOracle.run(files: files, form: form, today: Self.today, hour: 9, minute: 30)
                var dayOptions = AgendaOptions.terminal
                dayOptions.skip = skip
                dayOptions.logMode = true
                let days = Agenda.list([AgendaSource(path: "s.org", text: Self.file, defaults: defaults)], start: Self.today - 1, days: 3,
                                       today: Self.today, now: (9, 30), options: dayOptions)
                #expect(days.count == emacs.count)
                for (o, e) in zip(days, emacs) {
                    #expect(AgendaOracle.describe(o.items, today: Self.today) == AgendaOracle.describe(e.items), "\(fn) \(e.header)")
                }
            }
        }
    }

    @Test func parsesAndWrites() throws {
        let skip = try AgendaSkip.parse("'scheduled 'regexp \"\\\\<A\\\"B\" 'nottodo '(\"DONE\" \"KILL\") 'todo done", subtree: true).get()
        #expect(skip.conditions == [.scheduled, .regexp("\\<A\"B"), .notTodo(.list(["DONE", "KILL"])), .todo(.done)])
        #expect(try AgendaSkip.parse(skip.lisp, subtree: true).get() == skip)
        #expect(throws: AgendaSkip.Failure.self) { try AgendaSkip.parse("'level 2", subtree: false).get() }
    }
}
