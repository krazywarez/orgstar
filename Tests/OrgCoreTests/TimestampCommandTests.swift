import Foundation
import Testing
@testable import OrgCore

struct TimestampCommandTests {
    static let now = ReadDateTests.now
    static let calendar = ReadDateTests.utc

    func run(_ command: any OrgCommand, _ text: String, caret: Int, answer: String? = nil) -> (text: String, caret: Int, failure: String?) {
        let context = EditContext(
            revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret],
            now: Self.now, calendar: Self.calendar, answers: answer.map { ["date": $0] } ?? [:]
        )
        switch command.run(in: context) {
        case .commit(let result):
            let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
            return (new, result.selection?.first?.lowerBound ?? caret, nil)
        case .failed(let message): return (text, caret, message)
        case .prompt(let prompt): return (text, caret, "prompt \(prompt.key)")
        case .external(let request): return (text, caret, "external \(request)")
        }
    }

    @Test func examples() {
        #expect(run(InsertTimestamp(), "x\n", caret: 1, answer: "fri").text == "x<2026-09-11 Fri>\n")
        #expect(run(SetPlanning(deadline: false), "* a\n", caret: 0, answer: "+1").text == "* a\nSCHEDULED: <2026-09-11 Fri>\n")
        #expect(run(ShiftTimestampDay(later: true), "<2026-09-10 Thu>\n", caret: 5).text == "<2026-09-11 Fri>\n")
        #expect(run(ShiftTimestamp(up: true), "<2026-09-10 Thu 10:07>\n", caret: 20).text == "<2026-09-10 Thu 10:10>\n")
    }

    static let texts = [
        "* a\n",
        "* a\nbody <2026-09-01 Tue> text\n",
        "* a\nSCHEDULED: <2026-09-01 Tue +1w>\n",
        "* a\nDEADLINE: <2026-09-20 Sun> SCHEDULED: <2026-09-01 Tue 10:00-11:30>\n",
        "* a\nCLOSED: [2026-09-02 Wed 09:00] SCHEDULED: <2026-09-01 Tue>\n",
        "* a\n[2026-12-31 Thu 23:58] <2026-01-31 Sat .+2m -3d>\n",
        "text <2026-02-28 Sat 07:03>\n",
    ]
    static let answers = ["", "+1", "fri 9:00", "2027-01-15", "10:00-11:00", "++2d"]

    static let commands: [(any OrgCommand, String)] = [
        (InsertTimestamp(), "(org-timestamp nil)"),
        (InsertTimestamp(inactive: true), "(org-timestamp nil t)"),
        (SetPlanning(deadline: false), "(org-schedule nil)"),
        (SetPlanning(deadline: true), "(org-deadline nil)"),
        (RemovePlanning(deadline: false), "(org-schedule '(4))"),
        (ShiftTimestamp(up: true), "(org-timestamp-up)"),
        (ShiftTimestamp(up: false), "(org-timestamp-down)"),
        (ShiftTimestampDay(later: true), "(org-timestamp-up-day)"),
        (ShiftTimestampDay(later: false), "(org-timestamp-down-day)"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func timestampCommandsMatchEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
        for text in Self.texts {
            let tree = OrgParser.parse(text)
            for caret in EmacsOracle.positions(text) {
                for (command, form) in Self.commands {
                    let prompts = command is InsertTimestamp || command is SetPlanning
                    if command is RemovePlanning || command is SetPlanning, entryHeading(at: caret, in: tree) == nil { continue }
                    if command is ShiftTimestamp || command is ShiftTimestampDay, EmacsBuffer(text, point: caret).atTimestamp() == nil { continue }
                    for answer in prompts ? Self.answers : [""] {
                        let escaped = answer.replacingOccurrences(of: "\"", with: "\\\"")
                        let wrapped = frozenClock(1_789_000_000, """
                            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "\(escaped)")))
                              (let ((org-read-date-popup-calendar nil)) \(form)))
                            """)
                        cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: wrapped))
                        let result = run(command, text, caret: caret, answer: prompts ? answer : nil)
                        ours.append(("\(command.id) \(answer.debugDescription) at \(caret) in \(text.debugDescription)", result.text, result.caret, result.failure != nil))
                    }
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let failed = !emacs.error.isEmpty
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard mine.failed != failed || (!failed && (mine.text != emacs.text || mine.caret != caret)) else { continue }
            mismatches += 1
            if mismatches <= 12 {
                Issue.record("\(mine.label)\n  ours:  \(mine.failed ? "failed" : "\(mine.text.debugDescription) @\(mine.caret)")\n  emacs: \(failed ? emacs.error : "\(emacs.text.debugDescription) @\(caret)")")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }

    static let repeating = [
        "* TODO a\nSCHEDULED: <2026-09-01 Tue +1w>\n",
        "* TODO a\nDEADLINE: <2026-09-01 Tue .+1d>\n",
        "* TODO a\nSCHEDULED: <2026-08-01 Sat ++1m>\nbody\n",
        "* TODO a :t:\n<2026-09-08 Tue 10:00 +2d>\n",
        "* TODO a\nDEADLINE: <2026-09-05 Sat +1w> SCHEDULED: <2026-09-01 Tue>\n",
        "* TODO a\nSCHEDULED: <2026-09-01 Tue +1w>\n:PROPERTIES:\n:LAST_REPEAT: [2026-09-01 Tue 08:00]\n:END:\n- State \"DONE\"       from \"TODO\"       [2026-09-01 Tue 08:00]\nnotes\n",
        "#+TODO: TODO STRT | DONE\n* STRT a\nSCHEDULED: <2026-09-01 Tue +1d>\n",
        "* P [0/1]\n** TODO a\nSCHEDULED: <2026-09-01 Tue +1w>\n* Q\n",
        "* TODO no repeat\nSCHEDULED: <2026-09-01 Tue>\n",
        "* TODO hourly\nSCHEDULED: <2026-09-10 Thu 00:00 +1h>\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func repeatsMatchEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int)] = []
        for text in Self.repeating {
            let ns = text as NSString
            let heading = ns.range(of: "\n\\*|^\\*", options: .regularExpression)
            let start = heading.location == 0 ? 0 : heading.location + 1
            let lineEnd = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            for caret in [start, start + 2, lineEnd, min(lineEnd + 3, ns.length)] {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: frozenClock(1_789_000_000, "(progn (org-todo) (when org-log-setup (org-add-log-note)))")))
                let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Self.now, calendar: Self.calendar)
                guard case .commit(let result) = TodoCycle().run(in: context) else {
                    ours.append(("failed at \(caret)", "", -1))
                    continue
                }
                let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                ours.append(("at \(caret) in \(text.debugDescription)", new, result.selection?.first?.lowerBound ?? caret))
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard !emacs.error.isEmpty || mine.text != emacs.text || mine.caret != caret else { continue }
            mismatches += 1
            if mismatches <= 10 {
                let (a, b) = excerpts(mine.text, emacs.text)
                Issue.record("\(mine.label)\n  ours:  \(a.debugDescription) @\(mine.caret)\n  emacs: \(emacs.error.isEmpty ? "\(b.debugDescription) @\(caret)" : emacs.error)")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }
}
