import Foundation
import Testing
@testable import OrgCore

/// Diary sexps in the agenda (`org-agenda-get-sexps`, diary timestamps and planning).
struct DiarySexpTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let file = """
        #+FILETAGS: :ft:
        * Holidays :hol:
        %%(diary-float t 4 4) Fourth Thursday
        %%(diary-anniversary 10 7 1990) Birthday %d%s
        %%(org-anniversary 2000 10 8) Org %d years
        %%(diary-anniversary 2 29 2000) Leap %d
        %%(diary-block 10 5 2026 10 7 2026) Conference
        %%(diary-cyclic 3 10 1 2026) Every third, %d%s time
        %%(diary-date t 6 t) Sixth of month
        %%(diary-date '(10 11) '(5 9) 2026) List date
        %%(diary-remind '(diary-date 10 9 2026) 2) Remind me
        %%(diary-remind '(diary-date 10 12 2026) -3) Remind range
        %%(diary-remind '(diary-anniversary 10 14 2000) 7) Week ahead %d
        %%(org-class 2026 9 1 2026 12 20 2 41) Class on Tuesdays
        %%(org-block 2026 10 6 2026 10 6) Meeting at 10:30
        %%(memq (calendar-day-of-week date) '(1 3 5)) Gym
        %%(and (= (calendar-extract-day date) 2) "Custom; second part")
        %%(let ((d (calendar-extract-day date))) (when (= (% d 5) 0) (format "Day %d is a fifth" d)))
        %%(diary-float 10 1 -1) Last Monday of October
        %%(diary-float t 0 1 8) First Sunday after the 8th
        %%(diary-date 10 8 2026)
        &%%(diary-date 10 9 2026) Ampersand  
        * TODO Task with a diary stamp <%%(diary-float t 2 1)>
        * Meeting
          <%%(diary-date t 7 t) 14:00>
        * Due
          DEADLINE: <%%(diary-date 10 8 2026)>
        * Sched
          SCHEDULED: <%%(diary-float t 5 1)>
        * COMMENT Skipped tree
        %%(diary-date t t t) Never shown
        """ + "\n"

    @Test func evaluatesDiaryFunctions() throws {
        let day = Days.absolute(year: 2026, month: 10, day: 7)
        func run(_ text: String, _ entry: String = "E") throws -> [String]? {
            DiarySexp.entries(try LispReader.readFirst(text).sexp, entry: entry, day: day)
        }
        #expect(try run("(diary-anniversary 10 7 1990)", "%d%s") == ["36th"])
        #expect(try run("(diary-date 10 8 2026)") == nil)
        #expect(try run("(diary-float 10 3 1)") == ["E"])
        #expect(try run("\"a; b\"") == ["a", "b"])
        #expect(try run("(undefined)") == nil)
        #expect(try run("(diary-ordinal-suffix -3)") == nil)
    }

    @Test func skipsSexpsBeforeTheFirstHeading() {
        let source = AgendaSource(path: "a.org", text: "%%(diary-date t t t) Before\n* H\n%%(diary-date t t t) Under\n")
        let day = Days.absolute(year: 2026, month: 10, day: 7)
        #expect(Agenda.list([source], start: day, days: 1, today: day, now: (9, 0))[0].items.map(\.text) == ["Under"])
    }

    @Test(.enabled(if: oracle))
    func agendaMatchesEmacs() throws {
        let files = [("diary.org", Self.file)]
        let october = Days.absolute(year: 2026, month: 10, day: 1)
        let ours = Agenda.list([AgendaSource(path: "diary.org", text: Self.file)], start: october, days: 15, today: october + 4, now: (9, 30))
        let kinds = Set(ours.flatMap(\.items).map(\.kind))
        #expect(kinds.isSuperset(of: [.sexp, .timestamp, .deadline, .pastScheduled]))
        try AgendaOracle.compare(files: files, start: october, span: 15, today: october + 4)
        try AgendaOracle.compare(files: files, start: october + 20, span: 10, today: october + 26)
        let leap = Days.absolute(year: 2027, month: 2, day: 27)
        try AgendaOracle.compare(files: files, start: leap, span: 4, today: leap)
    }
}
